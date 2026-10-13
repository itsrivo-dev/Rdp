#!/usr/bin/env bash
# Shared helpers for the Ubuntu Cloud PC runtime scripts.
# shellcheck shell=bash

CLOUDPC_ROOT="${CLOUDPC_ROOT:-/opt/cloudpc}"
CLOUDPC_RUN_DIR="${CLOUDPC_RUN_DIR:-/run/cloudpc}"

_ts() { date -u '+%Y-%m-%dT%H:%M:%SZ'; }

log()  { printf '%s [cloud-pc] %s\n' "$(_ts)" "$*"; }
warn() { printf '%s [cloud-pc] WARNING: %s\n' "$(_ts)" "$*" >&2; }
err()  { printf '%s [cloud-pc] ERROR: %s\n' "$(_ts)" "$*" >&2; }
die()  { err "$*"; exit 1; }

# banner <line>...  -- prints a framed block, used for the credential notice.
banner() {
    local line width=74
    printf '\n'
    printf '%s\n' "$(printf '=%.0s' $(seq 1 "$width"))"
    for line in "$@"; do
        printf '  %s\n' "$line"
    done
    printf '%s\n\n' "$(printf '=%.0s' $(seq 1 "$width"))"
}

# is_true <value> -- lenient boolean parsing for environment variables.
is_true() {
    case "${1,,}" in
        1|true|yes|y|on) return 0 ;;
        *) return 1 ;;
    esac
}

# port_listening <port> -- returns 0 when something LISTENs on that TCP port,
# on any address family.
#
# This reads /proc instead of opening a connection, which matters:
#   * probing xrdp with a bare TCP connect makes it log a failed RDP handshake
#     every single time, which would bury real errors in the deploy logs;
#   * xrdp binds the session manager's "127.0.0.1" to ::1 on dual stack hosts,
#     so an IPv4-only connect probe reports a false outage (and would make the
#     watchdog restart a perfectly healthy service).
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

# http_ok <port> [path] -- returns 0 on a 2xx from the local status server.
http_ok() {
    local port="$1" path="${2:-/health}"
    python3 -c '
import sys, urllib.request
url = "http://127.0.0.1:%s%s" % (sys.argv[1], sys.argv[2])
try:
    with urllib.request.urlopen(url, timeout=5) as response:
        sys.exit(0 if 200 <= response.status < 300 else 1)
except Exception:
    sys.exit(1)
' "${port}" "${path}" 2>/dev/null
}

# render_template <src> <dst> -- substitutes @@KEY@@ placeholders from the
# exported environment. Keys are discovered from the template itself, so the
# caller only has to export the matching variables.
render_template() {
    local src="$1" dst="$2"
    [ -r "$src" ] || die "template not found: ${src}"
    python3 - "$src" "$dst" <<'PY'
import os
import re
import sys

src, dst = sys.argv[1], sys.argv[2]
with open(src, "r", encoding="utf-8") as fh:
    body = fh.read()

missing = []


def repl(match):
    key = match.group(1)
    value = os.environ.get(key)
    if value is None:
        missing.append(key)
        return match.group(0)
    return value


body = re.sub(r"@@([A-Z0-9_]+)@@", repl, body)
if missing:
    sys.stderr.write("missing template variables: %s\n" % ", ".join(sorted(set(missing))))
    sys.exit(1)

tmp = dst + ".tmp"
with open(tmp, "w", encoding="utf-8") as fh:
    fh.write(body)
os.replace(tmp, dst)
PY
}
