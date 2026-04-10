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
KERN_BASE=$(echo "$KERN" | sed -E 's/^([0-9]+\.[0-9]+\.[0-9]+).*/\1/')
KERN_MAJOR=$(echo "$KERN_BASE" | cut -d. -f1)
echo "$KERN_BASE" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' || \
    { echo "[gc2607] ERROR: Could not parse kernel base version from: $KERN" >&2; exit 1; }

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
RUNTIME_VERIFY_WARN=0

# ── Helpers ────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log()  { echo -e "${GREEN}[gc2607]${NC} $*"; }
warn() { echo -e "${YELLOW}[gc2607]${NC} $*"; }
die()  { echo -e "${RED}[gc2607] ERROR:${NC} $*" >&2; exit 1; }

wait_service_active() {
    local svc="$1"
    local timeout="${2:-25}"
    local i
    for i in $(seq 1 "$timeout"); do
        if systemctl is-active --quiet "$svc"; then
            return 0
        fi
        sleep 1
    done
    return 1
}

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
        if ! dnf install -y \
            gcc make \
            "kernel-devel-${KERN}" \
            elfutils-libelf-devel \
            dkms \
            wget \
            tar \
            xz \
            python3 \
            v4l-utils \
            openssl \
            mokutil; then
            warn "kernel-devel-${KERN} unavailable, retrying with generic kernel-devel"
            dnf install -y \
                gcc make \
                kernel-devel \
                elfutils-libelf-devel \
                dkms \
                wget \
                tar \
                xz \
                python3 \
                v4l-utils \
                openssl \
                mokutil || die "Failed to install required dependencies"
        fi

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

    # Tooling sanity check
    for cmd in dkms gcc make modprobe modinfo media-ctl v4l2-ctl xz python3; do
        command -v "$cmd" >/dev/null 2>&1 || die "Missing required tool: $cmd"
    done

    # Write modprobe.d config so v4l2loopback always loads with video_nr=50
    cat > /etc/modprobe.d/gc2607-v4l2loopback.conf <<'EOF'
