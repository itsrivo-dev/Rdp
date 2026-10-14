#!/usr/bin/env bash
# =============================================================================
#  verify_deployment.sh - check the *deployed* desktop over the public HTTPS
#  URL, from a machine that can reach it (GitHub Actions, your laptop).
#
#  This is the counterpart of tests/integration.sh: that one runs the image
#  locally, this one has no Docker and no container access - it only uses what
#  a phone browser can see, which is exactly what has to be verified before the
#  desktop can be called reachable:
#
#    * the URL answers over HTTPS and serves the login page
#    * the login page is self-contained (no external assets, mobile viewport)
#    * health/readiness report the desktop, the VNC server and the volume
#    * nothing behind the login is readable without a session cookie
#    * the VNC port is not exposed to the internet
#
#  It never needs the password and never prints it: sign in from the phone is
#  the one step a script cannot do for you.
#
#  Usage: tests/verify_deployment.sh <https-url> [--wait SECONDS] [--json-out FILE]
#  Exit status: 0 when every check passed, 1 otherwise, 2 for a bad invocation.
# =============================================================================
set -uo pipefail

URL=""
WAIT=0
JSON_OUT=""
while [ $# -gt 0 ]; do
    case "$1" in
        --wait) WAIT="${2:-0}"; shift 2 ;;
        --json-out) JSON_OUT="${2:-}"; shift 2 ;;
        -h|--help) sed -n '2,26p' "$0"; exit 0 ;;
        -*) printf 'unknown option: %s\n' "$1" >&2; exit 2 ;;
        *) URL="$1"; shift ;;
    esac
done

if [ -z "${URL}" ]; then
    printf 'usage: %s <https-url> [--wait SECONDS]\n' "$0" >&2
    exit 2
fi
case "${URL}" in
    https://*) ;;
    http://*)
        # Local runs of this very script are useful while developing, but a
        # deployment must be reached over HTTPS: only allow plain HTTP when it
        # is requested explicitly.
        if [ "${CLOUDPC_ALLOW_HTTP:-0}" != "1" ]; then
            printf 'the URL must start with https:// (Railway terminates TLS for you);\n' >&2
            printf 'set CLOUDPC_ALLOW_HTTP=1 to check a local gateway.\n' >&2
            exit 2
        fi
        printf 'WARNING: checking a plain HTTP URL because CLOUDPC_ALLOW_HTTP=1\n'
        ;;
    *) printf 'the URL must start with https:// (Railway terminates TLS for you)\n' >&2; exit 2 ;;
esac
BASE="${URL%/}"

PASS_COUNT=0
FAIL_COUNT=0
FAILED=()
ok()   { PASS_COUNT=$((PASS_COUNT + 1)); printf 'PASS %s\n' "$*"; }
fail() { FAIL_COUNT=$((FAIL_COUNT + 1)); FAILED+=("$*"); printf 'FAIL %s\n' "$*"; }

http_code() { curl -s -o /dev/null -w '%{http_code}' --max-time 30 "$@" 2>/dev/null; }

# --- wait for the deployment to answer --------------------------------------
DEADLINE=$(( $(date +%s) + WAIT ))
while :; do
    CODE="$(http_code "${BASE}/")"
    if [ "${CODE}" = "200" ] || [ "${CODE}" = "503" ]; then
        break
    fi
    if [ "$(date +%s)" -ge "${DEADLINE}" ]; then
        break
    fi
    printf 'waiting for %s to answer (http %s)...\n' "${BASE}" "${CODE}"
    sleep 10
done

# --- 1. the door -------------------------------------------------------------
LOGIN="$(mktemp)"
CODE="$(curl -s -o "${LOGIN}" -w '%{http_code}' --max-time 30 "${BASE}/")"
[ "${CODE}" = "200" ] && ok "GET / -> 200 over HTTPS" || fail "GET / -> ${CODE} (expected 200)"
if grep -q "Ubuntu Cloud PC" "${LOGIN}" 2>/dev/null; then
    ok "the login page is served"
else
    fail "the response is not the Cloud PC login page"
fi
if grep -qi 'type="password"' "${LOGIN}" 2>/dev/null; then
    ok "the login page has a password field"
