#!/usr/bin/env bash
# =============================================================================
#  Ubuntu Cloud PC - end to end test suite
# =============================================================================
#  Builds nothing: point it at an image that is already built.
#
#    tests/integration.sh [IMAGE]            (default: cloudpc:test)
#
#  Requirements on the host: docker, and - for the real RDP login test -
#  xfreerdp (freerdp2-x11) plus xvfb-run. The RDP tests are skipped with a
#  loud warning when those are not installed.
#
#  Everything it checks:
#    1  container boots and stays up
#    2  startup banner prints the generated credentials
#    3  /health becomes 200 and reports the expected structure
#    4  only the intended ports listen on a public interface
#    5  desktop toolchain works (python, pip, node, npm, git, editors, ...)
#    6  a real RDP client can authenticate and gets an XFCE session
#    7  file manager and terminal open inside that session
#    8  the session survives client disconnect and is resumed on reconnect
#    9  /admin requires authentication and works with the desktop credentials
#   10  logs are free of fatal errors
#   11  SIGTERM shuts the container down gracefully (exit 0)
#   12  volume data and the password survive a container replacement
#   13  running without a volume prints the ephemeral storage warning
# =============================================================================
set -uo pipefail

IMAGE="${1:-cloudpc:test}"
CONTAINER="cloudpc-test-$$"
VOLUME="cloudpc-test-vol-$$"
HOST_RDP_PORT="${HOST_RDP_PORT:-13389}"
HOST_HTTP_PORT="${HOST_HTTP_PORT:-18080}"
ARTIFACTS="${ARTIFACTS:-$(pwd)/test-results}"
KEEP="${KEEP:-false}"

mkdir -p "${ARTIFACTS}"

PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0
FAILED_TESTS=()

RED=$'\033[31m'; GRN=$'\033[32m'; YLW=$'\033[33m'; BLU=$'\033[34m'; RST=$'\033[0m'
[ -t 1 ] || { RED=""; GRN=""; YLW=""; BLU=""; RST=""; }

section() { printf '\n%s=== %s %s\n' "${BLU}" "$*" "${RST}"; }
ok()      { PASS_COUNT=$((PASS_COUNT+1)); printf '%sPASS%s %s\n' "${GRN}" "${RST}" "$*"; }
fail()    { FAIL_COUNT=$((FAIL_COUNT+1)); FAILED_TESTS+=("$*"); printf '%sFAIL%s %s\n' "${RED}" "${RST}" "$*"; }
skip()    { SKIP_COUNT=$((SKIP_COUNT+1)); printf '%sSKIP%s %s\n' "${YLW}" "${RST}" "$*"; }
info()    { printf '     %s\n' "$*"; }

check() { # check <description> <command...>
    local desc="$1"; shift
    if "$@" >/dev/null 2>&1; then ok "${desc}"; else fail "${desc}"; fi
}

dexec() { docker exec "${CONTAINER}" "$@"; }
duser() { docker exec -u "${DESKTOP_USER}" "${CONTAINER}" "$@"; }

# logs_contain <container> <pattern> -- grep container logs without piping.
# "docker logs | grep -q" dies of SIGPIPE under `set -o pipefail` as soon as
# grep exits early, which turns a successful match into a failed test.
logs_contain() {
    local target="$1" pattern="$2" tmp
    tmp="$(mktemp)"
    docker logs "${target}" > "${tmp}" 2>&1 || true
    grep -qE -- "${pattern}" "${tmp}"
    local rc=$?
    rm -f "${tmp}"
    return "${rc}"
}

# http_code <url> [curl args...] -- prints the response code, never fails.
http_code() {
    local url="$1"; shift
    curl -s -o /dev/null -w '%{http_code}' "$@" "${url}" 2>/dev/null || echo "000"
}

