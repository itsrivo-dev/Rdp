#!/usr/bin/env python3
"""Fast gateway test: starts the real server.py and exercises its whole surface.

No Docker needed - it runs the gateway in-process style (as a subprocess) with a
temporary runtime directory, a stand-in VNC server on the other end of the
WebSocket bridge, and checks the login flow, the cookie flags, the protected
paths, the static assets, gzip/ETag handling, path traversal, throttling and the
bidirectional WebSocket bridge.

    python3 tests/gateway_smoke.py [--novnc-dir DIR] [--keep-icons]

With ``--novnc-dir`` pointing at a patched noVNC tree (see
docker/tools/build_novnc_page.py) the desktop page and its assets are checked
too; without it those checks are skipped with a NOTE.

Requires: websocket-client. (Pillow and pycryptodome are only needed by
tests/clients/rfb_probe.py.)
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import http.client
import json
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GATEWAY = os.path.join(REPO, "docker", "gateway")
STATIC_DIR = os.path.join(GATEWAY, "static")
PORT = int(os.environ.get("SMOKE_PORT", "18099"))
VNC_FAKE_PORT = int(os.environ.get("SMOKE_VNC_PORT", "15900"))
PASSWORD = "smoke-test-password-123"
VNC_PASSWORD = "vncpassw"

PASSED: list[str] = []
FAILED: list[str] = []
SKIPPED: list[str] = []


def check(name: str, condition: bool, detail: str = "") -> None:
    (PASSED if condition else FAILED).append(name)
    suffix = "  (%s)" % detail if detail and not condition else ""
    print("%s %s%s" % ("PASS" if condition else "FAIL", name, suffix))


def note(name: str) -> None:
    SKIPPED.append(name)
    print("NOTE %s" % name)


def request(method: str, path: str, body: bytes | None = None,
            headers: dict | None = None, port: int | None = None):
    connection = http.client.HTTPConnection("127.0.0.1", port or PORT, timeout=20)
    connection.request(method, path, body=body, headers=headers or {})
    response = connection.getresponse()
    payload = response.read()
    result = (response.status, {k.lower(): v for k, v in response.getheaders()}, payload)
    connection.close()
    return result


class FakeVNC:
    """A TCP server that greets and then echoes - stands in for TigerVNC."""

    def __init__(self, port: int) -> None:
        self.stop = threading.Event()
        self.server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self.server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.server.bind(("127.0.0.1", port))
        self.server.listen(4)
        self.server.settimeout(0.5)
        threading.Thread(target=self._serve, daemon=True).start()

    def _serve(self) -> None:
        while not self.stop.is_set():
            try:
                client, _ = self.server.accept()
            except (socket.timeout, OSError):
                continue
            threading.Thread(target=self._handle, args=(client,), daemon=True).start()

    def _handle(self, client: socket.socket) -> None:
        client.settimeout(30)
        try:
            client.sendall(b"RFB 003.008\n")
            while True:
                data = client.recv(65536)
                if not data:
                    break
                client.sendall(data)
        except OSError:
            pass
        finally:
            client.close()

    def close(self) -> None:
        self.stop.set()
        try:
            self.server.close()
        except OSError:
            pass


def write_runtime_files(run_dir: str) -> None:
    salt = os.urandom(16)
    digest = hashlib.scrypt(PASSWORD.encode(), salt=salt, n=16384, r=8, p=1, dklen=32)
    with open(os.path.join(run_dir, "auth.json"), "w", encoding="utf-8") as handle:
        json.dump({"username": "ubuntu", "algorithm": "scrypt", "n": 16384, "r": 8, "p": 1,
                   "dklen": 32, "salt": base64.b64encode(salt).decode(),
                   "hash": base64.b64encode(digest).decode()}, handle)
    with open(os.path.join(run_dir, "session.key"), "w", encoding="ascii") as handle:
        handle.write(base64.urlsafe_b64encode(b"s" * 32).decode())
    with open(os.path.join(run_dir, "vnc_password"), "w", encoding="ascii") as handle:
        handle.write(VNC_PASSWORD)
    with open(os.path.join(run_dir, "runtime.json"), "w", encoding="utf-8") as handle:
        json.dump({"version": "2.0.0", "username": "ubuntu", "home": "/home/ubuntu",
                   "data_dir": "/data", "persistent": True,
                   "storage_note": "persistent volume at /data"}, handle)


def main() -> int:
    parser = argparse.ArgumentParser(description="Cloud PC gateway smoke test")
    parser.add_argument("--novnc-dir", default=None,
                        help="patched noVNC directory (enables the desktop page checks)")
    parser.add_argument("--log", default=os.path.join(tempfile.gettempdir(), "cloudpc-gateway-smoke.log"))
    args = parser.parse_args()

    try:
        import websocket
    except ImportError:
        print("websocket-client is required: pip install websocket-client", file=sys.stderr)
        return 3

    run_dir = tempfile.mkdtemp(prefix="cloudpc-run-")
    write_runtime_files(run_dir)

    # The Docker build generates the PWA icons into the static directory; do the
    # same here and remove what we created afterwards.
    generated_icons = []
    for name in ("icon-192.png", "icon-512.png", "icon-maskable-512.png", "favicon.ico"):
        path = os.path.join(STATIC_DIR, name)
        if not os.path.exists(path):
            generated_icons.append(path)
    if generated_icons:
        subprocess.run([sys.executable, os.path.join(REPO, "docker", "tools", "make_icons.py"),
                        STATIC_DIR], check=True, stdout=subprocess.DEVNULL)

    environment = dict(os.environ)
    environment.update({
        "PORT": str(PORT),
        "CLOUDPC_RUN_DIR": run_dir,
        "CLOUDPC_NOVNC_DIR": args.novnc_dir or os.path.join(REPO, "docker", "gateway", "static"),
        "CLOUDPC_STATIC_DIR": STATIC_DIR,
        "CLOUDPC_LOG_DIR": run_dir,
        "VNC_PORT": str(VNC_FAKE_PORT),
        "VNC_PASSWORD_FILE": os.path.join(run_dir, "vnc_password"),
        "DESKTOP_USER": "ubuntu",
        # Deliberately small: the connection accounting is checked below, and a
        # leak has to be visible after a handful of requests, not after 64.
        "CLOUDPC_MAX_CONNECTIONS": "8",
        "PYTHONPATH": GATEWAY,
    })

    log_handle = open(args.log, "w", encoding="utf-8")
    process = subprocess.Popen([sys.executable, "-u", os.path.join(GATEWAY, "server.py")],
                               env=environment, stdout=log_handle, stderr=subprocess.STDOUT)
    fake_vnc = FakeVNC(VNC_FAKE_PORT)

    try:
        for _ in range(100):
            if process.poll() is not None:
                break
            try:
                if request("GET", "/health")[0] == 200:
                    break
            except Exception:
                time.sleep(0.2)
        if process.poll() is not None:
            print("the gateway exited immediately; log follows", file=sys.stderr)
            print(open(args.log, encoding="utf-8").read()[-4000:], file=sys.stderr)
            return 1

        # --- public endpoints -------------------------------------------------
        status, _, body = request("GET", "/health")
        health = json.loads(body)
        check("GET /health -> 200", status == 200)
        check("/health identifies the service", health.get("service") == "ubuntu-cloud-pc")
        check("/health sees the VNC port", health["checks"]["vnc"] is True)
        check("/health contains no credentials", PASSWORD not in body.decode())
        status, headers, _ = request("GET", "/health", headers={"Accept-Encoding": "gzip"})
        check("/health is never cached", headers.get("cache-control") == "no-store")

        status, _, body = request("GET", "/")
        check("GET / serves the login page", status == 200 and b"<form" in body)
        check("the login page names the desktop user", b"ubuntu" in body)
        check("no template placeholders are left", b"{{" not in body)
        check("the login page links the web app manifest", b"manifest.webmanifest" in body)
        check("the login page loads nothing external", b"http://" not in body and b"https://" not in body)

        status, headers, _ = request("GET", "/static/icon-192.png")
        check("the app icon is public and typed correctly",
              status == 200 and headers.get("content-type") == "image/png", str(status))

        # --- protected paths --------------------------------------------------
        for path in ("/vnc/", "/vnc/core/rfb.js", "/vnc/package.json", "/api/session",
                     "/api/diagnostics", "/websockify"):
            status, _, _ = request("GET", path)
            check("unauthenticated %s -> 401" % path, status == 401, str(status))

        # --- login ------------------------------------------------------------
        form = {"Content-Type": "application/x-www-form-urlencoded"}
        status, headers, _ = request("POST", "/login", body=b"password=wrong-one", headers=form)
        check("a wrong password -> 401", status == 401, str(status))
        check("a failed login sets no cookie", "set-cookie" not in headers)
        status, _, _ = request("POST", "/login", body=b"password=", headers=form)
        check("an empty password -> 400", status == 400, str(status))

        status, headers, _ = request("POST", "/login", body=("password=" + PASSWORD).encode(),
                                     headers=form)
        check("the right password -> 303", status == 303, str(status))
        cookie = headers.get("set-cookie", "")
        check("the session cookie is HttpOnly", "HttpOnly" in cookie)
        check("the session cookie is SameSite=Lax", "SameSite=Lax" in cookie)
        check("the cookie is not Secure over plain HTTP", "Secure" not in cookie)
        token = cookie.split(";")[0]
        auth = {"Cookie": token}

        status, headers, _ = request("POST", "/login", body=("password=" + PASSWORD).encode(),
                                     headers=dict(form, **{"X-Forwarded-Proto": "https"}))
        check("the cookie becomes Secure behind the HTTPS proxy",
              "Secure" in headers.get("set-cookie", ""))

        # --- static assets ----------------------------------------------------
        status, headers, body = request("GET", "/static/login.html", headers=auth)
        check("the login page markup is served", status == 200 and b"Ubuntu Cloud PC" in body)

        if args.novnc_dir:
            status, headers, body = request("GET", "/vnc/", headers=auth)
            check("GET /vnc/ -> 200", status == 200, str(status))
            check("the desktop page is the patched noVNC page",
                  b"Ubuntu Desktop" in body and b"noVNC_container" in body)
            check("the desktop page talks to the gateway", b"api/session" in body)
            check("the desktop page carries a CSP", "content-security-policy" in headers)
            check("the desktop page is not cached", headers.get("cache-control") == "no-store")

            status, headers, body = request("GET", "/vnc/app/ui.js", headers=auth)
            check("noVNC modules are served", status == 200 and b"export default UI" in body)
            check("JavaScript content type", headers.get("content-type", "").startswith("text/javascript"))
            etag = headers.get("etag", "")
            check("assets carry an ETag", bool(etag))
            status, _, _ = request("GET", "/vnc/app/ui.js",
                                   headers=dict(auth, **{"If-None-Match": etag}))
            check("a conditional request -> 304", status == 304, str(status))
            status, headers, _ = request("GET", "/vnc/app/ui.js",
                                         headers=dict(auth, **{"Accept-Encoding": "gzip"}))
            check("text assets are gzipped on request", headers.get("content-encoding") == "gzip")
            check("gzip responses are marked Vary", headers.get("vary") == "Accept-Encoding")
        else:
            note("no --novnc-dir given: desktop page asset checks skipped")

        # --- session ----------------------------------------------------------
        status, _, body = request("GET", "/api/session", headers=auth)
        session = json.loads(body) if status == 200 else {}
        check("GET /api/session -> 200", status == 200, str(status))
        check("the session hands over the VNC password",
              session.get("vnc_password") == VNC_PASSWORD)
        check("the session points at /websockify", session.get("ws_path") == "websockify")
        check("the session reports the desktop state", "desktop" in session)

        # --- robustness -------------------------------------------------------
        status, _, _ = request("GET", "/vnc/../../etc/passwd", headers=auth)
        check("path traversal is refused", status in (403, 404), str(status))
        status, _, _ = request("PUT", "/api/session", headers=auth)
        check("unsupported methods -> 405", status == 405, str(status))
        status, _, _ = request("GET", "/nope")
        check("unknown paths -> 404", status == 404, str(status))

        # --- connection accounting -------------------------------------------
        # Every connection takes a slot and must hand it back when it ends, no
        # matter how it ended. A release on the error path only leaked one slot
        # per request, and the gateway then answered "503 server is busy" to
        # everything - including /health - once the slots ran out. The limit is
        # 8 in this run, so 24 sequential requests must all succeed.
        refused = []
        for index in range(24):
            status, _, _ = request("GET", "/health")
            if status != 200:
                refused.append(index)
        check("connection slots are not leaked (24 requests, 8 slots)",
              not refused, "refused after %s requests" % (refused[0] if refused else ""))

        # --- WebSocket bridge -------------------------------------------------
        def connect(headers=None):
            return websocket.create_connection("ws://127.0.0.1:%d/websockify" % PORT,
                                               header=headers or [], timeout=15)

        try:
            connection = connect()
            connection.close()
            check("a websocket without a session is refused", False)
        except Exception as exc:
            check("a websocket without a session is refused",
                  "401" in str(exc) or "Handshake" in str(exc), str(exc))

        connection = connect(["Cookie: " + token, "Origin: http://127.0.0.1:%d" % PORT])
        greeting = connection.recv()
        check("the bridge forwards the VNC greeting",
              greeting.startswith(b"RFB 003.008"), repr(greeting)[:60])
        connection.send_binary(b"hello-vnc")
        check("the bridge forwards client bytes to VNC", connection.recv() == b"hello-vnc")
        payload = os.urandom(70000)
        connection.send_binary(payload)
        received = b""
        while len(received) < len(payload):
            received += connection.recv()
        check("large payloads survive in both directions", received == payload)
        connection.close()

        try:
            connection = connect(["Cookie: " + token, "Origin: https://evil.example.com"])
            connection.close()
            check("a cross-origin websocket is refused", False)
        except Exception:
            check("a cross-origin websocket is refused", True)

        # --- throttling -------------------------------------------------------
        blocked = False
        for attempt in range(8):
            status, _, _ = request("POST", "/login", body=b"password=nope-%d" % attempt,
                                   headers=dict(form, **{"X-Forwarded-For": "198.51.100.9"}))
            if status == 429:
                blocked = True
                break
        check("brute force is throttled with 429", blocked)
        check("health still answers while logins are throttled", request("GET", "/health")[0] == 200)
        status, _, _ = request("POST", "/login", body=("password=" + PASSWORD).encode(),
                               headers=dict(form, **{"X-Forwarded-For": "198.51.100.9"}))
        check("throttling also blocks the correct password from that address", status == 429,
              str(status))

    finally:
        fake_vnc.close()
        process.terminate()
        try:
            process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            process.kill()
        log_handle.close()
        shutil.rmtree(run_dir, ignore_errors=True)
        for path in generated_icons:
            try:
                os.unlink(path)
            except OSError:
                pass

    print("\npassed: %d  failed: %d  skipped: %d" % (len(PASSED), len(FAILED), len(SKIPPED)))
    if FAILED:
        print("failures:")
        for name in FAILED:
            print("  - %s" % name)
        print("\n--- gateway log tail ---")
        print(open(args.log, encoding="utf-8").read()[-4000:])
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
