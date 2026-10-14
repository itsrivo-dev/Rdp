#!/usr/bin/env bash
# =============================================================================
#  Ubuntu Cloud PC - container entrypoint.
#
#  Everything that would otherwise be a manual post-deploy step happens here:
#  accounts, passwords, the home directory (on the Railway volume when one is
#  attached), TLS-free loopback wiring, the XFCE profile and the runtime status
#  file. It is idempotent, so container restarts and redeploys reuse whatever
#  is already in place.
#
#  When it is done it hands PID 1 over to supervisord, which starts and
#  supervises: dbus -> Xtigervnc -> XFCE session -> web gateway -> watchdog.
# =============================================================================
set -Eeuo pipefail

CLOUDPC_ROOT="${CLOUDPC_ROOT:-/opt/cloudpc}"
# shellcheck source=lib/common.sh
. "${CLOUDPC_ROOT}/lib/common.sh"

trap 'err "entrypoint failed at line ${LINENO}"' ERR

CLOUDPC_VERSION="2.0.0"
RUN_DIR="${CLOUDPC_RUN_DIR:-/run/cloudpc}"
LOG_DIR="${CLOUDPC_LOG_DIR:-/var/log/cloudpc}"

# -----------------------------------------------------------------------------
# 0. sanity
# -----------------------------------------------------------------------------
[ "$(id -u)" = "0" ] || die "the container must start as root (do not pass --user; Railway does not)"

# -----------------------------------------------------------------------------
# 1. configuration (every value has a working default)
# -----------------------------------------------------------------------------
DESKTOP_USER="${DESKTOP_USER:-ubuntu}"
DESKTOP_UID="${DESKTOP_UID:-1000}"
DESKTOP_GID="${DESKTOP_GID:-1000}"
HTTP_PORT="${PORT:-8080}"
VNC_PORT="${VNC_PORT:-5900}"
DESKTOP_DISPLAY="${DESKTOP_DISPLAY:-1}"
DESKTOP_RESOLUTION="${DESKTOP_RESOLUTION:-1280x720}"
DESKTOP_DEPTH="${DESKTOP_DEPTH:-24}"
VNC_FRAME_RATE="${VNC_FRAME_RATE:-30}"
DESKTOP_NAME="${DESKTOP_NAME:-Ubuntu Cloud Desktop}"
SESSION_TTL_HOURS="${SESSION_TTL_HOURS:-168}"
PASSWORD_PRINT="${DESKTOP_PASSWORD_PRINT:-true}"
SUDO_NOPASSWD="${DESKTOP_SUDO_NOPASSWD:-false}"
DATA_DIR="${RAILWAY_VOLUME_MOUNT_PATH:-${CLOUDPC_DATA_DIR:-/data}}"

# Everything the embedded Python blocks and supervisord's %(ENV_*)% references
# need must be exported: a shell variable that is only *set* does not exist for a
# child process. tests/unit/test_entrypoint_blocks.py enforces this.
export DESKTOP_USER DESKTOP_UID DESKTOP_GID HTTP_PORT VNC_PORT DESKTOP_DISPLAY
export DESKTOP_RESOLUTION DESKTOP_DEPTH VNC_FRAME_RATE DESKTOP_NAME SESSION_TTL_HOURS
export DATA_DIR SUDO_NOPASSWD PASSWORD_PRINT

id "${DESKTOP_USER}" >/dev/null 2>&1 || die "desktop user '${DESKTOP_USER}' does not exist in this image"

log "Ubuntu Cloud PC ${CLOUDPC_VERSION} starting"
log "ubuntu $(sed -n 's/^VERSION=//p' /etc/os-release | tr -d '"') | kernel $(uname -r) | $(nproc) vCPU | $(awk '/MemTotal/ {printf "%.1f GiB", $2/1048576}' /proc/meminfo) RAM"
log "gateway port ${HTTP_PORT} | vnc 127.0.0.1:${VNC_PORT} | display :${DESKTOP_DISPLAY} | ${DESKTOP_RESOLUTION}x${DESKTOP_DEPTH}"
if [ -n "${RAILWAY_PROJECT_NAME:-}${RAILWAY_SERVICE_NAME:-}" ]; then
    log "railway: project=${RAILWAY_PROJECT_NAME:-?} service=${RAILWAY_SERVICE_NAME:-?} environment=${RAILWAY_ENVIRONMENT_NAME:-?} region=${RAILWAY_REPLICA_REGION:-?}"
