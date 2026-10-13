#!/usr/bin/env python3
"""Status, health-check and administration endpoint for Ubuntu Cloud PC.

Runs as the unprivileged ``cloudpc`` user and only uses the Python standard
library, so it adds no dependencies and no attack surface worth speaking of.

Endpoints
---------
GET /health   public  - JSON service health, 200 when RDP is ready, 503 when not.
                        This is what the Railway healthcheck polls.
GET /         public  - small status page. Never contains credentials.
GET /admin    private - HTTP Basic auth against the desktop account; returns
                        the full connection details, session list, storage
                        state and recent service log lines.

The process never reads the RDP password. Administrative requests are verified
against a scrypt hash published by the entrypoint in /run/cloudpc/auth.json.
"""

from __future__ import annotations

import base64
import hashlib
import hmac
import html
import json
import os
import socket
import subprocess
import threading
import time
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

RUN_DIR = os.environ.get("CLOUDPC_RUN_DIR", "/run/cloudpc")
RUNTIME_FILE = os.path.join(RUN_DIR, "runtime.json")
AUTH_FILE = os.path.join(RUN_DIR, "auth.json")
XRDP_LOG = "/var/log/xrdp/xrdp.log"
SESMAN_LOG = "/var/log/xrdp/xrdp-sesman.log"

LISTEN_HOST = os.environ.get("CLOUDPC_HTTP_HOST", "0.0.0.0")  # noqa: S104 - must be reachable
LISTEN_PORT = int(os.environ.get("PORT", "8080"))
START_TIME = time.time()

_FAILED_AUTH: dict[str, list[float]] = {}
_FAILED_AUTH_LOCK = threading.Lock()
MAX_AUTH_FAILURES = 8
AUTH_LOCKOUT_SECONDS = 300


# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------
def read_json(path: str) -> dict:
    try:
        with open(path, "r", encoding="utf-8") as fh:
            return json.load(fh)
    except Exception:
        return {}


def tcp_ready(port: int, host: str = "127.0.0.1", timeout: float = 2.0) -> bool:
    try:
        with socket.create_connection((host, port), timeout=timeout):
            return True
    except OSError:
        return False


def run(cmd: list[str], timeout: float = 5.0) -> str:
    try:
        out = subprocess.run(
            cmd, capture_output=True, text=True, timeout=timeout, check=False
        )
        return out.stdout.strip()
    except Exception:
        return ""


def count_processes(name: str) -> int:
    """Count processes whose executable name matches exactly."""
    out = run(["pgrep", "-x", "-c", name])
    try:
        return int(out)
    except ValueError:
        return 0


def session_info() -> dict:
    """Describe the live desktop sessions (one Xvnc + xfce4-session each)."""
    displays = []
    try:
        for name in sorted(os.listdir("/tmp/.X11-unix")):
            if name.startswith("X") and name[1:].isdigit():
                displays.append(":" + name[1:])
    except OSError:
        pass
    return {
        "active": count_processes("xfce4-session") > 0,
        "displays": displays,
        "x_servers": count_processes("Xvnc"),
        "desktops": count_processes("xfce4-session"),
    }


def storage_info(runtime: dict) -> dict:
    data_dir = runtime.get("data_dir", "/data")
    info = {
        "persistent": bool(runtime.get("persistent")),
        "path": data_dir,
        "note": runtime.get("storage_note", ""),
    }
    try:
        st = os.statvfs(data_dir)
        info["total_bytes"] = st.f_blocks * st.f_frsize
        info["free_bytes"] = st.f_bavail * st.f_frsize
    except OSError:
        pass
    return info


def health_state() -> tuple[bool, dict]:
    runtime = read_json(RUNTIME_FILE)
    rdp_port = int(runtime.get("rdp_port", os.environ.get("RDP_PORT", 3389)))
    checks = {
        "xrdp": tcp_ready(rdp_port),
        "xrdp_sesman": tcp_ready(3350),
        "dbus": os.path.exists("/run/dbus/system_bus_socket"),
        "config": os.path.exists("/etc/xrdp/xrdp.ini"),
    }
    healthy = checks["xrdp"] and checks["xrdp_sesman"]
    payload = {
        "status": "ok" if healthy else "starting",
        "service": "ubuntu-cloud-pc",
        "version": runtime.get("version", "unknown"),
        "uptime_seconds": round(time.time() - START_TIME, 1),
        "checks": checks,
        "rdp_port": rdp_port,
        "sessions": session_info(),
        "storage": storage_info(runtime),
        "railway": {
            "service": runtime.get("railway_service", ""),
            "environment": runtime.get("railway_environment", ""),
            "region": runtime.get("railway_region", ""),
            "tcp_proxy": (
                f"{runtime['tcp_proxy_domain']}:{runtime['tcp_proxy_port']}"
                if runtime.get("tcp_proxy_domain") and runtime.get("tcp_proxy_port")
                else ""
            ),
        },
    }
    return healthy, payload


