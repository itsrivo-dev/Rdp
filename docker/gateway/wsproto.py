"""Minimal, dependency-free WebSocket (RFC 6455) framing.

Only the pieces a VNC-over-WebSocket bridge needs are implemented: the opening
handshake accept key, frame encoding, incremental frame parsing with client
masking, and the close/ping/pong control frames.

The module has no I/O of its own, which keeps it unit-testable without sockets
(see tests/unit/test_wsproto.py).
"""

from __future__ import annotations

import base64
import hashlib
import struct

GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

OP_CONTINUATION = 0x0
OP_TEXT = 0x1
OP_BINARY = 0x2
OP_CLOSE = 0x8
OP_PING = 0x9
OP_PONG = 0xA

CONTROL_OPCODES = frozenset((OP_CLOSE, OP_PING, OP_PONG))

#: Largest frame payload we accept from a client. noVNC sends small input and
#: clipboard messages (TigerVNC caps clipboard updates at 256 KiB by default),
#: so anything larger is either a bug or an attempt to exhaust memory.
MAX_CLIENT_FRAME = 1 << 20  # 1 MiB

CLOSE_NORMAL = 1000
CLOSE_PROTOCOL_ERROR = 1002
CLOSE_UNSUPPORTED_DATA = 1003
CLOSE_TOO_LARGE = 1009
CLOSE_INTERNAL_ERROR = 1011


class WebSocketError(Exception):
    """Raised when the peer violates the WebSocket protocol."""

    def __init__(self, message: str, code: int = CLOSE_PROTOCOL_ERROR) -> None:
        super().__init__(message)
        self.code = code


def compute_accept(key: str) -> str:
    """Return the value of the ``Sec-WebSocket-Accept`` response header."""
    digest = hashlib.sha1((key + GUID).encode("ascii")).digest()
    return base64.b64encode(digest).decode("ascii")


def validate_handshake(headers: dict, method: str = "GET") -> tuple[bool, str]:
    """Validate the headers of an opening handshake.

    Returns ``(ok, detail)``. ``detail`` is the error message when ``ok`` is
    False, otherwise the selected sub-protocol (possibly an empty string).
    """
    if method != "GET":
        return False, "handshake must use GET"

    upgrade = headers.get("upgrade", "")
    if upgrade.lower() != "websocket":
        return False, "missing Upgrade: websocket"

    connection = headers.get("connection", "")
    if "upgrade" not in [token.strip().lower() for token in connection.split(",")]:
        return False, "missing Connection: Upgrade"

    version = headers.get("sec-websocket-version", "")
    if version.strip() != "13":
        return False, "unsupported WebSocket version"

    key = headers.get("sec-websocket-key", "")
    try:
        if len(base64.b64decode(key, validate=True)) != 16:
            return False, "invalid Sec-WebSocket-Key"
    except Exception:
        return False, "invalid Sec-WebSocket-Key"

    protocol = ""
    offered = headers.get("sec-websocket-protocol", "")
    for candidate in offered.split(","):
        candidate = candidate.strip()
        # noVNC passes no sub-protocol by default, but older builds and other
        # clients ask for "binary". Echo it back when offered: a browser kills
        # the connection if the server ignores a requested sub-protocol.
        if candidate.lower() == "binary":
            protocol = candidate
            break
    return True, protocol


def encode_frame(opcode: int, payload: bytes = b"", fin: bool = True) -> bytes:
    """Encode a server-to-client frame (never masked, per RFC 6455)."""
    if opcode in CONTROL_OPCODES and len(payload) > 125:
        raise WebSocketError("control frame payload too large")
    if opcode not in CONTROL_OPCODES and opcode != OP_CONTINUATION:
        pass

    first = (0x80 if fin else 0x00) | (opcode & 0x0F)
    length = len(payload)
    if length < 126:
        header = struct.pack("!BB", first, length)
    elif length < 65536:
        header = struct.pack("!BBH", first, 126, length)
    else:
        header = struct.pack("!BBQ", first, 127, length)
    return header + payload


def encode_close(code: int = CLOSE_NORMAL, reason: str = "") -> bytes:
    return encode_frame(OP_CLOSE, struct.pack("!H", code) + reason.encode("utf-8")[:123])