fi

# -----------------------------------------------------------------------------
# 2. timezone
# -----------------------------------------------------------------------------
if [ -n "${TZ:-}" ] && [ -f "/usr/share/zoneinfo/${TZ}" ]; then
    ln -snf "/usr/share/zoneinfo/${TZ}" /etc/localtime
    echo "${TZ}" > /etc/timezone
    log "timezone set to ${TZ}"
fi

# -----------------------------------------------------------------------------
# 3. runtime directories
# -----------------------------------------------------------------------------
install -d -m 0755 -o root -g root "${RUN_DIR}" "${LOG_DIR}" /run/dbus
install -d -m 0750 -o "${DESKTOP_USER}" -g "${DESKTOP_USER}" "${RUN_DIR}/vnc"
install -d -m 0700 -o "${DESKTOP_UID}" -g "${DESKTOP_GID}" "/run/user/${DESKTOP_UID}"
install -d -m 1777 /tmp /tmp/.X11-unix /tmp/.ICE-unix
# A stale display socket or lock from an unclean shutdown would stop the
# display server from starting, which is the most common "it worked before"
# failure after a hard restart.
rm -f "/tmp/.X11-unix/X${DESKTOP_DISPLAY}" "/tmp/.X${DESKTOP_DISPLAY}-lock" 2>/dev/null || true
# Session log written by the desktop user, readable by the gateway's
# diagnostics endpoint. Contains no credentials.
: >> "${LOG_DIR}/session.log"
chown "${DESKTOP_USER}:${DESKTOP_USER}" "${LOG_DIR}/session.log"
chmod 0644 "${LOG_DIR}/session.log"
: > "${LOG_DIR}/entrypoint.log" 2>/dev/null || true

dbus-uuidgen --ensure=/etc/machine-id >/dev/null 2>&1 || true
rm -f /run/dbus/pid 2>/dev/null || true

# -----------------------------------------------------------------------------
# 4. persistent storage (Railway volume) + home directory
# -----------------------------------------------------------------------------
PERSISTENT=false
STORAGE_NOTE=""
if mkdir -p "${DATA_DIR}" 2>/dev/null && [ -w "${DATA_DIR}" ]; then
    if [ -n "${RAILWAY_VOLUME_MOUNT_PATH:-}" ] \
       || [ "$(stat -c %d / 2>/dev/null)" != "$(stat -c %d "${DATA_DIR}" 2>/dev/null)" ]; then
        PERSISTENT=true
    fi
fi

if [ "${PERSISTENT}" = true ]; then
    HOME_DIR="${DATA_DIR}/home/${DESKTOP_USER}"
    SECRETS_DIR="${DATA_DIR}/.secrets"
    STORAGE_NOTE="persistent volume at ${DATA_DIR} ($(df -h --output=avail "${DATA_DIR}" | tail -1 | tr -d ' ') free)"
    log "storage: ${STORAGE_NOTE}"
else
    HOME_DIR="/home/${DESKTOP_USER}"
    SECRETS_DIR="${RUN_DIR}/secrets"
    STORAGE_NOTE="EPHEMERAL - no Railway volume attached"
    warn "no persistent volume detected at ${DATA_DIR}"
    warn "everything in the desktop (files, settings, the generated password) lives in"
    warn "the container filesystem and WILL BE LOST on restart/redeploy."
    warn "attach a Railway volume with mount path ${DATA_DIR} to keep it."
fi
install -d -m 0700 -o root -g root "${SECRETS_DIR}"
export PERSISTENT HOME_DIR SECRETS_DIR

install -d -m 0755 "$(dirname "${HOME_DIR}")"
if [ ! -d "${HOME_DIR}" ]; then
    log "creating desktop home directory ${HOME_DIR}"
    install -d -m 0750 -o "${DESKTOP_USER}" -g "${DESKTOP_USER}" "${HOME_DIR}"
