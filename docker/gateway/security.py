"""Authentication, session cookies and login throttling for the web gateway.

Design notes
------------
* The password is never stored in this process. The entrypoint writes a scrypt
  hash to ``/run/cloudpc/auth.json`` (mode 0644 - it contains no secret that
  can be replayed) and this module only verifies against it.
* Sessions are stateless, HMAC-SHA256 signed cookies. The signing key lives in
  ``/run/cloudpc/session.key`` (0640 root:cloudpc). Rotating that key logs
  every browser out, which is what the password-change helper does.
* All comparisons use :func:`hmac.compare_digest` and a dummy scrypt run is
  performed when no hash is available, so timing does not reveal state.
"""

from __future__ import annotations

import base64
import hashlib
import hmac
import json
import secrets
import threading
import time

SCRYPT_DEFAULTS = {"n": 16384, "r": 8, "p": 1, "dklen": 32}
COOKIE_NAME = "cloudpc_session"


def _b64e(raw: bytes) -> str:
    return base64.urlsafe_b64encode(raw).decode("ascii").rstrip("=")


def _b64d(text: str) -> bytes:
    padding = "=" * (-len(text) % 4)
    return base64.urlsafe_b64decode(text + padding)


class PasswordStore:
    """Verifies the desktop password against the scrypt hash on disk."""

    def __init__(self, auth_file: str) -> None:
        self.auth_file = auth_file
        self._lock = threading.Lock()
        self._record: dict | None = None

    def _load(self) -> dict:
        """Read the hash file.

        It is read on every use rather than cached: the file is a few hundred
        bytes, and a stale cache after `cloudpc-password set` would let an old
        password keep working. The lock only serialises the read.
        """
        with self._lock:
            try:
                with open(self.auth_file, "r", encoding="utf-8") as handle:
                    self._record = json.load(handle)
            except Exception:
                self._record = None
            return self._record or {}

    @property
    def username(self) -> str:
        return self._load().get("username", "")

    def verify(self, password: str) -> bool:
        record = self._load()
        params = {key: record.get(key, SCRYPT_DEFAULTS[key]) for key in SCRYPT_DEFAULTS}
        if not record.get("hash") or not record.get("salt"):
            # No hash published: burn a comparable amount of CPU so an
            # attacker cannot tell "not configured" from "wrong password".
            hashlib.scrypt(b"cloudpc-dummy-password", salt=b"cloudpc-dummy-salt",
                           n=SCRYPT_DEFAULTS["n"], r=SCRYPT_DEFAULTS["r"],
                           p=SCRYPT_DEFAULTS["p"], dklen=SCRYPT_DEFAULTS["dklen"])
            return False

        try:
            salt = _b64d(record["salt"])
            expected = _b64d(record["hash"])
            computed = hashlib.scrypt(
                password.encode("utf-8"),
                salt=salt,
                n=int(params["n"]),
                r=int(params["r"]),
                p=int(params["p"]),
                dklen=int(params["dklen"]),
            )
        except Exception:
            return False
        return hmac.compare_digest(computed, expected)


class SessionManager:
    """Issues and validates signed session cookies."""

    def __init__(self, key_file: str, ttl_seconds: int, username: str = "") -> None:
        self.key_file = key_file
        self.ttl_seconds = ttl_seconds
        self.username = username
        self._key = b""
        self._lock = threading.Lock()

    def _load_key(self) -> bytes:
        """Read the signing key.

        Like the password hash it is read on every use (it is 44 bytes): a
        cached copy would keep validating cookies after the key was rotated by
        `cloudpc-password rotate-sessions`, and filesystem timestamps are too
        coarse to detect that reliably.
        """
        with self._lock:
            try:
                with open(self.key_file, "rb") as handle:
                    raw = handle.read().strip()
            except OSError:
                return b""
            try:
                return _b64d(raw.decode("ascii")) if raw else b""
            except Exception:
                return b""

    def available(self) -> bool:
        return bool(self._load_key())

    def _sign(self, payload: bytes) -> str:
        key = self._load_key()
        if not key:
            raise RuntimeError("session key unavailable")
        return _b64e(hmac.new(key, payload, hashlib.sha256).digest())

    def issue(self, now: float | None = None, user_agent: str = "") -> tuple[str, int]:
        now = time.time() if now is None else now
        expires = int(now + self.ttl_seconds)
        payload = json.dumps(
            {
                "sub": self.username,
                "iat": int(now),
                "exp": expires,
                "nonce": secrets.token_hex(8),
                "ua": hashlib.sha256(user_agent.encode("utf-8", "replace")).hexdigest()[:16]
                if user_agent
                else "",
            },
            separators=(",", ":"),
            sort_keys=True,
        ).encode("utf-8")
        token = _b64e(payload) + "." + self._sign(payload)
        return token, expires

    def verify(self, token: str, now: float | None = None) -> bool:
        now = time.time() if now is None else now
        if not token or token.count(".") != 1:
            return False
        encoded, signature = token.split(".", 1)
        try:
            payload = _b64d(encoded)
        except Exception:
            return False
        try:
            expected = self._sign(payload)
        except RuntimeError:
            return False
        if not hmac.compare_digest(signature, expected):
            return False
        try:
            data = json.loads(payload.decode("utf-8"))
        except Exception:
            return False
        if data.get("sub") != self.username:
            return False
        try:
            return int(data.get("exp", 0)) > int(now)
        except (TypeError, ValueError):
            return False


class LoginThrottle:
    """Sliding-window rate limit for the login form.

    Two independent limits are applied: per client address and globally. The
    global one keeps a distributed attacker from walking the password
    regardless of how many source addresses they use.
    """

    def __init__(self, max_per_client: int = 5, max_global: int = 25,
                 window_seconds: int = 900, lockout_seconds: int = 300) -> None:
        self.max_per_client = max_per_client
        self.max_global = max_global
        self.window_seconds = window_seconds
        self.lockout_seconds = lockout_seconds
        self._failures: dict[str, list[float]] = {}
        self._global: list[float] = []
        self._lock = threading.Lock()

    def _prune(self, now: float) -> None:
        cutoff = now - self.window_seconds
        for key in list(self._failures):
            kept = [stamp for stamp in self._failures[key] if stamp > cutoff]
            if kept:
                self._failures[key] = kept
            else:
                del self._failures[key]
        self._global = [stamp for stamp in self._global if stamp > cutoff]

    def allow(self, client: str, now: float | None = None) -> bool:
        now = time.time() if now is None else now
        with self._lock:
            self._prune(now)
            if len(self._global) >= self.max_global:
                return False
            stamps = self._failures.get(client, [])
            if len(stamps) >= self.max_per_client:
                if now - stamps[-1] < self.lockout_seconds:
                    return False
            return True

    def record_failure(self, client: str, now: float | None = None) -> None:
        now = time.time() if now is None else now
        with self._lock:
            self._failures.setdefault(client, []).append(now)
            self._global.append(now)

    def record_success(self, client: str) -> None:
        with self._lock:
            self._failures.pop(client, None)

    def retry_after(self, client: str, now: float | None = None) -> int:
        now = time.time() if now is None else now
        with self._lock:
            self._prune(now)
            stamps = self._failures.get(client, [])
            if not stamps:
                return 0
            return max(1, int(stamps[-1] + self.lockout_seconds - now))
