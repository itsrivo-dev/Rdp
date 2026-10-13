#!/bin/sh
# =============================================================================
#  /etc/xrdp/reconnectwm.sh - run by xrdp-sesman when an RDP client reconnects
#  to an existing desktop session. Keep this cheap and non-destructive: the
#  running XFCE session must not be disturbed.
# =============================================================================
xset s off 2>/dev/null || true
xset s noblank 2>/dev/null || true
xset -dpms 2>/dev/null || true
exit 0
