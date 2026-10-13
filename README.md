# Ubuntu Cloud PC

A real Ubuntu 22.04 LTS desktop (XFCE) running on [Railway](https://railway.com),
reachable from any Remote Desktop client - including Android phones.

Not a web terminal, not a simulated desktop, not a screenshot service: the
container runs a genuine X session with `xrdp`, a window manager, a file
manager, a browser and a full package manager. You connect to it with the RDP
protocol and use it like a PC.

```
Android RDP app  ──TLS/RDP──▶  Railway TCP proxy  ──▶  xrdp (3389)
                                                        │
                                                        ▼
                                              xrdp-sesman ─▶ Xvnc + XFCE session
                                                        │
                                              /data (Railway volume) = your home
```

---

## Contents

- [What you get](#what-you-get)
- [Deploy it](#deploy-it)
- [Connect from Android](#connect-from-android)
- [Credentials](#credentials)
- [Persistent storage](#persistent-storage)
- [Keeping the desktop alive](#keeping-the-desktop-alive)
- [Configuration](#configuration)
- [Security](#security)
- [Railway limits and the manual steps you cannot avoid](#railway-limits-and-the-manual-steps-you-cannot-avoid)
- [How it works](#how-it-works)
- [Testing](#testing)
- [Troubleshooting](#troubleshooting)
- [What has been verified](#what-has-been-verified)

---

## What you get

| | |
| --- | --- |
| OS | Ubuntu 22.04 LTS |
| Desktop | XFCE 4 (panel, window manager, desktop, app finder, task manager) |
| Remote access | xrdp over TLS, driving a TigerVNC X server |
| File manager | Thunar (+ archive plugin, xarchiver, thumbnails) |
| Terminal | xfce4-terminal |
| Browser | Firefox (official Mozilla build, not the snap stub) |
| Editors | Geany (lightweight graphical IDE), Mousepad |
| Languages | Python 3 + pip + venv, Node.js 22 LTS + npm, Git |
| Utilities | curl, wget, jq, htop, tree, zip/unzip, rsync, ssh client, nano, vim-tiny, xdotool |
| Viewer | Ristretto (images) |
| Admin tools | `cloudpc-status`, `cloudpc-health`, `cloudpc-credentials` |

Everything is installed with `--no-install-recommends` and without docs/man
pages. No audio stack, no snapd, no systemd, no desktop search indexer.

| Measured in CI | |
| --- | --- |
| Image size | ~1.1 GB |
| Memory, idle (booted, nobody connected) | ~41 MB |
| Memory, desktop session + terminal + file manager + editor + Firefox | ~540 MB |

Those numbers come from the test suite, which fails the build if the idle
footprint goes over 512 MB or the busy one over 1.5 GB. A 1 GB Railway
instance is enough for everyday use; 2 GB is comfortable with several browser
tabs.

---

## Deploy it

You need a Railway account with an active plan (Railway's free trial works;
see [limits](#railway-limits-and-the-manual-steps-you-cannot-avoid)).

### Option A - one command (recommended, creates everything)

```bash
git clone https://github.com/itsrivo-dev/Rdp.git
cd Rdp
./scripts/railway-setup.sh
```

The script installs the Railway CLI if needed, logs you in, links or creates a
project, and then applies [`.railway/railway.ts`](.railway/railway.ts), which
declares:

* the service, built from this repository's `Dockerfile`
* a **5 GB volume mounted at `/data`** (your home directory)
* a **TCP proxy for port 3389** - the public RDP endpoint
* the `/health` healthcheck and an `ALWAYS` restart policy
* `PORT=8080` so Railway knows which port serves HTTP

It then prints where to find your connection details. No file in this
repository needs to be edited, and no secret is ever written to disk.

### Option B - the Railway dashboard

1. **New Project → Deploy from GitHub repo →** pick this repository.
   Railway detects the `Dockerfile` and builds it. No build settings needed.
2. **Service → Settings → Networking → TCP Proxy →** enter port **3389**.
   Railway returns something like `shuttle.proxy.rlwy.net:21043`. *This is the
   address you put in your Android client.*
3. **Service → Variables → (right-click canvas) → Volume →** attach a volume
   to the service with mount path **`/data`**.
   Skip this and the desktop still works, but **everything you save is lost on
   the next deploy** - the container will say so loudly in the logs.
4. Open the **Deploy Logs** and copy the username and password from the banner.

Steps 2 and 3 are clicks in the dashboard because Railway creates proxies and
volumes at the *account* level - a file in a GitHub repository cannot do it.
Option A does both for you through the CLI.

> **Note on `railway.json`:** this repository deliberately does not ship one.
> Railway deprecated Config as Code, new services cannot opt into it, and the
> remaining files stop being read on 2026-12-01. `.railway/railway.ts`
> (Infrastructure as Code) is the supported replacement and is what Option A
> uses.

---

## Connect from Android

The server speaks standard RDP with TLS and is driven in CI by a real
`xfreerdp` client, so any Android client that supports TLS and a custom port
should work: Microsoft's **Windows App** (formerly *Microsoft Remote
Desktop*), **aFreeRDP**, **RD Client** forks, **Jump Desktop** and so on. The
steps below use Microsoft's client because it is the one most people have.

> The author has **not** connected to a deployed instance from a physical
> Android device - see [what has been verified](#what-has-been-verified).

**Microsoft "Windows App" / "Remote Desktop" (Android)**

1. **+ → Add PC**
2. **PC name**: `shuttle.proxy.rlwy.net:21043` - the host **and** port from the
   Railway TCP proxy (your values will differ; the port is never 3389).
3. **User account → Add user account**
   * Username: `ubuntu`
   * Password: the password from the deploy logs
4. **Display → Resolution**: pick a **fixed** resolution, e.g. `1280x720` or
   `1600x900`, and turn off "Change the display resolution automatically".
   This matters - see below.
5. Save, tap the PC, accept the self-signed certificate warning once.

You get the XFCE desktop. The first connection takes a few seconds longer
because the X server and session are created on demand.

### Why you should pin the resolution

xrdp keys a session by *user + colour depth + screen size*. Reconnecting with a
different screen size (for example after rotating the phone) starts a **second,
empty desktop** instead of resuming the first one. Pinning the resolution in
the client - and locking rotation - means every reconnect lands back in the
same session with your windows where you left them.

If you do end up with a stray session, log out of it from the XFCE menu, or
restart the service.

### Clipboard

Text copy/paste between the phone and the desktop is enabled (`cliprdr`).
Drive redirection and audio are intentionally off: both need container
capabilities Railway does not grant (`/dev/fuse`) or a sound daemon that would
only burn CPU.

---

## Credentials

* **Nothing is hardcoded and nothing is stored in Git.**
* On first boot the container generates a password with `secrets.choice` from
  a 31-character unambiguous alphabet, in 4 groups of 5 (about 99 bits of
  entropy, still typeable on a phone): `k7fm2-pqw9x-3tdhv-rn8cz`.
* It is printed **once per start** in a banner in the Railway **deploy logs**,
  which are private to your project:

  ```
  ==========================================================================
    UBUNTU CLOUD PC - REMOTE DESKTOP READY

      RDP address : shuttle.proxy.rlwy.net:21043
      Username    : ubuntu
      Password    : k7fm2-pqw9x-3tdhv-rn8cz
      Source      : generated at startup
      Storage     : persistent volume at /data (4.8G free)
  ==========================================================================
  ```

  From a terminal: `railway logs | grep -A6 "REMOTE DESKTOP READY"`.

* With a volume attached the password is stored at
  `/data/.secrets/rdp_password` (`root`, mode `0600`) and **stays the same**
  across restarts and redeploys. Without a volume a new one is generated on
  every start.
* To choose your own, set an `RDP_PASSWORD` variable on the service. It is then
  never written to disk and never printed.
* To rotate the generated one: delete `/data/.secrets/rdp_password`
  (`railway volume files` or a terminal inside the desktop with `sudo`) and
  redeploy.

### Retrieving them later

| Where | How |
| --- | --- |
| Railway logs | `railway logs` - printed on every start |
| Inside the container | `sudo cloudpc-credentials` (root-only; `railway ssh` or a desktop terminal) |
| Over HTTP | `GET /admin` with HTTP Basic auth as the desktop user |

The `/admin` endpoint returns the connection address, session list, storage
state and recent service logs. It **does not** return the password: the
HTTP server runs as an unprivileged user that never reads the password file.
It authenticates you against a scrypt hash published by the entrypoint, and
locks an address out for 5 minutes after 8 failed attempts.

The public pages (`/` and `/health`) never contain credentials.

---

## Persistent storage

| With a Railway volume at `/data` | Without |
| --- | --- |
| Home directory is `/data/home/ubuntu` | Home directory is `/home/ubuntu` |
| Files, desktop settings, browser profile, SSH keys survive restarts, redeploys and crashes | Everything is **lost** when the container is replaced |
| The RDP password and the TLS certificate are stable | Both are regenerated on every start |

The container detects the volume automatically from Railway's
`RAILWAY_VOLUME_MOUNT_PATH` variable (and falls back to checking whether
`/data` is a real mount point), moves the user's home directory onto it, seeds
the XFCE profile on first boot and repairs ownership on later boots.

If there is no volume you get this in the logs, and `/health` reports
`"persistent": false`:

```
WARNING: No persistent volume detected at /data.
WARNING: Files in the desktop home directory live in the container filesystem and
WARNING: WILL BE LOST whenever Railway restarts, redeploys or moves this container.
```

**What a volume does not cover:** packages you install with `apt` land in the
container filesystem, not on the volume, so they disappear on the next deploy.
Keep a small setup script in your home directory, or add the packages to the
`Dockerfile` and redeploy. Docker's writable layer is *not* storage - treat
everything outside `/data` as disposable.

---

## Keeping the desktop alive

* Disconnecting the RDP client does **not** end the session.
  `KillDisconnected=false`, `DisconnectedTimeLimit=0` and `IdleTimeLimit=0`
  are set in `sesman.ini`: your windows, editors and long-running jobs keep
  running, and reconnecting resumes exactly where you were.
* The session ends when you log out of XFCE, when the service is restarted, or
  when Railway stops/replaces/redeploys the container - a new deploy always
  starts a fresh container, and anything running inside the old one stops.
* Railway may also stop a service for reasons outside this project: usage
  limits, billing state, resource limits or platform maintenance. Nothing here
  tries to work around those, and you should not try either.
* If a *service* inside the container dies (xrdp, sesman, the status server),
  the built-in watchdog restarts it within ~60 s without touching your desktop
  session. If the container itself exits, Railway's `ALWAYS` restart policy
  brings it back.

---

## Configuration

Every setting has a working default; **none of these variables is required**.

| Variable | Default | Purpose |
| --- | --- | --- |
| `RDP_PASSWORD` | *(generated)* | Use your own password instead of a generated one |
| `RDP_USERNAME` | `ubuntu` | Desktop account name |
| `PORT` | `8080` | HTTP status/health port (Railway sets this itself) |
| `RDP_PORT` | `3389` | Internal RDP port (must match the TCP proxy) |
| `RDP_MAX_SESSIONS` | `4` | Concurrent desktop sessions allowed |
| `RDP_MAX_BPP` | `24` | Colour depth ceiling (`16` is noticeably lighter on mobile data) |
| `RDP_DPI` | `96` | X server DPI |
| `RDP_SUDO_NOPASSWD` | `false` | Set `true` for passwordless `sudo` |
| `CLOUDPC_DATA_DIR` | `/data` | Where the volume is expected |
| `CLOUDPC_WATCHDOG_INTERVAL` | `30` | Seconds between service probes |
| `TZ` | `UTC` | Container timezone |

Railway-provided variables used automatically when present:
`RAILWAY_VOLUME_MOUNT_PATH`, `RAILWAY_TCP_PROXY_DOMAIN`,
`RAILWAY_TCP_PROXY_PORT`, `RAILWAY_PUBLIC_DOMAIN`, `RAILWAY_SERVICE_NAME`,
`RAILWAY_ENVIRONMENT_NAME`, `RAILWAY_REPLICA_REGION`, `PORT`.

---

## Security

* **No unauthenticated RDP.** xrdp authenticates against PAM (the real Linux
  account) and `sesman.ini` sets `AlwaysGroupCheck=true` with
  `TerminalServerUsers=tsusers`, so only members of that group can open a
  session. Root login over RDP is disabled.
* **TLS.** `security_layer=negotiate` + `crypt_level=high`, TLS 1.2/1.3 only,
  `HIGH` ciphers, with a self-signed certificate generated at first boot and
  kept on the volume so the fingerprint stays stable. Android clients will warn
  once about the self-signed certificate - that is expected; the traffic is
  still encrypted end to end.
* **Two ports, both needed.** 3389 (RDP) and 8080 (status/health). The session
  manager (3350) and the per-session X servers (5910+) are bound to
  `127.0.0.1` and are not reachable from outside. The test suite asserts this.
* **Least privilege.** The desktop runs as the unprivileged `ubuntu` user; the
  HTTP server runs as a separate unprivileged `cloudpc` user with no shell and
  no access to the password; only `xrdp-sesman` (which has to create sessions)
  runs as root. `sudo` requires the password unless you opt out.
* **Rate limiting.** `MaxLoginRetry=3` on RDP, 8-attempts-per-5-minutes lockout
  on `/admin`.
* **No secrets in Git.** `.gitignore` covers keys, certificates, `.env` files,
  credential dumps, test output and local runtime data. The lint suite fails
  the build if a credential-shaped literal appears in the sources.
* Treat your Railway deploy logs as sensitive - they contain the password.

---

## Railway limits and the manual steps you cannot avoid

Honest list, no hand-waving:

1. **A Railway TCP Proxy must exist for port 3389.** Proxies are account-level
   resources; a repository cannot create one by itself. Use
   `./scripts/railway-setup.sh` / `railway config apply` (CLI, one command) or
   three clicks in the dashboard. Everything after that is automatic.
2. **A volume must be created and mounted at `/data`** for persistence, for the
   same reason. Same two options. Without it the deployment still works, with
   loud warnings.
3. **Railway requires a paid or trial plan.** Deployments stop when credits run
   out; the desktop stops with them.
4. **Deploys replace containers.** Any process you left running dies with the
   old container. That is how the platform works, by design.
5. **Volumes cannot be attached to more than one service**, and redeploys of a
   service with a volume have a short downtime (Railway prevents two
   deployments from mounting the same volume).
6. **No GPU, no `/dev/fuse`, no privileged capabilities.** Rendering is
   software (llvmpipe); 3D-heavy apps and video editing will be slow. Drive
   redirection is therefore disabled.
7. **`railway.json` is not used** - deprecated by Railway, ignored for new
   services, hard cutoff 2026-12-01. Service settings come from
   `.railway/railway.ts` (CLI) or from the dashboard.
8. **Resolution changes create a second session** (xrdp 0.9.x behaviour with
   the Xvnc backend). Pin the resolution in your client.

---

## How it works

```
docker/
├── entrypoint.sh              runs as root, PID 1 until it execs supervisord
├── lib/common.sh              logging, template rendering, TCP probe helpers
├── supervisor/supervisord.conf  service definitions, restart + shutdown policy
├── xrdp/
│   ├── xrdp.ini.tmpl          RDP listener: TLS, channels, autorun session
│   ├── sesman.ini.tmpl        session manager: PAM, group check, persistence
│   ├── startwm.sh             starts dbus + xfce4-session for a login
│   └── reconnectwm.sh         runs on reconnect, never disturbs the session
├── health/server.py           status page, /health, authenticated /admin
├── bin/                       cloudpc-health, -watchdog, -credentials, -status
└── skel/                      XFCE defaults seeded into a fresh home directory
```

**Boot sequence** (all automatic, no manual commands ever):

1. `entrypoint.sh` verifies it is root, prints the environment, applies `TZ`.
2. Creates runtime directories (`/var/run/xrdp`, `/run/user/1000`,
   `/tmp/.X11-unix`, `/run/dbus`), clears stale sockets and PID files, and
   fixes permissions.
3. Detects the volume, points the desktop user's home at it, seeds the XFCE
   profile on first boot (including the panel layout, so XFCE never shows its
   first-run dialog) and repairs ownership afterwards.
4. Resolves the password (variable → volume → generate), sets it with
   `chpasswd`, and publishes only a scrypt hash for the HTTP server.
5. Generates the TLS certificate and xrdp RSA keys if they are missing.
6. Renders `xrdp.ini` and `sesman.ini` from templates with the runtime ports.
7. Writes `/run/cloudpc/runtime.json` (no secrets) and prints the banner.
8. `exec supervisord`, which starts dbus → xrdp-sesman → xrdp → status server →
   watchdog, restarts anything that dies, and on `SIGTERM` stops everything in
   order and exits 0.

**Why TigerVNC and not Xorg:** `xorgxrdp` needs a virtual terminal, DRM access
and an X server that may run as root. None of that exists in an unprivileged
container, which is where the familiar "black screen after login" comes from.
`Xvnc` needs nothing but a socket, so sessions start reliably. The client still
speaks plain RDP - the VNC server is an internal implementation detail bound to
`127.0.0.1`.

---

## Testing

```bash
tests/lint.sh            # static checks, no Docker needed
scripts/test.sh          # build the image + full container test suite
tests/integration.sh     # container tests against an existing image
```

The integration suite boots the image and asserts, among other things:

* the container starts, stays up and prints credentials
* `/health` becomes `200` and reports the right structure and storage state
* exactly two public listeners (3389, 8080) and a loopback-only sesman
* python/pip/venv, node/npm, git, Firefox, Geany, Thunar, terminal all work
* a **real RDP client** (`xfreerdp`) authenticates and gets an XFCE session
  owned by the desktop user, with `xfwm4`, `xfce4-panel` and `xfdesktop` alive
* a terminal window and a Thunar window actually open on that X display
* the session **survives a client disconnect** and is **resumed** on reconnect
* `/admin` rejects anonymous and wrong-password requests and accepts valid ones
* the container log is free of fatal errors
* `SIGTERM` shuts it down cleanly (exit 0) well inside the timeout
* the volume keeps the password, files and desktop configuration across a
  container replacement
* running without a volume prints the data-loss warning

Every push runs all of this on GitHub Actions
([`.github/workflows/ci.yml`](.github/workflows/ci.yml)) and posts the full
report to an issue titled *CI test reports*.

---

## Troubleshooting

| Symptom | Fix |
| --- | --- |
| Client cannot connect | Is the TCP proxy created for port **3389**? Are you using the proxy's port (not 3389) in the client? Is the deployment running? |
| "Login failed" | Username is `ubuntu` (or your `RDP_USERNAME`); copy the password from the latest deploy log - a container without a volume regenerates it on every start |
| Certificate warning | Expected: the certificate is self-signed. Accept it once |
| Black screen for a few seconds | Normal on the first connection: the X server and XFCE session are starting |
| Desktop is empty after reconnect | You reconnected with a different screen size and got a second session. Pin the resolution, then log out of the extra session |
| Everything is gone after a deploy | No volume attached, or files were saved outside the home directory |
| Deploy marked unhealthy | The healthcheck probes `PORT`. If you enabled a healthcheck without the IaC file, add `PORT=8080` to the service variables |
| Slow / laggy over mobile data | Set `RDP_MAX_BPP=16`, use a smaller resolution, keep compositing off (it already is) |
| Need a service restarted | `cloudpc-status` shows everything; `sudo supervisorctl -c /opt/cloudpc/supervisor/supervisord.conf restart xrdp` |

---

## What has been verified

Every push builds the image on GitHub Actions and runs the full suite against
real containers - **78 checks, no mocks, no stubs**
([latest report](https://github.com/itsrivo-dev/Rdp/issues/2)):

| Verified | How |
| --- | --- |
| The image builds | `docker buildx build` from this `Dockerfile` |
| The container boots and stays up | supervisord with all five services `RUNNING` |
| XRDP starts and listens | port 3389 bound, sesman loopback-only on 3350 |
| XFCE starts | `xfce4-session`, `xfwm4`, `xfce4-panel`, `xfdesktop`, `xfsettingsd` alive in the session |
| An RDP session can really be created | `xfreerdp` logs in with the generated password and gets a session owned by `ubuntu` |
| File manager and terminal are reachable | Thunar, xfce4-terminal, Geany and Firefox windows opened on the session's X display and found with `xdotool` |
| Python, Node, npm, Git work | `venv` + `pip`, `npm init` + `node -e`, `git init` + commit, all as the desktop user |
| Ports are what they should be | exactly two public listeners (3389, 8080) |
| Health checks work | `/health` returns 200 with the right payload, the Docker `HEALTHCHECK` script passes |
| Startup logs are clean | no fatal errors; the only tolerated lines are documented upstream quirks |
| Shutdown is graceful | `SIGTERM` stops every service in order, exit code 0, in ~2 s |
| Disconnect does not kill the desktop | the session keeps the same PID after the client is killed, and is resumed on reconnect |
| Persistence works | password, files and desktop config survive replacing the container on the same volume |
| The no-volume warning is honest | a container without a volume says so loudly and reports `storage.persistent = false` |

**Not verified:** an actual Railway deployment, and connecting from a physical
Android handset. Both need a Railway account (and a phone), which the author
and the CI environment do not have. Everything Railway-specific here - the
TCP proxy on 3389, the volume at `/data`, `PORT=8080`, the healthcheck path,
the injected `RAILWAY_*` variables - follows Railway's current documentation
and its Infrastructure-as-Code SDK, and the container is exercised in CI with
the same variables Railway injects at runtime. The RDP protocol path itself
is verified end to end with a real client; an Android client is a different
RDP implementation, so expect to pin the resolution as described above.

---

## License

MIT - see [LICENSE](LICENSE).
