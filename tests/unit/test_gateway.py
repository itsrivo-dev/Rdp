#!/usr/bin/env python3
"""Unit tests for the pieces of the gateway that can be tested without Docker.

Covers the WebSocket framing (RFC 6455), the session cookie format, password
verification and the login rate limiter. Run with:

    python3 -m unittest discover -s tests/unit -v
"""

from __future__ import annotations

import base64
import hashlib
import hmac
import json
import os
import sys
import tempfile
import time
import unittest

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, os.path.join(REPO, "docker", "gateway"))

import wsproto  # noqa: E402
from security import (  # noqa: E402
    COOKIE_NAME,
    LoginThrottle,
    PasswordStore,
    SessionManager,
)


class AcceptKeyTests(unittest.TestCase):
    def test_rfc6455_example(self):
        # The example from RFC 6455 section 1.3.
        key = "dGhlIHNhbXBsZSBub25jZQ=="
        self.assertEqual(wsproto.compute_accept(key), "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=")


class HandshakeTests(unittest.TestCase):
    BASE = {
        "upgrade": "websocket",
        "connection": "Upgrade",
        "sec-websocket-version": "13",
        # "hello" padded to 16 bytes, base64 encoded
        "sec-websocket-key": base64.b64encode(b"0123456789abcdef").decode(),
    }

    def test_valid(self):
        ok, detail = wsproto.validate_handshake(self.BASE)
        self.assertTrue(ok, detail)
        self.assertEqual(detail, "")

    def test_connection_header_with_multiple_tokens(self):
        headers = dict(self.BASE, connection="keep-alive, Upgrade")
        self.assertTrue(wsproto.validate_handshake(headers)[0])

    def test_binary_subprotocol_is_echoed(self):
        headers = dict(self.BASE, **{"sec-websocket-protocol": "chat, binary"})
        ok, detail = wsproto.validate_handshake(headers)
        self.assertTrue(ok)
        self.assertEqual(detail, "binary")

    def test_unknown_subprotocol_is_ignored(self):
        headers = dict(self.BASE, **{"sec-websocket-protocol": "chat"})
        ok, detail = wsproto.validate_handshake(headers)
        self.assertTrue(ok)
        self.assertEqual(detail, "")

    def test_rejects_bad_requests(self):
        for mutate in (
            {"upgrade": "h2c"},
            {"connection": "keep-alive"},
            {"sec-websocket-version": "8"},
            {"sec-websocket-key": "not-base64!!"},
            {"sec-websocket-key": base64.b64encode(b"short").decode()},
        ):
            headers = dict(self.BASE)
            headers.update(mutate)
            ok, detail = wsproto.validate_handshake(headers)
            self.assertFalse(ok, "expected rejection for %s" % mutate)
            self.assertTrue(detail)

    def test_requires_get(self):
        self.assertFalse(wsproto.validate_handshake(self.BASE, method="POST")[0])


class FrameEncodingTests(unittest.TestCase):
    def test_small_frame(self):
        frame = wsproto.encode_frame(wsproto.OP_BINARY, b"hello")
        self.assertEqual(frame[0], 0x82)
        self.assertEqual(frame[1], 5)
        self.assertEqual(frame[2:], b"hello")

    def test_medium_frame_uses_16_bit_length(self):
        payload = b"x" * 200
        frame = wsproto.encode_frame(wsproto.OP_BINARY, payload)
        self.assertEqual(frame[1], 126)
        self.assertEqual(int.from_bytes(frame[2:4], "big"), 200)
        self.assertEqual(frame[4:], payload)

    def test_large_frame_uses_64_bit_length(self):
        payload = b"y" * 70000
        frame = wsproto.encode_frame(wsproto.OP_BINARY, payload)
        self.assertEqual(frame[1], 127)
        self.assertEqual(int.from_bytes(frame[2:10], "big"), 70000)
        self.assertEqual(frame[10:], payload)

    def test_control_frames_are_bounded(self):
        with self.assertRaises(wsproto.WebSocketError):
            wsproto.encode_frame(wsproto.OP_PING, b"z" * 126)

    def test_close_frame_round_trip(self):
        payload = wsproto.encode_close(wsproto.CLOSE_NORMAL, "bye")[2:]
        self.assertEqual(wsproto.parse_close(payload), (wsproto.CLOSE_NORMAL, "bye"))

    def test_ping_pong(self):
        self.assertEqual(wsproto.encode_ping(b"k")[1], 1)
        self.assertEqual(wsproto.encode_pong(b"k")[0], 0x8A)


