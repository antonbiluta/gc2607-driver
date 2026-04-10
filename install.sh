#!/bin/bash
# =============================================================================
# GC2607 Camera Driver Installer
# Huawei MateBook Pro VGHH-XX / Intel IPU6 / Fedora
#
# Usage:   sudo ./install.sh
# Re-run after kernel updates to rebuild modules.
#
# What this does:
#   1. Installs build dependencies (gcc, kernel-devel, dkms, v4l2loopback)
#   2. Registers gc2607.ko in DKMS (auto-rebuild on kernel updates)
#   3. Downloads kernel source, patches ipu_bridge with GC2607 support,
#      registers in DKMS
#   4. Compiles gc2607_isp (C userspace ISP, ~5% CPU)
#   5. Installs everything: /opt/gc2607/, systemd service, wireplumber config
# =============================================================================

set -euo pipefail

# ── Paths ──────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KERN=$(uname -r)
KERN_BASE=$(echo "$KERN" | grep -oP '^\d+\.\d+\.\d+')
KERN_MAJOR=$(echo "$KERN" | cut -d. -f1)

INSTALL_DIR="/opt/gc2607"
STATE_DIR="/var/lib/gc2607-driver"
STATE_FILE="$STATE_DIR/state"
BACKUP_DIR="$STATE_DIR/backups"
CONF_FILE="/etc/gc2607/gc2607.conf"

DKMS_GC2607_NAME="gc2607"
DKMS_GC2607_VER="1.0"
DKMS_GC2607_SRC="/usr/src/${DKMS_GC2607_NAME}-${DKMS_GC2607_VER}"

DKMS_IPU_NAME="ipu-bridge-gc2607"
DKMS_IPU_VER="1.0"
DKMS_IPU_SRC="/usr/src/${DKMS_IPU_NAME}-${DKMS_IPU_VER}"

WORK_DIR="$STATE_DIR/build"
TARBALL="$WORK_DIR/linux-${KERN_BASE}.tar.xz"

# ── Helpers ────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log()  { echo -e "${GREEN}[gc2607]${NC} $*"; }
warn() { echo -e "${YELLOW}[gc2607]${NC} $*"; }
die()  { echo -e "${RED}[gc2607] ERROR:${NC} $*" >&2; exit 1; }

require_root() {
    [ "$(id -u)" -eq 0 ] || die "Run with sudo: sudo $0"
}

real_user() {
    echo "${SUDO_USER:-$(logname 2>/dev/null || echo "")}"
}

real_uid() { id -u "$(real_user)"; }
real_gid() { id -g "$(real_user)"; }
real_home() { getent passwd "$(real_user)" | cut -d: -f6; }

# ── Phase 1: Dependencies ──────────────────────────────────────────────
install_deps() {
    log "=== Phase 1: Installing dependencies ==="

    if command -v dnf &>/dev/null; then
        log "Detected Fedora/RHEL (dnf)"

        # Basic build tools + kernel-devel for current kernel
        dnf install -y \
            gcc make \
            "kernel-devel-${KERN}" \
            elfutils-libelf-devel \
            dkms \
            wget \
            v4l-utils \
            2>/dev/null || true

        # v4l2loopback: try RPM Fusion, fallback to DKMS build
        if ! modinfo v4l2loopback &>/dev/null; then
            log "Installing v4l2loopback..."
            if dnf install -y v4l2loopback 2>/dev/null || \
               dnf install -y v4l2loopback-dkms 2>/dev/null; then
                log "v4l2loopback installed from package"
            else
                log "Building v4l2loopback via DKMS..."
                install_v4l2loopback_dkms
            fi
        fi

    elif command -v apt-get &>/dev/null; then
        log "Detected Debian/Ubuntu (apt)"
        apt-get install -y \
            gcc make \
            "linux-headers-${KERN}" \
            dkms \
            wget \
            v4l-utils \
            v4l2loopback-dkms \
            2>/dev/null || true
    else
        warn "Unknown distro. Install manually: gcc make kernel-devel dkms wget v4l-utils"
    fi

    # kernel-devel sanity check
    [ -d "/lib/modules/${KERN}/build" ] || \
        die "kernel-devel not found for ${KERN}. Install: sudo dnf install kernel-devel-${KERN}"

    log "Dependencies OK"
}