fi
CURRENT_HOME="$(getent passwd "${DESKTOP_USER}" | cut -d: -f6)"
if [ "${CURRENT_HOME}" != "${HOME_DIR}" ]; then
    log "pointing ${DESKTOP_USER}'s home at ${HOME_DIR}"
    usermod -d "${HOME_DIR}" "${DESKTOP_USER}"
fi

# Seed the XFCE profile once per home directory (the volume keeps it afterwards).
if [ ! -e "${HOME_DIR}/.cloudpc/initialized" ]; then
    log "seeding the desktop profile (first boot for this home directory)"
    cp -rn /etc/skel/. "${HOME_DIR}/" 2>/dev/null || true
    cp -rn "${CLOUDPC_ROOT}/skel/." "${HOME_DIR}/" 2>/dev/null || true
    # The XFCE panel asks "use default config?" on first start unless a panel
    # configuration already exists; ours ships in skel/.
    install -d -m 0755 "${HOME_DIR}/.config/xfce4/xfconf/xfce-perchannel-xml"
    install -d -m 0755 "${HOME_DIR}/Desktop" "${HOME_DIR}/Documents" \
                       "${HOME_DIR}/Downloads" "${HOME_DIR}/Pictures"
    install -d -m 0700 "${HOME_DIR}/.cloudpc"
    date -u '+%Y-%m-%dT%H:%M:%SZ' > "${HOME_DIR}/.cloudpc/initialized"
    chown -R "${DESKTOP_USER}:${DESKTOP_USER}" "${HOME_DIR}"
else
    # Cheap ownership repair: a full recursive chown on a large volume would
    # slow every boot down.
    find "${HOME_DIR}" -maxdepth 1 \( ! -user "${DESKTOP_UID}" -o ! -group "${DESKTOP_GID}" \) \
        -exec chown "${DESKTOP_USER}:${DESKTOP_USER}" {} + 2>/dev/null || true
fi
chmod 0750 "${HOME_DIR}"

# -----------------------------------------------------------------------------
# 5. secrets
#    desktop password : login for the browser gateway (and sudo in a terminal)
#    vnc password     : second factor for the loopback VNC listener
#    session key      : signs the browser session cookies
#    Nothing is ever written to the image or to a log file.
# -----------------------------------------------------------------------------
generate_password() {
    python3 - <<'PY'
import secrets
alphabet = "abcdefghjkmnpqrstuvwxyz23456789"
print("-".join("".join(secrets.choice(alphabet) for _ in range(5)) for _ in range(4)))
PY
}

generate_vnc_password() {
    # VNC authentication is DES based: only the first eight characters matter.
    python3 - <<'PY'
import secrets
alphabet = "abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789"
print("".join(secrets.choice(alphabet) for _ in range(8)))
PY
}

DESKTOP_PASSWORD_FILE="${SECRETS_DIR}/desktop_password"
PASSWORD_SOURCE=""
DESKTOP_PASSWORD_VALUE=""

if [ -n "${DESKTOP_PASSWORD:-}" ]; then
    DESKTOP_PASSWORD_VALUE="${DESKTOP_PASSWORD}"
    PASSWORD_SOURCE="DESKTOP_PASSWORD service variable"
elif [ -s "${DESKTOP_PASSWORD_FILE}" ]; then
    DESKTOP_PASSWORD_VALUE="$(cat "${DESKTOP_PASSWORD_FILE}")"
    PASSWORD_SOURCE="stored password (unchanged since it was set)"
else
    DESKTOP_PASSWORD_VALUE="$(generate_password)"
    PASSWORD_SOURCE="generated at first boot"
fi

if [ -z "${DESKTOP_PASSWORD:-}" ]; then
    ( umask 077; printf '%s' "${DESKTOP_PASSWORD_VALUE}" > "${DESKTOP_PASSWORD_FILE}" )
    chown root:root "${DESKTOP_PASSWORD_FILE}"
    chmod 0600 "${DESKTOP_PASSWORD_FILE}"
fi

printf '%s:%s\n' "${DESKTOP_USER}" "${DESKTOP_PASSWORD_VALUE}" | chpasswd
passwd -u "${DESKTOP_USER}" >/dev/null 2>&1 || true

