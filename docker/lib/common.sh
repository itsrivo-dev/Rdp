#!/usr/bin/env bash
# Shared helpers for the Ubuntu Cloud PC runtime scripts.
# shellcheck shell=bash

CLOUDPC_ROOT="${CLOUDPC_ROOT:-/opt/cloudpc}"
CLOUDPC_RUN_DIR="${CLOUDPC_RUN_DIR:-/run/cloudpc}"

_timestamp() { date -u '+%Y-%m-%dT%H:%M:%SZ'; }

log()  { printf '%s [cloud-pc] %s\n' "$(_timestamp)" "$*"; }
warn() { printf '%s [cloud-pc] WARNING: %s\n' "$(_timestamp)" "$*" >&2; }
err()  { printf '%s [cloud-pc] ERROR: %s\n' "$(_timestamp)" "$*" >&2; }
die()  { err "$*"; exit 1; }

# banner <line>...  -- framed block, used for the startup notice.
banner() {
    local line
    printf '\n'
    printf '%s\n' "$(printf '=%.0s' $(seq 1 74))"
    for line in "$@"; do
        printf '  %s\n' "$line"
    done
    printf '%s\n\n' "$(printf '=%.0s' $(seq 1 74))"
}

# is_true <value> -- lenient boolean parsing for environment variables.
is_true() {
    case "${1,,}" in
        1|true|yes|y|on) return 0 ;;
        *) return 1 ;;
    esac
}

# port_listening <port> -- true when a TCP port is in LISTEN state, IPv4 or IPv6.
#
# /proc is read instead of opening a socket on purpose: a bare TCP connect to
# the VNC server shows up as a failed authentication in its log, and probing
# from the wrong address family would report a false outage.
port_listening() {
    local hex
    local files=()
    printf -v hex '%04X' "$1"
    [ -r /proc/net/tcp ]  && files+=(/proc/net/tcp)
    [ -r /proc/net/tcp6 ] && files+=(/proc/net/tcp6)
    [ "${#files[@]}" -gt 0 ] || return 1
    awk -v want="${hex}" '
        $4 == "0A" { split($2, a, ":"); if (a[2] == want) { found = 1 } }
        END { exit !found }
    ' "${files[@]}" 2>/dev/null
}

# http_ok <port> [path] -- true on a 2xx/3xx answer from the local gateway.
http_ok() {
    local port="$1" path="${2:-/health}"
    python3 -c '
import sys, urllib.request
url = "http://127.0.0.1:%s%s" % (sys.argv[1], sys.argv[2])
request = urllib.request.Request(url, headers={"User-Agent": "cloudpc-health"})
try:
    with urllib.request.urlopen(request, timeout=5) as response:
        sys.exit(0 if 200 <= response.status < 400 else 1)
except Exception:
    sys.exit(1)
' "${port}" "${path}" 2>/dev/null
}

# render_template <src> <dst> -- substitute @@KEY@@ placeholders from the
# exported environment. Missing keys are a hard error.
render_template() {
    local src="$1" dst="$2"
    [ -r "$src" ] || die "template not found: ${src}"
    python3 - "$src" "$dst" <<'PY'
import os
import re
import sys

src, dst = sys.argv[1], sys.argv[2]
with open(src, "r", encoding="utf-8") as handle:
    body = handle.read()

missing = []


def replace(match):
    key = match.group(1)
    value = os.environ.get(key)
    if value is None:
        missing.append(key)
        return match.group(0)
    return value


body = re.sub(r"@@([A-Z0-9_]+)@@", replace, body)
if missing:
    sys.stderr.write("missing template variables: %s\n" % ", ".join(sorted(set(missing))))
    sys.exit(1)

tmp = dst + ".tmp"
with open(tmp, "w", encoding="utf-8") as handle:
    handle.write(body)
os.replace(tmp, dst)
PY
}
