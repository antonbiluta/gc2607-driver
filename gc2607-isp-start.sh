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
    local cap_entity
    cap_entity=$(media-ctl -d "$mdev" --print-topology 2>/dev/null | \
        sed -n 's/.*"\(Intel IPU6 ISYS Capture[^"]*\)".*/\1/p' | head -1)
    if [ -n "$cap_entity" ]; then
        local node_by_entity
        node_by_entity=$(media-ctl -d "$mdev" -e "$cap_entity" 2>/dev/null || true)
        if [ -n "$node_by_entity" ] && [ -e "$node_by_entity" ]; then
            echo "$node_by_entity"
            return 0
        fi
    fi

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

# ── Ensure v4l2loopback is loaded with correct parameters ──────────────
if ! [ -e "$OUTPUT_DEV" ]; then
    log "Loading v4l2loopback..."
    # Remove stale instance (wrong video_nr) if present
    modprobe -r v4l2loopback 2>/dev/null || true
    sleep 0.5
    if modprobe v4l2loopback video_nr=50 card_label="GC2607 Camera" exclusive_caps=1 2>/dev/null; then
        log "v4l2loopback loaded"
    else
        # modprobe.d may have locked in different params — try without params
        modprobe v4l2loopback 2>/dev/null || die "v4l2loopback failed to load. Install: sudo dnf install v4l2loopback"
    fi
    # Wait briefly for udev to create the node
    for i in $(seq 1 10); do
        [ -e "$OUTPUT_DEV" ] && break
        sleep 1
    done
fi
[ -e "$OUTPUT_DEV" ] || die "$OUTPUT_DEV still not found after loading v4l2loopback (modinfo: $(modinfo -F version v4l2loopback 2>/dev/null || echo 'not installed'))"

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
    die "Could not auto-detect IPU6 capture device for GC2607"
fi
log "Capture device: $CAP_DEV"

# ── Enable IPU6 media link: CSI2 pad1 → ISYS Capture pad0 ──────────────
# The link must be enabled before opening the capture device.
# We set it here once; gc2607_isp keeps it enabled while streaming.
# If already enabled (e.g. after a service restart), the command is a no-op.
CSI_ENTITY=$(media-ctl -d "$MEDIA_DEV" --print-topology 2>/dev/null | \
    sed -n 's/.*"\(Intel IPU6 CSI2 [^"]*\)".*/\1/p' | head -1)
CAP_ENTITY=$(media-ctl -d "$MEDIA_DEV" --print-topology 2>/dev/null | \
    sed -n 's/.*"\(Intel IPU6 ISYS Capture[^"]*\)".*/\1/p' | head -1)
if [ -n "$CSI_ENTITY" ] && [ -n "$CAP_ENTITY" ]; then
    log "Enabling media link: $CSI_ENTITY -> $CAP_ENTITY"
    media-ctl -d "$MEDIA_DEV" \
        -l "\"${CSI_ENTITY}\":1 -> \"${CAP_ENTITY}\":0[1]" 2>/dev/null || true
else
    warn "Could not detect CSI/Capture entities for media link setup (continuing)"
fi

# Also configure the sensor pad format so IPU6 knows what to expect
SENSOR_ENTITY=$(media-ctl -d "$MEDIA_DEV" --print-topology 2>/dev/null | \
    sed -n 's/.*"\([^"]*[Gg][Cc]2607[^"]*\)".*/\1/p' | head -1)
if [ -n "$SENSOR_ENTITY" ]; then
    media-ctl -d "$MEDIA_DEV" \
        --set-v4l2 "\"${SENSOR_ENTITY}\":0[fmt:SGRBG10_1X10/1920x1080]" 2>/dev/null || true
else
    warn "GC2607 sensor entity not found for explicit format set (continuing)"
fi

# ── Set capture pixel format ─────────────────────────────────────────────
v4l2-ctl -d "$CAP_DEV" \
    --set-fmt-video=width=1920,height=1080,pixelformat=BA10 2>/dev/null || \
    warn "Could not set BA10 format on $CAP_DEV (will try anyway)"

# ── Launch ISP ───────────────────────────────────────────────────────────
log "Starting: gc2607_isp $CAP_DEV $OUTPUT_DEV"
exec "${INSTALL_DIR}/gc2607_isp" "$CAP_DEV" "$OUTPUT_DEV"