# Password hash for the unprivileged gateway (it can verify, not recover).
CLOUDPC_PASSWORD_FOR_HASH="${DESKTOP_PASSWORD_VALUE}" \
python3 - "${RUN_DIR}/auth.json" "${DESKTOP_USER}" <<'PY'
import base64, hashlib, json, os, secrets, sys

path, user = sys.argv[1], sys.argv[2]
password = os.environ["CLOUDPC_PASSWORD_FOR_HASH"].encode()
salt = secrets.token_bytes(16)
digest = hashlib.scrypt(password, salt=salt, n=16384, r=8, p=1, dklen=32)
record = {
    "username": user,
    "algorithm": "scrypt",
    "n": 16384, "r": 8, "p": 1, "dklen": 32,
    "salt": base64.b64encode(salt).decode(),
    "hash": base64.b64encode(digest).decode(),
}
tmp = path + ".tmp"
with open(tmp, "w", encoding="utf-8") as handle:
    json.dump(record, handle)
os.replace(tmp, path)
os.chmod(path, 0o644)
PY
export -n CLOUDPC_PASSWORD_FOR_HASH 2>/dev/null || true
unset CLOUDPC_PASSWORD_FOR_HASH 2>/dev/null || true

# --- VNC password ------------------------------------------------------------
VNC_PASSWORD_FILE="${SECRETS_DIR}/vnc_password"
if [ -s "${VNC_PASSWORD_FILE}" ]; then
    VNC_PASSWORD_VALUE="$(cat "${VNC_PASSWORD_FILE}")"
else
    VNC_PASSWORD_VALUE="$(generate_vnc_password)"
    ( umask 077; printf '%s' "${VNC_PASSWORD_VALUE}" > "${VNC_PASSWORD_FILE}" )
    chown root:root "${VNC_PASSWORD_FILE}"
    chmod 0600 "${VNC_PASSWORD_FILE}"
fi
printf '%s\n' "${VNC_PASSWORD_VALUE}" | vncpasswd -f > "${RUN_DIR}/vnc/passwd.tmp" \
    || die "could not build the VNC password file (is tigervnc-common installed?)"
install -o "${DESKTOP_USER}" -g "${DESKTOP_USER}" -m 0600 \
    "${RUN_DIR}/vnc/passwd.tmp" "${RUN_DIR}/vnc/passwd"
rm -f "${RUN_DIR}/vnc/passwd.tmp"
# A copy the gateway can read and hand to authenticated browsers only.
printf '%s' "${VNC_PASSWORD_VALUE}" > "${RUN_DIR}/vnc_password.tmp"
install -o root -g cloudpc -m 0640 "${RUN_DIR}/vnc_password.tmp" "${RUN_DIR}/vnc_password"
rm -f "${RUN_DIR}/vnc_password.tmp"
unset VNC_PASSWORD_VALUE

# --- session signing key -----------------------------------------------------
SESSION_KEY_STORE="${SECRETS_DIR}/session.key"
if [ ! -s "${SESSION_KEY_STORE}" ]; then
    log "generating a new session signing key (browsers will sign in again)"
    python3 - "${SESSION_KEY_STORE}" <<'PY'
import base64, os, secrets, sys
with open(sys.argv[1], "w", encoding="ascii") as handle:
    handle.write(base64.urlsafe_b64encode(secrets.token_bytes(32)).decode())
PY
    chmod 0600 "${SESSION_KEY_STORE}"
fi
install -o root -g cloudpc -m 0640 "${SESSION_KEY_STORE}" "${RUN_DIR}/session.key"

# --- sudo --------------------------------------------------------------------
if is_true "${SUDO_NOPASSWD}"; then
    printf '%s ALL=(ALL) NOPASSWD:ALL\n' "${DESKTOP_USER}" > "/etc/sudoers.d/90-${DESKTOP_USER}"
    warn "passwordless sudo is enabled for ${DESKTOP_USER} (DESKTOP_SUDO_NOPASSWD=true)"
else
    printf '%s ALL=(ALL) ALL\n' "${DESKTOP_USER}" > "/etc/sudoers.d/90-${DESKTOP_USER}"
fi
chmod 0440 "/etc/sudoers.d/90-${DESKTOP_USER}"

