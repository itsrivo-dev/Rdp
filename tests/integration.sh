#!/usr/bin/env bash
# =============================================================================
#  End-to-end tests. Start the image the way Railway does and check that a
#  browser client can sign in and drive the real desktop.
#
#  tests/clients/rfb_probe.py plays the role of noVNC: it speaks the gateway's
#  WebSocket bridge, authenticates with VNC auth, takes screenshots and sends
#  pointer/keyboard input. A file created inside the container from the browser
#  side is the proof that the interactive desktop really works.
#
#  Usage: tests/integration.sh [image]        (default cloudpc:test)
#  Needs: docker, curl, jq, python3 (+ websocket-client, pycryptodome and
#  Pillow for the desktop tests - those are skipped with a NOTE if missing).
# =============================================================================
set -uo pipefail

IMAGE="${1:-cloudpc:test}"
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ARTIFACTS="${ARTIFACTS:-${REPO_DIR}/test-results}"
mkdir -p "${ARTIFACTS}"
cd "${REPO_DIR}" || exit 1

PROBE="tests/clients/rfb_probe.py"
HTTP_PORT_BASE="${HTTP_PORT_BASE:-18080}"
PASSWORD="CloudPc-Test-$(date +%s)-Aa1"
VNC_PASSWORD=""
COOKIE=""
CONTAINER="cloudpc-itest"
VOLUME="$(mktemp -d)"
BASE_URL=""

PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0
FAILED_TESTS=()
RED=$'\033[31m'; GRN=$'\033[32m'; YLW=$'\033[33m'; BLU=$'\033[1;34m'; RST=$'\033[0m'
[ -t 1 ] || { RED=""; GRN=""; YLW=""; BLU=""; RST=""; }

ok()      { PASS_COUNT=$((PASS_COUNT + 1)); printf '%sPASS%s %s\n' "${GRN}" "${RST}" "$*"; }
fail()    { FAIL_COUNT=$((FAIL_COUNT + 1)); FAILED_TESTS+=("$*"); printf '%sFAIL%s %s\n' "${RED}" "${RST}" "$*"; }
note()    { SKIP_COUNT=$((SKIP_COUNT + 1)); printf '%sNOTE%s %s\n' "${YLW}" "${RST}" "$*"; }
section() { printf '\n%s== %s ==%s\n' "${BLU}" "$*" "${RST}"; }