install_v4l2loopback_dkms() {
    local tmp; tmp=$(mktemp -d)
    local ver="0.13.1"
    local url="https://github.com/umlaeute/v4l2loopback/archive/v${ver}.tar.gz"
    wget -q -O "$tmp/v4l2loopback.tar.gz" "$url" || \
        die "Failed to download v4l2loopback source"
    tar xf "$tmp/v4l2loopback.tar.gz" -C "$tmp"
    local src_dir="$tmp/v4l2loopback-${ver}"
    mkdir -p "/usr/src/v4l2loopback-${ver}"
    cp -r "$src_dir"/* "/usr/src/v4l2loopback-${ver}/"
    cat > "/usr/src/v4l2loopback-${ver}/dkms.conf" <<EOF
PACKAGE_NAME="v4l2loopback"
PACKAGE_VERSION="${ver}"
BUILT_MODULE_NAME="v4l2loopback"
DEST_MODULE_LOCATION="/extra"
MAKE[0]="make KERNELRELEASE=\${kernelver}"
CLEAN="make clean"
AUTOINSTALL="yes"
EOF
    dkms add    "v4l2loopback/${ver}" 2>/dev/null || true
    dkms build  "v4l2loopback/${ver}" -k "$KERN"
    dkms install "v4l2loopback/${ver}" -k "$KERN"
    rm -rf "$tmp"
}

# ── Phase 2: gc2607.ko via DKMS ───────────────────────────────────────
setup_gc2607_dkms() {
    log "=== Phase 2: Setting up gc2607.ko DKMS ==="

    # Remove old DKMS entry if exists
    dkms remove "${DKMS_GC2607_NAME}/${DKMS_GC2607_VER}" --all 2>/dev/null || true
    rm -rf "$DKMS_GC2607_SRC"
    mkdir -p "$DKMS_GC2607_SRC"

    cp "$SCRIPT_DIR/gc2607.c" "$DKMS_GC2607_SRC/"

    cat > "$DKMS_GC2607_SRC/Makefile" <<'EOF'
obj-m := gc2607.o
all:
	$(MAKE) -C /lib/modules/$(KERNELRELEASE)/build M=$(PWD) modules
clean:
	$(MAKE) -C /lib/modules/$(KERNELRELEASE)/build M=$(PWD) clean
EOF

    cat > "$DKMS_GC2607_SRC/dkms.conf" <<EOF
PACKAGE_NAME="${DKMS_GC2607_NAME}"
PACKAGE_VERSION="${DKMS_GC2607_VER}"
BUILT_MODULE_NAME="gc2607"
BUILT_MODULE_LOCATION="."
DEST_MODULE_LOCATION="/extra"
MAKE[0]="make KERNELRELEASE=\${kernelver}"
CLEAN="make clean"
AUTOINSTALL="yes"
EOF

    dkms add "${DKMS_GC2607_NAME}/${DKMS_GC2607_VER}"

    dkms build "${DKMS_GC2607_NAME}/${DKMS_GC2607_VER}" -k "$KERN" || \
        die "DKMS build of gc2607 failed. Check: dkms status && cat /var/lib/dkms/gc2607/1.0/build/make.log"

    dkms install "${DKMS_GC2607_NAME}/${DKMS_GC2607_VER}" -k "$KERN" --force || \
        die "DKMS install of gc2607 failed"

    # Verify module is actually in place
    local gc2607_ko
    gc2607_ko=$(find "/lib/modules/${KERN}" -name "gc2607.ko*" | head -1)
    [ -n "$gc2607_ko" ] || die "gc2607.ko not found after DKMS install"
    log "gc2607.ko installed: $gc2607_ko"
}

# ── Phase 3: ipu_bridge patch via DKMS ────────────────────────────────
setup_ipu_bridge() {
    log "=== Phase 3: Patching ipu_bridge for GC2607 ==="

    mkdir -p "$WORK_DIR"

    # Download kernel source tarball (only once; reuse if valid)
    if [ -f "$TARBALL" ]; then
        log "Checking cached tarball..."
        xz --test "$TARBALL" &>/dev/null || { warn "Corrupt tarball, re-downloading"; rm -f "$TARBALL"; }
    fi

    if [ ! -f "$TARBALL" ]; then
        local url="https://cdn.kernel.org/pub/linux/kernel/v${KERN_MAJOR}.x/linux-${KERN_BASE}.tar.xz"
        log "Downloading kernel source: $url"
        wget --progress=bar:force -O "$TARBALL" "$url" || die "Download failed: $url"
        xz --test "$TARBALL" &>/dev/null || die "Downloaded tarball is corrupt"
    fi

    # Extract intel IPU driver directory using Python for reliable path detection
    log "Locating ipu-bridge source in tarball..."
    local ipu_src="$WORK_DIR/ipu_intel"
    rm -rf "$ipu_src"
    mkdir -p "$ipu_src"

    python3 - "$TARBALL" "$ipu_src" <<'PYEOF'
import sys, os, tarfile

tarball, dest = sys.argv[1], sys.argv[2]

# First pass: find the directory containing ipu-bridge.c
intel_prefix = None
print("[gc2607] Scanning tarball for ipu-bridge.c ...")
with tarfile.open(tarball, "r:xz") as tf:
    for member in tf:
        if member.name.endswith("/ipu-bridge.c") or member.name == "ipu-bridge.c":
            intel_prefix = member.name[: -len("ipu-bridge.c")]
            print(f"[gc2607] Found at: {member.name}")
            break

if intel_prefix is None:
    print("[gc2607] ERROR: ipu-bridge.c not found in tarball", file=sys.stderr)
    sys.exit(1)

# Second pass: extract all files from that directory
count = 0
with tarfile.open(tarball, "r:xz") as tf:
    for member in tf:
        if member.name.startswith(intel_prefix) and member.isfile():
            member.name = os.path.basename(member.name)
            try:
                tf.extract(member, dest, set_attrs=False, filter='data')
            except TypeError:
                tf.extract(member, dest, set_attrs=False)
            count += 1

print(f"[gc2607] Extracted {count} files to {dest}")
PYEOF

    [ $? -eq 0 ] || die "Failed to extract ipu-bridge source from tarball"

    # Find ipu-bridge.c (should be directly in ipu_src now)
    local src
    src=$(find "$ipu_src" -name "ipu-bridge.c" | head -1)
    [ -n "$src" ] || die "ipu-bridge.c not found after extraction"
    local src_dir
    src_dir=$(dirname "$src")
    log "Found ipu-bridge.c at: $src"

    # Check if GCTI2607 already present (previous patch)
    if grep -q "GCTI2607" "$src"; then
        log "GCTI2607 already in source, skipping patch"
    else
        # Find the insertion point: after the last IPU_SENSOR_CONFIG line in ipu_sensors[]
        log "Patching ipu-bridge.c with GC2607 support..."
        python3 - "$src" <<'PYEOF'
import sys

path = sys.argv[1]
lines = open(path).readlines()

if any('GCTI2607' in l for l in lines):
    print("[gc2607] Already patched")
    sys.exit(0)

entry = [
    '\t/* GalaxyCore GC2607 */\n',
    '\tIPU_SENSOR_CONFIG("GCTI2607", 1, 336000000),\n',
]