class FrameParserTests(unittest.TestCase):
    def parse(self, data: bytes) -> list:
        parser = wsproto.FrameParser()
        parser.feed(data)
        return list(parser.parse())

    def test_masked_single_frame(self):
        frame = wsproto.encode_client_frame(wsproto.OP_BINARY, b"payload", mask=b"\x01\x02\x03\x04")
        self.assertEqual(self.parse(frame), [(wsproto.OP_BINARY, b"payload")])

    def test_incremental_delivery(self):
        frame = wsproto.encode_client_frame(wsproto.OP_BINARY, b"abcdef", mask=b"\x05\x06\x07\x08")
        parser = wsproto.FrameParser()
        for index in range(0, len(frame) - 1):
            parser.feed(frame[index:index + 1])
            self.assertEqual(list(parser.parse()), [])
        parser.feed(frame[-1:])
        self.assertEqual(list(parser.parse()), [(wsproto.OP_BINARY, b"abcdef")])

    def test_multiple_frames_in_one_chunk(self):
        chunk = (wsproto.encode_client_frame(wsproto.OP_BINARY, b"one", mask=b"\x00\x00\x00\x01")
                 + wsproto.encode_client_frame(wsproto.OP_CONTINUATION, b"two", mask=b"\x00\x00\x00\x02"))
        self.assertEqual(self.parse(chunk), [(wsproto.OP_BINARY, b"one"),
                                             (wsproto.OP_CONTINUATION, b"two")])

    def test_empty_payload(self):
        frame = wsproto.encode_client_frame(wsproto.OP_BINARY, b"", mask=b"\x09\x09\x09\x09")
        self.assertEqual(self.parse(frame), [(wsproto.OP_BINARY, b"")])

    def test_minimal_mask_round_trip(self):
        for mask in (b"\x00\x00\x00\x00", b"\xff\xff\xff\xff", b"\x12\x34\x56\x78"):
            frame = wsproto.encode_client_frame(wsproto.OP_BINARY, b"unmask me", mask=mask)
            self.assertEqual(self.parse(frame)[0][1], b"unmask me")

    def test_16_bit_length_frame(self):
        payload = bytes(range(256)) * 3
        frame = wsproto.encode_client_frame(wsproto.OP_BINARY, payload, mask=b"\x11\x22\x33\x44")
        self.assertEqual(self.parse(frame)[0][1], payload)

    def test_unmasked_client_frame_is_rejected(self):
        # Server-to-client framing (never masked) must not be accepted.
        frame = wsproto.encode_frame(wsproto.OP_BINARY, b"hello")
        with self.assertRaises(wsproto.WebSocketError):
            self.parse(frame)

    def test_fragmented_control_frame_is_rejected(self):
        frame = wsproto.encode_client_frame(wsproto.OP_PING, b"x", mask=b"\x00\x00\x00\x00", fin=False)
        with self.assertRaises(wsproto.WebSocketError):
            self.parse(frame)

    def test_text_frames_are_rejected(self):
        frame = wsproto.encode_client_frame(wsproto.OP_TEXT, b"hi", mask=b"\x00\x00\x00\x00")
        with self.assertRaises(wsproto.WebSocketError) as ctx:
            self.parse(frame)
        self.assertEqual(ctx.exception.code, wsproto.CLOSE_UNSUPPORTED_DATA)

    def test_oversized_frame_is_rejected_before_buffering(self):
        header = wsproto.encode_client_frame(wsproto.OP_BINARY, b"x" * 10, mask=b"\x00\x00\x00\x00")
        # Rewrite the length field to something huge.
        oversized = bytes([0x82, 0x80 | 127]) + (50 * 1024 * 1024).to_bytes(8, "big") + b"\x00" * 4
        del header
        with self.assertRaises(wsproto.WebSocketError) as ctx:
            self.parse(oversized)
        self.assertEqual(ctx.exception.code, wsproto.CLOSE_TOO_LARGE)

    def test_reserved_bits_are_rejected(self):
        frame = bytearray(wsproto.encode_client_frame(wsproto.OP_BINARY, b"x", mask=b"\x00\x00\x00\x00"))
        frame[0] |= 0x40
        with self.assertRaises(wsproto.WebSocketError):
            self.parse(bytes(frame))


class PasswordStoreTests(unittest.TestCase):
    def make_record(self, password: str, username: str = "ubuntu") -> dict:
        salt = os.urandom(16)
        digest = hashlib.scrypt(password.encode(), salt=salt, n=16384, r=8, p=1, dklen=32)
        return {
            "username": username,
            "algorithm": "scrypt",
            "n": 16384, "r": 8, "p": 1, "dklen": 32,
            "salt": base64.b64encode(salt).decode(),
            "hash": base64.b64encode(digest).decode(),
        }

    def test_accepts_the_right_password(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "auth.json")
            with open(path, "w", encoding="utf-8") as handle:
                json.dump(self.make_record("correct-horse-battery"), handle)
            store = PasswordStore(path)
            self.assertTrue(store.verify("correct-horse-battery"))
            self.assertFalse(store.verify("correct-horse-batterz"))
            self.assertFalse(store.verify(""))
            self.assertEqual(store.username, "ubuntu")

    def test_missing_file_never_accepts(self):
        store = PasswordStore("/nonexistent/auth.json")
        self.assertFalse(store.verify("anything"))
        self.assertFalse(store.verify(""))

    def test_corrupt_file_is_rejected_not_crashed(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "auth.json")
            with open(path, "w", encoding="utf-8") as handle:
                handle.write("{ this is not json")
            self.assertFalse(PasswordStore(path).verify("anything"))
            with open(path, "w", encoding="utf-8") as handle:
                json.dump({"username": "ubuntu", "salt": "!!", "hash": "!!"}, handle)
            self.assertFalse(PasswordStore(path).verify("anything"))


class SessionManagerTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.key_file = os.path.join(self.tmp.name, "session.key")
        with open(self.key_file, "w", encoding="ascii") as handle:
            handle.write(base64.urlsafe_b64encode(b"k" * 32).decode())
        self.sessions = SessionManager(self.key_file, ttl_seconds=3600, username="ubuntu")

    def tearDown(self):
        self.tmp.cleanup()

    def test_round_trip(self):
        token, expires = self.sessions.issue()
        self.assertGreater(expires, time.time())
        self.assertTrue(self.sessions.verify(token))

    def test_tampered_payload_is_rejected(self):
        token, _ = self.sessions.issue()
        payload, signature = token.split(".")
        forged = base64.urlsafe_b64encode(
            json.dumps({"sub": "ubuntu", "exp": int(time.time()) + 9999}).encode()
        ).decode().rstrip("=")
        self.assertFalse(self.sessions.verify(forged + "." + signature))
        self.assertFalse(self.sessions.verify(payload + "." + ("A" * len(signature))))

    def test_other_user_is_rejected(self):
        other = SessionManager(self.key_file, ttl_seconds=3600, username="root")
        token, _ = self.sessions.issue()
        self.assertTrue(self.sessions.verify(token))
        self.assertFalse(other.verify(token))

    def test_expiry(self):
        token, _ = self.sessions.issue(now=time.time() - 7200)
        self.assertFalse(self.sessions.verify(token))

    def test_rotating_the_key_invalidates_sessions(self):
        token, _ = self.sessions.issue()
        with open(self.key_file, "w", encoding="ascii") as handle:
            handle.write(base64.urlsafe_b64encode(b"j" * 32).decode())
        self.assertFalse(self.sessions.verify(token))

    def test_missing_key_disables_sessions(self):
        manager = SessionManager(os.path.join(self.tmp.name, "absent.key"), 3600, "ubuntu")
        self.assertFalse(manager.available())
        with self.assertRaises(RuntimeError):
            manager.issue()
        self.assertFalse(manager.verify("anything.anything"))

    def test_garbage_tokens(self):
        for token in ("", "no-dot", "a.b.c", "....", "!!!.???"):
            self.assertFalse(self.sessions.verify(token))

    def test_cookie_name_is_stable(self):
        self.assertEqual(COOKIE_NAME, "cloudpc_session")


class ThrottleTests(unittest.TestCase):
    def test_per_client_limit(self):
        throttle = LoginThrottle(max_per_client=3, max_global=100, window_seconds=900,
                                 lockout_seconds=300)
        now = 1000.0
        for _ in range(3):
            self.assertTrue(throttle.allow("1.2.3.4", now))
            throttle.record_failure("1.2.3.4", now)
        self.assertFalse(throttle.allow("1.2.3.4", now))
        # Another client is unaffected.
        self.assertTrue(throttle.allow("5.6.7.8", now))
        # After the lockout window the client is allowed to try again.
        self.assertTrue(throttle.allow("1.2.3.4", now + 301))

    def test_global_limit(self):
        throttle = LoginThrottle(max_per_client=100, max_global=4, window_seconds=900,
                                 lockout_seconds=300)
        now = 5000.0
        for index in range(4):
            throttle.record_failure("10.0.0.%d" % index, now)
        self.assertFalse(throttle.allow("10.0.0.99", now))

    def test_success_clears_the_client_bucket(self):
        throttle = LoginThrottle(max_per_client=2, max_global=100)
        throttle.record_failure("1.1.1.1")
        throttle.record_success("1.1.1.1")
        self.assertTrue(throttle.allow("1.1.1.1"))

    def test_retry_after_is_reported(self):
        throttle = LoginThrottle(max_per_client=1, max_global=100, lockout_seconds=600)
        now = 2000.0
        throttle.record_failure("2.2.2.2", now)
        self.assertEqual(throttle.retry_after("2.2.2.2", now), 600)
        self.assertGreater(throttle.retry_after("2.2.2.2", now + 30), 0)


class ConstantTimeTests(unittest.TestCase):
    def test_compare_digest_is_used_for_hashes(self):
        # Guards against a regression to "==" comparisons on secrets.
        source = open(os.path.join(REPO, "docker", "gateway", "security.py"),
                      encoding="utf-8").read()
        self.assertIn("hmac.compare_digest", source)
        self.assertNotIn("hash == ", source)
        self.assertTrue(hmac.compare_digest(b"a", b"a"))


if __name__ == "__main__":
    unittest.main()
