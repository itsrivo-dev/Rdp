#!/bin/sh
# =============================================================================
#  /etc/xrdp/startwm.sh - launched by xrdp-sesman as the desktop user once an
#  RDP client has authenticated. Starts the XFCE session on the X display that
#  sesman created for this session.
#
#  The session keeps running when the RDP client disconnects: sesman is
#  configured with KillDisconnected=false / DisconnectedTimeLimit=0, so this
#  process tree is only torn down on logout or container shutdown.
# =============================================================================

# Login shell environment
if [ -r /etc/profile ]; then . /etc/profile; fi
if [ -r "$HOME/.profile" ]; then . "$HOME/.profile"; fi

# A stale session bus address inherited from sesman confuses dbus-launch.
unset DBUS_SESSION_BUS_ADDRESS
unset SESSION_MANAGER

export XDG_SESSION_TYPE=x11
export XDG_SESSION_DESKTOP=xfce
export XDG_CURRENT_DESKTOP=XFCE
export DESKTOP_SESSION=xfce
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
export XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
export XDG_DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}"
export XDG_CACHE_HOME="${XDG_CACHE_HOME:-$HOME/.cache}"
export LANG="${LANG:-en_US.UTF-8}"
export NO_AT_BRIDGE=1
# Software rendering only - there is no GPU in a Railway container.
export LIBGL_ALWAYS_SOFTWARE=1
export MOZ_ENABLE_WAYLAND=0

if [ ! -d "$XDG_RUNTIME_DIR" ]; then
    mkdir -p "$XDG_RUNTIME_DIR" 2>/dev/null || true
    chmod 700 "$XDG_RUNTIME_DIR" 2>/dev/null || true
fi
mkdir -p "$XDG_CONFIG_HOME" "$XDG_DATA_HOME" "$XDG_CACHE_HOME" 2>/dev/null || true

# No screen blanking, no DPMS, no X11 screensaver on a headless server.
xset s off 2>/dev/null || true
xset s noblank 2>/dev/null || true
xset -dpms 2>/dev/null || true

# Standard XDG user directories (Desktop, Documents, Downloads, ...)
command -v xdg-user-dirs-update >/dev/null 2>&1 && xdg-user-dirs-update

echo "$(date -u '+%Y-%m-%dT%H:%M:%SZ') starting XFCE session for $(id -un) on ${DISPLAY}" \
    >> "$HOME/.cloudpc-session.log" 2>/dev/null

# dbus-launch keeps the session bus bound to the lifetime of xfce4-session.
exec dbus-launch --exit-with-session xfce4-session
