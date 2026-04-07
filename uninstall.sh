#!/bin/bash
# =============================================================================
# GC2607 Camera Driver Uninstaller
# Usage: sudo ./uninstall.sh
# =============================================================================

set -euo pipefail

KERN=$(uname -r)
STATE_FILE="/var/lib/gc2607-driver/state"
BACKUP_DIR="/var/lib/gc2607-driver/backups"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log()  { echo -e "${GREEN}[gc2607]${NC} $*"; }
warn() { echo -e "${YELLOW}[gc2607]${NC} $*"; }

[ "$(id -u)" -eq 0 ] || { echo "Run with sudo: sudo $0"; exit 1; }

# Read state if available
INSTALL_DIR="/opt/gc2607"
DKMS_GC2607="gc2607/1.0"
DKMS_IPU="ipu-bridge-gc2607/1.0"
if [ -f "$STATE_FILE" ]; then
    # shellcheck disable=SC1090
    source "$STATE_FILE" 2>/dev/null || true
    INSTALL_DIR="${install_dir:-$INSTALL_DIR}"
    DKMS_GC2607="${dkms_gc2607:-$DKMS_GC2607}"
    DKMS_IPU="${dkms_ipu:-$DKMS_IPU}"
fi

log "GC2607 Camera Driver Uninstaller"
log "Kernel: $KERN"

# ── Stop service ───────────────────────────────────────────────────────
log "Stopping service..."
systemctl stop gc2607-camera.service 2>/dev/null || true
systemctl disable gc2607-camera.service 2>/dev/null || true
rm -f /etc/systemd/system/gc2607-camera.service
systemctl daemon-reload

# ── Unload modules ─────────────────────────────────────────────────────
log "Unloading modules..."
for mod in gc2607 intel-ipu6-isys intel-ipu6; do
    modprobe -r "$mod" 2>/dev/null || true
done
# Reload original ipu_bridge before removing DKMS entry
modprobe -r ipu_bridge 2>/dev/null || true

# ── Remove DKMS modules ────────────────────────────────────────────────
log "Removing DKMS modules..."
dkms remove "$DKMS_GC2607" --all 2>/dev/null && \
    log "Removed DKMS: $DKMS_GC2607" || warn "DKMS $DKMS_GC2607 not found (OK)"

dkms remove "$DKMS_IPU" --all 2>/dev/null && \
    log "Removed DKMS: $DKMS_IPU" || warn "DKMS $DKMS_IPU not found (OK)"

rm -rf "/usr/src/gc2607-1.0" "/usr/src/ipu-bridge-gc2607-1.0"

# ── Restore original ipu_bridge ────────────────────────────────────────
orig_backup="${BACKUP_DIR}/ipu_bridge.ko.xz.orig"
if [ -f "$orig_backup" ]; then
    log "Restoring original ipu_bridge.ko..."
    orig_dst="/lib/modules/${KERN}/kernel/drivers/media/pci/intel/ipu_bridge.ko.xz"
    cp "$orig_backup" "$orig_dst"
    log "Restored: $orig_dst"
else
    warn "No ipu_bridge backup found — original may already be active via DKMS removal"
fi

# Remove any leftover patched ipu_bridge from updates/dkms
find "/lib/modules/${KERN}/updates" -name "ipu_bridge.ko*" -delete 2>/dev/null || true

depmod -a "$KERN"

# ── Remove installed files ─────────────────────────────────────────────
log "Removing $INSTALL_DIR..."
rm -rf "$INSTALL_DIR"

log "Removing /etc/gc2607/..."
rm -rf /etc/gc2607

# ── Remove wireplumber config ──────────────────────────────────────────
log "Removing wireplumber config..."
# Remove for all users that have it
for conf in /home/*/.config/wireplumber/wireplumber.conf.d/50-hide-ipu6-raw.conf \
            /root/.config/wireplumber/wireplumber.conf.d/50-hide-ipu6-raw.conf; do
    [ -f "$conf" ] && rm -f "$conf" && log "Removed: $conf"
done

# ── Restart wireplumber for current user ───────────────────────────────
REAL_USER="${SUDO_USER:-$(logname 2>/dev/null || echo "")}"
if [ -n "$REAL_USER" ]; then
    REAL_UID=$(id -u "$REAL_USER")
    su - "$REAL_USER" -c \
        "XDG_RUNTIME_DIR=/run/user/${REAL_UID} systemctl --user restart wireplumber" \
        2>/dev/null || true
fi

# ── Remove state ───────────────────────────────────────────────────────
log "Removing state..."
rm -f "$STATE_FILE"
# Keep backups dir in case user wants to restore manually
[ -d "$BACKUP_DIR" ] && log "Backups kept at: $BACKUP_DIR (remove manually if not needed)"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo -e "${GREEN}✓ GC2607 driver uninstalled${NC}"
echo ""
echo "  Reboot recommended to fully restore original modules."
echo "  To reinstall: sudo ./install.sh"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
