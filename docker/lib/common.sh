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

# tcp_open <host> <port> -- returns 0 when a TCP connect succeeds.
# The subshell owns the file descriptor, so nothing leaks into the caller.
tcp_open() {
    (exec 3<>"/dev/tcp/${1}/${2}") >/dev/null 2>&1
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
