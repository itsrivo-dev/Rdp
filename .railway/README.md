# Railway Infrastructure as Code

`railway.ts` is the single source of truth for the Railway resources this
project needs. It is evaluated by the **Railway CLI**, not during a deploy -
Railway never reads this directory from your repository.

```bash
npm install                # the CLI needs the 'railway' SDK to evaluate the file
railway login
railway link               # or: railway init  (creates a new project)
railway config plan        # preview - makes no changes
railway config apply       # creates the service, volume, TCP proxy, healthcheck
```

or simply:

```bash
./scripts/railway-setup.sh
```

What it declares:

| Resource | Value |
| --- | --- |
| Service | built from `Dockerfile` in this repo |
| Volume | `cloud-pc-data`, mounted at `/data` (5 GB by default) |
| TCP proxy | container port `3389` &rarr; a public `*.proxy.rlwy.net:<port>` endpoint |
| Healthcheck | `GET /health`, 300 s timeout |
| Restart policy | `ALWAYS`, up to 10 retries |
| Variables | `PORT=8080` (the HTTP/healthcheck port; RDP uses the TCP proxy) |

Overrides without editing the file - set these before running the CLI:

```bash
CLOUD_PC_REPO=you/your-fork      # GitHub repository to deploy
CLOUD_PC_BRANCH=main             # branch to track
CLOUD_PC_SERVICE="Rdp"           # must match the service name in Railway
CLOUD_PC_PROJECT=ubuntu-cloud-pc # project name
CLOUD_PC_VOLUME_MB=5120          # volume size in MB
```

The file exports `partial = "ubuntu-cloud-pc"`, so `railway config apply` only
ever touches the resources declared here and leaves the rest of the
environment alone.

`railway.json` / `railway.toml` (Config as Code) are deliberately **not** used:
Railway deprecated them, new services cannot opt in, and the remaining files
stop being read on 2026-12-01.
