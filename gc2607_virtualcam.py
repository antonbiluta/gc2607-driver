#!/usr/bin/env python3
"""
GC2607 Virtual Camera - Final Performance & Quality Tune
"""
import sys
import subprocess
import time
import signal
import numpy as np
import pyfakewebcam

# Sensor parameters
WIDTH = 1920
HEIGHT = 1080
FRAME_SIZE = WIDTH * HEIGHT * 2 
BLACK_LEVEL = 48  # Lowered to preserve shadow detail
OUT_W = WIDTH // 2
OUT_H = HEIGHT // 2

# White Balance (Faster but smoother)
WB_SMOOTHING = 0.30
R_OFFSET = 1.05
G_OFFSET = 0.75
B_OFFSET = 1.05

# Auto-exposure (Balanced Target)
AE_TARGET = 85 
AE_SMOOTHING = 0.90

# Sensor limits
EXPOSURE_MIN = 4
EXPOSURE_MAX = 2002
GAIN_MIN = 0
GAIN_MAX = 16

running = True

def create_isp_lut():
    x = np.linspace(0, 1, 1024, dtype=np.float32)
    s_curve = x * x * (3 - 2 * x)
    gamma = np.power(np.clip(s_curve, 0, 1), 1.0 / 2.2)
    return (gamma * 255).astype(np.uint8)

ISP_LUT = create_isp_lut()

# PRE-ALLOCATED BUFFERS (CRITICAL FOR CPU)
# We use one large 3D array for the whole RGB frame to avoid stacking
_rgb_float = np.zeros((OUT_H, OUT_W, 3), dtype=np.float32)
# View references for easier channel access without copying
_r = _rgb_float[:, :, 0]
_g = _rgb_float[:, :, 1]
_b = _rgb_float[:, :, 2]

def signal_handler(sig, frame):
    global running
    running = False

def set_sensor_controls(subdev, exposure, gain):
    exposure = int(np.clip(exposure, EXPOSURE_MIN, EXPOSURE_MAX))
    gain = int(np.clip(gain, GAIN_MIN, GAIN_MAX))
    subprocess.run(['v4l2-ctl', '-d', subdev, '--set-ctrl', f'exposure={exposure},analogue_gain={gain}'], capture_output=True)
    return exposure, gain

def find_sensor_subdev():
    import glob
    for sd in sorted(glob.glob('/dev/v4l-subdev*')):
        result = subprocess.run(['v4l2-ctl', '-d', sd, '--list-ctrls'], capture_output=True, text=True)
        if 'exposure' in result.stdout:
            return sd
    return None

def process_frame(raw_bytes, prev_gains, brightness):
    global _rgb_float, _r, _g, _b
    # Fast read of uint16 Bayer
    bayer = np.frombuffer(raw_bytes, dtype=np.uint16).reshape(HEIGHT, WIDTH)

    # 1. Direct extraction into pre-allocated float buffers
    # Bayer GRBG: [0,0]=G1, [0,1]=R, [1,0]=B, [1,1]=G2
    _r[:,:] = bayer[0::2, 1::2]
    _b[:,:] = bayer[1::2, 0::2]
    
    # Green is average of G1 and G2
    g1 = bayer[0::2, 0::2]
    g2 = bayer[1::2, 1::2]
    np.add(g1, g2, out=_g)
    _g *= 0.5

    # 2. Subtract black level
    _r -= BLACK_LEVEL
    _g -= BLACK_LEVEL
    _b -= BLACK_LEVEL
    
    # Capture raw median for AE loop BEFORE any software gains
    raw_median = np.median(_g[::8, ::8])

    # 3. White Balance Calculation (Gray World)
    r_avg = _r.mean()
    g_avg = _g.mean()
    b_avg = _b.mean()

    r_gain = (g_avg / (r_avg + 1e-6)) * R_OFFSET
    b_gain = (g_avg / (b_avg + 1e-6)) * B_OFFSET
    
    if prev_gains is not None:
        r_gain = WB_SMOOTHING * prev_gains[0] + (1 - WB_SMOOTHING) * r_gain
        b_gain = WB_SMOOTHING * prev_gains[1] + (1 - WB_SMOOTHING) * b_gain

    # 4. Apply Scaling & WB Gains in-place
    # Max sensor is ~959. Scale to [0, 1]
    scale = brightness / 959.0
    _r *= (r_gain * scale)
    _g *= (G_OFFSET * scale)
    _b *= (b_gain * scale)

    # 5. Simple Cross-talk reduction (Slightly desaturate shadows)
    _r -= 0.05 * _g
    _b -= 0.05 * _g
    
    # 6. Apply LUT via fast indexing
    # Clip and map to 0-1023
    rgb_idx = (np.clip(_rgb_float, 0, 1) * 1023).astype(np.uint16)
    rgb_8bit = np.take(ISP_LUT, rgb_idx)
    
    # Rotate 180 (In-place flipping is faster)
    rgb_8bit = np.ascontiguousarray(rgb_8bit[::-1, ::-1])

    return rgb_8bit, (r_gain, b_gain), raw_median