def tail(path: str, lines: int = 40) -> list[str]:
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as fh:
            return [ln.rstrip("\n") for ln in fh.readlines()[-lines:]]
    except OSError:
        return []


# ---------------------------------------------------------------------------
# authentication for /admin
# ---------------------------------------------------------------------------
def _locked_out(client: str) -> bool:
    now = time.time()
    with _FAILED_AUTH_LOCK:
        hits = [t for t in _FAILED_AUTH.get(client, []) if now - t < AUTH_LOCKOUT_SECONDS]
        _FAILED_AUTH[client] = hits
        return len(hits) >= MAX_AUTH_FAILURES


def _record_failure(client: str) -> None:
    with _FAILED_AUTH_LOCK:
        _FAILED_AUTH.setdefault(client, []).append(time.time())


def check_credentials(header: str | None) -> bool:
    """Validate an HTTP Basic credential against the published scrypt hash."""
    auth = read_json(AUTH_FILE)
    if not auth or not header or not header.startswith("Basic "):
        return False
    try:
        decoded = base64.b64decode(header[6:], validate=True).decode("utf-8")
        username, _, password = decoded.partition(":")
    except Exception:
        return False
    if not hmac.compare_digest(username, str(auth.get("username", ""))):
        return False
    try:
        digest = hashlib.scrypt(
            password.encode(),
            salt=base64.b64decode(auth["salt"]),
            n=int(auth.get("n", 16384)),
            r=int(auth.get("r", 8)),
            p=int(auth.get("p", 1)),
            dklen=int(auth.get("dklen", 32)),
        )
    except Exception:
        return False
    return hmac.compare_digest(digest, base64.b64decode(auth["hash"]))


# ---------------------------------------------------------------------------
# rendering
# ---------------------------------------------------------------------------
def status_page(payload: dict, runtime: dict) -> bytes:
    ok = payload["status"] == "ok"
    proxy = payload["railway"]["tcp_proxy"]
    storage = payload["storage"]
    if proxy:
        address = (
            f'<code>{html.escape(proxy)}</code>'
            "<p class=hint>Enter this address in your Android RDP client.</p>"
        )
    else:
        address = (
            "<code>not exposed yet</code>"
            "<p class=hint>Create a Railway <b>TCP Proxy</b> for port "
            f"{payload['rdp_port']} (Service &rarr; Settings &rarr; Networking) "
            "to get a public <code>host:port</code> for RDP.</p>"
        )
    rows = [
        ("Remote desktop", address),
        ("Service health", "running" if ok else "starting&nbsp;/&nbsp;unavailable"),
        (
            "Desktop session",
            "active" if payload["sessions"]["active"] else "idle (starts when you connect)",
        ),
        (
            "Storage",
            ("persistent volume at " + html.escape(storage["path"]))
            if storage["persistent"]
            else "<b>ephemeral</b> &ndash; attach a Railway Volume to keep your files",
        ),
        ("Credentials", "username and password are printed in the Railway deploy logs"),
    ]
    body = "\n".join(
        f"<tr><th>{html.escape(k)}</th><td>{v}</td></tr>" for k, v in rows
    )
    page = f"""<!doctype html>
<html lang=en><head><meta charset=utf-8>
<meta name=viewport content="width=device-width, initial-scale=1">
<title>Ubuntu Cloud PC</title>
<style>
 body{{font:16px/1.5 system-ui,-apple-system,Segoe UI,Roboto,sans-serif;margin:0;
      background:#11151c;color:#e6edf3;display:flex;justify-content:center}}
 main{{max-width:40rem;padding:2rem 1.25rem}}
 h1{{font-size:1.4rem;margin:0 0 .25rem}}
 .dot{{display:inline-block;width:.6rem;height:.6rem;border-radius:50%;
      background:{'#3fb950' if ok else '#d29922'};margin-right:.5rem}}
 table{{width:100%;border-collapse:collapse;margin-top:1.5rem}}
 th{{text-align:left;font-weight:600;color:#8b949e;padding:.6rem .75rem .6rem 0;
     vertical-align:top;white-space:nowrap;width:9rem}}
 td{{padding:.6rem 0;border-bottom:1px solid #222a35}}
 code{{background:#1b2430;padding:.15rem .4rem;border-radius:.3rem;
       word-break:break-all}}
 .hint{{color:#8b949e;font-size:.85rem;margin:.4rem 0 0}}
 footer{{margin-top:2rem;color:#6e7681;font-size:.8rem}}
</style></head><body><main>
<h1><span class=dot></span>Ubuntu Cloud PC</h1>
<p class=hint>Ubuntu 22.04 LTS &middot; XFCE &middot; xrdp {html.escape(str(payload['version']))}</p>
<table>{body}</table>
<footer>Machine-readable status: <code>/health</code> &middot;
Full connection details (sign in with your desktop account):
<code>/admin</code></footer>
</main></body></html>"""
    return page.encode("utf-8")


