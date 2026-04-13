#!/bin/bash
# Detect and remove extra virtual cameras, keeping only GC2607 on /dev/video50.
#
# Usage:
#   ./gc2607-prune-cameras.sh            # dry-run (default)
#   sudo ./gc2607-prune-cameras.sh --apply

set -euo pipefail

KEEP_DEV="/dev/video50"
KEEP_LABEL="GC2607 Camera"
MODE="${1:---dry-run}"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
log()  { echo -e "${GREEN}[gc2607-prune]${NC} $*"; }
warn() { echo -e "${YELLOW}[gc2607-prune]${NC} $*"; }
die()  { echo -e "${RED}[gc2607-prune] ERROR:${NC} $*" >&2; exit 1; }

need_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

need_root_if_apply() {
    if [ "$MODE" = "--apply" ] && [ "$(id -u)" -ne 0 ]; then
        die "Run with sudo for --apply mode"
    fi
}

is_virtual_cam() {
    local name="$1" dev="$2"
    local lname
    lname=$(echo "$name" | tr '[:upper:]' '[:lower:]')
    if [[ "$lname" == *"virtual"* ]] || [[ "$lname" == *"obs"* ]] || [[ "$lname" == *"loopback"* ]]; then
        return 0
    fi
    # Some virtual cams still expose generic names but are loopback-backed
    local sys_path="/sys/class/video4linux/$(basename "$dev")/device/driver"
    if [ -L "$sys_path" ] && readlink -f "$sys_path" | grep -qi "v4l2loopback"; then
        return 0
    fi
    return 1
}

print_current_devices() {
    echo "Current V4L2 devices:"
    if command -v v4l2-ctl >/dev/null 2>&1; then
        v4l2-ctl --list-devices || true
    else
        warn "v4l2-ctl not found"
    fi
    echo ""
}

collect_extra_virtual_devs() {
    local out=()
    local dev
    for dev_path in /sys/class/video4linux/video*; do
        [ -e "$dev_path/name" ] || continue
        dev="/dev/$(basename "$dev_path")"
        local name
        name=$(cat "$dev_path/name" 2>/dev/null || echo "")
        [ -n "$name" ] || continue

        # Keep the intended camera explicitly.
        if [ "$dev" = "$KEEP_DEV" ] || [ "$name" = "$KEEP_LABEL" ]; then
            continue
        fi

        if is_virtual_cam "$name" "$dev"; then
            out+=("$dev|$name")
        fi
    done

    printf '%s\n' "${out[@]:-}"
}

disable_conflicting_services() {
    if systemctl list-unit-files 2>/dev/null | grep -q "^virtual-webcam.service"; then
        warn "Disabling conflicting virtual-webcam.service"
        systemctl disable --now virtual-webcam.service 2>/dev/null || true
        rm -f /etc/systemd/system/virtual-webcam.service
        systemctl daemon-reload
    fi
}

remove_extra_virtual_devices() {
    local entries=("$@")
    [ "${#entries[@]}" -gt 0 ] || return 0

    if command -v v4l2loopback-ctl >/dev/null 2>&1; then
        local e dev name
        for e in "${entries[@]}"; do
            dev="${e%%|*}"
            name="${e#*|}"
            warn "Removing extra virtual camera: $dev ($name)"
            v4l2loopback-ctl delete "$dev" 2>/dev/null || true
        done
    else
        warn "v4l2loopback-ctl not found; will reset module instead"
    fi
}

enforce_single_gc2607_loopback() {
    log "Enforcing single v4l2loopback camera at ${KEEP_DEV}"

    cat > /etc/modprobe.d/gc2607-v4l2loopback.conf <<'EOF'
# GC2607 ISP output device — fixed single virtual cam at /dev/video50
options v4l2loopback devices=1 video_nr=50 card_label="GC2607 Camera" exclusive_caps=0
EOF

    # Keep deterministic priority over distro defaults (e.g. OBS virtual camera presets)
    cat > /etc/modprobe.d/98-v4l2loopback.conf <<'EOF'
# Override distro defaults for v4l2loopback
options v4l2loopback devices=1 video_nr=50 card_label="GC2607 Camera" exclusive_caps=0
EOF

    systemctl stop gc2607-isp.service 2>/dev/null || true
    modprobe -r v4l2loopback 2>/dev/null || true
    modprobe v4l2loopback devices=1 video_nr=50 card_label="GC2607 Camera" exclusive_caps=0 || \
        die "Failed to load v4l2loopback with GC2607 options"
    systemctl start gc2607-isp.service 2>/dev/null || true
}

main() {
    need_cmd awk
    if [ "$MODE" = "--apply" ]; then
        need_cmd systemctl
        need_cmd modprobe
    fi
    need_root_if_apply

    if [ "$MODE" != "--dry-run" ] && [ "$MODE" != "--apply" ]; then
        die "Unknown mode: $MODE (use --dry-run or --apply)"
    fi

    print_current_devices

    extras=()
    while IFS= read -r line; do
        [ -n "$line" ] && extras+=("$line")
    done < <(collect_extra_virtual_devs)
    if [ "${#extras[@]}" -eq 0 ] || [ -z "${extras[0]:-}" ]; then
        log "No extra virtual cameras detected."
    else
        echo "Detected extra virtual cameras:"
        local e
        for e in "${extras[@]}"; do
            echo "  - ${e%%|*} (${e#*|})"
        done
    fi

    if [ "$MODE" = "--dry-run" ]; then
        log "Dry-run complete. Re-run with --apply to remove extra virtual cameras."
        exit 0
    fi

    disable_conflicting_services
    if [ "${#extras[@]}" -gt 0 ] && [ -n "${extras[0]:-}" ]; then
        remove_extra_virtual_devices "${extras[@]}"
    fi
    enforce_single_gc2607_loopback

    echo ""
    log "Done."
    print_current_devices
}

main "$@"
