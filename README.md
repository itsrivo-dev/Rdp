# Ubuntu Cloud PC — a full Ubuntu 22.04 + XFCE4 desktop in your browser

A real Ubuntu 22.04 LTS "Jammy" desktop with XFCE4, streamed to a normal web
browser. No VNC client, no RDP client, no SSH, no local setup: deploy this
repository to [Railway](https://railway.com), open the HTTPS URL it gives you
in Chrome on your Android phone, sign in, and you are on a Linux desktop with a
terminal, a file manager, a panel and an application menu.

```
Your phone (Chrome)                     Railway container (Ubuntu 22.04)
┌──────────────────────┐                ┌──────────────────────────────────────┐
│ https://<svc>.up.…   │  HTTPS + WSS   │  web gateway  (python3, port $PORT)  │
│  login page          │ ─────────────► │   ├── login (scrypt + signed cookie) │
│  noVNC 1.7.0 (ESM)   │                │   ├── noVNC assets  /vnc/            │
│  on-screen keyboard  │ ◄───────────── │   └── /websockify ──┐               │
│  pinch / pan / zoom  │   framebuffer  │                     │ 127.0.0.1:5900 │
└──────────────────────┘                │  TigerVNC (Xtigervnc) ◄──┘           │
                                        │      └── XFCE4 session (:1)          │
                                        │           ├── xfwm4 + xfce4-panel    │
                                        │           ├── xfce4-terminal         │
                                        │           └── Thunar, Firefox, …     │
                                        └──────────────────────────────────────┘
```

Everything in this repository is implemented and tested: the Dockerfile, the
startup scripts, the XFCE configuration, the login page and the WebSocket/VNC
gateway. There are no placeholders, no mock screenshots and no fake terminal.

---

## Contents

- [What you get](#what-you-get)
- [Deploy to Railway from GitHub](#deploy-to-railway-from-github)
- [Signing in](#signing-in)
- [Environment variables](#environment-variables)
- [Changing the password](#changing-the-password)
- [Persistent storage — what survives what](#persistent-storage--what-survives-what)
- [Using it on a phone or tablet](#using-it-on-a-phone-or-tablet)
- [Resource use and tuning](#resource-use-and-tuning)
- [Local development and testing](#local-development-and-testing)
- [Security model](#security-model)
- [How it works](#how-it-works)
- [Limitations — read this before you rely on it](#limitations--read-this-before-you-rely-on-it)
- [Troubleshooting](#troubleshooting)
- [Repository layout](#repository-layout)
- [Licences and credits](#licences-and-credits)

---

## What you get

| | |
| --- | --- |
| Operating system | Ubuntu 22.04 LTS (Jammy) |
| Desktop | XFCE4 — `xfwm4`, `xfce4-panel`, `xfdesktop`, `xfsettingsd`, application menu, task list, clock |
| Terminal | `xfce4-terminal` (also `Ctrl+Alt+T`) |
| File manager | Thunar, with archive support and thumbnails |
| Editor / viewer | Mousepad, Ristretto, `nano`/`vim` |
| Browser | Firefox from Mozilla's APT repository (build arg `INSTALL_BROWSER=false` skips it) |
| Tooling | `python3`, `git`, `curl`, `wget`, `jq`, `htop`, `tree`, `zip`/`unzip`, `rsync`, `ssh` client |
| Remote protocol | TigerVNC (`Xtigervnc`) on `127.0.0.1:5900`, reached only through the gateway |
| Browser client | noVNC 1.7.0, served as ES modules, patched to auto-connect |
| Access control | login page, scrypt-hashed password, HMAC-signed session cookie, login throttling |
| Health | `GET /health` (JSON) for Railway, plus a watchdog with capped restarts |

---

## Deploy to Railway from GitHub

Railway builds the `Dockerfile` in this repository. You need a Railway account
and this repository on GitHub (fork it, or use the original).

### 1. Create the service

1. Railway dashboard → **New Project** → **Deploy from GitHub repo**.
2. Pick this repository and, if asked, the branch (`main`).
3. Railway detects `Dockerfile` and starts building. The first build takes a
   while (it installs XFCE, TigerVNC and Firefox — roughly 8–15 minutes on
   Railway's builders) and later builds are cached.

### 2. Add a volume (recommended, one minute)

Service → **Settings** → **Volumes** → **Add volume**, mount path **`/data`**.

The entrypoint detects the mount automatically: your home directory, the
generated password and the session signing key move to `/data` and survive
restarts and redeploys. Without a volume the container still works, but
everything is lost whenever Railway restarts or replaces it.

### 3. Generate the public HTTPS domain

Service → **Settings** → **Networking** → **Generate Domain**, or:

```bash
railway domain            # prints e.g. https://rdp-production-1a2b.up.railway.app
```

Railway terminates TLS in front of the container and forwards `PORT` to it. The
gateway listens on that port (default `8080`) and accepts both `http://` inside
the container and the proxy's `X-Forwarded-Proto: https`.

### 4. Open it and sign in

Open the domain in Chrome. You will get the sign-in page; the credentials are
in the deploy logs (see below).

**Nothing else is required.** No CLI, no SSH, no variables, no second port. If
you would rather drive it from a terminal, `./scripts/railway-setup.sh` and
`.railway/railway.ts` (Railway Infrastructure as Code) automate steps 1–3.

### Do I need to set any variables?

No. Every variable has a working default; the password is generated on first
boot. Variables are only for choosing your own password, resolution, timezone,
or to stop the password from appearing in the logs.

---

## Signing in

The deploy log contains a framed block on every start:

```
==========================================================================
  UBUNTU CLOUD PC IS READY - open this in Chrome

  Desktop URL : https://<your-service>.up.railway.app/
  Username    : ubuntu
  Password    : abcde-fghij-klmno-pqrst   (generated at first boot)
  Storage     : persistent volume at /data (5.0G free)

  The VNC server listens on 127.0.0.1 only. The browser login above is
  the only way in, and the session cookie is signed and HttpOnly.
  ...
==========================================================================
```

- Railway dashboard: service → **Deployments** → latest → **View Logs**.
- CLI: `railway logs | grep -A8 "UBUNTU CLOUD PC IS READY"`.
- The generated password is 20 characters in four groups of five, from an
  alphabet without `l`, `i`, `o`, `0` and `1` — about 99 bits of entropy and
  still typeable on a phone.
- Sessions last 7 days (`SESSION_TTL_HOURS`) and the cookie is
  `HttpOnly; SameSite=Lax; Secure` (Secure automatically behind HTTPS).
- **The deploy logs are private to your Railway project.** If you would rather
  no password ever passes through them, set `DESKTOP_PASSWORD` (choose your own)
  and `DESKTOP_PASSWORD_PRINT=false` — both are described below.

---

## Environment variables

All of them are optional. Set them in the Railway dashboard under service →
**Variables** (a redeploy applies them), or pass `-e NAME=value` to `docker run`.

| Variable | Default | Purpose |
| --- | --- | --- |
| `PORT` | `8080` | Injected by Railway. The gateway listens here; it is the only public port. |
| `DESKTOP_PASSWORD` | *(generated)* | Set your own login password. Leave empty to let the container generate and store one. |
| `DESKTOP_PASSWORD_PRINT` | `true` | `false` keeps the password out of the deploy logs (use with `DESKTOP_PASSWORD`). |
| `DESKTOP_USER` | `ubuntu` | Desktop account name. |
| `DESKTOP_RESOLUTION` | `1280x720` | Virtual screen size, e.g. `1600x900`, `1920x1080`. Must match what you want; VNC cannot resize a running session. |
| `DESKTOP_DEPTH` | `24` | Colour depth. `24` is right; lower it only to save bandwidth. |
| `VNC_FRAME_RATE` | `30` | Maximum updates/second sent to the client. `20` is smoother on a slow phone link; `60` needs more CPU. |
| `SESSION_TTL_HOURS` | `168` | How long a browser stays signed in (7 days). |
| `TZ` | `UTC` | Container and desktop timezone, e.g. `Asia/Dhaka`. |
| `DESKTOP_SUDO_NOPASSWD` | `false` | `true` gives the desktop user passwordless `sudo` (convenient, weaker). |
| `VNC_PORT` | `5900` | Loopback VNC port. Only change it if something else uses 5900. |
| `DESKTOP_DISPLAY` | `1` | X display number (`:1`). |
| `DESKTOP_NAME` | `Ubuntu Cloud Desktop` | Name shown by the VNC server. |
| `CLOUDPC_WATCHDOG_INTERVAL` | `30` | Seconds between watchdog probes. |
| `CLOUDPC_WATCHDOG_MAX_RESTARTS` | `3` | Restart attempts per service before the watchdog gives up and logs an error instead of looping. |
| `CLOUDPC_DATA_DIR` | `/data` | Fallback path when `RAILWAY_VOLUME_MOUNT_PATH` is not set. |

---

## Changing the password

Three ways, all of them valid:

**1. Railway variable (recommended — survives everything).**
Set `DESKTOP_PASSWORD` to your new password and set
`DESKTOP_PASSWORD_PRINT=false`, then redeploy. The container applies it on every
start, so it can never drift. To go back to a generated password, delete the
variable and run `cloudpc-password set` once (below).

**2. From inside the desktop.**
Open a terminal in the desktop and run:

```bash
sudo cloudpc-password set
```

It prompts for a new password (minimum 12 characters), updates the login, the
`sudo` password and the VNC password, rotates the session signing key (every
browser is signed out) and restarts the gateway. Other commands:

```bash
cloudpc-password show              # print the current password
cloudpc-password status            # where the password comes from
cloudpc-password rotate-sessions   # log out every browser, keep the password
```

**3. From your own machine with the Railway CLI.**

```bash
railway ssh                        # or: railway run bash
cloudpc-password show
cloudpc-password set 'my-new-password'
```

> The password lives on the volume at `/data/.secrets/desktop_password`
> (mode `0600`, root) and is never written into the image or into a log file.
> The gateway only ever sees a scrypt hash (`/run/cloudpc/auth.json`).

---

## Persistent storage — what survives what

| Data | With a volume at `/data` | Without a volume |
| --- | --- | --- |
| Your home directory (`~/…`) | ✅ survives restarts and redeploys | ❌ lost on every restart/redeploy |
| Desktop settings (`.config/xfce4`, panel, theme) | ✅ | ❌ |
| The generated password | ✅ (so logins stay valid) | ❌ new password each start |
| Browser sessions (session signing key) | ✅ (cookies stay valid) | ❌ signed out |
| The VNC password | ✅ | ❌ |
| Installed packages (`sudo apt install …`) | ❌ container filesystem | ❌ |
| `/etc` changes, extra config | ❌ | ❌ |
| Files outside `/data` (e.g. `/tmp`, `/opt`) | ❌ | ❌ |

So: keep your work in your home directory, and keep a small setup script there
if you need extra packages installed on every deploy. Everything else is
rebuilt from the image on each deploy.

Railway restarts, redeploys and (on some plans) sleeps replace or stop the
container; the volume is what makes the desktop feel like *your* machine.

---

## Using it on a phone or tablet

- Rotate to **landscape** — the desktop is 16:9 and uses far more of the screen.
- **Pinch to zoom**, drag with **two fingers to pan** while zoomed.
- The noVNC control bar (the arrow on the left edge, or the button that appears
  on touch devices) gives you:
  - an **on-screen keyboard** (the keyboard button),
  - **extra keys** — `Ctrl`, `Alt`, `Super`, `Tab`, `Esc`, `Ctrl+Alt+Del`,
  - **clipboard sync** in both directions (desktop ⇄ phone),
  - **scaling mode** — *Local scaling* fits the desktop to your screen; *Remote
    resizing* makes the remote screen match your browser window,
  - **quality/compression** sliders for a slow mobile link.
- **Add to home screen** in Chrome for a full-screen, app-like desktop (a web
  app manifest and icons are included).
- Zoom the whole page with Chrome's own zoom if the panel is still small: the
  desktop scales to whatever space it has.
- The desktop keeps running when you close the tab: reopen the URL, sign in
  again (the cookie lasts 7 days by default) and everything is where you left it.

---

## Resource use and tuning

The image is built to run in a small container (Railway's default is a fraction
of a vCPU and a few hundred MB of RAM):

- **XFCE without the heavy extras** — no power manager, no screensaver, no
  compositing (`xfwm4` compositing is off), no desktop effects. One workspace.
- **A flat background colour** instead of a photographic wallpaper: a full-screen
  photo is re-sent every time the desktop repaints.
- **TigerVNC tuned for a phone link** — `-localhost`, `-FrameRate 30`,
  `-CompareFB 2` (skip unchanged pixels), RGB888 (no expensive colour
  conversion), and no `-noreset`, so the desktop survives disconnects.
- **noVNC defaults come from the gateway** — quality 6, compression 2, local
  scaling, auto-reconnect, dot cursor on touch. The user can still change them
  in the control bar.
- **Static assets are served gzipped** with ETags; the noVNC bundle is ~2.9 MB
  uncompressed and about a third of that over the wire.

If the container feels slow: lower `DESKTOP_RESOLUTION` (e.g. `1024x600`),
lower `VNC_FRAME_RATE` to `20`, and leave noVNC's compression high. Firefox is
the heaviest thing in the image — rebuild with `--build-arg INSTALL_BROWSER=false`
if you never use it.

---

## Local development and testing

Docker is the only requirement to run the whole thing locally:

```bash
# build and run exactly what Railway builds
docker build -t cloudpc:test .
docker run --rm -p 8080:8080 -v cloudpc-data:/data cloudpc:test

# open http://localhost:8080 and read the password from the container logs
```

Full test suite (static checks, unit tests, build, end-to-end):

```bash
scripts/test.sh                 # everything
scripts/test.sh --fast          # static checks + unit tests only (no Docker)
python3 -m unittest discover -s tests/unit -v
pip install websocket-client pycryptodome Pillow   # for the desktop tests
```

What the end-to-end suite actually verifies (`tests/integration.sh`):

- the gateway serves the login page, and **every** protected path is `401`
  without a session (including `/websockify`);
- a wrong password is rejected and issues no cookie; the right one signs in,
  with a `HttpOnly`, `SameSite=Lax` cookie that becomes `Secure` when
  `X-Forwarded-Proto: https` is present (the Railway proxy case);
- repeated failures are rate limited to `429`;
- `/vnc/` serves the patched noVNC page and its ES-module assets, gzipped, with
  ETags, and path traversal is refused;
- `tests/clients/rfb_probe.py` — an independent RFB client that plays the role of
  a browser — completes the real handshake through the WebSocket bridge,
  **authenticates with VNC auth**, then:
  - captures a **screenshot of the real XFCE desktop** (written to
    `test-results/desktop-1.png` as CI evidence),
  - sends `Ctrl+Alt+T` and types a command, and the test then checks with
    `docker exec` that the **file that command creates exists in the container**,
  - compares before/after frames to prove the screen reacted to the input,
  - reads the desktop clipboard through the RFB `ServerCutText` message;
- `Xtigervnc`, `xfce4-session`, `xfwm4`, `xfce4-panel` and `xfdesktop` are
  running, the X display really is `1280x720`, and Thunar/Terminal/Mousepad run;
- the listening sockets are checked from `/proc`: **VNC on `127.0.0.1:5900`
  only**, the gateway on `0.0.0.0:8080`;
- no secret is stored in the runtime files or printed in the logs;
- the desktop comes back on a **replacement container without any environment
  variables**, with the same password and the files still there (and a clear
  data-loss warning when no volume is attached).

`.github/workflows/ci.yml` runs all of that on every push and pull request and
uploads the logs plus the captured screenshots as artefacts.

---

## Security model

- **The VNC server is never public.** It listens on `127.0.0.1:5900` inside the
  container (`-localhost`) and still requires VNC authentication on top. The
  Dockerfile exposes only the web port, and there is no second public endpoint
  to forget about.
- **Access requires the login.** The gateway mints a stateless, HMAC-SHA256
  signed cookie (`HttpOnly`, `SameSite=Lax`, 7-day TTL) after checking the
  password with **scrypt** (N=16384, r=8, p=1) against a hash; the plaintext
  password is never held by the web process.
- **Throttling.** Five failures per client address plus a global cap, in a
  rolling window, with a lockout; failed attempts are delayed and logged
  (without the attempted password).
- **No secrets in logs or code.** The password is printed once at startup so you
  can read it, and can be suppressed entirely (`DESKTOP_PASSWORD_PRINT=false`).
  The repository contains no credentials; `.gitignore` covers `.env`, keys and
  password files, and `tests/lint.sh` greps the sources for hardcoded secrets.
- **HTTPS everywhere** — Railway terminates TLS in front of the container; the
  container itself speaks plain HTTP on the private network, and the session
  cookie is only marked `Secure` in that case.
- **Least privilege.** The gateway runs as an unprivileged user that can read
  the scrypt hash and the session key but never the plaintext password; the
  desktop user `ubuntu` is a normal account with `sudo` (password required
  unless you enable `DESKTOP_SUDO_NOPASSWD`).
- **Anti-CSRF / origin checks** on the WebSocket upgrade, a hardened
  `Content-Security-Policy` on the app pages, `X-Content-Type-Options`,
  `X-Frame-Options: SAMEORIGIN`, `Referrer-Policy: no-referrer`, HSTS when the
  request arrived over HTTPS, bounded request sizes and a hard socket cap.
- **The supplied packages are verified.** noVNC's tarball is pinned by version
  *and* sha256, and Mozilla's APT signing key fingerprint is checked during the
  build; the build fails if either changes.

What this is **not**: a hardened multi-tenant service. It is a single-user
desktop with a password in front of it. Do not put secrets you cannot lose in
it, and do not hand the URL to people you would not give a shell to — that is
exactly what the desktop is.

---

## How it works

**Start-up order** (supervisord, PID 1, `docker/supervisor/supervisord.conf`):

1. `dbus` — the system bus XFCE and Thunar expect.
2. `vnc` (`cloudpc-vnc`) — `Xtigervnc` on `:1`, bound to `127.0.0.1:5900`, with
   `-noreset` so sessions survive browser disconnects.
3. `session` (`cloudpc-session`) — waits for the X socket, sets up the session
   environment (`XDG_*`, software GL, no screen blanking) and runs
   `dbus-run-session -- xfce4-session`.
4. `gateway` (`docker/gateway/server.py`) — login page, noVNC assets,
   `/api/session`, `/health`, and the WebSocket ⇄ VNC bridge.
5. `watchdog` — probes the three of them and restarts a dead service through
   supervisord, with a cap (`CLOUDPC_WATCHDOG_MAX_RESTARTS`) so a broken image
   reports itself instead of restarting forever.

**The gateway** is written against the Python standard library only — no pip
packages, no Node.js, no bundler in the image. `wsproto.py` is a small RFC 6455
implementation (handshake, framing, masking, control frames, ping/pong), and
`server.py` bridges each authenticated WebSocket to the loopback VNC socket,
select-looping in both directions with a 1 MiB client-frame cap and idle
timeouts. Every 25 seconds it sends a protocol-level ping so that idle mobile
connections (and Railway's proxy) are kept alive, and it closes the WebSocket
politely when the desktop goes away.

**The noVNC page** is generated at image build time by
`docker/tools/build_novnc_page.py`: it keeps noVNC's whole interface, replaces
the bootstrap so it waits for the desktop, fetches `/api/session`, connects
automatically with the VNC password, and shows a branded "Starting your Ubuntu
desktop" overlay instead of noVNC's connection dialog. The script asserts the
expected noVNC markers exist, so a future noVNC upgrade fails the build instead
of silently producing a broken page.

---

## Limitations — read this before you rely on it

- **Railway's plan decides the limits.** On the free/trial or Hobby plans a
  deployment can be **stopped, restarted or removed** when the monthly usage
  credit runs out, and services may be put to sleep when inactive. This desktop
  is *not* permanently available: treat it as a session you can lose, and put
  anything important in a Git repository or on another service. A Railway plan
  with a guaranteed resource allocation is what makes it dependable.
- **One replica, one desktop.** Scaling out would produce two independent
  desktops; keep `numReplicas: 1`.
- **A container restart ends the session.** XFCE is not restarted with your
  running programs, because they live in the container, not on the volume.
  Files on `/data` and the desktop *settings* come back.
- **No GPU.** Everything is software-rendered (`LIBGL_ALWAYS_SOFTWARE=1`), so
  video playback and 3D are slow.
- **The screen size is fixed at boot.** `DESKTOP_RESOLUTION` is applied when the
  VNC server starts; changing it needs a redeploy. Use noVNC's *Remote resizing*
  or *Local scaling* to fit your device instead.
- **Firefox needs memory.** With Firefox open, expect a few hundred MB of RAM;
  without it the desktop is happy in far less. Build with
  `--build-arg INSTALL_BROWSER=false` if you do not need it.
- **Sound is not forwarded** (no PulseAudio in the image). The desktop is
  silent by design.
- **First boot is slow** — installing XFCE and TigerVNC dominates the first
  build, and the first start seeds the XFCE profile. Subsequent deploys reuse
  the Docker layer cache and the volume.
- **Writing to the desktop through the browser is exactly what it sounds like.**
  Anyone with the URL and password gets a shell. Rotate the password if you ever
  shared the URL, and prefer `DESKTOP_SUDO_NOPASSWD=false`.
- **Not verified on Railway from this sandbox.** This project was built and
  tested here with Docker and GitHub Actions (see the CI section), but the
  sandbox cannot reach Railway's API, so the live deployment had to be created
  in the dashboard. If a deploy fails, `railway logs` plus the
  [Troubleshooting](#troubleshooting) table will normally identify it.

---

## Troubleshooting

| Symptom | Likely cause / fix |
| --- | --- |
| Deployment fails during build | Look for the failing `RUN` step in the build logs. `apt-get` or the Mozilla repository can fail transiently — redeploy. Building with `INSTALL_BROWSER=false` removes a large, network-dependent layer. |
| The URL shows "Application failed to respond" | The service is not listening on `PORT`. Check that `PORT` is Railway's value (it injects it) and that `GET /health` returns 200 in the logs of the last deploy. |
| `503` from `/health`, desktop never ready | XFCE failed to start. `railway logs` shows the `session` program's output; a corrupted panel config on the volume is the usual cause — remove `/data/home/ubuntu/.config/xfce4` and restart, or mount a fresh volume. |
| Login page loads, "Incorrect password" | The password changed (new volume, or `DESKTOP_PASSWORD` was set later). Read the current one with `railway logs | grep -A8 READY` or `cloudpc-password show`. |
| `429` on login | Login throttling. Wait five minutes, or restart the container to clear the in-memory counters. |
| Blank/black desktop | The session died (the watchdog restarts it within ~1 minute) or is still starting. Reload in a few seconds. `/api/diagnostics` (signed in) shows the VNC and session logs. |
| Desktop is tiny on the phone | Pinch to zoom, or switch noVNC's *Scaling mode* to *Remote resizing*. |
| Typing does nothing on Android | Tap the desktop once, then use the keyboard button in the noVNC control bar; Chrome's own keyboard needs focus inside the canvas. |
| Everything is lost after a redeploy | No volume. Add one with mount path `/data`. |
| "Storage: EPHEMERAL" in the logs | Same as above — the volume is missing or mounted somewhere else. |

Useful inside the desktop: `cloudpc-status` (services, sessions, storage, URL),
`cloudpc-health --json`, and `sudo cloudpc-password show`.

---

## Repository layout

```
Dockerfile                        two-stage build: vendored noVNC, then the desktop
docker/
  entrypoint.sh                   configures the container, then execs supervisord
  lib/common.sh                   shared shell helpers (logging, /proc port probes)
  bin/cloudpc-vnc                 Xtigervnc supervisor program (loopback + VNC auth)
  bin/cloudpc-session             starts the XFCE session on the VNC display
  bin/cloudpc-apply-defaults      re-asserts desktop settings inside the session
  bin/cloudpc-password            show / change / rotate credentials
  bin/cloudpc-health              health probe (Docker HEALTHCHECK, watchdog)
  bin/cloudpc-status              human readable status overview
  bin/cloudpc-watchdog            self-healing with capped restarts
  gateway/server.py               HTTP + WebSocket gateway (stdlib only)
  gateway/wsproto.py              minimal RFC 6455 implementation
  gateway/security.py             scrypt verification, signed cookies, throttling
  gateway/static/login.html       the sign-in page (no external assets)
  gateway/static/manifest.webmanifest
  supervisor/supervisord.conf     start order, restarts, graceful shutdown
  skel/…                          XFCE profile seeded into the home directory
  tools/build_novnc_page.py       generates the desktop page from noVNC's vnc.html
  tools/make_icons.py             generates the PWA icons and favicon
tests/
  lint.sh                         static checks (no Docker needed)
  unit/test_gateway.py            WebSocket framing, sessions, hashing, throttling
  clients/rfb_probe.py            independent RFB client used by the e2e tests
  integration.sh                  full end-to-end suite against a real container
.railway/railway.ts               optional Railway Infrastructure as Code
.github/workflows/ci.yml          build + test on every push and pull request
scripts/{build,test,railway-setup}.sh
```

---

## Licences and credits

This project is MIT licensed (see `LICENSE`). It would not exist without:

- **noVNC** (MPL-2.0) — the browser client, fetched and checksum-verified at
  build time and shipped unmodified apart from the generated landing page.
- **TigerVNC** (GPL-2.0) — the `Xtigervnc` display/VNC server, installed from
  Ubuntu's repositories.
- **XFCE4**, **Ubuntu** and the rest of the desktop stack, likewise from
  Ubuntu's repositories; **Firefox** from Mozilla's APT repository.