# Strategy 1: find the ipu_sensors[] array and insert before its closing };
# We look for the array definition, then find its closing brace.
array_start = None
for i, line in enumerate(lines):
    if 'ipu_sensors' in line and ('[]' in line or ('=' in line and '{' in line)):
        array_start = i
        break

if array_start is not None:
    # Find closing }; of the array (first }; after array_start)
    for i in range(array_start + 1, len(lines)):
        stripped = lines[i].strip()
        if stripped.startswith('};'):
            lines[i:i] = entry
            open(path, 'w').writelines(lines)
            print(f"[gc2607] Patched: inserted GC2607 before ipu_sensors closing at line {i+1}")
            sys.exit(0)

# Strategy 2 (fallback): insert after the last IPU_SENSOR_CONFIG line
# that is not in a comment and not a macro definition
last_idx = None
for i, line in enumerate(lines):
    stripped = line.strip()
    if ('IPU_SENSOR_CONFIG' in line
            and not stripped.startswith('//')
            and not stripped.startswith('*')
            and not stripped.startswith('#define')):
        last_idx = i

if last_idx is not None:
    lines[last_idx + 1:last_idx + 1] = entry
    open(path, 'w').writelines(lines)
    print(f"[gc2607] Patched (fallback): inserted GC2607 after line {last_idx + 1}")
    sys.exit(0)

