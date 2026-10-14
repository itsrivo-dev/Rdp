# Railway Infrastructure as Code (optional)

`railway.ts` is the single source of truth for the Railway resources this
project needs. It is evaluated by the **Railway CLI**, not during a deploy -
Railway never reads this directory from your repository.

You do **not** need it to deploy: Railway builds the `Dockerfile` straight from
GitHub, reads the `PORT` variable it injects itself, and serves the desktop on
the domain you generate in the dashboard. Use this file when you would rather
have the service, volume, healthcheck and restart policy created from code.

```bash
npm install                # the CLI needs the 'railway' SDK to evaluate the file
railway login
railway link               # or: railway init (creates a new project)
railway config plan        # preview - makes no changes
railway config apply       # creates the service, volume, healthcheck
```

or simply:

```bash
./scripts/railway-setup.sh
```

| Resource | Value |
| --- | --- |
| Service | built from `Dockerfile` in this repo |
| Volume | `cloudpc-data`, mounted at `/data` (5 GB by default) |
| Healthcheck | `GET /health`, 300 s timeout |
| Restart policy | `ALWAYS`, up to 10 retries |
| Variables | `PORT=8080`, `DESKTOP_RESOLUTION=1280x720`, `VNC_FRAME_RATE=30` |
| Public access | HTTPS domain generated in the dashboard (`Settings -> Networking -> Generate Domain`), or `railway domain` |

Overrides without editing the file - set these before running the CLI:

```bash
CLOUD_PC_REPO=you/your-fork        # GitHub repository to deploy
CLOUD_PC_BRANCH=main               # branch to track
CLOUD_PC_SERVICE="Rdp"             # must match the service name in Railway
CLOUD_PC_PROJECT=ubuntu-cloud-pc   # project name
CLOUD_PC_VOLUME_MB=5120            # volume size in MB
```

The file exports `partial = "ubuntu-cloud-pc"`, so `railway config apply` only
touches the resources declared here and leaves the rest of the environment
alone.

## Why not railway.json / railway.toml?

Railway deprecated Config as Code: existing files stop being read on
**2026-12-01**, new services cannot opt in, and `railway config plan` refuses to
manage a service that still uses them. Infrastructure as Code
(`.railway/railway.ts`) is the supported replacement, and the plain GitHub
deployment path (build the Dockerfile, inject `PORT`) needs neither.