def main():
    global running
    capture_dev = sys.argv[1] if len(sys.argv) > 1 else '/dev/video1'
    output_dev = sys.argv[2] if len(sys.argv) > 2 else '/dev/video50'

    print("GC2607 Virtual Camera (Stability Tune)")
    signal.signal(signal.SIGINT, signal_handler)
    signal.signal(signal.SIGTERM, signal_handler)

    subdev = find_sensor_subdev()
    # Initial defaults: avoid maxing out early
    cur_exposure, cur_gain = 600, 4
    if subdev:
        set_sensor_controls(subdev, cur_exposure, cur_gain)

    try:
        cam = pyfakewebcam.FakeWebcam(output_dev, OUT_W, OUT_H)
    except:
        subprocess.run(['v4l2-ctl', '-d', output_dev, '--set-fmt-video', f'width={OUT_W},height={OUT_H},pixelformat=RGB3'])
        cam = pyfakewebcam.FakeWebcam(output_dev, OUT_W, OUT_H)

    # Start capture with larger buffer for stability
    proc = subprocess.Popen(['v4l2-ctl', '-d', capture_dev, '--stream-mmap', '--stream-count=0', '--stream-to=-'], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, bufsize=FRAME_SIZE*3)

    prev_gains, brightness = None, 1.0
    last_ae = time.monotonic()
    buf = b''

    try:
        while running and proc.poll() is None:
            while len(buf) < FRAME_SIZE:
                chunk = proc.stdout.read(FRAME_SIZE - len(buf))
                if not chunk: break
                buf += chunk
            if not running or len(buf) < FRAME_SIZE: break
            
            frame_data = buf[:FRAME_SIZE]; buf = buf[FRAME_SIZE:]
            rgb, prev_gains, raw_median = process_frame(frame_data, prev_gains, brightness)
            cam.schedule_frame(rgb)

            # Auto-exposure loop: Keep RAW median around a target
            # This adjusts the SOFTWARE gain (brightness) first
            # 90 / 1024 is roughly where we want the raw signal
            target_raw = AE_TARGET * (959.0 / 255.0)
            if raw_median > 0:
                ae_ratio = target_raw / raw_median
                brightness = AE_SMOOTHING * brightness + (1 - AE_SMOOTHING) * (brightness * ae_ratio)
                brightness = np.clip(brightness, 0.5, 3.5)

            now = time.monotonic()
            if subdev and now - last_ae >= 1.5:
                # If software gain is railing, adjust hardware
                if brightness > 2.5 and cur_exposure < EXPOSURE_MAX:
                    cur_exposure = min(int(cur_exposure * 1.4), EXPOSURE_MAX)
                    if cur_exposure == EXPOSURE_MAX and cur_gain < GAIN_MAX:
                        cur_gain = min(cur_gain + 1, GAIN_MAX)
                    set_sensor_controls(subdev, cur_exposure, cur_gain)
                    brightness = 1.0
                elif brightness < 0.8 and cur_exposure > EXPOSURE_MIN:
                    cur_exposure = max(int(cur_exposure * 0.7), EXPOSURE_MIN)
                    if cur_exposure == EXPOSURE_MIN and cur_gain > GAIN_MIN:
                        cur_gain = max(cur_gain - 1, GAIN_MIN)
                    set_sensor_controls(subdev, cur_exposure, cur_gain)
                    brightness = 1.0
                last_ae = now
                
    finally:
        proc.terminate()

if __name__ == '__main__':
    main()