# ---------------------------------------------------------------------------
# HTTP
# ---------------------------------------------------------------------------
class Handler(BaseHTTPRequestHandler):
    server_version = "cloudpc"
    sys_version = ""
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt: str, *args) -> None:  # noqa: A003
        print(
            "%s [status] %s %s"
            % (time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), self.address_string(), fmt % args),
            flush=True,
        )

    # -- helpers ----------------------------------------------------------
    def _send(self, code: int, body: bytes, ctype: str, extra: dict | None = None) -> None:
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Referrer-Policy", "no-referrer")
        for key, value in (extra or {}).items():
            self.send_header(key, value)
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def _json(self, code: int, payload: dict) -> None:
        self._send(code, json.dumps(payload, indent=2).encode(), "application/json; charset=utf-8")

    # -- routes -----------------------------------------------------------
    def do_HEAD(self) -> None:  # noqa: N802
        self.do_GET()

    def do_GET(self) -> None:  # noqa: N802
        path = self.path.split("?", 1)[0].rstrip("/") or "/"
        if path in ("/health", "/healthz", "/_health"):
            healthy, payload = health_state()
            self._json(HTTPStatus.OK if healthy else HTTPStatus.SERVICE_UNAVAILABLE, payload)
        elif path == "/":
            _, payload = health_state()
            self._send(HTTPStatus.OK, status_page(payload, read_json(RUNTIME_FILE)), "text/html; charset=utf-8")
        elif path == "/admin":
            self._admin()
        else:
            self._send(HTTPStatus.NOT_FOUND, b"not found\n", "text/plain; charset=utf-8")

    def _admin(self) -> None:
        client = self.client_address[0] if self.client_address else "?"
        if _locked_out(client):
            self._json(
                HTTPStatus.TOO_MANY_REQUESTS,
                {"error": "too many failed attempts, try again later"},
            )
            return
        if not check_credentials(self.headers.get("Authorization")):
            _record_failure(client)
            time.sleep(1.0)
            self._send(
                HTTPStatus.UNAUTHORIZED,
                b'{"error": "authentication required"}\n',
                "application/json; charset=utf-8",
                {"WWW-Authenticate": 'Basic realm="Ubuntu Cloud PC admin", charset="UTF-8"'},
            )
            return

        runtime = read_json(RUNTIME_FILE)
        _, payload = health_state()
        proxy_domain = runtime.get("tcp_proxy_domain", "")
        proxy_port = runtime.get("tcp_proxy_port", "")
        payload["connection"] = {
            "protocol": "RDP (TLS)",
            "address": f"{proxy_domain}:{proxy_port}" if proxy_domain else "",
            "username": runtime.get("username", ""),
            "password": "not stored by this service - see the Railway deploy logs",
            "password_source": runtime.get("password_source", ""),
            "internal_port": runtime.get("rdp_port", 3389),
            "hint": (
                "Create a Railway TCP Proxy for the internal RDP port to get a "
                "public address."
                if not proxy_domain
                else "Use this address in a Remote Desktop client."
            ),
        }
        payload["home"] = runtime.get("home", "")
        payload["logs"] = {
            "xrdp": tail(XRDP_LOG, 25),
            "xrdp_sesman": tail(SESMAN_LOG, 25),
        }
        self._json(HTTPStatus.OK, payload)


def main() -> None:
    ThreadingHTTPServer.allow_reuse_address = True
    ThreadingHTTPServer.daemon_threads = True
    httpd = ThreadingHTTPServer((LISTEN_HOST, LISTEN_PORT), Handler)
    print(
        "%s [status] listening on %s:%s"
        % (time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), LISTEN_HOST, LISTEN_PORT),
        flush=True,
    )
    try:
        httpd.serve_forever(poll_interval=0.5)
    except KeyboardInterrupt:
        pass
    finally:
        httpd.server_close()


if __name__ == "__main__":
    main()
