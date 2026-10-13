#!/usr/bin/env bash
# =============================================================================
#  One-command Railway setup for the Ubuntu Cloud PC.
#
#  Creates (or updates) everything the deployment needs:
#    * the service, built from this repository's Dockerfile
#    * a persistent volume mounted at /data
#    * a public TCP proxy for port 3389 (the RDP endpoint)
#    * healthcheck + restart policy
#
#  Then prints the connection details.
#
#  Requirements: Node.js (for the Railway CLI and the IaC SDK) and a Railway
#  account. Nothing here contains or asks for secrets.
# =============================================================================
set -Eeuo pipefail
cd "$(dirname "$0")/.."

RDP_PORT=3389
YES=false
[ "${1:-}" = "--yes" ] && YES=true

say()  { printf '\n\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

# --- 1. tooling --------------------------------------------------------------
command -v node >/dev/null 2>&1 || die "Node.js is required (https://nodejs.org)"
if ! command -v railway >/dev/null 2>&1; then
    say "Installing the Railway CLI (npm i -g @railway/cli)"
    npm install -g @railway/cli || die "could not install the Railway CLI"
fi
say "Railway CLI $(railway --version 2>/dev/null || echo '?')"

# --- 2. account --------------------------------------------------------------
if ! railway whoami >/dev/null 2>&1; then
    say "Logging in to Railway (a browser window will open)"
    railway login
fi
say "Logged in as $(railway whoami 2>/dev/null | tail -1)"

# --- 3. project link ---------------------------------------------------------
if ! railway status >/dev/null 2>&1; then
    say "This directory is not linked to a Railway project yet"
    echo "    Choose an existing project with 'railway link', or create a new one"
    echo "    with 'railway init'. Running 'railway link' now:"
    railway link
fi
railway status || true

# --- 4. IaC dependencies -----------------------------------------------------
[ -d node_modules/railway ] || { say "Installing the IaC SDK (npm install)"; npm install --no-audit --no-fund; }

# --- 5. plan + apply ---------------------------------------------------------
say "Planning infrastructure changes"
railway config plan

if [ "${YES}" != true ]; then
    printf '\nApply these changes? [y/N] '
    read -r answer
    case "${answer}" in [yY]*) ;; *) die "aborted - nothing was changed" ;; esac
fi

say "Applying"
railway config apply --yes

# --- 6. make sure the RDP TCP proxy exists -----------------------------------
say "Checking the TCP proxy for port ${RDP_PORT}"
if railway tcp-proxy list 2>/dev/null | grep -q "${RDP_PORT}"; then
    railway tcp-proxy list
else
    warn "No TCP proxy found for port ${RDP_PORT}; creating one"
    railway tcp-proxy create --port "${RDP_PORT}" \
        || warn "Could not create it from the CLI. Create it in the dashboard:
       Service -> Settings -> Networking -> TCP Proxy -> port ${RDP_PORT}"
fi

# --- 7. connection details ---------------------------------------------------
say "Deploy status"
railway status || true

cat <<'EOF'

----------------------------------------------------------------------
Next steps
----------------------------------------------------------------------
1. Wait for the deployment to finish (railway logs, or the dashboard).

2. Read the connection details from the deploy logs. They are printed in
   a framed banner on every start and are private to your project:

       railway logs | grep -A6 "REMOTE DESKTOP READY"

3. In your Android RDP client, add a PC with:
       PC name : <something>.proxy.rlwy.net : <port>   (from the banner)
       Username: ubuntu
       Password: the password from the banner

   Both values are also shown by:
       railway variables | grep RAILWAY_TCP_PROXY
----------------------------------------------------------------------
EOF
