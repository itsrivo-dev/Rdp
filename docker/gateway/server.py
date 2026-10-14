#!/usr/bin/env python3
"""Ubuntu Cloud PC web gateway.

One HTTP server that does four jobs:

1. serves the authenticated login page,
2. serves the static noVNC application and the page that drives it,
3. bridges ``/websockify`` WebSocket connections to the loopback-only
   TigerVNC server (the noVNC "websockify" role),
4. exposes health and diagnostics endpoints for Railway and the operator.

It is written against the Python standard library only, so the image needs no
pip packages, and it runs as the unprivileged ``cloudpc`` user: it can read the
scrypt password hash and the session signing key but never the plaintext
password, and it cannot modify the container configuration.
"""

from __future__ import annotations

import json
import mimetypes
import os
import re
import select
import socket
import socketserver
import sys
import threading
import time
import zlib
from dataclasses import dataclass, field
from urllib.parse import parse_qs, unquote, urlsplit

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import wsproto  # noqa: E402  (local module, path prepared above)
from security import (  # noqa: E402
    COOKIE_NAME,
    LoginThrottle,
    PasswordStore,
    SessionManager,
)

SERVICE_NAME = "ubuntu-cloud-pc"
VERSION = "2.0.0"

RUN_DIR = os.environ.get("CLOUDPC_RUN_DIR", "/run/cloudpc")
LOG_DIR = os.environ.get("CLOUDPC_LOG_DIR", "/var/log/cloudpc")
NOVNC_DIR = os.environ.get("CLOUDPC_NOVNC_DIR", "/usr/share/novnc")
STATIC_DIR = os.environ.get("CLOUDPC_STATIC_DIR", "/opt/cloudpc/gateway/static")

LISTEN_HOST = os.environ.get("CLOUDPC_HTTP_HOST", "0.0.0.0")  # noqa: S104 - Railway ingress
LISTEN_PORT = int(os.environ.get("PORT", "8080") or 8080)

VNC_HOST = os.environ.get("VNC_HOST", "127.0.0.1")
VNC_PORT = int(os.environ.get("VNC_PORT", "5900") or 5900)
VNC_PASSWORD_FILE = os.environ.get("VNC_PASSWORD_FILE", "/run/cloudpc/vnc_password")

DESKTOP_USER = os.environ.get("DESKTOP_USER", "ubuntu")
DESKTOP_RESOLUTION = os.environ.get("DESKTOP_RESOLUTION", "1280x720")
DESKTOP_NAME = os.environ.get("DESKTOP_NAME", "Ubuntu Cloud Desktop")

SESSION_TTL_HOURS = float(os.environ.get("SESSION_TTL_HOURS", "168") or 168)
COOKIE_SECURE_MODE = os.environ.get("COOKIE_SECURE", "auto").strip().lower()

MAX_CONNECTIONS = int(os.environ.get("CLOUDPC_MAX_CONNECTIONS", "64") or 64)
HEADER_TIMEOUT = 25.0
BRIDGE_IDLE_TIMEOUT = 3600.0
BRIDGE_PING_INTERVAL = 25.0
MAX_HEADER_BYTES = 16 * 1024
MAX_BODY_BYTES = 8 * 1024
MAX_KEEPALIVE_REQUESTS = 100
STATIC_CACHE_MAX = 48

START_TIME = time.time()
LOG_LOCK = threading.Lock()

TEXT_TYPES = (
    "text/",
    "application/javascript",
    "application/json",
    "application/manifest+json",
    "application/xml",
    "image/svg+xml",
)


def log(message: str, level: str = "info") -> None:
    stamp = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    with LOG_LOCK:
        stream = sys.stderr if level in ("warning", "error") else sys.stdout
        print("%s [gateway] %s%s" % (stamp, "WARNING: " if level == "warning" else "", message),
              file=stream, flush=True)


# ---------------------------------------------------------------------------
# small helpers
# ---------------------------------------------------------------------------
def read_file(path: str, binary: bool = False, limit: int | None = None):
    try:
        with open(path, "rb" if binary else "r", **({} if binary else {"encoding": "utf-8"})) as fh:
            return fh.read(limit) if limit else fh.read()
    except OSError:
        return None


def tail_file(path: str, lines: int = 40) -> list[str]:
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as fh:
            return [line.rstrip("\n") for line in fh.readlines()[-lines:]]
    except OSError:
        return []


