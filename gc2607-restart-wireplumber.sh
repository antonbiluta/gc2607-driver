#!/bin/bash
# Restart wireplumber for the logged-in user so PipeWire detects the virtual camera.
# Called by gc2607-camera.service ExecStartPost.

# Wait for the virtualcam to start writing frames
sleep 5

# Find the logged-in user's session and restart wireplumber
# Find the logged-in desktop user
USER=$(logname 2>/dev/null || who | grep -m1 'tty\|:0' | awk '{print $1}') || true
if [ -z "$USER" ]; then
    USER=$(ls -1 /run/user/ 2>/dev/null | head -1 | xargs -I{} getent passwd {} | cut -d: -f1) || true
fi
UID_NUM=$(id -u "$USER" 2>/dev/null) || exit 0

export XDG_RUNTIME_DIR="/run/user/${UID_NUM}"
export DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${UID_NUM}/bus"

# Retry a few times — user session may not be ready yet at boot
for i in 1 2 3 4 5; do
    if [ -S "${XDG_RUNTIME_DIR}/bus" ]; then
        su - "$USER" -c "XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR} systemctl --user restart wireplumber" 2>/dev/null && exit 0
    fi
    sleep 5
done
