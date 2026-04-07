# GC2607 Camera Driver — Huawei MateBook Pro VGHH-XX

> 🇷🇺 [Читать на русском](README_RU.md)

Linux camera driver for the GalaxyCore GC2607 sensor with Intel IPU6 support.

---

## Requirements

- Huawei MateBook Pro VGHH-XX (or similar device with GC2607 sensor)
- Fedora 40+ / Linux kernel 6.x
- `kernel-devel` package for the running kernel

---

## Installation

```bash
sudo ./install.sh
```

The script automatically:
- Installs build dependencies
- Builds and registers `gc2607.ko` via DKMS
- Downloads kernel source, patches `ipu_bridge` for GC2607 support, registers via DKMS
- Builds the C ISP processor (`gc2607_isp`, ~5% CPU vs ~43% for Python)
- Installs a systemd service with auto-start on boot
- Configures WirePlumber to hide raw IPU6 nodes so apps see only `GC2607 Camera`

---

## After a kernel update

DKMS rebuilds both modules automatically on reboot.
If something breaks, just re-run:

```bash
sudo ./install.sh
```

---

## Camera settings

Config file: `/etc/gc2607/gc2607.conf`

```ini
resolution=1920x1080   # or 960x540 for lower CPU usage
fps=30                 # 1–30
brightness=100         # AE target brightness 0–255
saturation=100         # 100 = neutral, 140 = more vivid
wb=auto                # auto, daylight, cloudy, shade,
                       # tungsten, fluorescent, manual
# wb_red=1.8           # only used when wb=manual
# wb_blue=1.6
```

Apply changes:

```bash
sudo systemctl restart gc2607-camera.service
```

---

## Service management

```bash
# Status
sudo systemctl status gc2607-camera.service

# Live logs
journalctl -u gc2607-camera.service -f

# Restart
sudo systemctl restart gc2607-camera.service

# DKMS module status
dkms status
```

---

## Uninstall

```bash
sudo ./uninstall.sh
```

Restores the original `ipu_bridge` module from backup and removes all installed files.

---

## Files

| File | Description |
|------|-------------|
| `install.sh` | Full installer (DKMS + service + config) |
| `uninstall.sh` | Full uninstaller with backup restore |
| `gc2607.c` | Kernel module source |
| `gc2607_isp.c` | Userspace ISP — Bayer→YUYV, ~5% CPU |
| `gc2607-service.sh` | Virtual camera service startup script |
| `gc2607_virtualcam.py` | Python fallback ISP |
| `Makefile` | For manual kernel module builds |

---

## Credits

Based on [abbood/gc2607-v4l2-driver](https://github.com/abbood/gc2607-v4l2-driver) —
a port of the proprietary GC2607 driver from the Ingenic T41 platform to Linux V4L2
with Intel IPU6 integration.

Special thanks to [yegor-alexeyev](https://github.com/yegor-alexeyev) for identifying
the GC2607 sensor in the Huawei MateBook Pro VGHH-XX
([source](https://github.com/intel/ipu6-drivers/issues/399#issuecomment-3707318638)).