def port_listening(port: int) -> bool:
    """True when something listens on *port*, on either address family.

    /proc is read instead of opening a TCP connection on purpose: probing the
    VNC port with a bare connect would show up as a failed authentication in
    TigerVNC's log every time health is checked.
    """
    want = "%04X" % port
    for path in ("/proc/net/tcp", "/proc/net/tcp6"):
        try:
            with open(path, "r", encoding="utf-8") as fh:
                next(fh, None)
                for line in fh:
                    fields = line.split()
                    if len(fields) < 4 or fields[3] != "0A":
                        continue
                    local = fields[1].rsplit(":", 1)
                    if len(local) == 2 and local[1].upper() == want:
                        return True
        except OSError:
            continue
    return False


def count_processes(name: str) -> int:
    """Count processes whose command name matches exactly (procfs scan)."""
    count = 0
    try:
        entries = os.listdir("/proc")
    except OSError:
        return 0
    for entry in entries:
        if not entry.isdigit():
            continue
        try:
            with open("/proc/%s/comm" % entry, "r", encoding="utf-8") as fh:
                comm = fh.read().strip()
        except OSError:
            continue
        if comm == name:
            count += 1
    return count


def display_sockets() -> list[str]:
    displays = []
    try:
        for name in sorted(os.listdir("/tmp/.X11-unix")):
            if name.startswith("X") and name[1:].isdigit():
                displays.append(":" + name[1:])
    except OSError:
        pass
    return displays


def guess_type(path: str) -> str:
    override = {
        ".js": "text/javascript; charset=utf-8",
        ".mjs": "text/javascript; charset=utf-8",
        ".css": "text/css; charset=utf-8",
        ".html": "text/html; charset=utf-8",
        ".json": "application/json; charset=utf-8",
        ".webmanifest": "application/manifest+json; charset=utf-8",
        ".svg": "image/svg+xml",
        ".woff2": "font/woff2",
        ".ico": "image/x-icon",
        ".png": "image/png",
        ".txt": "text/plain; charset=utf-8",
    }
    ext = os.path.splitext(path)[1].lower()
    if ext in override:
        return override[ext]
    guessed, _ = mimetypes.guess_type(path)
    return guessed or "application/octet-stream"


def gzip_bytes(payload: bytes) -> bytes:
    compressor = zlib.compressobj(6, zlib.DEFLATED, 16 + zlib.MAX_WBITS)
    return compressor.compress(payload) + compressor.flush()


# ---------------------------------------------------------------------------
# request / response model
# ---------------------------------------------------------------------------
@dataclass
class Request:
    method: str
    target: str
    version: str
    headers: dict
    body: bytes
    client: str
    buffer: bytearray = field(default_factory=bytearray)

    @property
    def split(self):
        parts = urlsplit(self.target)
        return parts.path or "/", parse_qs(parts.query)

    def cookie(self, name: str) -> str:
        raw = self.headers.get("cookie", "")
        for item in raw.split(";"):
            if "=" not in item:
                continue
            key, _, value = item.partition("=")
            if key.strip() == name:
                return unquote(value.strip())
        return ""

    @property
    def is_https(self) -> bool:
        proto = self.headers.get("x-forwarded-proto", "")
        return proto.split(",")[0].strip().lower() == "https"

    @property
    def client_ip(self) -> str:
        """Best-effort client address for rate limiting.

        ``X-Forwarded-For`` is honoured because the container sits behind
        Railway's HTTPS proxy, but the *last* entry is used: that is the one a
        fronting proxy appends, so a client cannot choose its own bucket by
        sending a forged header of its own.
        """
        forwarded = self.headers.get("x-forwarded-for", "")
        if forwarded:
            candidate = forwarded.split(",")[-1].strip()
            if candidate:
                return candidate
        return self.client


class Response:
    def __init__(self, status: int, body: bytes = b"", content_type: str = "text/plain; charset=utf-8",
                 headers: dict | None = None, keep_alive: bool = True) -> None:
        self.status = status
        self.body = body
        self.content_type = content_type
        self.headers = dict(headers or {})
        self.keep_alive = keep_alive


REASONS = {
    200: "OK",
    204: "No Content",
    303: "See Other",
    304: "Not Modified",
    400: "Bad Request",
    401: "Unauthorized",
    403: "Forbidden",
    404: "Not Found",
    405: "Method Not Allowed",
    408: "Request Timeout",
    413: "Payload Too Large",
    429: "Too Many Requests",
    431: "Request Header Fields Too Large",
    500: "Internal Server Error",
    503: "Service Unavailable",
}