def encode_pong(payload: bytes = b"") -> bytes:
    return encode_frame(OP_PONG, payload[:125])


def encode_ping(payload: bytes = b"") -> bytes:
    return encode_frame(OP_PING, payload[:125])


class FrameParser:
    """Incremental parser for client-to-server frames.

    ``feed()`` appends raw bytes; ``parse()`` yields ``(opcode, payload)`` for
    every complete *message fragment*. Data frames are returned as they arrive:
    the RFB protocol on top is a byte stream, so fragment reassembly is not
    needed for correctness and streaming them avoids extra buffering.
    """

    def __init__(self, max_frame: int = MAX_CLIENT_FRAME) -> None:
        self._buffer = bytearray()
        self._max_frame = max_frame

    def feed(self, data: bytes) -> None:
        self._buffer.extend(data)

    def pending(self) -> int:
        return len(self._buffer)

    def parse(self):
        """Yield ``(opcode, payload)`` tuples for every complete frame."""
        while True:
            frame = self._try_parse_one()
            if frame is None:
                return
            yield frame

    def _try_parse_one(self):
        buf = self._buffer
        if len(buf) < 2:
            return None

        first, second = buf[0], buf[1]
        fin = bool(first & 0x80)
        if first & 0x70:
            raise WebSocketError("reserved bits must be zero")
        opcode = first & 0x0F
        masked = bool(second & 0x80)
        length = second & 0x7F

        offset = 2
        if length == 126:
            if len(buf) < offset + 2:
                return None
            length = struct.unpack_from("!H", buf, offset)[0]
            offset += 2
        elif length == 127:
            if len(buf) < offset + 8:
                return None
            length = struct.unpack_from("!Q", buf, offset)[0]
            offset += 8

        if opcode in CONTROL_OPCODES:
            if not fin:
                raise WebSocketError("control frames must not be fragmented")
            if length > 125:
                raise WebSocketError("control frame payload too large")

        if length > self._max_frame:
            raise WebSocketError(
                "frame of %d bytes exceeds the %d byte limit" % (length, self._max_frame),
                code=CLOSE_TOO_LARGE,
            )

        if not masked:
            raise WebSocketError("client frames must be masked")

        if len(buf) < offset + 4 + length:
            return None

        mask = bytes(buf[offset:offset + 4])
        offset += 4
        payload = bytes(buf[offset:offset + length]) if length else b""
        del buf[:offset + length]

        if payload:
            payload = bytes(byte ^ mask[i % 4] for i, byte in enumerate(payload))

        if opcode not in CONTROL_OPCODES and opcode not in (OP_CONTINUATION, OP_BINARY, OP_TEXT):
            raise WebSocketError("unsupported opcode 0x%x" % opcode, code=CLOSE_UNSUPPORTED_DATA)

        if opcode == OP_TEXT:
            # noVNC never sends text frames; treat binary as the only data type.
            raise WebSocketError("text frames are not supported", code=CLOSE_UNSUPPORTED_DATA)

        return opcode, payload


def parse_close(payload: bytes) -> tuple[int, str]:
    """Decode a close frame payload into ``(code, reason)``."""
    if len(payload) >= 2:
        code = struct.unpack_from("!H", payload, 0)[0]
        return code, payload[2:].decode("utf-8", "replace")
    return CLOSE_NORMAL, ""


def encode_client_frame(opcode: int, payload: bytes = b"", mask: bytes = b"\x00\x00\x00\x00",
                        fin: bool = True) -> bytes:
    """Encode a masked client-to-server frame.

    Only used by the test suite, which plays the role of the browser.
    """
    first = (0x80 if fin else 0x00) | (opcode & 0x0F)
    length = len(payload)
    if length < 126:
        header = struct.pack("!BB", first, 0x80 | length)
    elif length < 65536:
        header = struct.pack("!BBH", first, 0x80 | 126, length)
    else:
        header = struct.pack("!BBQ", first, 0x80 | 127, length)
    masked = bytes(byte ^ mask[i % 4] for i, byte in enumerate(payload))
    return header + mask + masked
