#!/bin/bash
# Restart wireplumber for the logged-in user so PipeWire detects the virtual camera.
# Called by gc2607-camera.service ExecStartPost.

log() { echo "[gc2607-wp] $*"; }

# Wait for the virtualcam to start writing frames
sleep 5

# Find the active graphical session user via loginctl (skips gdm, system accounts)
find_desktop_user() {
    # loginctl list-sessions: columns are SESSION UID USER SEAT TTY
    loginctl list-sessions --no-legend 2>/dev/null | while read -r sess uid user seat rest; do
        # Skip gdm and accounts without a seat (non-graphical)
        [ "$user" = "gdm" ] && continue
        [ -z "$seat" ] && continue
        # Check session is active and graphical
        local type state
        type=$(loginctl  show-session "$sess" -p Type  --value 2>/dev/null)
        state=$(loginctl show-session "$sess" -p State --value 2>/dev/null)
        if [ "$state" = "active" ] && { [ "$type" = "wayland" ] || [ "$type" = "x11" ]; }; then
            echo "$user"
            return 0
        fi
    done | head -1
}

# Retry — user session may not be ready yet at boot
for attempt in 1 2 3 4 5 6; do
    DESK_USER=$(find_desktop_user)
    if [ -n "$DESK_USER" ]; then
        break
    fi
    log "Attempt $attempt: no active desktop session yet, waiting..."
    sleep 5
done

if [ -z "$DESK_USER" ]; then
    log "No desktop user found, skipping wireplumber restart"
    exit 0
fi

DESK_UID=$(id -u "$DESK_USER" 2>/dev/null)
if [ -z "$DESK_UID" ]; then
    log "Cannot resolve UID for $DESK_USER"
    exit 0
fi

log "Restarting wireplumber for user: $DESK_USER (uid=$DESK_UID)"
export XDG_RUNTIME_DIR="/run/user/${DESK_UID}"
export DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${DESK_UID}/bus"

# Use systemctl --machine to avoid su/shell restrictions on corporate accounts
if systemctl --machine="${DESK_USER}@.host" --user restart wireplumber 2>/dev/null; then
    log "wireplumber restarted via systemctl --machine"
    exit 0
fi

# Fallback: runuser (more reliable than su on LDAP/corporate accounts)
if runuser -l "$DESK_USER" -c \
    "XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR} systemctl --user restart wireplumber" 2>/dev/null; then
    log "wireplumber restarted via runuser"
    exit 0
fi

log "WARNING: could not restart wireplumber for $DESK_USER"
exit 0