print("[gc2607] ERROR: could not find insertion point in ipu-bridge.c", file=sys.stderr)
sys.exit(1)
PYEOF

        grep -q "GCTI2607" "$src" || die "Patch failed: GCTI2607 not found after patch"
        log "Patch applied"
    fi

    # Set up DKMS for ipu_bridge
    dkms remove "${DKMS_IPU_NAME}/${DKMS_IPU_VER}" --all 2>/dev/null || true
    rm -rf "$DKMS_IPU_SRC"
    mkdir -p "$DKMS_IPU_SRC"

    # Copy all intel driver source files (ipu_bridge needs its headers)
    cp "$src_dir"/*.c "$DKMS_IPU_SRC/" 2>/dev/null || true
    cp "$src_dir"/*.h "$DKMS_IPU_SRC/" 2>/dev/null || true

    cat > "$DKMS_IPU_SRC/Makefile" <<'EOF'
# Build only ipu_bridge module
obj-m := ipu_bridge.o
ipu_bridge-objs := ipu-bridge.o

KDIR := /lib/modules/$(KERNELRELEASE)/build

all:
	cp $(KDIR)/Module.symvers . 2>/dev/null || true
	$(MAKE) -C $(KDIR) M=$(PWD) modules
clean:
	$(MAKE) -C $(KDIR) M=$(PWD) clean
EOF

    cat > "$DKMS_IPU_SRC/dkms.conf" <<EOF
PACKAGE_NAME="${DKMS_IPU_NAME}"
PACKAGE_VERSION="${DKMS_IPU_VER}"
BUILT_MODULE_NAME="ipu_bridge"
BUILT_MODULE_LOCATION="."
DEST_MODULE_LOCATION="/updates/dkms"
MAKE[0]="make KERNELRELEASE=\${kernelver}"
CLEAN="make clean"
AUTOINSTALL="yes"
EOF

    dkms add "${DKMS_IPU_NAME}/${DKMS_IPU_VER}"
    dkms build "${DKMS_IPU_NAME}/${DKMS_IPU_VER}" -k "$KERN" || \
        die "DKMS build of ipu_bridge failed. Check: cat /var/lib/dkms/ipu-bridge-gc2607/1.0/build/make.log"

    # Use DKMS only for building; install manually to kernel directory
    # to guarantee priority over the original module (Fedora DKMS 3.x
    # ignores DEST_MODULE_LOCATION and installs to /extra/ which loses
    # to /kernel/ in some depmod configurations).
    install_ipu_bridge_to_kernel

    log "ipu_bridge patched and installed"
}

install_ipu_bridge_to_kernel() {
    # Detect the real on-disk path — on Fedora 43+ the file is ipu-bridge.ko.xz (dash),
    # on older kernels it may be ipu_bridge.ko.xz (underscore).
    local dst
    dst=$(modinfo -F filename ipu_bridge 2>/dev/null || true)
    if [ -z "$dst" ]; then
        dst=$(find "/lib/modules/${KERN}/kernel" \
            \( -name "ipu_bridge.ko*" -o -name "ipu-bridge.ko*" \) \
            2>/dev/null | head -1)
    fi
    if [ -z "$dst" ]; then
        dst="/lib/modules/${KERN}/kernel/drivers/media/pci/intel/ipu_bridge.ko.xz"
        warn "Could not detect ipu_bridge on-disk path, using fallback: $dst"
    fi
    log "Target path: $dst"

    # DKMS stores built modules in one of these locations depending on version
    local built
    built=$(find "/var/lib/dkms/${DKMS_IPU_NAME}/${DKMS_IPU_VER}" \
        \( -name "ipu_bridge.ko" -o -name "ipu_bridge.ko.xz" \) \
        2>/dev/null | head -1)

    if [ -z "$built" ]; then
        built=$(find "/var/lib/dkms/${DKMS_IPU_NAME}" \
            \( -name "ipu_bridge.ko" -o -name "ipu_bridge.ko.xz" \) \
            2>/dev/null | head -1)
    fi

    [ -n "$built" ] || die "DKMS build output not found. Try: find /var/lib/dkms/${DKMS_IPU_NAME} -name '*.ko*'"
    log "Using built module: $built"

    # Backup original (only once)
    local backup_name
    backup_name="$(basename "$dst").orig"
    if [ -f "$dst" ] && [ ! -f "${BACKUP_DIR}/${backup_name}" ]; then
        mkdir -p "$BACKUP_DIR"
        cp "$dst" "${BACKUP_DIR}/${backup_name}"
        log "Backed up original: $dst → ${BACKUP_DIR}/${backup_name}"
    fi

    # Compress with CRC32 (required by Fedora kernel loader)
    local tmp
    tmp=$(mktemp -d)

    if [[ "$built" == *.xz ]]; then
        xz -dc "$built" > "$tmp/ipu_bridge.ko" || \
            { rm -rf "$tmp"; die "Failed to decompress $built"; }
    else
        cp "$built" "$tmp/ipu_bridge.ko"
    fi

    xz -9 --check=crc32 "$tmp/ipu_bridge.ko" || \
        { rm -rf "$tmp"; die "xz compression failed"; }

    # Verify patch was applied to source
    grep -q "GCTI2607" "${DKMS_IPU_SRC}/ipu-bridge.c" || \
        { rm -rf "$tmp"; die "GCTI2607 not in DKMS source — patch failed. Re-run: sudo ./install.sh"; }

    cp "$tmp/ipu_bridge.ko.xz" "$dst"
    rm -rf "$tmp"

    depmod -a "$KERN"
    log "Installed patched module → $dst"
}


# ── Phase 4: Build gc2607_isp ──────────────────────────────────────────
build_isp() {
    log "=== Phase 4: Building gc2607_isp ==="

    gcc -O2 -Wall -Wextra -march=native \
        -o "$SCRIPT_DIR/gc2607_isp" \
        "$SCRIPT_DIR/gc2607_isp.c" \
        -lm || die "Failed to build gc2607_isp"

    log "Build OK: $(ls -lh "$SCRIPT_DIR/gc2607_isp")"
}

# ── Phase 5: Install to /opt/gc2607/ ──────────────────────────────────
install_files() {
    log "=== Phase 5: Installing to $INSTALL_DIR ==="

    # Stop both services first — otherwise running gc2607_isp binary can't be overwritten
    systemctl stop gc2607-isp.service    2>/dev/null || true
    systemctl stop gc2607-camera.service 2>/dev/null || true
    sleep 1

    mkdir -p "$INSTALL_DIR"

    cp "$SCRIPT_DIR/gc2607_isp"                    "$INSTALL_DIR/"
    cp "$SCRIPT_DIR/gc2607_virtualcam.py"          "$INSTALL_DIR/" 2>/dev/null || true
    cp "$SCRIPT_DIR/gc2607-service.sh"             "$INSTALL_DIR/"
    cp "$SCRIPT_DIR/gc2607-isp-start.sh"           "$INSTALL_DIR/"
    cp "$SCRIPT_DIR/gc2607-restart-wireplumber.sh" "$INSTALL_DIR/"
    cp "$SCRIPT_DIR/gc2607-settings"               "$INSTALL_DIR/"
    cp "$SCRIPT_DIR/gc2607-settings-helper.sh"     "$INSTALL_DIR/"

    chmod +x "$INSTALL_DIR/gc2607_isp"
    chmod +x "$INSTALL_DIR/gc2607-service.sh"
    chmod +x "$INSTALL_DIR/gc2607-isp-start.sh"
    chmod +x "$INSTALL_DIR/gc2607-restart-wireplumber.sh"
    chmod +x "$INSTALL_DIR/gc2607-settings"
    chmod +x "$INSTALL_DIR/gc2607-settings-helper.sh"

    # Fix SCRIPT_DIR inside service script
    sed -i "s|^SCRIPT_DIR=.*|SCRIPT_DIR=\"${INSTALL_DIR}\"|" \
        "$INSTALL_DIR/gc2607-service.sh"

    log "Files installed"
}

# ── Phase 6: Config file ───────────────────────────────────────────────
install_config() {
    log "=== Phase 6: Camera config ==="

    mkdir -p /etc/gc2607

    if [ ! -f "$CONF_FILE" ]; then
        cat > "$CONF_FILE" <<'EOF'
# GC2607 ISP settings
# Edit and run: sudo systemctl restart gc2607-camera.service
#
# resolution  — 1920x1080 (default) or 960x540 (less CPU)
# fps         — output fps 1-30 (default: 30)
# brightness  — AE target brightness 0-255 (default: 100)
# saturation  — color saturation, 100=neutral (default: 100)
# wb          — white balance: auto, daylight, cloudy, shade,
#               tungsten, fluorescent, manual (default: auto)
# wb_red      — red gain for wb=manual (e.g. 1.8)
# wb_blue     — blue gain for wb=manual (e.g. 1.6)

resolution=1920x1080
fps=30
brightness=100
saturation=100
wb=auto
rotation=180
EOF
        log "Created $CONF_FILE"
    else
        log "Keeping existing $CONF_FILE"
    fi
}

# ── Phase 6b: Settings app + polkit ───────────────────────────────────
install_settings_app() {
    log "=== Phase 6b: Installing settings app ==="

    # Make config file group-writable so the GUI can write without pkexec
    # when the user is in the 'gc2607' group (added below).
    groupadd -f gc2607 2>/dev/null || true
    local user; user=$(real_user)
    if [ -n "$user" ]; then
        usermod -aG gc2607 "$user" 2>/dev/null || true
    fi
    chown root:gc2607 /etc/gc2607 2>/dev/null || true
    chmod 775 /etc/gc2607 2>/dev/null || true
    [ -f "$CONF_FILE" ] && chown root:gc2607 "$CONF_FILE" && chmod 664 "$CONF_FILE" || true

    # polkit rule: allow gc2607 group to run the helper without password
    mkdir -p /etc/polkit-1/rules.d
    cat > /etc/polkit-1/rules.d/50-gc2607.rules <<'POLKIT'
polkit.addRule(function(action, subject) {
    if (action.id == "org.freedesktop.policykit.exec" &&
        action.lookup("program") == "/opt/gc2607/gc2607-settings-helper.sh" &&
        subject.isInGroup("gc2607")) {
        return polkit.Result.YES;
    }
});
POLKIT

    # .desktop file → visible in GNOME app drawer
    cp "$SCRIPT_DIR/gc2607-settings.desktop" \
        /usr/share/applications/gc2607-settings.desktop
    chmod 644 /usr/share/applications/gc2607-settings.desktop

    # Symlink binary so it's in PATH
    ln -sf "$INSTALL_DIR/gc2607-settings" /usr/local/bin/gc2607-settings 2>/dev/null || true

    log "Settings app installed — launch 'GC2607 Camera Settings' from GNOME or run: gc2607-settings"
    if [ -n "$user" ]; then
        warn "Group membership for '$user' takes effect on next login (or run: newgrp gc2607)"
    fi
}

# ── Phase 7: Wireplumber config ────────────────────────────────────────
install_wireplumber() {
    log "=== Phase 7: Wireplumber config ==="

    local user; user=$(real_user)
    local home; home=$(real_home)
    local uid; uid=$(real_uid)
    local gid; gid=$(real_gid)
    local wpdir="${home}/.config/wireplumber/wireplumber.conf.d"

    [ -n "$user" ] || { warn "Could not determine user, skipping wireplumber config"; return; }

    mkdir -p "$wpdir"
    cat > "${wpdir}/50-hide-ipu6-raw.conf" <<'EOF'
monitor.v4l2.rules = [
  {
    matches = [
      {
        device.name = "~v4l2_device.pci-*"
      }
    ]
    actions = {
      update-props = {
        device.disabled = true
      }
    }
  }
]
EOF
    chown -R "${uid}:${gid}" "${home}/.config/wireplumber"
    log "Wireplumber config installed for user: $user"
}

# ── Phase 8: Systemd services ──────────────────────────────────────────
install_service() {
    log "=== Phase 8: Systemd services ==="

    # gc2607-camera.service — oneshot: load modules and verify media topology
    cat > /etc/systemd/system/gc2607-camera.service <<EOF
[Unit]
Description=GC2607 Camera Driver Setup
After=multi-user.target
# Re-run if kernel modules change (e.g. after kernel update)
ConditionPathExists=/lib/modules/${KERN}/kernel/drivers/media/i2c

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=${INSTALL_DIR}/gc2607-service.sh
ExecStartPost=${INSTALL_DIR}/gc2607-restart-wireplumber.sh
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

    # gc2607-isp.service — persistent: ISP pipeline /dev/videoX → /dev/video50
    # gc2607_isp auto-pauses when no app reads /dev/video50 (LED turns off)
    cat > /etc/systemd/system/gc2607-isp.service <<EOF
[Unit]
Description=GC2607 ISP Pipeline (raw sensor → /dev/video50)
After=gc2607-camera.service
Requires=gc2607-camera.service

[Service]
Type=simple
ExecStart=${INSTALL_DIR}/gc2607-isp-start.sh
Restart=on-failure
RestartSec=10
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable gc2607-camera.service
    systemctl enable gc2607-isp.service
    log "Services installed and enabled"
}

# ── Phase 9: Sign modules (Secure Boot) ───────────────────────────────
sign_modules() {
    # Skip if Secure Boot is not enabled
    if ! mokutil --sb-state 2>/dev/null | grep -q "SecureBoot enabled"; then
        log "Secure Boot not active, skipping signing"
        return
    fi

    log "=== Secure Boot detected: signing modules ==="

    local mok_key="/var/lib/shim-signed/mok/MOK.priv"
    local mok_cert="/var/lib/shim-signed/mok/MOK.der"

    if [ ! -f "$mok_key" ]; then
        log "Generating MOK key pair..."
        mkdir -p /var/lib/shim-signed/mok
        openssl req -new -x509 -newkey rsa:2048 -keyout "$mok_key" \
            -out "$mok_cert" -days 3650 -subj "/CN=GC2607 Driver MOK/" \
            -nodes 2>/dev/null
        mokutil --import "$mok_cert"
        log ""
        log "  *** MOK key created. You must enroll it: ***"
        log "  1. Reboot and look for 'Perform MOK management' screen"
        log "  2. Select 'Enroll MOK' → 'Continue' → enter password"
        log "  3. After reboot, run install.sh again to complete signing"
        exit 0
    fi

    local sign_cmd="/lib/modules/${KERN}/build/scripts/sign-file"
    [ -f "$sign_cmd" ] || sign_cmd="$(which sign-file 2>/dev/null)" || \
        { warn "sign-file not found, modules not signed"; return; }

    local tmp; tmp=$(mktemp -d)

    # Modules may be .ko or .ko.xz — handle both
    # Pattern covers gc2607, ipu_bridge, ipu-bridge (Fedora dash naming)
    while IFS= read -r -d '' ko_path; do
        if [[ "$ko_path" == *.xz ]]; then
            # Decompress → sign → recompress → replace
            local ko_name; ko_name=$(basename "${ko_path%.xz}")
            if ! xz -dc "$ko_path" > "$tmp/$ko_name" 2>/dev/null; then
                warn "Failed to decompress $ko_path, skipping"; continue
            fi
            if ! "$sign_cmd" sha256 "$mok_key" "$mok_cert" "$tmp/$ko_name" 2>/dev/null; then
                warn "sign-file failed for $ko_path, skipping"; continue
            fi
            if ! xz -9 --check=crc32 "$tmp/$ko_name" 2>/dev/null; then
                warn "Recompression failed for $ko_path, skipping"; continue
            fi
            cp "$tmp/${ko_name}.xz" "$ko_path"
            rm -f "$tmp/$ko_name" "$tmp/${ko_name}.xz"
            log "Signed (xz): $ko_path"
        else
            if "$sign_cmd" sha256 "$mok_key" "$mok_cert" "$ko_path" 2>/dev/null; then
                log "Signed: $ko_path"
            else
                warn "sign-file failed for $ko_path"
            fi
        fi
    done < <(find "/lib/modules/${KERN}" \
        \( -name "gc2607.ko"        -o -name "gc2607.ko.xz" \
           -o -name "ipu_bridge.ko" -o -name "ipu_bridge.ko.xz" \
           -o -name "ipu-bridge.ko" -o -name "ipu-bridge.ko.xz" \) \
        -print0 2>/dev/null)

    rm -rf "$tmp"
    depmod -a "$KERN"
}

# ── Phase 10: Start services ───────────────────────────────────────────
start_camera() {
    log "=== Phase 10: Starting camera ==="

    systemctl stop gc2607-isp.service    2>/dev/null || true
    systemctl stop gc2607-camera.service 2>/dev/null || true
    sleep 1

    # Check if the patched ipu_bridge is already loaded in memory.
    # If so, no module reload is needed — just restart the services.
    local ipu_loaded=0
    local ipu_patched=0
    if grep -q "^ipu_bridge " /proc/modules 2>/dev/null; then
        ipu_loaded=1
        # Check if the currently loaded module has GC2607 support
        # (the in-memory binary contains the GCTI2607 string)
        local ipu_mod_path
        ipu_mod_path=$(modinfo -F filename ipu_bridge 2>/dev/null || true)
        if [ -n "$ipu_mod_path" ]; then
            if [[ "$ipu_mod_path" == *.xz ]]; then
                xz -dc "$ipu_mod_path" 2>/dev/null | grep -qa "GCTI2607" && ipu_patched=1
            else
                grep -qa "GCTI2607" "$ipu_mod_path" 2>/dev/null && ipu_patched=1
            fi
        fi
    fi

    if [ "$ipu_loaded" -eq 1 ] && [ "$ipu_patched" -eq 1 ]; then
        # Patched modules are already loaded — no need to reload anything.
        log "Patched ipu_bridge already loaded — skipping module reload"
    else
        # Try to unload and reload the module stack so the patched modules take effect.
        # If any module is busy, a single reboot is needed.
        local need_reboot=0
        for mod in gc2607 intel-ipu6-isys intel-ipu6 ipu_bridge; do
            if grep -q "^${mod} " /proc/modules 2>/dev/null; then
                if ! modprobe -r "$mod" 2>/dev/null; then
                    warn "Cannot unload $mod (device busy)"
                    need_reboot=1
                fi
            fi
        done

        if [ "$need_reboot" -eq 1 ]; then
            echo ""
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo -e "${YELLOW}⚠  Installation complete. Reboot required.${NC}"
            echo ""
            echo "  Modules are in use and cannot be reloaded live."
            echo "  After reboot the camera will be ready automatically."
            echo ""
            echo "  sudo reboot"
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            save_state
            exit 0
        fi
    fi

    # Load v4l2loopback for /dev/video50 (ISP output)
    modprobe v4l2loopback video_nr=50 card_label="GC2607 Camera" \
        exclusive_caps=1 2>/dev/null || true

    systemctl start gc2607-camera.service || \
        die "Camera setup failed. Check: journalctl -u gc2607-camera.service -n 30"

    systemctl start gc2607-isp.service || \
        warn "ISP service failed to start immediately (will retry automatically)"

    log "Camera ready. LED activates only when an app opens the camera."
}

# ── Phase 11: Save state ───────────────────────────────────────────────
save_state() {
    mkdir -p "$STATE_DIR"
    cat > "$STATE_FILE" <<EOF
install_date=$(date -Iseconds)
kernel=${KERN}
kern_base=${KERN_BASE}
install_dir=${INSTALL_DIR}
dkms_gc2607=${DKMS_GC2607_NAME}/${DKMS_GC2607_VER}
dkms_ipu=${DKMS_IPU_NAME}/${DKMS_IPU_VER}
EOF
    log "State saved to $STATE_FILE"
}

# ── Status report ──────────────────────────────────────────────────────
show_status() {
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    if systemctl is-active --quiet gc2607-camera.service; then
        echo -e "${GREEN}✓ gc2607-camera  (module setup)   — OK${NC}"
    else
        echo -e "${RED}✗ gc2607-camera  (module setup)   — NOT running${NC}"
        echo "    Check: journalctl -u gc2607-camera.service -n 30"
    fi

    if systemctl is-active --quiet gc2607-isp.service; then
        echo -e "${GREEN}✓ gc2607-isp     (ISP pipeline)   — running${NC}"
    else
        echo -e "${YELLOW}⚠ gc2607-isp     (ISP pipeline)   — not running yet${NC}"
        echo "    Check: journalctl -u gc2607-isp.service -n 30"
    fi

    echo ""
    echo "  Open any camera app — it will find 'GC2607 Camera' (/dev/video50)"
    echo "  LED turns on only when an app is actively reading the camera"
    echo ""
    echo "  Settings GUI:  gc2607-settings   (or search GNOME apps)"
    echo "  Config file:   $CONF_FILE        (changes apply instantly)"
    echo "  All logs:      journalctl -u gc2607-camera.service -u gc2607-isp.service -f"
    echo "  DKMS:          dkms status"
    echo ""
    echo "  After kernel update: sudo ./install.sh  (DKMS usually handles it)"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

# ── Main ───────────────────────────────────────────────────────────────
main() {
    require_root

    log "GC2607 Camera Driver Installer"
    log "Kernel: $KERN"
    log "User:   $(real_user)"

    install_deps
    setup_gc2607_dkms
    setup_ipu_bridge
    build_isp
    install_files
    install_config
    install_settings_app
    install_wireplumber
    install_service
    sign_modules
    start_camera
    save_state
    show_status
}

main "$@"
