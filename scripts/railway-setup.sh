#!/usr/bin/env bash
# =============================================================================
#  One-command Railway setup for the Ubuntu Cloud PC (optional).
#
#  Creates, from .railway/railway.ts:
#    * the service, built from this repository's Dockerfile
#    * a persistent volume mounted at /data
#    * the /health healthcheck and the always-on restart policy
#    * the PORT / resolution variables
#
#  Then prints the desktop URL and the next steps.
#
#  If you prefer the dashboard: create a project from this GitHub repository,
#  add a volume mounted at /data, and generate a domain. Nothing else is
#  required - see README.md.
#
#  Requirements: Node.js (for the Railway CLI and the IaC SDK) and a Railway
#  account. Nothing here contains or asks for secrets.
# =============================================================================
set -Eeuo pipefail
cd "$(dirname "$0")/.."

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
    say "Logging in to Railway (a browser window opens)"
    railway login
fi
say "Logged in as $(railway whoami 2>/dev/null | tail -1)"

# --- 3. project link ---------------------------------------------------------
if ! railway status >/dev/null 2>&1; then
    say "This directory is not linked to a Railway project yet"
    echo "    Choose an existing project with 'railway link', or create one with"
    echo "    'railway init'. Running 'railway link' now:"
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

# --- 6. deploy from the GitHub source ---------------------------------------
say "Triggering a deployment from the linked GitHub repository"
railway redeploy --from-source --yes 2>/dev/null \
    || warn "could not trigger a redeploy from here - Railway deploys automatically on push to the tracked branch"

# --- 7. public HTTPS domain --------------------------------------------------
say "Checking the public domain"
if railway domain 2>/dev/null | grep -q "https://"; then
    railway domain
else
    warn "No public domain yet. Generate one with:  railway domain
       (or in the dashboard: service -> Settings -> Networking -> Generate Domain)"
fi

say "Deployment status"
railway status || true

cat <<'EOF'

----------------------------------------------------------------------
Next steps
----------------------------------------------------------------------
1. Wait for the deployment to finish (railway logs, or the dashboard).

2. Read the desktop URL and the login password from the deploy logs:

       railway logs | grep -A8 "UBUNTU CLOUD PC IS READY"

   The password only appears there if DESKTOP_PASSWORD is not set as a
   service variable.

3. Open the URL in Chrome on your phone, sign in, and use the desktop.

4. Reading the URL later - either:

       railway domain
       railway variables | grep RAILWAY_PUBLIC_DOMAIN

----------------------------------------------------------------------
EOF
