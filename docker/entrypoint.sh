#!/usr/bin/env bash
# =============================================================================
#  Ubuntu Cloud PC - container entrypoint
# =============================================================================
#  Performs every piece of runtime configuration that would otherwise be a
#  manual step, then hands the container over to supervisord (PID 1) which
#  owns service start order, restarts and graceful shutdown.
#
#  Idempotent: safe to run on every container start, including restarts that
#  reuse an existing Railway volume.
# =============================================================================
set -Eeuo pipefail

CLOUDPC_ROOT="${CLOUDPC_ROOT:-/opt/cloudpc}"
# shellcheck source=lib/common.sh
. "${CLOUDPC_ROOT}/lib/common.sh"

trap 'err "entrypoint failed at line ${LINENO} (exit ${?})"' ERR

CLOUDPC_VERSION="1.0.0"

# -----------------------------------------------------------------------------
# 0. Sanity checks
# -----------------------------------------------------------------------------
[ "$(id -u)" = "0" ] || die "this container must start as root (Railway does this by default; locally do not pass --user)"

# -----------------------------------------------------------------------------
# 1. Resolve configuration (every value has a working default)
# -----------------------------------------------------------------------------
DESKTOP_USER="${RDP_USERNAME:-${DESKTOP_USER:-ubuntu}}"
DESKTOP_UID="${DESKTOP_UID:-1000}"
RDP_PORT="${RDP_PORT:-3389}"
HTTP_PORT="${PORT:-8080}"
RDP_MAX_SESSIONS="${RDP_MAX_SESSIONS:-4}"
RDP_MAX_BPP="${RDP_MAX_BPP:-24}"
RDP_DPI="${RDP_DPI:-96}"
SUDO_NOPASSWD="${RDP_SUDO_NOPASSWD:-false}"
RUN_DIR="/run/cloudpc"

# Railway injects RAILWAY_VOLUME_MOUNT_PATH when a volume is attached.
DATA_DIR="${RAILWAY_VOLUME_MOUNT_PATH:-${CLOUDPC_DATA_DIR:-/data}}"

export DESKTOP_USER DESKTOP_UID RDP_PORT HTTP_PORT DATA_DIR

log "Ubuntu Cloud PC ${CLOUDPC_VERSION} starting"
log "ubuntu $(sed -n 's/^VERSION=//p' /etc/os-release | tr -d '\"') | kernel $(uname -r) | $(nproc) vCPU | $(awk '/MemTotal/ {printf "%.1f GiB RAM", $2/1048576}' /proc/meminfo)"
if [ -n "${RAILWAY_ENVIRONMENT_NAME:-}${RAILWAY_SERVICE_NAME:-}" ]; then
    log "railway: project=${RAILWAY_PROJECT_NAME:-?} service=${RAILWAY_SERVICE_NAME:-?} environment=${RAILWAY_ENVIRONMENT_NAME:-?} region=${RAILWAY_REPLICA_REGION:-?}"
fi

# -----------------------------------------------------------------------------
# 2. Timezone (optional, non-secret, auto-applied when TZ is provided)
# -----------------------------------------------------------------------------
if [ -n "${TZ:-}" ] && [ -f "/usr/share/zoneinfo/${TZ}" ]; then
    ln -snf "/usr/share/zoneinfo/${TZ}" /etc/localtime
    echo "${TZ}" > /etc/timezone
fi