# GC2607 ISP output device — fixed single virtual cam at /dev/video50
options v4l2loopback devices=1 video_nr=50 card_label="GC2607 Camera" exclusive_caps=1
EOF
    log "modprobe.d config written for v4l2loopback"

    # Load it now so gc2607-isp.service doesn't have to wait
    modprobe -r v4l2loopback 2>/dev/null || true
    modprobe v4l2loopback || warn "v4l2loopback failed to load (will retry at boot)"

    # Verify /dev/video50 appeared
    if [ -e /dev/video50 ]; then
        log "v4l2loopback OK: /dev/video50 ready"
    else
        warn "/dev/video50 not found yet — may appear after udev settles"
    fi

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
    local ipu_src="$WORK_DIR/ipu_intel"
    rm -rf "$ipu_src"
    mkdir -p "$ipu_src"

    # Prefer local kernel-devel tree (works offline and matches Fedora kernel build)
    local local_intel_src="/usr/src/kernels/${KERN}/drivers/media/pci/intel"
    if [ -f "${local_intel_src}/ipu-bridge.c" ]; then
        log "Using local kernel source: ${local_intel_src}"
        cp "${local_intel_src}"/*.c "$ipu_src/" 2>/dev/null || true
        cp "${local_intel_src}"/*.h "$ipu_src/" 2>/dev/null || true
    fi

    # Fallback: download vanilla kernel tree if local source is unavailable
    if [ ! -f "${ipu_src}/ipu-bridge.c" ]; then
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
    fi

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

    mkdir -p /etc/gc2607
    chmod 1777 /etc/gc2607

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
        chmod 666 "$CONF_FILE"
        log "Created $CONF_FILE"
    else
        chmod 666 "$CONF_FILE"   # ensure writable even if installed previously
        log "Keeping existing $CONF_FILE"
    fi
}

# ── Phase 6b: Settings app + polkit ───────────────────────────────────
install_settings_app() {
    log "=== Phase 6b: Installing settings app ==="

    # Make config dir+file world-writable so any logged-in user can write
    # the config directly from the GUI — no group, no pkexec, no password.
    # The file contains only camera tuning parameters, nothing sensitive.
    mkdir -p /etc/gc2607
    chmod 1777 /etc/gc2607          # sticky + rwxrwxrwx (like /tmp)
    [ -f "$CONF_FILE" ] && chmod 666 "$CONF_FILE" || true

    # polkit rule: allow any active session user to run the helper
    # (kept as a fallback in case direct write ever fails)
    mkdir -p /etc/polkit-1/rules.d
    cat > /etc/polkit-1/rules.d/50-gc2607.rules <<'POLKIT'
polkit.addRule(function(action, subject) {
    if (action.id == "org.freedesktop.policykit.exec" &&
        action.lookup("program") == "/opt/gc2607/gc2607-settings-helper.sh" &&
        subject.active) {
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
    # Remove old config name if it exists from a previous install
    rm -f "${wpdir}/50-hide-ipu6-raw.conf"
    # Force apps to use the ISP output /dev/video50:
    # 1) hide raw PCI-backed IPU6 V4L2 devices
    # 2) hide libcamera-provided camera nodes (they bypass our ISP settings)
    cat > "${wpdir}/50-gc2607-routing.conf" <<'EOF'
# Hide raw IPU6 V4L2 capture nodes (PCI devices) from PipeWire.
# /dev/video50 (v4l2loopback) is NOT a PCI device so it stays visible.
monitor.v4l2.rules = [
  {
    matches = [ { device.name = "~v4l2_device.pci-*" } ]
    actions = { update-props = { device.disabled = true } }
  }
]

# Hide libcamera camera nodes so desktop apps use /dev/video50 (ISP output)
monitor.libcamera.rules = [
  {
    matches = [ { device.name = "~.*" } ]
    actions = { update-props = { device.disabled = true } }
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
After=systemd-modules-load.service
Before=gc2607-isp.service

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
Requires=gc2607-camera.service
After=gc2607-camera.service

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

    systemctl start gc2607-camera.service || true
    if ! systemctl is-active --quiet gc2607-camera.service; then
        warn "Initial camera start failed, forcing module stack reload and retrying..."
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
        systemctl start gc2607-camera.service || \
            die "Camera setup failed after retry. Check: journalctl -u gc2607-camera.service -n 80"
    fi

    systemctl start gc2607-isp.service || true
    wait_service_active gc2607-isp.service 25 || \
        die "ISP service failed to become active. Check: journalctl -u gc2607-isp.service -n 80"

    log "Camera ready. LED activates only when an app opens the camera."
}

# ── Phase 11b: Runtime verification ───────────────────────────────────
verify_runtime() {
    log "=== Phase 11b: Verifying runtime ==="

    local media_ok=0
    for dev in /dev/media*; do
        [ -e "$dev" ] || continue
        if media-ctl -d "$dev" --print-topology 2>/dev/null | grep -qi "gc2607"; then
            media_ok=1
            break
        fi
    done
    [ "$media_ok" -eq 1 ] || die "GC2607 not visible in media topology after install"

    local i
    for i in $(seq 1 20); do
        [ -e /dev/video50 ] && break
        sleep 1
    done
    [ -e /dev/video50 ] || die "/dev/video50 not found (v4l2loopback routing not ready)"

    local smoke="/tmp/gc2607-smoke-test.yuv"
    local smoke_ok=0
    local attempt
    for attempt in 1 2 3; do
        rm -f "$smoke"

        # On some machines the first run is too early: ISP is up but not yet pushing frames.
        # Retry with a short settle delay and restart ISP between attempts.
        if [ "$attempt" -gt 1 ]; then
            warn "Smoke test retry ${attempt}/3: restarting gc2607-isp.service"
            systemctl restart gc2607-isp.service 2>/dev/null || true
            sleep 3
        fi

        if timeout 35 v4l2-ctl -d /dev/video50 \
            --stream-mmap=3 --stream-count=60 --stream-to="$smoke" >/dev/null 2>&1; then
            if [ -s "$smoke" ]; then
                smoke_ok=1
                break
            fi
        fi
        sleep 2
    done

    if [ "$smoke_ok" -ne 1 ]; then
        rm -f "$smoke"
        warn "Smoke test failed. Recent logs:"
        journalctl -u gc2607-camera.service -u gc2607-isp.service -n 120 --no-pager || true
        warn "Failed to capture non-empty frames from /dev/video50 after retries"
        warn "A reboot is likely required to activate the patched camera stack cleanly"
        RUNTIME_VERIFY_WARN=1
        return 0
    fi
    rm -f "$smoke"

    log "Runtime verification passed (/dev/video50 streams correctly)"
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
    if [ "$RUNTIME_VERIFY_WARN" -eq 1 ]; then
        echo -e "${YELLOW}⚠ Runtime verification incomplete.${NC}"
        echo "  Reboot now and test the camera again:"
        echo "  sudo reboot"
        echo ""
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
    verify_runtime
    show_status
}

main "$@"