def json_response(payload: dict, status: int = 200, headers: dict | None = None,
                  keep_alive: bool = True) -> Response:
    body = json.dumps(payload, indent=2, sort_keys=True).encode("utf-8") + b"\n"
    merged = {"Cache-Control": "no-store"}
    merged.update(headers or {})
    return Response(status, body, "application/json; charset=utf-8", merged, keep_alive)


class StaticCache:
    """Bounded memory cache of pre-compressed static assets."""

    def __init__(self, limit: int = STATIC_CACHE_MAX) -> None:
        self.limit = limit
        self._entries: dict = {}
        self._lock = threading.Lock()

    def get(self, key):
        with self._lock:
            return self._entries.get(key)

    def put(self, key, value) -> None:
        with self._lock:
            if len(self._entries) >= self.limit:
                self._entries.pop(next(iter(self._entries)))
            self._entries[key] = value


# ---------------------------------------------------------------------------
# gateway
# ---------------------------------------------------------------------------
class Gateway:
    def __init__(self) -> None:
        self.passwords = PasswordStore(os.path.join(RUN_DIR, "auth.json"))
        self.sessions = SessionManager(
            os.path.join(RUN_DIR, "session.key"),
            int(SESSION_TTL_HOURS * 3600),
            DESKTOP_USER,
        )
        self.throttle = LoginThrottle()
        self.static_cache = StaticCache()
        self.login_page = read_file(os.path.join(STATIC_DIR, "login.html")) or (
            "<!doctype html><title>Ubuntu Cloud PC</title>"
            "<h1>Ubuntu Cloud PC</h1><form method=post action=/login>"
            "<input type=password name=password><button>Sign in</button></form>"
        )
        self.vnc_password_cache: tuple[float, str] = (0.0, "")

    # -- secrets ----------------------------------------------------------
    def vnc_password(self) -> str:
        """Read the VNC password (never logged, only handed to a session)."""
        try:
            mtime = os.stat(VNC_PASSWORD_FILE).st_mtime
        except OSError:
            return ""
        cached_mtime, cached = self.vnc_password_cache
        if cached and cached_mtime == mtime:
            return cached
        raw = read_file(VNC_PASSWORD_FILE)
        value = (raw or "").strip()
        self.vnc_password_cache = (mtime, value)
        return value

    # -- sessions ---------------------------------------------------------
    def authenticated(self, request: Request) -> bool:
        token = request.cookie(COOKIE_NAME)
        return bool(token) and self.sessions.verify(token)

    def session_cookie(self, token: str, expires: int, secure: bool) -> str:
        parts = [
            "%s=%s" % (COOKIE_NAME, token),
            "Path=/",
            "HttpOnly",
            "SameSite=Lax",
            "Max-Age=%d" % max(0, expires - int(time.time())),
        ]
        if secure:
            parts.append("Secure")
        return "; ".join(parts)

    def security_headers(self, request: Request, csp: str | None = None) -> dict:
        headers = {
            "X-Content-Type-Options": "nosniff",
            "Referrer-Policy": "no-referrer",
            "X-Frame-Options": "SAMEORIGIN",
        }
        if csp:
            headers["Content-Security-Policy"] = csp
        if request.is_https:
            headers["Strict-Transport-Security"] = "max-age=31536000"
        return headers

    # -- desktop state ----------------------------------------------------
    def desktop_state(self) -> dict:
        displays = display_sockets()
        sessions = count_processes("xfce4-session")
        wm = count_processes("xfwm4")
        panel = count_processes("xfce4-panel")
        return {
            "vnc_port": VNC_PORT,
            "vnc_listening": port_listening(VNC_PORT),
            "displays": displays,
            "xfce_sessions": sessions,
            "window_manager": wm > 0,
            "panel": panel > 0,
            "ready": port_listening(VNC_PORT) and sessions > 0 and wm > 0,
        }

    def storage_state(self) -> dict:
        runtime = read_file(os.path.join(RUN_DIR, "runtime.json"))
        try:
            data = json.loads(runtime) if runtime else {}
        except Exception:
            data = {}
        info = {
            "persistent": bool(data.get("persistent")),
            "path": data.get("data_dir", ""),
            "note": data.get("storage_note", ""),
        }
        try:
            stat = os.statvfs(info["path"]) if info["path"] else None
            if stat:
                info["total_bytes"] = stat.f_blocks * stat.f_frsize
                info["free_bytes"] = stat.f_bavail * stat.f_frsize
        except OSError:
            pass
        return info

    # -- routes -----------------------------------------------------------
    def dispatch(self, request: Request) -> Response:
        path, query = request.split
        path = re.sub(r"/{2,}", "/", path)

        if path == "/health" or path == "/healthz":
            return self.route_health(request)

        if path == "/favicon.ico":
            return self.serve_static(request, STATIC_DIR, "favicon.ico")

        if path in ("/manifest.webmanifest",):
            return self.serve_static(request, STATIC_DIR, "manifest.webmanifest")

        if path == "/static" or path.startswith("/static/"):
            return self.serve_static(request, STATIC_DIR, path[len("/static/"):] or "login.html")

        if path == "/" or path == "/login":
            if self.authenticated(request):
                return Response(303, b"", "text/plain; charset=utf-8", {"Location": "/vnc/"})
            return self.route_login_page(request)

        if path == "/logout":
            headers = {"Location": "/", "Set-Cookie": self.session_cookie("gone", int(time.time()) - 60, True)}
            headers.update(self.security_headers(request))
            return Response(303, b"", "text/plain; charset=utf-8", headers)

        if path == "/login":
            return self.route_login_page(request)

        if path == "/vnc" or path == "/vnc/":
            if not self.authenticated(request):
                return self.unauthorized(request)
            return self.serve_static(request, NOVNC_DIR, "index.html")

        if path.startswith("/vnc/"):
            if not self.authenticated(request):
                return self.unauthorized(request)
            return self.serve_static(request, NOVNC_DIR, path[len("/vnc/"):])

        if path == "/api/session":
            return self.route_session(request)

        if path == "/api/diagnostics":
            return self.route_diagnostics(request)

        if path == "/websockify" or path.startswith("/websockify/"):
            # Handled by the request loop (it takes over the socket).
            return Response(404, b"not found\n")

        return Response(404, b"not found\n", headers=self.security_headers(request))

    def route_health(self, request: Request) -> Response:
        desktop = self.desktop_state()
        payload = {
            "status": "ok",
            "service": SERVICE_NAME,
            "version": VERSION,
            "uptime_seconds": round(time.time() - START_TIME, 1),
            "desktop": desktop,
            "storage": self.storage_state(),
            "sessions_available": self.sessions.available(),
            "checks": {
                "gateway": True,
                "dbus": os.path.exists("/run/dbus/system_bus_socket"),
                "vnc": desktop["vnc_listening"],
                "xfce": desktop["xfce_sessions"] > 0,
            },
            "hints": []
            if desktop["ready"]
            else ["the desktop is still starting - reload in a few seconds"],
        }
        headers = self.security_headers(request)
        headers["Cache-Control"] = "no-store"
        body = json.dumps(payload, indent=2, sort_keys=True).encode("utf-8") + b"\n"
        return Response(200, body, "application/json; charset=utf-8", headers)

    def route_login_page(self, request: Request, error: str = "", status: int = 200) -> Response:
        page = self.login_page
        page = page.replace("{{USERNAME}}", DESKTOP_USER)
        page = page.replace("{{VERSION}}", VERSION)
        page = page.replace("{{SERVICE}}", SERVICE_NAME)
        if error:
            banner = '<div class="error" role="alert">%s</div>' % error
        else:
            banner = ""
        page = page.replace("{{ERROR}}", banner)
        csp = ("default-src 'none'; style-src 'unsafe-inline'; img-src 'self' data:; "
               "form-action 'self'; base-uri 'none'; frame-ancestors 'none'")
        headers = self.security_headers(request, csp)
        headers["Cache-Control"] = "no-store"
        return Response(status, page.encode("utf-8"), "text/html; charset=utf-8", headers)

    def route_login_submit(self, request: Request) -> Response:
        client = request.client_ip
        if not self.throttle.allow(client):
            retry = self.throttle.retry_after(client)
            log("login blocked for %s (rate limit, retry in %ss)" % (client, retry), "warning")
            return self.route_login_page(
                request,
                "Too many failed attempts. Try again in about %d minute(s)." % max(1, retry // 60),
                status=429,
            )

        fields = parse_qs(request.body.decode("utf-8", "replace"), keep_blank_values=True)
        password = (fields.get("password") or [""])[0]
        if not password:
            return self.route_login_page(request, "Please enter the desktop password.", status=400)

        if not self.passwords.verify(password):
            self.throttle.record_failure(client)
            log("failed login from %s" % client, "warning")
            time.sleep(0.75)
            return self.route_login_page(request, "Incorrect password.", status=401)

        self.throttle.record_success(client)
        token, expires = self.sessions.issue(user_agent=request.headers.get("user-agent", ""))
        secure = self.secure_cookies(request)
        log("login succeeded from %s" % client)
        headers = {
            "Location": "/vnc/",
            "Set-Cookie": self.session_cookie(token, expires, secure),
        }
        headers.update(self.security_headers(request))
        return Response(303, b"", "text/plain; charset=utf-8", headers)

    def secure_cookies(self, request: Request) -> bool:
        mode = COOKIE_SECURE_MODE
        if mode in ("true", "yes", "1", "on"):
            return True
        if mode in ("false", "no", "0", "off"):
            return False
        return request.is_https

    def unauthorized(self, request: Request) -> Response:
        headers = {"WWW-Authenticate": 'Basic realm="Ubuntu Cloud PC"'}
        headers.update(self.security_headers(request))
        return Response(401, b"authentication required - open / to sign in\n",
                        "text/plain; charset=utf-8", headers)

    def route_session(self, request: Request) -> Response:
        if not self.authenticated(request):
            return self.unauthorized(request)
        password = self.vnc_password()
        if not password:
            return json_response(
                {"error": "the desktop is still starting - retry in a few seconds"},
                status=503,
            )
        desktop = self.desktop_state()
        return json_response(
            {
                "username": DESKTOP_USER,
                "desktop_name": DESKTOP_NAME,
                "resolution": DESKTOP_RESOLUTION,
                "ws_path": "websockify",
                "vnc_password": password,
                "desktop": desktop,
            }
        )

    def route_diagnostics(self, request: Request) -> Response:
        if not self.authenticated(request):
            return self.unauthorized(request)
        return json_response(
            {
                "desktop": self.desktop_state(),
                "storage": self.storage_state(),
                "logs": {
                    "vnc": tail_file(os.path.join(LOG_DIR, "vnc.log"), 30),
                    "session": tail_file(os.path.join(LOG_DIR, "session.log"), 30),
                    "gateway": tail_file(os.path.join(LOG_DIR, "gateway.log"), 30),
                    "watchdog": tail_file(os.path.join(LOG_DIR, "watchdog.log"), 30),
                },
                "note": "log output is credential-free by design",
            }
        )

    # -- static files -----------------------------------------------------
    def serve_static(self, request: Request, root: str, relative: str) -> Response:
        if request.method not in ("GET", "HEAD"):
            return Response(405, b"method not allowed\n", headers={"Allow": "GET, HEAD"})

        relative = unquote(relative or "").lstrip("/")
        if not relative or relative.endswith("/"):
            relative += "index.html"
        candidate = os.path.normpath(os.path.join(root, relative))
        if not candidate.startswith(os.path.normpath(root) + os.sep):
            return Response(403, b"forbidden\n")
        if os.path.isdir(candidate):
            candidate = os.path.join(candidate, "index.html")
        if not os.path.isfile(candidate):
            return Response(404, b"not found\n", headers=self.security_headers(request))

        try:
            stat = os.stat(candidate)
            with open(candidate, "rb") as handle:
                payload = handle.read()
        except OSError:
            return Response(404, b"not found\n")

        etag = 'W/"%x-%x"' % (int(stat.st_mtime), stat.st_size)
        headers = {
            "ETag": etag,
            "Cache-Control": "private, max-age=86400" if root == NOVNC_DIR else "public, max-age=3600",
            "Last-Modified": time.strftime("%a, %d %b %Y %H:%M:%S GMT", time.gmtime(stat.st_mtime)),
        }
        csp = None
        if candidate.endswith(".html"):
            csp = ("default-src 'self'; img-src 'self' data: blob:; style-src 'self' 'unsafe-inline'; "
                   "script-src 'self' 'unsafe-inline' blob:; worker-src 'self' blob:; "
                   "connect-src 'self' ws: wss:; base-uri 'none'; frame-ancestors 'none'")
            headers["Cache-Control"] = "no-store"
        headers.update(self.security_headers(request, csp))

        if request.headers.get("if-none-match") == etag:
            return Response(304, b"", guess_type(candidate), headers)

        content_type = guess_type(candidate)
        accepts_gzip = "gzip" in request.headers.get("accept-encoding", "").lower()
        compressible = content_type.startswith(TEXT_TYPES) and 512 <= len(payload) <= 4 * 1024 * 1024
        if accepts_gzip and compressible and request.method == "GET":
            cache_key = (candidate, stat.st_mtime, stat.st_size, "gzip")
            cached = self.static_cache.get(cache_key)
            if cached is None:
                cached = gzip_bytes(payload)
                self.static_cache.put(cache_key, cached)
            payload = cached
            headers["Content-Encoding"] = "gzip"
            headers["Vary"] = "Accept-Encoding"

        body = b"" if request.method == "HEAD" else payload
        return Response(200, body, content_type, headers)


# ---------------------------------------------------------------------------
# HTTP plumbing
# ---------------------------------------------------------------------------
def parse_headers(block: bytes) -> tuple[str, str, str, dict] | None:
    try:
        text = block.decode("iso-8859-1")
    except Exception:
        return None
    lines = text.split("\r\n")
    if not lines or not lines[0]:
        return None
    parts = lines[0].split(" ")
    if len(parts) != 3:
        return None
    method, target, version = parts
    headers: dict = {}
    for line in lines[1:]:
        if not line:
            continue
        if line[0] in " \t":  # obsolete line folding
            continue
        name, _, value = line.partition(":")
        headers[name.strip().lower()] = value.strip()
    return method, target, version, headers


class GatewayServer(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True
    request_queue_size = 64

    def __init__(self, address, handler, gateway: Gateway) -> None:
        self.gateway = gateway
        self._slots = threading.BoundedSemaphore(MAX_CONNECTIONS)
        super().__init__(address, handler)

    def process_request(self, request, client_address) -> None:
        if not self._slots.acquire(blocking=False):
            # No slot was taken for this connection, so close it through the
            # base class: going through shutdown_request() would hand a slot
            # back that this connection never held.
            try:
                request.sendall(b"HTTP/1.1 503 Service Unavailable\r\n"
                                b"Content-Length: 17\r\nConnection: close\r\n\r\nserver is busy\n")
            except OSError:
                pass
            socketserver.TCPServer.shutdown_request(self, request)
            return
        try:
            super().process_request(request, client_address)
        except Exception:
            self._slots.release()
            raise

    def shutdown_request(self, request) -> None:
        # One slot per connection, taken in process_request and given back here
        # whenever the connection ends - successful or not. Releasing only on
        # the error path leaked a slot per request, so after
        # CLOUDPC_MAX_CONNECTIONS requests every answer was "503 server is
        # busy", including /health: the login page never loaded.
        try:
            super().shutdown_request(request)
        finally:
            self._slots.release()

    def handle_error(self, request, client_address) -> None:
        exc = sys.exc_info()[1]
        if isinstance(exc, (ConnectionResetError, BrokenPipeError, socket.timeout)):
            return
        log("unhandled error for %s: %r" % (client_address[0], exc), "error")


class GatewayHandler(socketserver.BaseRequestHandler):
    """One thread per TCP connection; handles keep-alive and the WS upgrade."""

    server: GatewayServer

    def handle(self) -> None:
        sock = self.request
        gateway = self.server.gateway
        try:
            sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        except OSError:
            pass
        buffer = bytearray()
        client = "%s" % (self.client_address[0],)
        try:
            for _ in range(MAX_KEEPALIVE_REQUESTS):
                sock.settimeout(HEADER_TIMEOUT)
                request = self._read_request(sock, buffer, client)
                if request is None:
                    return
                path, _ = request.split
                if path == "/websockify":
                    self._handle_websocket(sock, request, buffer)
                    return

                if request.method == "POST" and path == "/login":
                    response = gateway.route_login_submit(request)
                elif request.method in ("GET", "HEAD"):
                    response = gateway.dispatch(request)
                else:
                    response = Response(405, b"method not allowed\n", headers={"Allow": "GET, HEAD, POST"})

                self._send_response(sock, response, request)
                if not response.keep_alive:
                    return
        except socket.timeout:
            return
        except (ConnectionResetError, BrokenPipeError):
            return
        except Exception as exc:  # pragma: no cover - defensive
            log("request handling failed for %s: %r" % (client, exc), "error")
        finally:
            try:
                sock.close()
            except OSError:
                pass

    # -- low level --------------------------------------------------------
    def _read_request(self, sock, buffer: bytearray, client: str):
        deadline = time.monotonic() + HEADER_TIMEOUT
        while b"\r\n\r\n" not in buffer:
            if len(buffer) > MAX_HEADER_BYTES:
                self._send_response(sock, Response(431, b"request header too large\n",
                                                   headers={"Connection": "close"}), None)
                return None
            if time.monotonic() > deadline:
                return None
            try:
                chunk = sock.recv(4096)
            except socket.timeout:
                return None
            if not chunk:
                return None
            buffer.extend(chunk)

        head_end = buffer.index(b"\r\n\r\n")
        head = bytes(buffer[:head_end])
        del buffer[: head_end + 4]
        parsed = parse_headers(head)
        if parsed is None:
            self._send_response(sock, Response(400, b"bad request\n", headers={"Connection": "close"}), None)
            return None
        method, target, version, headers = parsed

        if method not in ("GET", "HEAD", "POST"):
            self._send_response(sock, Response(405, b"method not allowed\n", headers={"Connection": "close"}), None)
            return None

        body = b""
        length_header = headers.get("content-length")
        if length_header:
            try:
                length = int(length_header)
            except ValueError:
                length = -1
            if length < 0 or length > MAX_BODY_BYTES:
                self._send_response(sock, Response(413, b"payload too large\n",
                                                   headers={"Connection": "close"}), None)
                return None
            if headers.get("expect", "").lower() == "100-continue":
                sock.sendall(b"HTTP/1.1 100 Continue\r\n\r\n")
            while len(buffer) < length:
                chunk = sock.recv(4096)
                if not chunk:
                    return None
                buffer.extend(chunk)
            body = bytes(buffer[:length])
            del buffer[:length]

        return Request(method=method, target=target, version=version, headers=headers,
                       body=body, client=client, buffer=buffer)

    def _send_response(self, sock, response: Response, request: Request | None) -> None:
        reason = REASONS.get(response.status, "OK")
        keep_alive = response.keep_alive
        if request is not None and "close" in request.headers.get("connection", "").lower():
            keep_alive = False
        head = ["HTTP/1.1 %d %s" % (response.status, reason)]
        headers = dict(response.headers)
        headers.setdefault("Server", "cloudpc-gateway")
        headers.setdefault("Date", time.strftime("%a, %d %b %Y %H:%M:%S GMT", time.gmtime()))
        headers["Content-Type"] = response.content_type
        headers["Content-Length"] = str(len(response.body))
        headers["Connection"] = "keep-alive" if keep_alive else "close"
        for name, value in headers.items():
            head.append("%s: %s" % (name, value))
        head.extend(["", ""])
        payload = "\r\n".join(head).encode("iso-8859-1") + response.body
        try:
            sock.sendall(payload)
        except OSError:
            return

    # -- websocket bridge -------------------------------------------------
    def _handle_websocket(self, sock, request: Request, buffer: bytearray) -> None:
        gateway = self.server.gateway
        if not gateway.authenticated(request):
            self._send_response(sock, gateway.unauthorized(request), request)
            return

        origin = request.headers.get("origin", "")
        host = request.headers.get("host", "")
        if origin and host and not origin_matches(origin, host, request):
            log("rejected websocket from origin %s" % origin, "warning")
            self._send_response(sock, Response(403, b"cross-origin websocket refused\n"), request)
            return

        ok, detail = wsproto.validate_handshake(request.headers, request.method)
        if not ok:
            self._send_response(sock, Response(400, ("%s\n" % detail).encode()), request)
            return

        try:
            upstream = socket.create_connection((VNC_HOST, VNC_PORT), timeout=10)
        except OSError as exc:
            log("VNC server unreachable at %s:%s (%s)" % (VNC_HOST, VNC_PORT, exc), "warning")
            self._send_response(
                sock,
                json_response({
                    "error": "desktop is starting",
                    "detail": "the VNC server is not accepting connections yet",
                }, status=503, keep_alive=False),
                request,
            )
            return

        accept = wsproto.compute_accept(request.headers.get("sec-websocket-key", ""))
        lines = [
            "HTTP/1.1 101 Switching Protocols",
            "Upgrade: websocket",
            "Connection: Upgrade",
            "Sec-WebSocket-Accept: %s" % accept,
        ]
        if detail:
            lines.append("Sec-WebSocket-Protocol: %s" % detail)
        lines.extend(["", ""])
        sock.sendall("\r\n".join(lines).encode("iso-8859-1"))
        log("websocket bridge open for %s" % request.client_ip)

        try:
            self._bridge(sock, upstream, buffer)
        finally:
            for handle in (upstream, sock):
                try:
                    handle.close()
                except OSError:
                    pass
            log("websocket bridge closed for %s" % request.client_ip)

    def _bridge(self, client: socket.socket, upstream: socket.socket, buffer: bytearray) -> None:
        parser = wsproto.FrameParser()
        if buffer:
            parser.feed(bytes(buffer))
            buffer.clear()

        client.settimeout(30.0)
        upstream.settimeout(30.0)
        last_client_traffic = time.monotonic()
        last_ping = time.monotonic()
        closing = False

        while True:
            now = time.monotonic()
            if now - last_client_traffic > BRIDGE_IDLE_TIMEOUT:
                self._close_ws(client, wsproto.CLOSE_NORMAL, "idle timeout")
                return
            timeout = max(1.0, min(5.0, BRIDGE_PING_INTERVAL - (now - last_ping)))
            try:
                readable, _, _ = select.select([client, upstream], [], [], timeout)
            except (OSError, ValueError):
                return

            if upstream in readable:
                try:
                    data = upstream.recv(65536)
                except socket.timeout:
                    data = None
                except OSError:
                    return
                if data == b"":
                    self._close_ws(client, wsproto.CLOSE_NORMAL, "desktop closed the session")
                    return
                if data:
                    try:
                        client.sendall(wsproto.encode_frame(wsproto.OP_BINARY, data))
                    except OSError:
                        return

            if client in readable:
                try:
                    chunk = client.recv(65536)
                except socket.timeout:
                    chunk = None
                except OSError:
                    return
                if chunk == b"":
                    return
                if chunk:
                    parser.feed(chunk)
                    last_client_traffic = time.monotonic()
                    try:
                        for opcode, payload in parser.parse():
                            if opcode == wsproto.OP_PING:
                                client.sendall(wsproto.encode_pong(payload))
                            elif opcode == wsproto.OP_PONG:
                                continue
                            elif opcode == wsproto.OP_CLOSE:
                                code, reason = wsproto.parse_close(payload)
                                log("client closed websocket (%d %s)" % (code, reason))
                                if not closing:
                                    closing = True
                                    try:
                                        client.sendall(wsproto.encode_close(wsproto.CLOSE_NORMAL))
                                    except OSError:
                                        pass
                                return
                            elif opcode in (wsproto.OP_BINARY, wsproto.OP_CONTINUATION):
                                upstream.sendall(payload)
                    except wsproto.WebSocketError as exc:
                        log("websocket protocol error: %s" % exc, "warning")
                        self._close_ws(client, exc.code, str(exc))
                        return
                    except OSError:
                        return

            now = time.monotonic()
            if now - last_ping >= BRIDGE_PING_INTERVAL:
                last_ping = now
                try:
                    client.sendall(wsproto.encode_ping())
                except OSError:
                    return

    def _close_ws(self, client: socket.socket, code: int, reason: str) -> None:
        try:
            client.sendall(wsproto.encode_close(code, reason))
        except OSError:
            pass


def origin_matches(origin: str, host: str, request: Request) -> bool:
    try:
        parsed = urlsplit(origin)
    except Exception:
        return False
    if not parsed.netloc:
        return False
    if parsed.netloc == host:
        return True
    # Railway terminates TLS, so a wss:// origin legitimately arrives over plain
    # HTTP with the same Host header - only the host:port part is compared.
    return parsed.hostname is not None and parsed.hostname in host.split(":")[0]


def main() -> int:
    gateway = Gateway()
    log("%s %s starting on %s:%d" % (SERVICE_NAME, VERSION, LISTEN_HOST, LISTEN_PORT))
    log("desktop user=%s vnc=%s:%d sessions=%s" % (
        DESKTOP_USER, VNC_HOST, VNC_PORT,
        "enabled" if gateway.sessions.available() else "key missing (logins disabled)"))
    if not gateway.sessions.available():
        log("session signing key is missing - run the container entrypoint first", "error")

    server = GatewayServer((LISTEN_HOST, LISTEN_PORT), GatewayHandler, gateway)
    stopping = threading.Event()

    def shutdown(signum, frame):  # noqa: ARG001
        if stopping.is_set():
            return
        stopping.set()
        log("signal %d received - shutting down" % signum)
        threading.Thread(target=server.shutdown, daemon=True).start()

    import signal
    signal.signal(signal.SIGTERM, shutdown)
    signal.signal(signal.SIGINT, shutdown)

    try:
        server.serve_forever(poll_interval=0.5)
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
        log("gateway stopped")
    return 0


if __name__ == "__main__":
    sys.exit(main())
