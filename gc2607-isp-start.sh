#!/bin/bash
#
# gc2607-isp-start.sh — Locate the IPU6 capture device, enable the media link,
# and exec gc2607_isp.  Called by gc2607-isp.service.
#
# gc2607_isp reads raw Bayer from /dev/videoX (the IPU6 ISYS capture node),
# applies ISP (demosaic, white balance, rotation, AE) and writes YUYV to
# /dev/video50 (v4l2loopback).  Any app can then open /dev/video50.

set -euo pipefail

INSTALL_DIR="/opt/gc2607"
OUTPUT_DEV="/dev/video50"

log()  { echo "[gc2607-isp] $*"; }
warn() { echo "[gc2607-isp] WARN: $*" >&2; }
die()  { echo "[gc2607-isp] ERROR: $*" >&2; exit 1; }

# ── Find the media device that has gc2607 in its topology ──────────────
find_media_dev() {
    for dev in /dev/media*; do
        [ -e "$dev" ] || continue
        if media-ctl -d "$dev" --print-topology 2>/dev/null | grep -qi "gc2607"; then
            echo "$dev"
            return 0
        fi
    done
    return 1
}

# ── Find the V4L2 capture node for "Intel IPU6 ISYS Capture 0" ─────────
find_capture_dev() {
    local mdev="$1"
    # media-ctl -e returns the /dev/videoX path for a named entity
    local node
    node=$(media-ctl -d "$mdev" -e "Intel IPU6 ISYS Capture 0" 2>/dev/null || true)
    if [ -n "$node" ] && [ -e "$node" ]; then
        echo "$node"
        return 0
    fi
    # Fallback: find the first video device that accepts BA10 (SGRBG10) format
    for vdev in /dev/video*; do
        [ -e "$vdev" ] || continue
        if v4l2-ctl -d "$vdev" --get-fmt-video 2>/dev/null | grep -qE "BA10|SGRBG"; then
            echo "$vdev"
            return 0
        fi
    done
    return 1
}

# ── Wait for v4l2loopback output device ────────────────────────────────
log "Waiting for output device $OUTPUT_DEV..."
for i in $(seq 1 15); do
    [ -e "$OUTPUT_DEV" ] && break
    sleep 2
done
[ -e "$OUTPUT_DEV" ] || die "$OUTPUT_DEV not found — is v4l2loopback loaded?"

# ── Wait for IPU6 media device with gc2607 ─────────────────────────────
log "Waiting for gc2607 in media topology..."
MEDIA_DEV=""
for i in $(seq 1 10); do
    MEDIA_DEV=$(find_media_dev) && break
    log "  attempt $i/10..."
    sleep 3
done
[ -n "$MEDIA_DEV" ] || die "gc2607 not found in any media device topology"
log "Media device: $MEDIA_DEV"

# ── Find the capture video node ─────────────────────────────────────────
CAP_DEV=""
CAP_DEV=$(find_capture_dev "$MEDIA_DEV") || true
if [ -z "$CAP_DEV" ]; then
    warn "Could not auto-detect capture device; falling back to /dev/video0"
    CAP_DEV="/dev/video0"
fi
log "Capture device: $CAP_DEV"

# ── Enable IPU6 media link: CSI2 pad1 → ISYS Capture pad0 ──────────────
# The link must be enabled before opening the capture device.
# We set it here once; gc2607_isp keeps it enabled while streaming.
# If already enabled (e.g. after a service restart), the command is a no-op.
log "Enabling media link..."
media-ctl -d "$MEDIA_DEV" \
    -l '"Intel IPU6 CSI2 0":1 -> "Intel IPU6 ISYS Capture 0":0[1]' 2>/dev/null || true

# Also configure the sensor pad format so IPU6 knows what to expect
media-ctl -d "$MEDIA_DEV" \
    --set-v4l2 '"gc2607 5-0037":0[fmt:SGRBG10_1X10/1920x1080]' 2>/dev/null || true

# ── Set capture pixel format ─────────────────────────────────────────────
v4l2-ctl -d "$CAP_DEV" \
    --set-fmt-video=width=1920,height=1080,pixelformat=BA10 2>/dev/null || \
    warn "Could not set BA10 format on $CAP_DEV (will try anyway)"

# ── Launch ISP ───────────────────────────────────────────────────────────
log "Starting: gc2607_isp $CAP_DEV $OUTPUT_DEV"
exec "${INSTALL_DIR}/gc2607_isp" "$CAP_DEV" "$OUTPUT_DEV"