# -----------------------------------------------------------------------------
# 3. Runtime directories, ownership and temporary files
# -----------------------------------------------------------------------------
install -d -m 0755 -o root -g root /var/log/xrdp /var/run/xrdp "${RUN_DIR}" /run/dbus
install -d -m 1777 /tmp /tmp/.X11-unix /tmp/.ICE-unix /tmp/.font-unix
install -d -m 0755 /run/user
install -d -m 0700 -o "${DESKTOP_UID}" -g "${DESKTOP_UID}" "/run/user/${DESKTOP_UID}"
# Stale sockets/pids from a previous container generation (volume-backed /tmp
# is possible when someone mounts a volume there) would block xrdp startup.
rm -f /var/run/xrdp/*.pid /tmp/.X11-unix/X* /tmp/.X1*-lock 2>/dev/null || true
: > /var/log/xrdp/xrdp.log
: > /var/log/xrdp/xrdp-sesman.log
# 0644: the unprivileged status server tails these for the authenticated
# /admin endpoint. They contain no secrets.
chmod 0644 /var/log/xrdp/*.log

# dbus needs a machine id and a clean socket directory
dbus-uuidgen --ensure=/etc/machine-id >/dev/null 2>&1 || true
rm -f /run/dbus/pid 2>/dev/null || true

# -----------------------------------------------------------------------------
# 4. Persistent storage detection (Railway volume) + home directory placement
# -----------------------------------------------------------------------------
PERSISTENT=false
STORAGE_NOTE=""
if mkdir -p "${DATA_DIR}" 2>/dev/null && [ -w "${DATA_DIR}" ]; then
    if [ -n "${RAILWAY_VOLUME_MOUNT_PATH:-}" ] \
       || [ "$(stat -c %d / 2>/dev/null)" != "$(stat -c %d "${DATA_DIR}" 2>/dev/null)" ]; then
        PERSISTENT=true
    fi
fi

if [ "${PERSISTENT}" = "true" ]; then
    HOME_DIR="${DATA_DIR}/home/${DESKTOP_USER}"
    STORAGE_NOTE="persistent volume at ${DATA_DIR} ($(df -h --output=avail "${DATA_DIR}" | tail -1 | tr -d ' ') free)"
    log "storage: ${STORAGE_NOTE}"
else
    HOME_DIR="/home/${DESKTOP_USER}"
    STORAGE_NOTE="EPHEMERAL - no Railway volume attached"
    warn "No persistent volume detected at ${DATA_DIR}."
    warn "Files in the desktop home directory live in the container filesystem and"
    warn "WILL BE LOST whenever Railway restarts, redeploys or moves this container."
    warn "Attach a Railway Volume with mount path ${DATA_DIR} to keep your files."
fi
export HOME_DIR PERSISTENT

SECRETS_DIR="${DATA_DIR}/.secrets"
if [ "${PERSISTENT}" != "true" ]; then
    SECRETS_DIR="/run/cloudpc/secrets"
fi
install -d -m 0700 -o root -g root "${SECRETS_DIR}" "${SECRETS_DIR}/tls"

# Create / move the desktop home directory
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

# Seed the desktop profile exactly once per home directory
if [ ! -e "${HOME_DIR}/.cloudpc/initialized" ]; then
    log "seeding desktop profile (first boot for this home directory)"
    cp -rn /etc/skel/. "${HOME_DIR}/" 2>/dev/null || true
    cp -rn "${CLOUDPC_ROOT}/skel/." "${HOME_DIR}/" 2>/dev/null || true
    # The XFCE panel asks "default or empty panel?" on first start unless the
    # distribution default is already present in the user's configuration.
    install -d -m 0755 "${HOME_DIR}/.config/xfce4/xfconf/xfce-perchannel-xml"
    if [ -f /etc/xdg/xfce4/panel/default.xml ] \
       && [ ! -f "${HOME_DIR}/.config/xfce4/xfconf/xfce-perchannel-xml/xfce4-panel.xml" ]; then
        cp /etc/xdg/xfce4/panel/default.xml \
           "${HOME_DIR}/.config/xfce4/xfconf/xfce-perchannel-xml/xfce4-panel.xml"
    fi
    install -d -m 0755 "${HOME_DIR}/Desktop" "${HOME_DIR}/Documents" \
                       "${HOME_DIR}/Downloads" "${HOME_DIR}/Projects"
    install -d -m 0700 "${HOME_DIR}/.cloudpc"
    date -u '+%Y-%m-%dT%H:%M:%SZ' > "${HOME_DIR}/.cloudpc/initialized"
    chown -R "${DESKTOP_USER}:${DESKTOP_USER}" "${HOME_DIR}"
else
    # Cheap ownership repair (a full recursive chown on a large volume would
    # make every boot slow): fix anything at the top level that drifted.
    find "${HOME_DIR}" -maxdepth 1 \( ! -user "${DESKTOP_UID}" -o ! -group "${DESKTOP_UID}" \) \
        -exec chown "${DESKTOP_USER}:${DESKTOP_USER}" {} + 2>/dev/null || true
fi
chmod 0750 "${HOME_DIR}"

# Persist the per-user XDG dirs config so Thunar/XFCE do not regenerate it
[ -f "${HOME_DIR}/.config/user-dirs.dirs" ] || \
    install -o "${DESKTOP_USER}" -g "${DESKTOP_USER}" -m 0644 /dev/null "${HOME_DIR}/.config/user-dirs.dirs" 2>/dev/null || true

# -----------------------------------------------------------------------------
# 5. Credentials
#    Priority: RDP_PASSWORD variable > password persisted on the volume >
#    freshly generated strong random password.
#    The plaintext never leaves the container except through the deploy logs
#    (which are private to the Railway project) and is stored root-only 0600.
# -----------------------------------------------------------------------------
PASSWORD_FILE="${SECRETS_DIR}/rdp_password"
PASSWORD_SOURCE=""
RDP_PASSWORD_VALUE=""

generate_password() {
    # 4 groups of 5 characters from an unambiguous 31-character alphabet
    # (~99 bits of entropy) - strong, and still typeable on a phone keyboard.
    python3 - <<'PY'
import secrets
alphabet = "abcdefghjkmnpqrstuvwxyz23456789"
print("-".join("".join(secrets.choice(alphabet) for _ in range(5)) for _ in range(4)))
PY
}

if [ -n "${RDP_PASSWORD:-}" ]; then
    RDP_PASSWORD_VALUE="${RDP_PASSWORD}"
    PASSWORD_SOURCE="RDP_PASSWORD environment variable"
elif [ -s "${PASSWORD_FILE}" ]; then
    RDP_PASSWORD_VALUE="$(cat "${PASSWORD_FILE}")"
    PASSWORD_SOURCE="persistent volume (unchanged since first boot)"
else
    RDP_PASSWORD_VALUE="$(generate_password)"
    PASSWORD_SOURCE="generated at startup"
fi

if [ -z "${RDP_PASSWORD:-}" ]; then
    ( umask 077; printf '%s' "${RDP_PASSWORD_VALUE}" > "${PASSWORD_FILE}" )
    chown root:root "${PASSWORD_FILE}"
    chmod 0600 "${PASSWORD_FILE}"
fi

printf '%s:%s\n' "${DESKTOP_USER}" "${RDP_PASSWORD_VALUE}" | chpasswd
passwd -u "${DESKTOP_USER}" >/dev/null 2>&1 || true

# Publish a *hash* of the password so the unprivileged status server can
# authenticate administrative requests without ever holding the secret.
CLOUDPC_PASSWORD_FOR_HASH="${RDP_PASSWORD_VALUE}" \
python3 - "${RUN_DIR}/auth.json" "${DESKTOP_USER}" <<'PY'
import base64, hashlib, json, os, secrets, sys
path, user = sys.argv[1], sys.argv[2]
password = os.environ["CLOUDPC_PASSWORD_FOR_HASH"].encode()
salt = secrets.token_bytes(16)
digest = hashlib.scrypt(password, salt=salt, n=16384, r=8, p=1, dklen=32)
tmp = path + ".tmp"
with open(tmp, "w", encoding="utf-8") as fh:
    json.dump({
        "username": user,
        "algorithm": "scrypt",
        "n": 16384, "r": 8, "p": 1, "dklen": 32,
        "salt": base64.b64encode(salt).decode(),
        "hash": base64.b64encode(digest).decode(),
    }, fh)
os.replace(tmp, path)
os.chmod(path, 0o644)
PY
export -n CLOUDPC_PASSWORD_FOR_HASH 2>/dev/null || true

# sudo policy
if is_true "${SUDO_NOPASSWD}"; then
    printf '%s ALL=(ALL) NOPASSWD:ALL\n' "${DESKTOP_USER}" > "/etc/sudoers.d/90-${DESKTOP_USER}"
    warn "passwordless sudo is enabled for ${DESKTOP_USER} (RDP_SUDO_NOPASSWD=true)"
else
    rm -f "/etc/sudoers.d/90-${DESKTOP_USER}"
fi
chmod 0440 "/etc/sudoers.d/90-${DESKTOP_USER}" 2>/dev/null || true

# -----------------------------------------------------------------------------
# 6. TLS material for xrdp (persisted with the volume so the certificate
#    fingerprint stays stable across restarts)
# -----------------------------------------------------------------------------
TLS_CERT="${SECRETS_DIR}/tls/cert.pem"
TLS_KEY="${SECRETS_DIR}/tls/key.pem"
if [ ! -s "${TLS_CERT}" ] || [ ! -s "${TLS_KEY}" ]; then
    log "generating self-signed TLS certificate for RDP"
    CN="${RAILWAY_TCP_PROXY_DOMAIN:-${RAILWAY_PUBLIC_DOMAIN:-ubuntu-cloud-pc}}"
    openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
        -keyout "${TLS_KEY}" -out "${TLS_CERT}" \
        -subj "/CN=${CN}/O=Ubuntu Cloud PC" \
        -addext "subjectAltName=DNS:${CN}" >/dev/null 2>&1
fi
chown root:root "${TLS_CERT}" "${TLS_KEY}"
chmod 0644 "${TLS_CERT}"
chmod 0600 "${TLS_KEY}"
[ -s /etc/xrdp/rsakeys.ini ] || { xrdp-keygen xrdp auto >/dev/null 2>&1; chmod 0600 /etc/xrdp/rsakeys.ini; }

# -----------------------------------------------------------------------------
# 7. Render xrdp / sesman configuration
# -----------------------------------------------------------------------------
export TLS_CERT TLS_KEY RDP_MAX_SESSIONS RDP_MAX_BPP RDP_DPI
render_template "${CLOUDPC_ROOT}/xrdp/xrdp.ini.tmpl"   /etc/xrdp/xrdp.ini
render_template "${CLOUDPC_ROOT}/xrdp/sesman.ini.tmpl" /etc/xrdp/sesman.ini
chmod 0644 /etc/xrdp/xrdp.ini /etc/xrdp/sesman.ini
install -m 0755 "${CLOUDPC_ROOT}/xrdp/startwm.sh"     /etc/xrdp/startwm.sh
install -m 0755 "${CLOUDPC_ROOT}/xrdp/reconnectwm.sh" /etc/xrdp/reconnectwm.sh

# Only members of tsusers may open a session (sesman AlwaysGroupCheck=true).
id -nG "${DESKTOP_USER}" | tr ' ' '\n' | grep -qx tsusers || usermod -aG tsusers "${DESKTOP_USER}"

# -----------------------------------------------------------------------------
# 8. Runtime facts for the status server / CLI helpers (no secrets in here)
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
    "rdp_port": int(os.environ["RDP_PORT"]),
    "http_port": int(os.environ["HTTP_PORT"]),
    "data_dir": os.environ["DATA_DIR"],
    "persistent": os.environ.get("PERSISTENT") == "true",
    "storage_note": os.environ.get("CLOUDPC_STORAGE_NOTE", ""),
    "password_source": os.environ.get("CLOUDPC_PASSWORD_SOURCE", ""),
    "max_sessions": int(os.environ["RDP_MAX_SESSIONS"]),
    "tcp_proxy_domain": os.environ.get("RAILWAY_TCP_PROXY_DOMAIN", ""),
    "tcp_proxy_port": os.environ.get("RAILWAY_TCP_PROXY_PORT", ""),
    "tcp_application_port": os.environ.get("RAILWAY_TCP_APPLICATION_PORT", ""),
    "public_domain": os.environ.get("RAILWAY_PUBLIC_DOMAIN", ""),
    "railway_service": os.environ.get("RAILWAY_SERVICE_NAME", ""),
    "railway_environment": os.environ.get("RAILWAY_ENVIRONMENT_NAME", ""),
    "railway_region": os.environ.get("RAILWAY_REPLICA_REGION", ""),
}
tmp = path + ".tmp"
with open(tmp, "w", encoding="utf-8") as fh:
    json.dump(data, fh, indent=2)
os.replace(tmp, path)
os.chmod(path, 0o644)
PY

# -----------------------------------------------------------------------------
# 9. Connection details (deploy logs are private to the Railway project)
# -----------------------------------------------------------------------------
CONNECT_HOST="${RAILWAY_TCP_PROXY_DOMAIN:-<enable a Railway TCP Proxy on port ${RDP_PORT}>}"
CONNECT_PORT="${RAILWAY_TCP_PROXY_PORT:-}"
if [ -n "${RAILWAY_TCP_PROXY_DOMAIN:-}" ]; then
    CONNECT_TARGET="${CONNECT_HOST}:${CONNECT_PORT}"
else
    CONNECT_TARGET="${CONNECT_HOST}"
fi

if [ -n "${RDP_PASSWORD:-}" ]; then
    banner \
        "UBUNTU CLOUD PC - REMOTE DESKTOP READY" \
        "" \
        "  RDP address : ${CONNECT_TARGET}" \
        "  Username    : ${DESKTOP_USER}" \
        "  Password    : (taken from the RDP_PASSWORD variable - not printed)" \
        "  Storage     : ${STORAGE_NOTE}"
else
    banner \
        "UBUNTU CLOUD PC - REMOTE DESKTOP READY" \
        "" \
        "  RDP address : ${CONNECT_TARGET}" \
        "  Username    : ${DESKTOP_USER}" \
        "  Password    : ${RDP_PASSWORD_VALUE}" \
        "  Source      : ${PASSWORD_SOURCE}" \
        "  Storage     : ${STORAGE_NOTE}" \
        "" \
        "  These deploy logs are private to your Railway project. Keep them that" \
        "  way, or set an RDP_PASSWORD variable to choose your own password." \
        "  The password is re-printed on every start; with a volume attached it" \
        "  stays the same across restarts."
fi
unset RDP_PASSWORD_VALUE

# -----------------------------------------------------------------------------
# 10. Hand over to supervisord (PID 1: service supervision, restart handling
#     and graceful shutdown on SIGTERM from Railway)
# -----------------------------------------------------------------------------
if [ "${1:-supervisord}" = "supervisord" ]; then
    log "starting services (xrdp, xrdp-sesman, dbus, status server, watchdog)"
    exec /usr/bin/supervisord -c "${CLOUDPC_ROOT}/supervisor/supervisord.conf"
fi

log "running custom command: $*"
exec "$@"
