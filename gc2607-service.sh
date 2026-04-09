#!/bin/bash
#
# GC2607 Camera Setup Script
# Called once at boot by systemd gc2607-camera.service (Type=oneshot).
# Sets up the kernel module stack and media pipeline, then exits.
# The sensor is powered on/off on demand by libcamera when an app uses the camera.
#

set -euo pipefail

KVER="$(uname -r)"

log() { echo "[gc2607] $*"; }
die() { echo "[gc2607] ERROR: $*" >&2; exit 1; }

# ── Check if on-disk ipu_bridge contains GCTI2607 ───────────────────
ipu_bridge_has_gc2607() {
    local f
    f=$(modinfo -F filename ipu_bridge 2>/dev/null) || return 1
    if [[ "$f" == *.xz ]]; then
        xz -dc "$f" 2>/dev/null | grep -qa "GCTI2607"
    else
        grep -qa "GCTI2607" "$f" 2>/dev/null
    fi
}

# ── Load Modules ─────────────────────────────────────────────────────
log "Loading kernel modules..."
modprobe videodev    2>/dev/null || true
modprobe v4l2-async  2>/dev/null || true

# Reload ipu_bridge stack if loaded without GC2607 support
if grep -q "^ipu_bridge " /proc/modules && ! ipu_bridge_has_gc2607; then
    log "ipu_bridge missing GC2607 — reloading stack..."
    for mod in gc2607 intel-ipu6-isys intel-ipu6 ipu_bridge; do
        modprobe -r "$mod" 2>/dev/null && log "  unloaded $mod" || true
        sleep 0.3
    done
    sleep 1
fi

if ! grep -q "^ipu_bridge " /proc/modules; then
    modprobe ipu_bridge || die "ipu_bridge load failed. Check: dmesg | tail -20"
fi

if ! ipu_bridge_has_gc2607; then
    die "ipu_bridge loaded but missing GC2607 support. Re-run: sudo ./install.sh"
fi
log "ipu_bridge OK"

modprobe intel-ipu6      2>/dev/null || true
modprobe intel-ipu6-isys 2>/dev/null || true
sleep 2

# Load gc2607 sensor driver
if ! grep -q "^gc2607 " /proc/modules; then
    modprobe gc2607 2>/dev/null || \
        insmod "$(find /lib/modules/${KVER} -name 'gc2607.ko*' | head -1)" || \
        die "gc2607 load failed"
fi

# Wait for udev + async subdev registration
udevadm settle --timeout=10 2>/dev/null || true
sleep 3

# ── Verify media topology ────────────────────────────────────────────
MEDIA_DEV=""
for attempt in 1 2 3 4 5; do
    for dev in /dev/media*; do
        [ -e "$dev" ] || continue
        if media-ctl -d "$dev" --print-topology 2>/dev/null | grep -qi "gc2607"; then
            MEDIA_DEV="$dev"
            break 2
        fi
    done
    log "Topology attempt $attempt/5, waiting 3s..."
    sleep 3
done

if [ -z "$MEDIA_DEV" ]; then
    log "ERROR: GC2607 not in media topology. Diagnostics:"
    lsmod | grep -E "gc2607|ipu_bridge|intel.ipu" || true
    dmesg | grep -i "gc2607\|GCTI2607\|ipu_bridge" | tail -20 || true
    for dev in /dev/media*; do
        [ -e "$dev" ] && media-ctl -d "$dev" --print-topology 2>/dev/null | head -30 || true
    done
    die "GC2607 not in media topology"
fi
log "Sensor found on $MEDIA_DEV"

# ── Configure media pipeline ─────────────────────────────────────────
media-ctl -d "$MEDIA_DEV" \
    -V '"Intel IPU6 CSI2 0":0 [fmt:SGRBG10_1X10/1920x1080]' 2>/dev/null || true
media-ctl -d "$MEDIA_DEV" \
    -V '"Intel IPU6 CSI2 0":1 [fmt:SGRBG10_1X10/1920x1080]' 2>/dev/null || true

CAPTURE_DEV=$(media-ctl -d "$MEDIA_DEV" --print-topology 2>/dev/null \
    | grep -A3 "Intel IPU6 ISYS Capture 0" \
    | grep -o "/dev/video[0-9]*" | head -1) || true

if [ -n "$CAPTURE_DEV" ]; then
    media-ctl -d "$MEDIA_DEV" \
        -l '"Intel IPU6 CSI2 0":1 -> "Intel IPU6 ISYS Capture 0":0[1]' 2>/dev/null || true
    v4l2-ctl -d "$CAPTURE_DEV" \
        --set-fmt-video=width=1920,height=1080,pixelformat=BA10 2>/dev/null || true
    log "Pipeline configured: $CAPTURE_DEV"
else
    log "WARNING: Could not find capture device, pipeline not configured"
fi

# ── Done — sensor is ready, will activate on-demand via libcamera ────
log "GC2607 ready. Camera activates on demand when an app opens it."
