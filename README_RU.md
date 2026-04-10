# Драйвер камеры GC2607 — Huawei MateBook Pro VGHH-XX

> 🇬🇧 [Read in English](README.md)

Драйвер камеры GalaxyCore GC2607 для Linux с поддержкой Intel IPU6.

---

## Требования

- Huawei MateBook Pro VGHH-XX (или аналогичное устройство с сенсором GC2607)
- Fedora 40+ / ядро Linux 6.x
- Пакет `kernel-devel` для текущего ядра

---

## Установка

```bash
sudo ./install.sh
```

Скрипт автоматически:
- Устанавливает зависимости сборки
- Собирает и регистрирует `gc2607.ko` через DKMS
- Использует локальные исходники ядра (fallback: tarball с kernel.org), патчит `ipu_bridge`, собирает через DKMS
- Собирает C-ISP процессор (`gc2607_isp`, ~5% CPU против ~43% у Python-версии)
- Устанавливает и включает systemd-сервисы (`gc2607-camera`, `gc2607-isp`)
- Настраивает `v4l2loopback` как одно устройство (`/dev/video50`, `GC2607 Camera`)
- Настраивает маршрутизацию WirePlumber и синхронизацию user media stack (PipeWire/portal)
- Отключает конфликтующий `virtual-webcam.service`, если он есть

После первой установки рекомендуется один раз перезагрузиться:

```bash
sudo reboot
```

---

## После обновления ядра

DKMS пересобирает оба модуля автоматически при перезагрузке.
Если что-то пошло не так — повторно запустите:

```bash
sudo ./install.sh
```

---

## Настройки камеры

Файл конфигурации: `/etc/gc2607/gc2607.conf`

```ini
resolution=1920x1080   # или 960x540 (меньше нагрузки на CPU)
fps=30                 # 1–30
brightness=100         # цель автоэкспозиции 0–255
saturation=100         # 100 = нейтральный, 140 = насыщеннее
wb=auto                # auto, daylight, cloudy, shade,
                       # tungsten, fluorescent, manual
# wb_red=1.8           # только для wb=manual
# wb_blue=1.6
```

Применить изменения:

```bash
sudo systemctl restart gc2607-isp.service
```

---

## Управление сервисом

```bash
# Статус
sudo systemctl status gc2607-camera.service gc2607-isp.service

# Логи в реальном времени
journalctl -u gc2607-camera.service -u gc2607-isp.service -f

# Перезапуск
sudo systemctl restart gc2607-camera.service gc2607-isp.service

# Статус DKMS-модулей
dkms status
```

Быстрая проверка runtime:

```bash
v4l2-ctl --list-devices
wpctl status
```

Должна быть камера `GC2607 Camera` на `/dev/video50`.

---

## Решение проблем

- Если камера есть как device, но пропадает как source в PipeWire:
  - Один раз перезагрузитесь.
  - Затем повторно запустите `sudo ./install.sh`.
- Если Chrome не видит камеру:
  - Полностью закройте и заново откройте Chrome.
  - Проверьте `chrome://settings/content/camera` и выберите `GC2607 Camera`.
- Если снова появляется конфликтующая виртуальная камера:
  - Проверьте, что `virtual-webcam.service` выключен:
    `systemctl status virtual-webcam.service --no-pager`

---

## Удаление

```bash
sudo ./uninstall.sh
```

Восстанавливает оригинальный модуль `ipu_bridge` из резервной копии и удаляет все установленные файлы.

---

## Файлы

| Файл | Описание |
|------|----------|
| `install.sh` | Полная установка (DKMS + сервис + конфиг) |
| `uninstall.sh` | Полное удаление с восстановлением |
| `gc2607.c` | Исходник kernel-модуля |
| `gc2607_isp.c` | Userspace ISP — Bayer→YUYV, ~5% CPU |
| `gc2607-service.sh` | Скрипт запуска виртуальной камеры |
| `gc2607_virtualcam.py` | Python-fallback ISP |
| `Makefile` | Для ручной сборки модуля |

---

## Благодарности

Основано на проекте [abbood/gc2607-v4l2-driver](https://github.com/abbood/gc2607-v4l2-driver) —
порт проприетарного драйвера GC2607 с платформы Ingenic T41 на Linux V4L2
с интеграцией Intel IPU6.

Отдельная благодарность [yegor-alexeyev](https://github.com/yegor-alexeyev) за идентификацию
сенсора GC2607 в Huawei MateBook Pro VGHH-XX
([источник](https://github.com/intel/ipu6-drivers/issues/399#issuecomment-3707318638)).