cleanup() {
    local rc=$?
    section "cleanup"
    if docker container inspect "${CONTAINER}" >/dev/null 2>&1; then
        docker logs "${CONTAINER}" > "${ARTIFACTS}/container.log" 2>&1 || true
    fi
    if [ "${KEEP}" = "true" ]; then
        info "keeping container ${CONTAINER} and volume ${VOLUME}"
    else
        docker rm -f "${CONTAINER}" >/dev/null 2>&1 || true
        docker rm -f "${CONTAINER}-restart" >/dev/null 2>&1 || true
        docker rm -f "${CONTAINER}-ephemeral" >/dev/null 2>&1 || true
        docker volume rm -f "${VOLUME}" >/dev/null 2>&1 || true
    fi
    exit "${rc}"
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
section "0. environment"
# ---------------------------------------------------------------------------
docker image inspect "${IMAGE}" >/dev/null 2>&1 || { echo "image ${IMAGE} not found"; exit 2; }
IMAGE_SIZE="$(docker image inspect "${IMAGE}" --format '{{.Size}}')"
info "image      : ${IMAGE} ($((IMAGE_SIZE / 1024 / 1024)) MB)"
info "docker     : $(docker version --format '{{.Server.Version}}')"
HAVE_RDP=false
RDP_BIN=""
for candidate in xfreerdp xfreerdp3; do
    if command -v "${candidate}" >/dev/null 2>&1 && command -v xvfb-run >/dev/null 2>&1; then
        HAVE_RDP=true; RDP_BIN="${candidate}"; break
    fi
done
info "rdp client : ${RDP_BIN:-not installed}"

# ---------------------------------------------------------------------------
section "1. container boots"
# ---------------------------------------------------------------------------
docker volume create "${VOLUME}" >/dev/null
docker run -d --name "${CONTAINER}" \
    -p "${HOST_RDP_PORT}:3389" -p "${HOST_HTTP_PORT}:8080" \
    -v "${VOLUME}:/data" \
    -e RAILWAY_VOLUME_MOUNT_PATH=/data \
    -e RAILWAY_SERVICE_NAME=cloud-pc-test \
    -e RAILWAY_ENVIRONMENT_NAME=test \
    --shm-size=512m \
    "${IMAGE}" >/dev/null

sleep 5
if [ "$(docker inspect -f '{{.State.Running}}' "${CONTAINER}")" = "true" ]; then
    ok "container is running"
else
    fail "container exited immediately"
    docker logs "${CONTAINER}" 2>&1 | tail -50
    exit 1
fi

# ---------------------------------------------------------------------------
section "2. startup banner and generated credentials"
# ---------------------------------------------------------------------------
DESKTOP_USER="ubuntu"
RDP_PASSWORD=""
for _ in $(seq 1 60); do
    RDP_PASSWORD="$(docker logs "${CONTAINER}" 2>&1 \
        | sed -n 's/^ *Password *: *\([a-z0-9-]\{20,\}\) *$/\1/p' | head -1)"
    [ -n "${RDP_PASSWORD}" ] && break
    sleep 1
done
if [ -n "${RDP_PASSWORD}" ]; then
    ok "startup log contains a generated password (${#RDP_PASSWORD} chars)"
else
    fail "no generated password found in the startup log"
fi
if logs_contain "${CONTAINER}" "persistent volume at /data"; then
    ok "persistent volume detected"
else
    fail "volume not detected as persistent"
fi

# ---------------------------------------------------------------------------
section "3. health endpoint"
# ---------------------------------------------------------------------------
HEALTH_OK=false
for _ in $(seq 1 120); do
    code="$(curl -s -o "${ARTIFACTS}/health.json" -w '%{http_code}' \
        "http://127.0.0.1:${HOST_HTTP_PORT}/health" 2>/dev/null || echo 000)"
    if [ "${code}" = "200" ]; then HEALTH_OK=true; break; fi
    sleep 1
done
if [ "${HEALTH_OK}" = true ]; then
    ok "/health returned 200"
    info "$(tr -d '\n ' < "${ARTIFACTS}/health.json" | cut -c1-240)"
    for field in '.status' '.checks.xrdp' '.checks.xrdp_sesman' '.storage.persistent' '.sessions'; do
        if jq -e "${field}" "${ARTIFACTS}/health.json" >/dev/null 2>&1; then
            ok "/health exposes ${field}"
        else
            fail "/health is missing ${field}"
        fi
    done
    [ "$(jq -r '.checks.xrdp' "${ARTIFACTS}/health.json")" = "true" ] \
        && ok "health reports xrdp up" || fail "health reports xrdp down"
    [ "$(jq -r '.storage.persistent' "${ARTIFACTS}/health.json")" = "true" ] \
        && ok "health reports persistent storage" || fail "health reports ephemeral storage"
else
    fail "/health never returned 200 (last body below)"
    cat "${ARTIFACTS}/health.json" 2>/dev/null | sed 's/^/     /'
    docker logs "${CONTAINER}" 2>&1 | tail -40
fi
code="$(http_code "http://127.0.0.1:${HOST_HTTP_PORT}/")"
[ "${code}" = "200" ] && ok "status page returns 200" || fail "status page returned ${code}"
curl -fsS "http://127.0.0.1:${HOST_HTTP_PORT}/" -o "${ARTIFACTS}/status.html" 2>/dev/null || true
if grep -qiF "${RDP_PASSWORD:-__nope__}" "${ARTIFACTS}/status.html" 2>/dev/null; then
    fail "status page leaks the password"
else
    ok "status page contains no credentials"
fi

# ---------------------------------------------------------------------------
section "4. service supervision and open ports"
# ---------------------------------------------------------------------------
# supervisord only promotes a program from STARTING to RUNNING once it has
# survived its startsecs window, so give it time rather than sampling once.
for _ in $(seq 1 40); do
    dexec supervisorctl -c /opt/cloudpc/supervisor/supervisord.conf status \
        > "${ARTIFACTS}/supervisor.txt" 2>&1 || true
    grep -qE '\bSTARTING\b' "${ARTIFACTS}/supervisor.txt" || break
    sleep 1
done
sed 's/^/     /' "${ARTIFACTS}/supervisor.txt"
for prog in dbus xrdp-sesman xrdp status-server watchdog; do
    grep -qE "^${prog}\s+RUNNING" "${ARTIFACTS}/supervisor.txt" \
        && ok "supervisor: ${prog} RUNNING" || fail "supervisor: ${prog} not running"
done

dexec ss -lntH > "${ARTIFACTS}/ports.txt" 2>&1 || true
cat "${ARTIFACTS}/ports.txt" | sed 's/^/     /'
PUBLIC_PORTS="$(awk '{print $4}' "${ARTIFACTS}/ports.txt" \
    | grep -E '^(0\.0\.0\.0|\*|\[::\]):' | sed 's/.*://' | sort -un | tr '\n' ' ')"
if [ "$(echo "${PUBLIC_PORTS}" | tr -s ' ' | sed 's/ $//')" = "3389 8080" ]; then
    ok "exactly two public listeners: 3389 (RDP) and 8080 (HTTP)"
else
    fail "unexpected public listeners: ${PUBLIC_PORTS}"
fi
if grep -qE '(127\.0\.0\.1|\[::1\]):3350' "${ARTIFACTS}/ports.txt"; then
    ok "xrdp-sesman bound to loopback only"
else
    fail "xrdp-sesman is not loopback-only"
fi

check "docker HEALTHCHECK script passes" dexec /opt/cloudpc/bin/cloudpc-health --quiet

# ---------------------------------------------------------------------------
section "5. desktop toolchain"
# ---------------------------------------------------------------------------
tool_version() { # tool_version <label> <command...>
    local label="$1"; shift
    local out rc first
    # No pipeline here: `cmd | head -1` makes the tool die of SIGPIPE, which
    # `set -o pipefail` would then report as a failed tool.
    out="$(duser "$@" 2>&1)"; rc=$?
    first="$(printf '%s\n' "${out}" | head -1)"
    if [ "${rc}" -eq 0 ]; then
        ok "${label}: ${first}"
    else
        fail "${label} failed (exit ${rc}): ${first}"
    fi
}

installed() { # installed <package> -- GUI apps that need an X display are
              # version-checked through dpkg and really launched in part 7.
    local pkg="$1" ver
    ver="$(dexec dpkg-query -W -f='${Version}' "${pkg}" 2>/dev/null)"
    if [ -n "${ver}" ]; then ok "${pkg} installed: ${ver}"; else fail "${pkg} is not installed"; fi
}
tool_version "python3"         python3 --version
tool_version "pip3"            pip3 --version
tool_version "node"            node --version
tool_version "npm"             npm --version
tool_version "git"             git --version
tool_version "firefox"         firefox --version
tool_version "xfce4-terminal"  xfce4-terminal --version
tool_version "Xvnc"            Xvnc -version
tool_version "xrdp"            xrdp --version
installed "thunar"
installed "geany"
installed "xfce4-session"
installed "xfce4-panel"
installed "xfdesktop4"
installed "xfwm4"
installed "mousepad"
installed "xarchiver"

info "running a real python/node/git workload as ${DESKTOP_USER}"
duser bash -lc 'cd ~ && python3 -m venv /tmp/venv-test && /tmp/venv-test/bin/pip --version' >/dev/null 2>&1 \
    && ok "python venv + pip usable" || fail "python venv creation failed"
duser bash -lc 'cd /tmp && rm -rf npmtest && mkdir npmtest && cd npmtest && npm init -y >/dev/null && node -e "console.log(2+2)"' \
    > "${ARTIFACTS}/node.txt" 2>&1 \
    && [ "$(tail -1 "${ARTIFACTS}/node.txt")" = "4" ] \
    && ok "npm init + node execution work" || fail "npm/node workload failed"
duser bash -lc 'cd /tmp && rm -rf gittest && mkdir gittest && cd gittest && git init -q && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m x && git log --oneline' \
    >/dev/null 2>&1 && ok "git init + commit work" || fail "git workload failed"
duser bash -lc 'test -w ~ && touch ~/write-test && rm ~/write-test' \
    && ok "home directory is writable by ${DESKTOP_USER}" || fail "home directory is not writable"
duser bash -lc 'readlink -f ~' | grep -q '^/data/home' \
    && ok "home directory lives on the volume" || fail "home directory is not on the volume"

# ---------------------------------------------------------------------------
section "6. RDP login creates a desktop session"
# ---------------------------------------------------------------------------
rdp_connect() { # rdp_connect <seconds> <logfile>
    local secs="$1" logfile="$2"
    xvfb-run -a --server-args="-screen 0 1280x800x24" \
        timeout "${secs}" "${RDP_BIN}" \
        "/v:127.0.0.1:${HOST_RDP_PORT}" "/u:${DESKTOP_USER}" "/p:${RDP_PASSWORD}" \
        /cert:ignore /size:1280x800 /bpp:24 -grab-keyboard /log-level:INFO \
        > "${logfile}" 2>&1 &
    echo $!
}

SESSION_PID=""
if [ "${HAVE_RDP}" != true ]; then
    skip "RDP client test (xfreerdp/xvfb-run not installed)"
elif [ -z "${RDP_PASSWORD}" ]; then
    skip "RDP client test (no password was captured)"
else
    CLIENT_PID="$(rdp_connect 70 "${ARTIFACTS}/rdp-client-1.log")"
    SESSION_UP=false
    for _ in $(seq 1 60); do
        if dexec pgrep -x xfce4-session >/dev/null 2>&1; then SESSION_UP=true; break; fi
        kill -0 "${CLIENT_PID}" 2>/dev/null || break
        sleep 1
    done
    if [ "${SESSION_UP}" = true ]; then
        ok "RDP authentication succeeded and an XFCE session was created"
        SESSION_PID="$(dexec pgrep -x xfce4-session | head -1)"
        info "xfce4-session pid ${SESSION_PID}"
        dexec pgrep -a -x 'Xvnc' | sed 's/^/     /'
        dexec pgrep -x Xvnc >/dev/null 2>&1 \
            && ok "Xvnc X server running for the session" || fail "no Xvnc process"
        COMPONENTS_OK=false
        for _ in $(seq 1 45); do
            if dexec bash -c 'pgrep -x xfdesktop >/dev/null && pgrep -x xfwm4 >/dev/null && pgrep -x xfce4-panel >/dev/null'; then
                COMPONENTS_OK=true; break
            fi
            sleep 1
        done
        if [ "${COMPONENTS_OK}" = true ]; then
            ok "window manager, panel and desktop are running"
        else
            fail "XFCE components missing (xfwm4 / xfce4-panel / xfdesktop)"
            dexec pgrep -a -u "${DESKTOP_USER}" . | sed 's/^/     /' | head -20
        fi
        SESSION_OWNER="$(dexec ps -o user= -p "${SESSION_PID}" | tr -d ' ')"
        [ "${SESSION_OWNER}" = "${DESKTOP_USER}" ] \
            && ok "session runs as ${DESKTOP_USER} (not root)" \
            || fail "session runs as ${SESSION_OWNER}"
        SESSION_REPORTED=false
        for _ in $(seq 1 15); do
            curl -s "http://127.0.0.1:${HOST_HTTP_PORT}/health" -o "${ARTIFACTS}/health-session.json" 2>/dev/null || true
            if [ "$(jq -r '.sessions.active' "${ARTIFACTS}/health-session.json" 2>/dev/null)" = "true" ]; then
                SESSION_REPORTED=true; break
            fi
            sleep 2
        done
        if [ "${SESSION_REPORTED}" = true ]; then
            ok "/health reports the active session"
            info "sessions: $(jq -c '.sessions' "${ARTIFACTS}/health-session.json" 2>/dev/null)"
        else
            fail "/health does not report the session"
            cat "${ARTIFACTS}/health-session.json" 2>/dev/null | sed 's/^/     /'
        fi
    else
        fail "no XFCE session was created after RDP login"
        tail -40 "${ARTIFACTS}/rdp-client-1.log" | sed 's/^/     /'
        dexec tail -40 /var/log/xrdp/xrdp-sesman.log | sed 's/^/     /' || true
    fi

    # -----------------------------------------------------------------------
    section "7. file manager and terminal inside the session"
    # -----------------------------------------------------------------------
    if [ "${SESSION_UP}" = true ]; then
        DISPLAY_NUM="$(dexec bash -c 'ls /tmp/.X11-unix | head -1 | sed "s/^X/:/"')"
        info "session display ${DISPLAY_NUM}"
        gui() { docker exec -u "${DESKTOP_USER}" -e DISPLAY="${DISPLAY_NUM}" "${CONTAINER}" "$@"; }
        gui xdpyinfo >/dev/null 2>&1 \
            && ok "X display ${DISPLAY_NUM} is reachable by ${DESKTOP_USER}" \
            || fail "cannot reach X display ${DISPLAY_NUM}"
        docker exec -u "${DESKTOP_USER}" -e DISPLAY="${DISPLAY_NUM}" -d "${CONTAINER}" \
            xfce4-terminal --disable-server --title=cloudpc-test-term >/dev/null 2>&1
        docker exec -u "${DESKTOP_USER}" -e DISPLAY="${DISPLAY_NUM}" -d "${CONTAINER}" \
            thunar >/dev/null 2>&1
        docker exec -u "${DESKTOP_USER}" -e DISPLAY="${DISPLAY_NUM}" -d "${CONTAINER}" \
            bash -c 'geany >/tmp/geany.log 2>&1' >/dev/null 2>&1
        TERM_OK=false; THUNAR_OK=false; EDITOR_OK=false
        for _ in $(seq 1 45); do
            gui xdotool search --class "xfce4-terminal" >/dev/null 2>&1 && TERM_OK=true
            gui xdotool search --class "Thunar" >/dev/null 2>&1 && THUNAR_OK=true
            gui xdotool search --class "Geany" >/dev/null 2>&1 && EDITOR_OK=true
            [ "${TERM_OK}" = true ] && [ "${THUNAR_OK}" = true ] && [ "${EDITOR_OK}" = true ] && break
            sleep 1
        done
        [ "${TERM_OK}" = true ] && ok "terminal window opened on the desktop" || fail "terminal window did not open"
        [ "${THUNAR_OK}" = true ] && ok "file manager window opened on the desktop" || fail "file manager window did not open"
        [ "${EDITOR_OK}" = true ] && ok "code editor window opened on the desktop" || fail "code editor window did not open"

        # Firefox is the slowest to start (it creates a profile on first run).
        docker exec -u "${DESKTOP_USER}" -e DISPLAY="${DISPLAY_NUM}" -d "${CONTAINER}" \
            bash -c 'firefox --no-remote about:blank >/tmp/firefox.log 2>&1' >/dev/null 2>&1
        FIREFOX_OK=false
        for _ in $(seq 1 90); do
            if gui xdotool search --class "Navigator" >/dev/null 2>&1 \
               || gui xdotool search --classname "firefox" >/dev/null 2>&1; then
                FIREFOX_OK=true; break
            fi
            sleep 1
        done
        if [ "${FIREFOX_OK}" = true ]; then
            ok "Firefox opened a browser window on the desktop"
        else
            fail "Firefox did not open a window"
            dexec tail -20 /tmp/firefox.log 2>/dev/null | sed 's/^/     /'
        fi
        gui xdotool search --name "." getwindowname %@ 2>/dev/null | sed 's/^/     window: /' | head -14
        docker logs "${CONTAINER}" > "${ARTIFACTS}/panel-check.log" 2>&1 || true
        if grep -qF "was not found and has been removed from the configuration" "${ARTIFACTS}/panel-check.log"; then
            fail "the panel dropped plugins that are not installed"
            grep -F "was not found and has been removed" "${ARTIFACTS}/panel-check.log" | head -5 | sed 's/^/     /'
        else
            ok "panel loaded its full layout (no missing plugins)"
        fi
        LAUNCHERS_OK=true
        for launcher in launcher-2 launcher-3 launcher-4 launcher-5; do
            # Quoted so $HOME is expanded inside the container, not on the host.
            duser bash -c 'test -d "$HOME/.config/xfce4/panel/'"${launcher}"'"' \
                || LAUNCHERS_OK=false
        done
        [ "${LAUNCHERS_OK}" = true ] \
            && ok "panel launchers for terminal, files, browser and editor are installed" \
            || fail "panel launcher directories are missing from the home directory"
        # Leave a clean desktop behind for the reconnect test.
        duser pkill -u "${DESKTOP_USER}" -x firefox >/dev/null 2>&1 || true
        duser pkill -u "${DESKTOP_USER}" -x geany >/dev/null 2>&1 || true
    else
        skip "desktop application tests (no session)"
    fi

    # -----------------------------------------------------------------------
    section "8. session survives disconnect and is resumed"
    # -----------------------------------------------------------------------
    if [ "${SESSION_UP}" = true ]; then
        kill "${CLIENT_PID}" 2>/dev/null || true
        wait "${CLIENT_PID}" 2>/dev/null || true
        pkill -f "${RDP_BIN}" 2>/dev/null || true
        sleep 15
        if dexec pgrep -x xfce4-session >/dev/null 2>&1; then
            STILL="$(dexec pgrep -x xfce4-session | head -1)"
            if [ "${STILL}" = "${SESSION_PID}" ]; then
                ok "desktop session still alive 15s after the client disconnected (pid ${STILL})"
            else
                fail "session pid changed after disconnect (${SESSION_PID} -> ${STILL})"
            fi
        else
            fail "desktop session died when the RDP client disconnected"
        fi
        CLIENT2_PID="$(rdp_connect 45 "${ARTIFACTS}/rdp-client-2.log")"
        sleep 25
        RESUMED="$(dexec pgrep -x xfce4-session | head -1)"
        [ "${RESUMED}" = "${SESSION_PID}" ] \
            && ok "reconnect resumed the same session (pid ${RESUMED})" \
            || fail "reconnect created a new session (${SESSION_PID} -> ${RESUMED})"
        COUNT="$(dexec pgrep -x -c xfce4-session 2>/dev/null | head -1)"
        COUNT="${COUNT:-0}"
        [ "${COUNT}" = "1" ] && ok "exactly one desktop session is running" \
            || fail "${COUNT} desktop sessions are running (expected 1)"
        kill "${CLIENT2_PID}" 2>/dev/null || true
        wait "${CLIENT2_PID}" 2>/dev/null || true
        pkill -f "${RDP_BIN}" 2>/dev/null || true
    else
        skip "session persistence tests (no session)"
    fi
fi

# ---------------------------------------------------------------------------
section "9. authenticated admin endpoint"
# ---------------------------------------------------------------------------
code="$(curl -fsS -o /dev/null -w '%{http_code}' "http://127.0.0.1:${HOST_HTTP_PORT}/admin" 2>/dev/null || true)"
[ "${code}" = "401" ] && ok "/admin rejects anonymous requests (401)" || fail "/admin returned ${code} without credentials"
code="$(curl -s -o /dev/null -w '%{http_code}' -u "${DESKTOP_USER}:wrong-password" "http://127.0.0.1:${HOST_HTTP_PORT}/admin")"
[ "${code}" = "401" ] && ok "/admin rejects a wrong password" || fail "/admin returned ${code} for a wrong password"
if [ -n "${RDP_PASSWORD}" ]; then
    code="$(curl -s -o "${ARTIFACTS}/admin.json" -w '%{http_code}' \
        -u "${DESKTOP_USER}:${RDP_PASSWORD}" "http://127.0.0.1:${HOST_HTTP_PORT}/admin")"
    if [ "${code}" = "200" ]; then
        ok "/admin accepts the desktop credentials"
        jq -e '.connection.username' "${ARTIFACTS}/admin.json" >/dev/null 2>&1 \
            && ok "/admin returns connection details" || fail "/admin response is incomplete"
        grep -q "${RDP_PASSWORD}" "${ARTIFACTS}/admin.json" \
            && fail "/admin echoes the plaintext password" \
            || ok "/admin does not echo the plaintext password"
    else
        fail "/admin returned ${code} for valid credentials"
    fi
fi

# ---------------------------------------------------------------------------
section "10. log inspection"
# ---------------------------------------------------------------------------
docker logs "${CONTAINER}" > "${ARTIFACTS}/container.log" 2>&1

# Known-benign noise from upstream components, filtered out before the log is
# searched for real problems. Every entry is a message that xrdp/XFCE print on
# a completely healthy run:
#   * scp_process_msg / trans_check_wait_objs -> xrdp 0.9.x logs this every
#     time xrdp closes its session-manager control connection after a session
#     has been created or resumed (neutrinolabs/xrdp#1400).
#   * pm-is-supported -> xfce4-session probes for pm-utils, which is a laptop
#     suspend helper that has no purpose in a container.
#   * CanCreateUserNamespace -> Firefox reporting that the container runtime
#     forbids unprivileged user namespaces; it falls back to a weaker sandbox.
BENIGN=(
    "scp_process_msg failed"
    "trans_check_wait_objs failed"
    "pm-is-supported"
    "CanCreateUserNamespace"
)
# This test suite kills its RDP client processes outright to simulate a phone
# losing signal, so xrdp logs the usual "the peer vanished" cascade. Those
# lines are expected here; everything else in the xrdp logs is not.
XRDP_BENIGN=(
    "libxrdp_force_read: header read error"
    "Connection Sequence: CR-TPDU (Connection Request) failed"
    "xrdp_sec_incoming: xrdp_iso_incoming failed"
    "xrdp_rdp_incoming: xrdp_sec_incoming failed"
    "xrdp_process_main_loop: libxrdp_process_incoming failed"
    "xrdp_iso_send: trans_write_copy_s failed"
    "SSL_read: Failure in SSL library"
    "unexpected eof while reading"
    "SSL_shutdown"
    "DisconnectProviderUltimatum failed"
    "xrdp_mm_module_cleanup"
)
grep -vF "$(printf '%s\n' "${BENIGN[@]}")" "${ARTIFACTS}/container.log" \
    > "${ARTIFACTS}/container.filtered.log" || true

BAD_LITERALS=(
    "Traceback (most recent call last)"
    "entrypoint failed at line"
    "Segmentation fault"
    "command not found"
    "Permission denied"
    "No such file or directory"
    "login failed for display"
    "Access denied"
    "xrdp_wm_log_msg: error"
    "cannot open display"
    "BACKOFF"
    "FATAL"
)
BAD_REGEXES=(
    'exited: [a-z0-9_-]+ \(exit status [1-9]'
    'entered (FATAL|BACKOFF) state'
)
LOG_CLEAN=true
for pattern in "${BAD_LITERALS[@]}"; do
    if grep -qF -- "${pattern}" "${ARTIFACTS}/container.filtered.log"; then
        fail "log contains '${pattern}'"
        grep -nF -- "${pattern}" "${ARTIFACTS}/container.filtered.log" | head -5 | sed 's/^/     /'
        LOG_CLEAN=false
    fi
done
for pattern in "${BAD_REGEXES[@]}"; do
    if grep -qE -- "${pattern}" "${ARTIFACTS}/container.filtered.log"; then
        fail "log matches /${pattern}/"
        grep -nE -- "${pattern}" "${ARTIFACTS}/container.filtered.log" | head -5 | sed 's/^/     /'
        LOG_CLEAN=false
    fi
done
[ "${LOG_CLEAN}" = true ] && ok "no fatal errors in the container log"

dexec cat /var/log/xrdp/xrdp.log > "${ARTIFACTS}/xrdp.log" 2>/dev/null || true
dexec cat /var/log/xrdp/xrdp-sesman.log > "${ARTIFACTS}/xrdp-sesman.log" 2>/dev/null || true
for logfile in xrdp.log xrdp-sesman.log; do
    [ -s "${ARTIFACTS}/${logfile}" ] || continue
    grep -vF "$(printf '%s\n' "${BENIGN[@]}" "${XRDP_BENIGN[@]}")" "${ARTIFACTS}/${logfile}" \
        > "${ARTIFACTS}/${logfile}.filtered" || true
    ERRORS="$(grep -cE '\[ERROR\]' "${ARTIFACTS}/${logfile}.filtered" || true)"
    if [ "${ERRORS:-0}" -eq 0 ]; then
        ok "${logfile} has no unexpected ERROR lines"
    else
        fail "${logfile} contains ${ERRORS} ERROR lines"
        grep -E '\[ERROR\]' "${ARTIFACTS}/${logfile}.filtered" | head -8 | sed 's/^/     /'
    fi
done

# ---------------------------------------------------------------------------
section "11. graceful shutdown"
# ---------------------------------------------------------------------------
dexec bash -c "echo persistence-probe > /data/home/${DESKTOP_USER}/persist.txt && chown ${DESKTOP_USER} /data/home/${DESKTOP_USER}/persist.txt"
START_STOP="$(date +%s)"
docker stop -t 30 "${CONTAINER}" >/dev/null
STOP_SECONDS=$(( $(date +%s) - START_STOP ))
EXIT_CODE="$(docker inspect -f '{{.State.ExitCode}}' "${CONTAINER}")"
[ "${STOP_SECONDS}" -lt 25 ] && ok "container stopped in ${STOP_SECONDS}s (no SIGKILL timeout)" \
    || fail "container needed ${STOP_SECONDS}s to stop"
[ "${EXIT_CODE}" = "0" ] && ok "clean exit code 0 after SIGTERM" || fail "exit code ${EXIT_CODE} after SIGTERM"
docker logs "${CONTAINER}" > "${ARTIFACTS}/container.log" 2>&1 || true
tail -15 "${ARTIFACTS}/container.log" | sed 's/^/     /'
STOPPED_OK=true
for prog in xrdp xrdp-sesman status-server watchdog dbus; do
    # Either the program returned an exit code, or it took the default action
    # for SIGTERM. Both mean supervisord stopped it in order; only a SIGKILL
    # (sent after stopwaitsecs) would mean it ignored the request.
    grep -qE "stopped: ${prog} \\((exit status [0-9]+|terminated by SIGTERM)" \
        "${ARTIFACTS}/container.log" || STOPPED_OK=false
done
if [ "${STOPPED_OK}" = true ]; then
    ok "every supervised service was stopped in order (no SIGKILL)"
else
    fail "some services were not stopped cleanly"
    grep -E "stopped:|SIGTERM|SIGKILL" "${ARTIFACTS}/container.log" | tail -10 | sed 's/^/     /'
fi

# ---------------------------------------------------------------------------
section "12. data and credentials survive a container replacement"
# ---------------------------------------------------------------------------
docker rm -f "${CONTAINER}" >/dev/null 2>&1 || true
docker run -d --name "${CONTAINER}-restart" \
    -p "$((HOST_HTTP_PORT + 1)):8080" \
    -v "${VOLUME}:/data" -e RAILWAY_VOLUME_MOUNT_PATH=/data \
    "${IMAGE}" >/dev/null
for _ in $(seq 1 90); do
    curl -fsS -o /dev/null "http://127.0.0.1:$((HOST_HTTP_PORT + 1))/health" 2>/dev/null && break
    sleep 1
done
NEW_PASSWORD="$(docker logs "${CONTAINER}-restart" 2>&1 \
    | sed -n 's/^ *Password *: *\([a-z0-9-]\{20,\}\) *$/\1/p' | head -1)"
[ -n "${RDP_PASSWORD}" ] && [ "${NEW_PASSWORD}" = "${RDP_PASSWORD}" ] \
    && ok "password is stable across container replacement" \
    || fail "password changed after restart (${RDP_PASSWORD} -> ${NEW_PASSWORD})"
docker exec "${CONTAINER}-restart" cat "/data/home/${DESKTOP_USER}/persist.txt" 2>/dev/null | grep -q persistence-probe \
    && ok "user files survived the container replacement" || fail "user files were lost"
docker exec "${CONTAINER}-restart" test -f "/data/home/${DESKTOP_USER}/.config/xfce4/xfconf/xfce-perchannel-xml/xfwm4.xml" \
    && ok "desktop configuration persisted on the volume" || fail "desktop configuration was lost"
if logs_contain "${CONTAINER}-restart" "persistent volume"; then
    ok "restart detected the volume again"
else
    fail "restart did not detect the volume"
fi
docker rm -f "${CONTAINER}-restart" >/dev/null 2>&1 || true

# ---------------------------------------------------------------------------
section "13. ephemeral storage warning (no volume attached)"
# ---------------------------------------------------------------------------
docker run -d --name "${CONTAINER}-ephemeral" -p "$((HOST_HTTP_PORT + 2)):8080" "${IMAGE}" >/dev/null
for _ in $(seq 1 90); do
    code="$(http_code "http://127.0.0.1:$((HOST_HTTP_PORT + 2))/health")"
    [ "${code}" = "200" ] && break
    sleep 1
done
curl -s -o "${ARTIFACTS}/health-ephemeral.json" "http://127.0.0.1:$((HOST_HTTP_PORT + 2))/health" 2>/dev/null || true
docker logs "${CONTAINER}-ephemeral" > "${ARTIFACTS}/container-ephemeral.log" 2>&1 || true
if grep -qF "WILL BE LOST" "${ARTIFACTS}/container-ephemeral.log"; then
    ok "ephemeral mode prints a clear data loss warning"
else
    fail "no ephemeral storage warning"
fi
[ "$(jq -r '.storage.persistent' "${ARTIFACTS}/health-ephemeral.json" 2>/dev/null)" = "false" ] \
    && ok "/health reports storage as not persistent" || fail "/health wrongly claims persistence"
if grep -qF "RDP address" "${ARTIFACTS}/container-ephemeral.log"; then
    ok "ephemeral container still starts the desktop stack"
else
    fail "ephemeral container did not start"
    tail -30 "${ARTIFACTS}/container-ephemeral.log" | sed 's/^/     /'
fi
docker rm -f "${CONTAINER}-ephemeral" >/dev/null 2>&1 || true

# ---------------------------------------------------------------------------
section "summary"
# ---------------------------------------------------------------------------
printf '%spassed: %d%s  %sfailed: %d%s  %sskipped: %d%s\n' \
    "${GRN}" "${PASS_COUNT}" "${RST}" "${RED}" "${FAIL_COUNT}" "${RST}" "${YLW}" "${SKIP_COUNT}" "${RST}"
if [ "${FAIL_COUNT}" -gt 0 ]; then
    printf '\nfailed tests:\n'
    printf '  - %s\n' "${FAILED_TESTS[@]}"
    exit 1
fi
exit 0
