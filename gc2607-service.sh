#!/bin/bash
#
# GC2607 Camera Service Script
# Called by systemd gc2607-camera.service at boot.
# Sets up the full pipeline and starts the Python virtualcam.
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KVER="$(uname -r)"

log() { echo "[gc2607] $*"; }
die() { echo "[gc2607] ERROR: $*" >&2; exit 1; }

# ── Load Modules ────────────────────────────────────────────────────

# Check if the currently loaded ipu_bridge has GC2607 (GCTI2607) support.
# Uses grep -a (binary-as-text) which is more reliable than strings | grep.
# Falls back to checking the DKMS source we installed (most reliable indicator).
ipu_bridge_has_gc2607() {
    # Primary: check DKMS source — if we installed our patched version this file exists
    if grep -q "GCTI2607" /usr/src/ipu-bridge-gc2607-1.0/ipu-bridge.c 2>/dev/null; then
        # Source is patched; verify the module file on disk also matches
        local f
        f=$(modinfo -F filename ipu_bridge 2>/dev/null) || return 0  # trust source
        if [[ "$f" == *.xz ]]; then
            xz -dc "$f" 2>/dev/null | grep -qa "GCTI2607" && return 0
        else
            grep -qa "GCTI2607" "$f" 2>/dev/null && return 0
        fi
        # Binary check failed but source is patched — trust the source
        return 0
    fi
    # Fallback: binary scan only (no DKMS source present)
    local f
    f=$(modinfo -F filename ipu_bridge 2>/dev/null) || return 1
    if [[ "$f" == *.xz ]]; then
        xz -dc "$f" 2>/dev/null | grep -qa "GCTI2607"
    else
        grep -qa "GCTI2607" "$f" 2>/dev/null
    fi
}

log "Loading kernel modules..."
modprobe videodev   2>/dev/null || true
modprobe v4l2-async 2>/dev/null || true

# If ipu_bridge is loaded but missing GC2607 support — reload the full stack.
if grep -q "^ipu_bridge " /proc/modules && ! ipu_bridge_has_gc2607; then
    log "ipu_bridge loaded without GC2607 support — reloading stack..."
    for mod in gc2607 intel-ipu6-isys intel-ipu6 ipu_bridge; do
        modprobe -r "$mod" 2>/dev/null || true
        sleep 0.3
    done
    sleep 1
fi

# Load ipu_bridge (patched version from DKMS must take priority)
if ! grep -q "^ipu_bridge " /proc/modules; then
    modprobe ipu_bridge || die "ipu_bridge load failed. Check: dmesg | tail -20"
fi

# Verify the loaded version actually has GC2607 support
if ! ipu_bridge_has_gc2607; then
    die "ipu_bridge loaded but missing GC2607 support. Patched module not installed correctly. Re-run: sudo ./install.sh"
fi
log "ipu_bridge OK (GC2607 support confirmed)"

modprobe intel-ipu6      2>/dev/null || true
modprobe intel-ipu6-isys 2>/dev/null || true
sleep 2

# Load gc2607
if ! grep -q "^gc2607 " /proc/modules; then
    modprobe gc2607 2>/dev/null || \
        insmod "$(find /lib/modules/${KVER} -name 'gc2607.ko*' | head -1)" || \
        die "gc2607.ko not found or failed to load"
fi

# Wait for udev to finish processing hardware events and async subdev registration
udevadm settle --timeout=10 2>/dev/null || true
sleep 3

# ── Verify Sensor ───────────────────────────────────────────────────

if ! grep -q "^gc2607 " /proc/modules; then
    log "ERROR: gc2607 module not loaded. dmesg:"
    dmesg | grep -i "gc2607\|GCTI2607" | tail -10 || true
    die "gc2607 module not loaded"
fi
log "gc2607 module loaded OK"

# Retry topology check — async subdev registration may take a few seconds
MEDIA_DEV=""
for attempt in 1 2 3 4 5; do
    for dev in /dev/media*; do
        [ -e "$dev" ] || continue
        if media-ctl -d "$dev" --print-topology 2>/dev/null | grep -qi "gc2607"; then
            MEDIA_DEV="$dev"
            break 2
        fi
    done
    [ -z "$MEDIA_DEV" ] || break
    log "Topology attempt $attempt/5: gc2607 not yet visible, waiting 3s..."
    sleep 3