else
    fail "the login page has no password field"
fi
if grep -qi 'name="viewport"' "${LOGIN}" 2>/dev/null; then
    ok "the page is declared responsive (mobile viewport)"
else
    fail "no viewport meta tag: the page would be unreadable on a phone"
fi
if grep -qE 'src="http|href="http' "${LOGIN}" 2>/dev/null; then
    fail "the login page loads external assets"
else
    ok "the login page loads no external assets"
fi

# --- 2. health ---------------------------------------------------------------
HEALTH="$(curl -s --max-time 30 "${BASE}/health")"
if [ -n "${HEALTH}" ] && printf '%s' "${HEALTH}" | grep -q '"service": *"ubuntu-cloud-pc"'; then
    ok "/health identifies the service"
else
    fail "/health did not answer with the expected JSON"
fi
if printf '%s' "${HEALTH}" | grep -q '"ready": *true'; then
    ok "/health reports the desktop ready (X display + XFCE session)"
else
    fail "/health does not report a ready desktop: ${HEALTH:-no answer}"
fi
if printf '%s' "${HEALTH}" | grep -q '"vnc_listening": *true'; then
    ok "/health sees the VNC display server"
else
    fail "/health does not see the VNC display server"
fi
if printf '%s' "${HEALTH}" | grep -q '"persistent": *true'; then
    ok "persistent storage is configured (volume mounted)"
else
    printf 'NOTE storage is ephemeral - everything is lost on redeploy\n'
fi
if printf '%s' "${HEALTH}" | grep -qi "password"; then
    fail "/health exposes credential-looking fields"
else
    ok "/health contains no credentials"
fi
if [ -n "${JSON_OUT}" ]; then
    printf '%s\n' "${HEALTH}" > "${JSON_OUT}" 2>/dev/null || true
fi

# --- 3. nothing behind the login is public ----------------------------------
for path in /vnc/ /vnc/core/rfb.js /api/session /api/diagnostics /websockify; do
    CODE="$(http_code "${BASE}${path}")"
    if [ "${CODE}" = "401" ] || [ "${CODE}" = "403" ]; then
        ok "unauthenticated ${path} -> ${CODE}"
    else
        fail "unauthenticated ${path} -> ${CODE} (expected 401)"
    fi
done

# --- 4. the VNC port must not be reachable from outside ---------------------
HOST="$(printf '%s' "${BASE}" | sed -E 's#^https?://([^/:]+).*#\1#')"
if timeout 8 bash -c "exec 3<>/dev/tcp/${HOST}/5900" 2>/dev/null; then
    fail "port 5900 answers on ${HOST}: the VNC server is exposed to the internet"
else
    ok "no public VNC port on ${HOST} (the browser gateway is the only way in)"
fi

# --- 5. a wrong password must not open anything -----------------------------
WRONG="$(curl -s -o /dev/null -D - --max-time 30 -X POST --data-urlencode "password=definitely-not-the-password" "${BASE}/login")"
if printf '%s' "${WRONG}" | grep -qE "^HTTP/[0-9.]+ (401|429)"; then
    ok "a wrong password is refused ($(printf '%s' "${WRONG}" | head -1 | tr -d '\r'))"
else
    fail "a wrong password was not refused: $(printf '%s' "${WRONG}" | head -1 | tr -d '\r')"
fi
if printf '%s' "${WRONG}" | grep -qi "^set-cookie"; then
    fail "a session cookie was issued for a wrong password"
else
    ok "no session cookie without a correct password"
fi

# --- summary -----------------------------------------------------------------
rm -f "${LOGIN}"
printf '\npassed: %d  failed: %d\n' "${PASS_COUNT}" "${FAIL_COUNT}"
if [ "${FAIL_COUNT}" -gt 0 ]; then
    printf '\nfailed checks:\n'
    printf '  - %s\n' "${FAILED[@]}"
    printf '\nThe deployment is not usable yet. Check the Railway deploy logs\n(service -> Deployments -> the newest one) and the container log.\n'
    exit 1
fi
printf '\nThe deployed desktop answers correctly and keeps everything behind the login.\n'
printf 'Open %s/ in Chrome on the phone and sign in with the desktop password.\n' "${BASE}"