# -----------------------------------------------------------------------------
# 6. runtime facts for the gateway/status tooling (never contains secrets)
# -----------------------------------------------------------------------------
CLOUDPC_VERSION="${CLOUDPC_VERSION}" CLOUDPC_STORAGE_NOTE="${STORAGE_NOTE}" \
CLOUDPC_PASSWORD_SOURCE="${PASSWORD_SOURCE}" \
python3 - "${RUN_DIR}/runtime.json" <<'PY'
import json, os, sys

path = sys.argv[1]
data = {
    "version": os.environ.get("CLOUDPC_VERSION", ""),
    "username": os.environ["DESKTOP_USER"],
    "home": os.environ["HOME_DIR"],
    "data_dir": os.environ["DATA_DIR"],
    "persistent": os.environ.get("PERSISTENT") == "true",
    "storage_note": os.environ.get("CLOUDPC_STORAGE_NOTE", ""),
    "password_source": os.environ.get("CLOUDPC_PASSWORD_SOURCE", ""),
    "http_port": int(os.environ["HTTP_PORT"]),
    "vnc_port": int(os.environ["VNC_PORT"]),
    "display": ":" + os.environ["DESKTOP_DISPLAY"],
    "resolution": os.environ["DESKTOP_RESOLUTION"],
    "depth": int(os.environ["DESKTOP_DEPTH"]),
    "session_ttl_hours": float(os.environ["SESSION_TTL_HOURS"]),
    "public_domain": os.environ.get("RAILWAY_PUBLIC_DOMAIN", ""),
    "railway_service": os.environ.get("RAILWAY_SERVICE_NAME", ""),
    "railway_environment": os.environ.get("RAILWAY_ENVIRONMENT_NAME", ""),
    "railway_region": os.environ.get("RAILWAY_REPLICA_REGION", ""),
    "railway_project": os.environ.get("RAILWAY_PROJECT_NAME", ""),
}
tmp = path + ".tmp"
with open(tmp, "w", encoding="utf-8") as handle:
    json.dump(data, handle, indent=2, sort_keys=True)
os.replace(tmp, path)
os.chmod(path, 0o644)
PY

# -----------------------------------------------------------------------------
# 7. startup notice
# -----------------------------------------------------------------------------
if [ -n "${RAILWAY_PUBLIC_DOMAIN:-}" ]; then
    DESKTOP_URL="https://${RAILWAY_PUBLIC_DOMAIN}/"
else
    DESKTOP_URL="https://<your-service>.up.railway.app/  (generate a domain: service -> Settings -> Networking)"
fi

if [ -z "${DESKTOP_PASSWORD:-}" ] && is_true "${PASSWORD_PRINT}"; then
    PASSWORD_LINE="Password    : ${DESKTOP_PASSWORD_VALUE}   (${PASSWORD_SOURCE})"
elif [ -n "${DESKTOP_PASSWORD:-}" ]; then
    PASSWORD_LINE="Password    : (from the DESKTOP_PASSWORD service variable - not printed)"
else
    PASSWORD_LINE="Password    : (printing disabled - run: cloudpc-password show)"
fi

banner \
    "UBUNTU CLOUD PC IS READY - open this in Chrome" \
    "" \
    "  Desktop URL : ${DESKTOP_URL}" \
    "  Username    : ${DESKTOP_USER}" \
    "  ${PASSWORD_LINE}" \
    "  Storage     : ${STORAGE_NOTE}" \
    "" \
    "  The VNC server listens on 127.0.0.1 only. The browser login above is" \
    "  the only way in, and the session cookie is signed and HttpOnly." \
    "  These deploy logs are private to your Railway project - keep them that" \
    "  way, or set DESKTOP_PASSWORD (and DESKTOP_PASSWORD_PRINT=false) to keep" \
    "  the password out of them entirely." \
    "  Change the password any time with: cloudpc-password set"
unset DESKTOP_PASSWORD_VALUE

# -----------------------------------------------------------------------------
# 8. hand over to supervisord
# -----------------------------------------------------------------------------
if [ "${1:-supervisord}" = "supervisord" ]; then
    log "starting services: dbus -> Xtigervnc -> XFCE -> gateway -> watchdog"
    exec /usr/bin/supervisord -c "${CLOUDPC_ROOT}/supervisor/supervisord.conf"
fi

log "running custom command: $*"
exec "$@"