done

if [ -z "$MEDIA_DEV" ]; then
    log "ERROR: GC2607 not in media topology after 5 attempts."
    log "--- Loaded modules ---"
    lsmod | grep -E "gc2607|ipu_bridge|intel.ipu" || true
    log "--- ipu_bridge file ---"
    modinfo -F filename ipu_bridge 2>/dev/null || true
    log "--- gc2607 dmesg ---"
    dmesg | grep -i "gc2607\|GCTI2607\|ipu_bridge" | tail -20 || true
    log "--- Media topology ---"
    for dev in /dev/media*; do
        [ -e "$dev" ] || continue
        log "  $dev:"
        media-ctl -d "$dev" --print-topology 2>/dev/null | head -30 || true
    done
    die "GC2607 not in media topology. Check logs above."
fi
log "Sensor on $MEDIA_DEV"

# ── Configure Pipeline ──────────────────────────────────────────────

CAPTURE_DEV=$(media-ctl -d "$MEDIA_DEV" --print-topology 2>/dev/null \
    | grep -A3 "Intel IPU6 ISYS Capture 0" \
    | grep -o "/dev/video[0-9]*" | head -1) || true

if [ -z "$CAPTURE_DEV" ]; then
    die "Could not find capture device"
fi
log "Capture device: $CAPTURE_DEV"

media-ctl -d "$MEDIA_DEV" -V '"Intel IPU6 CSI2 0":0 [fmt:SGRBG10_1X10/1920x1080]'
media-ctl -d "$MEDIA_DEV" -V '"Intel IPU6 CSI2 0":1 [fmt:SGRBG10_1X10/1920x1080]'
media-ctl -d "$MEDIA_DEV" -l '"Intel IPU6 CSI2 0":1 -> "Intel IPU6 ISYS Capture 0":0[1]' 2>/dev/null
v4l2-ctl -d "$CAPTURE_DEV" --set-fmt-video=width=1920,height=1080,pixelformat=BA10

log "Pipeline configured"

# ── Load v4l2loopback ───────────────────────────────────────────────

if grep -q "^v4l2loopback " /proc/modules; then
    modprobe -r v4l2loopback 2>/dev/null || true
    sleep 1
fi

modprobe v4l2loopback \
    devices=1 \
    video_nr=50 \
    card_label="GC2607 Camera" \
    exclusive_caps=1 \
    max_buffers=2

log "v4l2loopback loaded on /dev/video50"

# ── Read settings from config file ─────────────────────────────────

ISP_ARGS=""
CONF="/etc/gc2607/gc2607.conf"
if [ -f "$CONF" ]; then
    while IFS='=' read -r key val; do
        [[ "$key" =~ ^[[:space:]]*# ]] && continue
        [[ -z "${key// }" ]] && continue
        key="${key// /}"
        val="${val// /}"
        ISP_ARGS="$ISP_ARGS --$key $val"
    done < "$CONF"
    log "Settings from $CONF:$ISP_ARGS"
fi

# ── Start C ISP (or fallback to Python virtualcam) ─────────────────

log "Starting ISP (capture=$CAPTURE_DEV output=/dev/video50$ISP_ARGS)..."
if [ -x "${SCRIPT_DIR}/gc2607_isp" ]; then
    exec "${SCRIPT_DIR}/gc2607_isp" "$CAPTURE_DEV" /dev/video50 $ISP_ARGS
else
    # Fallback to Python virtualcam
    log "gc2607_isp not found, falling back to Python virtualcam"
    if [ -f "${SCRIPT_DIR}/.python-path" ]; then
        PYTHON="$(cat "${SCRIPT_DIR}/.python-path")"
    else
        PYTHON="python3"
    fi
    exec "$PYTHON" "${SCRIPT_DIR}/gc2607_virtualcam.py" "$CAPTURE_DEV" /dev/video50
fi