cleanup() {
    for name in "${CONTAINER}" "${CONTAINER}-2" "${CONTAINER}-3" "${CONTAINER}-4"; do
        docker rm -f "${name}" >/dev/null 2>&1 || true
    done
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------
http_code() { curl -s -o /dev/null -w '%{http_code}' --max-time 15 "$@" 2>/dev/null; }

desktop_ready() {
    local port="$1"
    curl -s --max-time 10 "http://127.0.0.1:${port}/health" 2>/dev/null \
        | jq -e '.desktop.ready == true and .desktop.panel == true and .desktop.window_manager == true' \
        >/dev/null 2>&1
}

wait_for_health() {
    local port="$1" want_desktop="${2:-true}" tries="${3:-240}"
    for _ in $(seq 1 "${tries}"); do
        if [ "$(http_code "http://127.0.0.1:${port}/health")" = "200" ]; then
            if [ "${want_desktop}" = "false" ]; then
                return 0
            fi
            desktop_ready "${port}" && return 0
        fi
        sleep 2
    done
    return 1
}

dump_diagnostics() {
    local name="$1" port="$2"
    {
        echo "### ${name} ###"
        echo "--- docker logs (tail) ---"
        docker logs "${name}" 2>&1 | tail -60
        echo "--- /health ---"
        curl -s --max-time 10 "http://127.0.0.1:${port}/health" || true
        echo
        echo "--- supervisor status ---"
        docker exec "${name}" supervisorctl -c /opt/cloudpc/supervisor/supervisord.conf status 2>&1 || true
        echo "--- processes ---"
        docker exec "${name}" ps -eo pid,user,comm --sort=pid 2>&1 | tail -30 || true
        echo "--- cloudpc-health ---"
        docker exec "${name}" cloudpc-health 2>&1 || true
        echo
    } >> "${ARTIFACTS}/diagnostics.log" 2>&1
}

start_container() {
    local name="$1" port="$2" with_volume="$3" extra_env="$4"
    local args=(docker run -d --name "${name}" -p "127.0.0.1:${port}:8080"
                -e PORT=8080 -e TZ=UTC
                -e RAILWAY_SERVICE_NAME=cloudpc-test -e RAILWAY_ENVIRONMENT_NAME=ci)
    if [ "${with_volume}" = "yes" ]; then
        args+=(-v "${VOLUME}:/data" -e RAILWAY_VOLUME_MOUNT_PATH=/data)
    fi
    if [ -n "${extra_env}" ]; then
        # shellcheck disable=SC2206  # deliberate word splitting of "-e A=B -e C=D"
        args+=(${extra_env})
    fi
    args+=("${IMAGE}")
    "${args[@]}" >/dev/null
}

# The desktop user's HOME can be on the volume, so resolve it from the container.
desktop_home() { docker exec "$1" getent passwd ubuntu 2>/dev/null | cut -d: -f6; }

run_as_desktop() {  # <container> <shell command>
    local container="$1"; shift
    local home
    home="$(desktop_home "${container}")"
    docker exec -u ubuntu -e HOME="${home}" -e DISPLAY=:1 -e XAUTHORITY="${home}/.Xauthority" \
        "${container}" bash -c "$*"
}

window_exists() {  # <container> <class>
    run_as_desktop "$1" "xdotool search --class $2" >/dev/null 2>&1
}

probe() {  # <url> <extra args...>
    local url="$1"; shift
    python3 "${PROBE}" --url "${url}" --cookie "${COOKIE}" --password "${VNC_PASSWORD}" "$@"
}

client_deps_ok() {
    python3 -c 'import websocket, Crypto, PIL' >/dev/null 2>&1
}

# ===========================================================================
section "0. image and prerequisites"
# ===========================================================================
if ! docker image inspect "${IMAGE}" >/dev/null 2>&1; then
    fail "image ${IMAGE} is not available"
    exit 1
fi
ok "image ${IMAGE} present"

if docker run --rm --entrypoint /bin/sh "${IMAGE}" -c 'command -v node >/dev/null 2>&1' >/dev/null 2>&1; then
    fail "Node.js is in the image (noVNC is served as plain ES modules and needs no bundler)"
else
    ok "no Node.js in the image: noVNC is served as static ES modules"
fi

for binary in Xtigervnc vncpasswd python3 supervisorctl xfce4-session xfwm4 xfce4-panel \
              thunar xfce4-terminal mousepad dbus-run-session xdg-user-dirs-update; do
    if docker run --rm --entrypoint /bin/sh "${IMAGE}" -c "command -v ${binary}" >/dev/null 2>&1; then
        ok "image provides ${binary}"
    else
        fail "image is missing ${binary}"
    fi
done

# ===========================================================================
section "1. boot: volume attached, password supplied by the service variable"
# ===========================================================================
PORT1="${HTTP_PORT_BASE}"
BASE_URL="http://127.0.0.1:${PORT1}"
if start_container "${CONTAINER}" "${PORT1}" yes "-e DESKTOP_PASSWORD=${PASSWORD} -e DESKTOP_PASSWORD_PRINT=false"; then
    ok "container started"
else
    fail "could not start the container"
    exit 1
fi

if wait_for_health "${PORT1}" true 300; then
    ok "gateway answered and the desktop is ready (X display + XFCE + panel + window manager)"
else
    fail "the desktop never became ready"
    dump_diagnostics "${CONTAINER}" "${PORT1}"
    docker logs "${CONTAINER}" 2>&1 | tail -40 | sed 's/^/     /'
fi

docker logs "${CONTAINER}" > "${ARTIFACTS}/container-1.log" 2>&1
HEALTH="$(curl -s --max-time 15 "${BASE_URL}/health")"
echo "${HEALTH}" > "${ARTIFACTS}/health-volume.json"

[ "$(jq -r '.service' <<<"${HEALTH}")" = "ubuntu-cloud-pc" ] \
    && ok "/health identifies the service" || fail "/health service name wrong"
[ "$(jq -r '.checks.vnc' <<<"${HEALTH}")" = "true" ] \
    && ok "/health sees the VNC display server" || fail "/health does not see the display server"
[ "$(jq -r '.checks.dbus' <<<"${HEALTH}")" = "true" ] \
    && ok "/health sees the system bus" || fail "/health does not see dbus"
[ "$(jq -r '.checks.xfce' <<<"${HEALTH}")" = "true" ] \
    && ok "/health sees a running XFCE session" || fail "/health does not see XFCE"
[ "$(jq -r '.storage.persistent' <<<"${HEALTH}")" = "true" ] \
    && ok "/health reports persistent storage" || fail "/health does not see the volume"
if grep -q "${PASSWORD}" <<<"${HEALTH}"; then
    fail "/health leaked the password"
else
    ok "/health contains no credentials"
fi

if grep -q "UBUNTU CLOUD PC IS READY" "${ARTIFACTS}/container-1.log"; then
    ok "the operator banner is printed on startup"
else
    fail "the startup banner is missing"
fi
if grep -q "${PASSWORD}" "${ARTIFACTS}/container-1.log"; then
    fail "the password appears in the container logs"
else
    ok "the password never appears in the container logs"
fi
if grep -qi "not printed\|DESKTOP_PASSWORD service variable" "${ARTIFACTS}/container-1.log"; then
    ok "the banner explains that DESKTOP_PASSWORD is not printed"
else
    note "no explicit 'not printed' note in the banner"
fi

# ===========================================================================
section "2. access control at the door"
# ===========================================================================
LOGIN_BODY="$(curl -s --max-time 15 "${BASE_URL}/")"
grep -q "<form" <<<"${LOGIN_BODY}" && ok "GET / serves the login page" \
    || fail "GET / did not serve a login form"
grep -q "Desktop password" <<<"${LOGIN_BODY}" && ok "the login page asks for the password" \
    || fail "the login page has no password field"
grep -q "${PASSWORD}" <<<"${LOGIN_BODY}" && fail "the login page leaked the password" \
    || ok "the login page contains no credentials"
grep -qi "manifest.webmanifest" <<<"${LOGIN_BODY}" && ok "login page is installable (web app manifest)" \
    || note "login page does not reference the manifest"

for path in "/vnc/" "/vnc/index.html" "/vnc/core/rfb.js" "/vnc/package.json" "/api/session" "/api/diagnostics"; do
    code="$(http_code "${BASE_URL}${path}")"
    [ "${code}" = "401" ] && ok "unauthenticated ${path} -> 401" \
        || fail "unauthenticated ${path} -> ${code} (expected 401)"
done
code="$(http_code "${BASE_URL}/websockify")"
[ "${code}" = "401" ] && ok "unauthenticated /websockify -> 401" \
    || fail "unauthenticated /websockify -> ${code} (expected 401)"

for path in "/static/icon-192.png" "/manifest.webmanifest" "/favicon.ico"; do
    code="$(http_code "${BASE_URL}${path}")"
    [ "${code}" = "200" ] && ok "public asset ${path} -> 200" \
        || fail "public asset ${path} -> ${code}"
done

code="$(http_code "${BASE_URL}/does-not-exist")"
[ "${code}" = "404" ] && ok "unknown paths return 404" || fail "unknown path -> ${code}"

# ===========================================================================
section "3. login"
# ===========================================================================
WRONG="$(curl -s -D - -o /dev/null --max-time 15 -X POST -d "password=wrong-${PASSWORD}" "${BASE_URL}/login")"
grep -q "^HTTP/1.1 401" <<<"${WRONG}" && ok "a wrong password is rejected with 401" \
    || fail "a wrong password was not rejected (got $(head -1 <<<"${WRONG}"))"
grep -qi "^set-cookie" <<<"${WRONG}" && fail "a session cookie was issued for a wrong password" \
    || ok "no session cookie for a failed login"

LOGIN="$(curl -s -D - -o /dev/null --max-time 15 -X POST -d "password=${PASSWORD}" "${BASE_URL}/login")"
grep -q "^HTTP/1.1 303" <<<"${LOGIN}" && ok "the correct password is accepted (303 -> desktop)" \
    || fail "the correct password was rejected: $(head -1 <<<"${LOGIN}")"
grep -qi "^set-cookie: cloudpc_session=" <<<"${LOGIN}" && ok "a session cookie is issued" \
    || fail "no session cookie in the login response"
grep -qi "httponly" <<<"${LOGIN}" && ok "the session cookie is HttpOnly" \
    || fail "the session cookie is not HttpOnly"
grep -qi "samesite=lax" <<<"${LOGIN}" && ok "the session cookie is SameSite=Lax" \
    || fail "the session cookie has no SameSite"
grep -qi "secure" <<<"${LOGIN}" && fail "the cookie is Secure over plain HTTP (local access would break)" \
    || ok "the cookie is not Secure over plain HTTP"

TLS="$(curl -s -D - -o /dev/null --max-time 15 -X POST -d "password=${PASSWORD}" \
    -H "X-Forwarded-Proto: https" "${BASE_URL}/login")"
grep -qi "secure" <<<"${TLS}" && ok "the cookie becomes Secure behind the HTTPS proxy (Railway)" \
    || fail "the cookie is not Secure when the request arrived over HTTPS"

COOKIE="$(grep -i '^set-cookie:' <<<"${LOGIN}" | head -1 | sed 's/^[Ss]et-[Cc]ookie: //' | cut -d';' -f1 | tr -d '\r')"
[ -n "${COOKIE}" ] && ok "session cookie captured for the desktop tests" \
    || fail "could not capture the session cookie"

# ===========================================================================
section "4. the desktop application served to signed-in clients"
# ===========================================================================
VNC_HTML="$(curl -s --max-time 20 -H "Cookie: ${COOKIE}" "${BASE_URL}/vnc/")"
grep -q "Ubuntu Desktop" <<<"${VNC_HTML}" && ok "/vnc/ serves the Cloud PC desktop page" \
    || fail "/vnc/ did not serve the patched noVNC page"
grep -q "api/session" <<<"${VNC_HTML}" && ok "the page asks the gateway for its session" \
    || fail "the desktop page does not talk to the gateway"
grep -q "noVNC_container" <<<"${VNC_HTML}" && ok "the noVNC interface markup is intact" \
    || fail "noVNC markup is missing from the page"

for asset in "/vnc/app/ui.js" "/vnc/core/rfb.js" "/vnc/vendor/pako/lib/zlib/inflate.js" \
             "/vnc/app/styles/base.css" "/vnc/package.json"; do
    code="$(http_code -H "Cookie: ${COOKIE}" "${BASE_URL}${asset}")"
    [ "${code}" = "200" ] && ok "asset ${asset} -> 200" || fail "asset ${asset} -> ${code}"
done

ETAG="$(curl -s -D - -o /dev/null --max-time 15 -H "Cookie: ${COOKIE}" "${BASE_URL}/vnc/app/ui.js" \
    | grep -i '^etag:' | sed 's/^[Ee][Tt][Aa][Gg]: //' | tr -d '\r')"
[ -n "${ETAG}" ] && ok "static assets carry an ETag (${ETAG})" || fail "no ETag on static assets"
code="$(http_code -H "Cookie: ${COOKIE}" -H "If-None-Match: ${ETAG}" "${BASE_URL}/vnc/app/ui.js")"
[ "${code}" = "304" ] && ok "a conditional request returns 304" || fail "If-None-Match -> ${code} (expected 304)"

if curl -s -D - -o /dev/null --max-time 20 -H "Cookie: ${COOKIE}" -H "Accept-Encoding: gzip" \
        "${BASE_URL}/vnc/app/ui.js" | grep -qi "content-encoding: gzip"; then
    ok "text assets are gzipped when the client asks (mobile bandwidth)"
else
    fail "no gzip Content-Encoding for ui.js"
fi

SESSION="$(curl -s --max-time 15 -H "Cookie: ${COOKIE}" "${BASE_URL}/api/session")"
echo "${SESSION}" > "${ARTIFACTS}/session.json"
VNC_PASSWORD="$(jq -r '.vnc_password // empty' <<<"${SESSION}")"
[ -n "${VNC_PASSWORD}" ] && ok "/api/session hands the VNC password to a signed-in client" \
    || fail "/api/session returned no VNC password"
[ "$(jq -r '.ws_path' <<<"${SESSION}")" = "websockify" ] && ok "the session points at /websockify" \
    || fail "unexpected ws_path in /api/session"
[ "$(jq -r '.desktop.ready' <<<"${SESSION}")" = "true" ] && ok "the session reports the desktop ready" \
    || fail "the session says the desktop is not ready"

code="$(http_code --path-as-is -H "Cookie: ${COOKIE}" "${BASE_URL}/vnc/../../etc/passwd")"
if [ "${code}" = "404" ] || [ "${code}" = "403" ]; then ok "path traversal is refused (${code})"
else fail "path traversal returned ${code}"; fi
code="$(http_code -X PUT -H "Cookie: ${COOKIE}" "${BASE_URL}/api/session")"
[ "${code}" = "405" ] && ok "unsupported methods are rejected (405)" || fail "PUT -> ${code}"

# ===========================================================================
section "5. the real desktop: RFB handshake, screenshots, input"
# ===========================================================================
if client_deps_ok; then
    WS_URL="ws://127.0.0.1:${PORT1}/websockify"

    if probe "${WS_URL}" --password "${VNC_PASSWORD}" --out /dev/null \
            --cookie "cloudpc_session=forged-token" >/dev/null 2>&1; then
        fail "the websocket bridge accepted a forged session cookie"
    else
        ok "the websocket bridge refuses a forged session cookie"
    fi

    if probe "${WS_URL}" --subprotocol binary --out "${ARTIFACTS}/desktop-1.png" \
            --json > "${ARTIFACTS}/probe-1.json" 2>&1; then
        ok "RFB handshake over the WebSocket bridge succeeded"
    else
        fail "the RFB probe failed: $(tail -3 "${ARTIFACTS}/probe-1.json" | tr '\n' ' ')"
    fi
    RES="$(jq -r '(.width|tostring) + "x" + (.height|tostring)' "${ARTIFACTS}/probe-1.json" 2>/dev/null)"
    [ "${RES}" = "1280x720" ] && ok "the desktop is ${RES}" || fail "unexpected resolution: ${RES}"
    [ "$(jq -r '.desktop_name' "${ARTIFACTS}/probe-1.json" 2>/dev/null)" = "Ubuntu Cloud Desktop" ] \
        && ok "TigerVNC advertises the desktop name" || note "desktop name differs from the default"

    if [ -s "${ARTIFACTS}/desktop-1.png" ]; then
        ANALYSIS="$(python3 - "${ARTIFACTS}/desktop-1.png" <<'PY'
import sys
from PIL import Image
image = Image.open(sys.argv[1]).convert("RGB")
width, height = image.size
pixels = list(image.getdata())
sample = pixels[:: max(1, len(pixels) // 20000)]
unique = len(set(sample))
dark = sum(1 for r, g, b in sample if (r + g + b) / 3 < 120)
# The panel is the bottom 40 pixels; it must differ from the middle of the screen.
panel = [pixels[y * width + x] for y in range(height - 30, height - 5, 5) for x in range(0, width, 40)]
middle = [pixels[y * width + x] for y in range(height // 2 - 40, height // 2 + 40, 8) for x in range(0, width, 40)]
panel_avg = tuple(sum(c[i] for c in panel) // len(panel) for i in range(3))
middle_avg = tuple(sum(c[i] for c in middle) // len(middle) for i in range(3))
print("%d %d %d %d" % (unique, dark, len(sample),
                         abs(panel_avg[0] - middle_avg[0])))
PY
)"
        read -r UNIQUE DARK TOTAL PANEL_DELTA <<<"${ANALYSIS}"
        [ "${UNIQUE:-0}" -gt 20 ] && ok "the screenshot is a real desktop (${UNIQUE} distinct colours in sample)" \
            || fail "the screenshot looks empty (${UNIQUE} distinct colours)"
        RATIO=$(( DARK * 100 / (TOTAL > 0 ? TOTAL : 1) ))
        [ "${RATIO}" -gt 40 ] && ok "the desktop uses the dark theme/background (${RATIO}% dark pixels)" \
            || note "only ${RATIO}% of sampled pixels are dark - check the theme"
        [ "${PANEL_DELTA:-0}" -ge 3 ] && ok "the bottom panel is drawn (panel/middle difference ${PANEL_DELTA})" \
            || note "panel and desktop background look identical (${PANEL_DELTA})"
    else
        fail "no first screenshot was produced"
    fi

    # --- pointer + keyboard: prove a terminal receives browser input ---------
    SHORTCUT_XML="$(desktop_home "${CONTAINER}")/.config/xfce4/xfconf/xfce-perchannel-xml/xfce4-keyboard-shortcuts.xml"
    for _ in $(seq 1 20); do
        docker exec "${CONTAINER}" test -f "${SHORTCUT_XML}" 2>/dev/null && break
        sleep 1
    done
    if docker exec "${CONTAINER}" grep -q "Alt&gt;t" "${SHORTCUT_XML}" 2>/dev/null; then
        ok "the Ctrl+Alt+T shortcut is registered by the desktop defaults"
    else
        note "the keyboard shortcut file is missing - falling back to clicking the panel"
    fi

    PROOF="/tmp/cloudpc-input-proof-$(date +%s)"
    docker exec "${CONTAINER}" rm -f "${PROOF}" >/dev/null 2>&1
    TERMINAL_OPEN=0
    if probe "${WS_URL}" --combo ctrl-alt-t --pause 6 --settle 3 --json \
            > "${ARTIFACTS}/probe-2.json" 2>&1; then
        for _ in $(seq 1 10); do
            window_exists "${CONTAINER}" xfce4-terminal && { TERMINAL_OPEN=1; break; }
            sleep 1
        done
    fi
    [ "${TERMINAL_OPEN}" = "1" ] && ok "Ctrl+Alt+T opened a terminal inside the desktop" \
        || note "Ctrl+Alt+T did not open a terminal - trying the panel launcher"

    if [ "${TERMINAL_OPEN}" = "0" ]; then
        for x in 78 100 60 120 45; do
            probe "${WS_URL}" --click "${x},700" --pause 5 --settle 2 --json \
                > "${ARTIFACTS}/probe-click.json" 2>&1 || true
            window_exists "${CONTAINER}" xfce4-terminal && { TERMINAL_OPEN=1; break; }
        done
        [ "${TERMINAL_OPEN}" = "1" ] && ok "clicking the panel launcher opened a terminal" \
            || fail "could not open a terminal window from the browser session"
    fi

    if [ "${TERMINAL_OPEN}" = "1" ]; then
        if probe "${WS_URL}" --type "touch ${PROOF}
" --out2 "${ARTIFACTS}/desktop-2.png" --settle 5 --json > "${ARTIFACTS}/probe-3.json" 2>&1; then
            ok "keyboard input was delivered to the desktop"
        else
            fail "sending keystrokes failed: $(tail -3 "${ARTIFACTS}/probe-3.json" | tr '\n' ' ')"
        fi
        FOUND=0
        for _ in $(seq 1 20); do
            docker exec "${CONTAINER}" test -f "${PROOF}" 2>/dev/null && { FOUND=1; break; }
            sleep 2
        done
        if [ "${FOUND}" = "1" ]; then
            ok "a command typed in the browser ran in a terminal inside the desktop"
        else
            fail "the typed command never ran (keyboard input did not reach the shell)"
        fi
    fi

    if [ -s "${ARTIFACTS}/desktop-1.png" ] && [ -s "${ARTIFACTS}/desktop-2.png" ]; then
        CHANGED="$(python3 - "${ARTIFACTS}/desktop-1.png" "${ARTIFACTS}/desktop-2.png" <<'PY'
import sys
from PIL import Image, ImageChops
a = Image.open(sys.argv[1]).convert("RGB")
b = Image.open(sys.argv[2]).convert("RGB")
if a.size != b.size:
    print("resized")
    raise SystemExit
changed = sum(1 for pixel in ImageChops.difference(a, b).getdata() if sum(pixel) > 30)
print(changed)
PY
)"
        if [ "${CHANGED}" = "resized" ]; then
            note "the desktop changed size between probes"
        elif [ "${CHANGED:-0}" -gt 500 ]; then
            ok "the screen changed after the input (${CHANGED} pixels) - the desktop is interactive"
        else
            fail "the screen did not change after input (${CHANGED} pixels)"
        fi
    fi

    # --- clipboard from the desktop to the browser --------------------------
    if ! docker exec "${CONTAINER}" bash -c 'command -v xclip' >/dev/null 2>&1; then
        docker exec "${CONTAINER}" bash -c \
            'apt-get update -qq >/dev/null 2>&1 && apt-get install -y -qq xclip >/dev/null 2>&1' \
            >/dev/null 2>&1 || true
    fi
    if docker exec "${CONTAINER}" bash -c 'command -v xclip' >/dev/null 2>&1; then
        run_as_desktop "${CONTAINER}" 'printf clipboard-sync-proof | xclip -selection clipboard' >/dev/null 2>&1
        sleep 2
        if probe "${WS_URL}" --read-clipboard --json > "${ARTIFACTS}/probe-4.json" 2>&1 \
           && jq -e '.clipboard | test("clipboard-sync-proof")' "${ARTIFACTS}/probe-4.json" >/dev/null 2>&1; then
            ok "the desktop clipboard reaches the browser session"
        else
            note "clipboard round trip not confirmed: $(jq -r '.clipboard // .error // "no data"' \
                "${ARTIFACTS}/probe-4.json" 2>/dev/null)"
        fi
    else
        note "xclip unavailable in the container - clipboard test skipped"
    fi
else
    note "websocket-client / pycryptodome / Pillow missing - desktop interaction tests skipped"
fi

# ===========================================================================
section "6. the desktop itself, seen from inside the container"
# ===========================================================================
for process in Xtigervnc xfce4-session xfwm4 xfce4-panel xfdesktop xfsettingsd; do
    if docker exec "${CONTAINER}" pgrep -x "${process}" >/dev/null 2>&1; then
        ok "${process} is running"
    else
        fail "${process} is not running"
    fi
done

HOME_DIR="$(desktop_home "${CONTAINER}")"
DIMENSIONS="$(docker exec -u ubuntu -e HOME="${HOME_DIR}" -e DISPLAY=:1 \
    -e XAUTHORITY="${HOME_DIR}/.Xauthority" "${CONTAINER}" xdpyinfo 2>/dev/null \
    | awk '/dimensions:/ {print $2}')"
[ "${DIMENSIONS}" = "1280x720" ] && ok "the X display really is ${DIMENSIONS}" \
    || fail "the X display reports '${DIMENSIONS}'"

for app in thunar xfce4-terminal mousepad xfce4-screenshooter xfce4-taskmanager; do
    if run_as_desktop "${CONTAINER}" "${app} --version" >/dev/null 2>&1; then
        ok "${app} runs inside the desktop"
    else
        note "${app} --version did not answer (some apps do not support --version)"
    fi
done

LISTENERS="$(docker exec "${CONTAINER}" python3 -c '
import glob
for path in sorted(glob.glob("/proc/net/tcp") + glob.glob("/proc/net/tcp6")):
    for line in open(path).read().splitlines()[1:]:
        fields = line.split()
        if fields[3] != "0A":
            continue
        address, port = fields[1].rsplit(":", 1)
        print("%s %d" % (address, int(port, 16)))
')"
grep -q "^0100007F 5900$" <<<"${LISTENERS}" && ok "VNC listens on 127.0.0.1:5900" \
    || fail "VNC is not bound to loopback: $(grep ' 5900$' <<<"${LISTENERS}" | tr '\n' ' ')"
if grep -qE "^(00000000|00000000000000000000000000000000) 5900$" <<<"${LISTENERS}"; then
    fail "VNC is listening on a public interface"
else
    ok "there is no public VNC listener"
fi
grep -qE "^(00000000|00000000000000000000000000000000) 8080$" <<<"${LISTENERS}" \
    && ok "the gateway listens on 0.0.0.0:8080 (Railway ingress)" \
    || fail "the gateway does not listen on all interfaces"

if docker exec "${CONTAINER}" grep -rq "${PASSWORD}" /run/cloudpc/auth.json /run/cloudpc/runtime.json 2>/dev/null; then
    fail "a plaintext secret is stored in the runtime files"
else
    ok "the runtime files hold hashes and metadata only"
fi
if docker exec "${CONTAINER}" sh -c 'stat -c %a /run/cloudpc/session.key' 2>/dev/null | grep -q "640"; then
    ok "the session key is mode 640 (root:cloudpc)"
else
    note "unexpected session key permissions"
fi

# ===========================================================================
section "7. brute-force protection"
# ===========================================================================
BLOCKED=0
ATTEMPTS=0
for attempt in $(seq 1 8); do
    ATTEMPTS="${attempt}"
    code="$(http_code -X POST -d "password=definitely-wrong-${attempt}" \
        -H "X-Forwarded-For: 203.0.113.7" "${BASE_URL}/login")"
    if [ "${code}" = "429" ]; then
        BLOCKED=1
        break
    fi
done
[ "${BLOCKED}" = "1" ] && ok "repeated failed logins are rate limited (429 after ${ATTEMPTS} attempts)" \
    || fail "the login form was never rate limited"
code="$(http_code "${BASE_URL}/health")"
[ "${code}" = "200" ] && ok "health checks keep working while logins are throttled" \
    || fail "health endpoint broke during throttling"

# ===========================================================================
section "8. persistence across a container replacement"
# ===========================================================================
run_as_desktop "${CONTAINER}" 'echo persistence-probe > "$HOME/persist.txt"' >/dev/null 2>&1
[ -f "${VOLUME}/home/ubuntu/persist.txt" ] && ok "the home directory lives on the volume" \
    || fail "the home directory is not on the volume"
[ -f "${VOLUME}/home/ubuntu/.config/xfce4/xfconf/xfce-perchannel-xml/xfwm4.xml" ] \
    && ok "the desktop configuration is persisted" || fail "the desktop configuration is not persisted"
[ -f "${VOLUME}/.secrets/session.key" ] && ok "the session signing key is persisted" \
    || fail "the session key is not persisted"
[ -f "${VOLUME}/.secrets/vnc_password" ] && ok "the VNC password is persisted" \
    || fail "the VNC password is not persisted"

docker stop -t 30 "${CONTAINER}" >/dev/null 2>&1
CLEAN_STOPS="$(docker logs "${CONTAINER}" 2>&1 | grep -cE \
    "stopped: (watchdog|gateway|session|vnc|dbus) \((exit status|terminated by SIGTERM)")"
[ "${CLEAN_STOPS:-0}" -ge 4 ] && ok "services stop cleanly on SIGTERM (${CLEAN_STOPS} clean stops)" \
    || note "only ${CLEAN_STOPS} clean shutdown markers found"
docker rm -f "${CONTAINER}" >/dev/null 2>&1

PORT2=$((HTTP_PORT_BASE + 1))
if start_container "${CONTAINER}-2" "${PORT2}" yes ""; then
    ok "container restarted on the same volume without DESKTOP_PASSWORD"
else
    fail "could not restart the container"
fi
if wait_for_health "${PORT2}" true 300; then
    ok "the desktop came back after the container replacement"
else
    fail "the desktop did not come back"
    dump_diagnostics "${CONTAINER}-2" "${PORT2}"
fi

GENERATED_PASSWORD="$(docker logs "${CONTAINER}-2" 2>&1 \
    | sed -n 's/^ *Password *: *\([A-Za-z0-9-]\{20,\}\).*$/\1/p' | head -1)"
[ -n "${GENERATED_PASSWORD}" ] && ok "the generated password is printed for the operator" \
    || note "no password line in the logs (printing may be disabled)"
STORED_PASSWORD="$(docker exec "${CONTAINER}-2" cat /data/.secrets/desktop_password 2>/dev/null)"
if [ -n "${GENERATED_PASSWORD}" ] && [ "${GENERATED_PASSWORD}" = "${STORED_PASSWORD}" ]; then
    ok "the printed password matches the one stored on the volume"
else
    fail "the printed password and the stored password differ"
fi

NEW_LOGIN="$(curl -s -D - -o /dev/null --max-time 15 -X POST \
    -d "password=${GENERATED_PASSWORD}" "http://127.0.0.1:${PORT2}/login")"
grep -q "^HTTP/1.1 303" <<<"${NEW_LOGIN}" && ok "the generated password signs in" \
    || fail "the generated password does not sign in"
code="$(http_code -H "Cookie: ${COOKIE}" "http://127.0.0.1:${PORT2}/api/session")"
[ "${code}" = "200" ] && ok "the earlier session still works (signing key persisted)" \
    || note "the earlier session was invalidated (${code})"
docker exec "${CONTAINER}-2" test -f "/data/home/ubuntu/persist.txt" 2>/dev/null \
    && ok "user files survived the replacement" || fail "user files were lost"

PORT3=$((HTTP_PORT_BASE + 2))
docker rm -f "${CONTAINER}-2" >/dev/null 2>&1
if start_container "${CONTAINER}-3" "${PORT3}" yes "" && wait_for_health "${PORT3}" true 300; then
    THIRD_PASSWORD="$(docker logs "${CONTAINER}-3" 2>&1 \
        | sed -n 's/^ *Password *: *\([A-Za-z0-9-]\{20,\}\).*$/\1/p' | head -1)"
    [ "${THIRD_PASSWORD}" = "${GENERATED_PASSWORD}" ] && ok "the password is stable across restarts" \
        || fail "the password changed after a restart"
else
    fail "the third container did not start"
fi
docker stop -t 30 "${CONTAINER}-3" >/dev/null 2>&1
docker rm -f "${CONTAINER}-3" >/dev/null 2>&1

# ===========================================================================
section "9. ephemeral storage (no volume) still works and warns"
# ===========================================================================
PORT4=$((HTTP_PORT_BASE + 3))
if start_container "${CONTAINER}-4" "${PORT4}" "" ""; then
    ok "a container without a volume starts"
else
    fail "a container without a volume failed to start"
fi
if wait_for_health "${PORT4}" true 300; then
    ok "the desktop also works without a volume"
else
    fail "the desktop did not start without a volume"
    dump_diagnostics "${CONTAINER}-4" "${PORT4}"
fi
curl -s --max-time 10 "http://127.0.0.1:${PORT4}/health" > "${ARTIFACTS}/health-ephemeral.json"
[ "$(jq -r '.storage.persistent' "${ARTIFACTS}/health-ephemeral.json")" = "false" ] \
    && ok "/health reports storage as not persistent" || fail "/health wrongly claims persistence"
docker logs "${CONTAINER}-4" 2>&1 | grep -q "WILL BE LOST" \
    && ok "the data-loss warning is printed" || fail "no ephemeral storage warning"
docker stop -t 30 "${CONTAINER}-4" >/dev/null 2>&1
docker rm -f "${CONTAINER}-4" >/dev/null 2>&1

# ===========================================================================
section "summary"
# ===========================================================================
printf 'passed: %s%d%s  failed: %s%d%s  skipped: %s%d%s\n' \
    "${GRN}" "${PASS_COUNT}" "${RST}" "${RED}" "${FAIL_COUNT}" "${RST}" "${YLW}" "${SKIP_COUNT}" "${RST}"
if [ "${FAIL_COUNT}" -gt 0 ]; then
    printf '\nfailed checks:\n'
    printf '  - %s\n' "${FAILED_TESTS[@]}"
    exit 1
fi
exit 0
