#!/usr/bin/env python3
"""Talk to the Cloud PC the way a browser does, and prove the desktop works.

This is an independent implementation of the client side of the stack: it
connects to the gateway's ``/websockify`` endpoint over WebSocket (the same
transport noVNC uses), performs the real RFB handshake with VNC authentication,
asks for a framebuffer update and writes it out as an image. It can also send
pointer and keyboard events, or read the server clipboard.

That makes the CI run a genuine end-to-end test: if the screenshot shows the
XFCE desktop and typing into it creates a file inside the container, then the
whole chain - gateway, WebSocket bridge, TigerVNC, XFCE, xterm - really works.

Requirements: websocket-client, pycryptodome (VNC auth needs DES), Pillow
(optional - without it screenshots are written as .ppm).

Example:
    rfb_probe.py --url ws://127.0.0.1:8080/websockify \
                 --cookie "cloudpc_session=…" --password 8charpass \
                 --out /tmp/desktop.png --click 25,700 --keys "echo hi\n"
"""

from __future__ import annotations

import argparse
import io
import struct
import sys
import time

try:
    import websocket  # type: ignore
except ImportError:  # pragma: no cover - exercised only without the dependency
    print("websocket-client is required: pip install websocket-client", file=sys.stderr)
    raise SystemExit(3)

# --- RFB constants -----------------------------------------------------------
SEC_TYPE_VNC_AUTH = 2
ENCODING_RAW = 0
ENCODING_COPY_RECT = 1
ENCODING_DESKTOP_SIZE = -223

KEYSYMS = {
    "enter": 0xFF0D,
    "return": 0xFF0D,
    "tab": 0xFF09,
    "escape": 0xFF1B,
    "esc": 0xFF1B,
    "backspace": 0xFF08,
    "delete": 0xFFFF,
    "space": 0x0020,
    "ctrl": 0xFFE3,
    "control": 0xFFE3,
    "alt": 0xFFE9,
    "shift": 0xFFE1,
    "super": 0xFFEB,
}

ASCII_KEYSYMS = {
    "\n": KEYSYMS["enter"],
    "\r": KEYSYMS["enter"],
    "\t": KEYSYMS["tab"],
    " ": 0x0020,
    "!": 0x0021, '"': 0x0022, "#": 0x0023, "$": 0x0024, "%": 0x0025, "&": 0x0026,
    "'": 0x0027, "(": 0x0028, ")": 0x0029, "*": 0x002A, "+": 0x002B, ",": 0x002C,
    "-": 0x002D, ".": 0x002E, "/": 0x002F, ":": 0x003A, ";": 0x003B, "<": 0x003C,
    "=": 0x003D, ">": 0x003E, "?": 0x003F, "@": 0x0040, "[": 0x005B, "\\": 0x005C,
    "]": 0x005D, "^": 0x005E, "_": 0x005F, "`": 0x0060, "{": 0x007B, "|": 0x007C,
    "}": 0x007D, "~": 0x007E,
}


def keysym_for(char: str) -> int:
    if char in ASCII_KEYSYMS:
        return ASCII_KEYSYMS[char]
    code = ord(char)
    if 0x20 <= code <= 0x7E:
        return code
    raise ValueError("cannot send character %r (only ASCII is supported)" % char)


class RFBError(RuntimeError):
    pass


class Transport:
    """Byte-stream view on top of a WebSocket connection."""

    def __init__(self, url: str, cookie: str, origin: str | None = None,
                 subprotocols: list[str] | None = None, timeout: float = 20.0) -> None:
        headers = []
        if cookie:
            headers.append("Cookie: %s" % cookie)
        if origin:
            headers.append("Origin: %s" % origin)
        self._ws = websocket.create_connection(
            url,
            header=headers,
            subprotocols=subprotocols or [],
            timeout=timeout,
            enable_multithread=False,
        )
        self._buffer = bytearray()

    @property
    def subprotocol(self) -> str:
        return getattr(self._ws, "subprotocol", "") or ""

    def send(self, payload: bytes) -> None:
        self._ws.send_binary(payload)

    def set_timeout(self, timeout: float) -> None:
        self._ws.settimeout(timeout)

    def _fill(self, count: int) -> None:
        while len(self._buffer) < count:
            try:
                chunk = self._ws.recv()
            except Exception as exc:  # includes WebSocketTimeoutException
                raise RFBError("read timeout or socket error: %s" % exc) from exc
            if isinstance(chunk, str):
                chunk = chunk.encode("iso-8859-1")
            if not chunk:
                raise RFBError("connection closed by the server")
            self._buffer.extend(chunk)

    def read(self, count: int) -> bytes:
        self._fill(count)
        data = bytes(self._buffer[:count])
        del self._buffer[:count]
        return data

    def read_available(self, timeout: float = 1.0) -> bytes:
        """Return whatever arrives within *timeout* seconds (may be empty)."""
        self._ws.settimeout(timeout)
        try:
            chunk = self._ws.recv()
        except Exception:
            return b""
        finally:
            self._ws.settimeout(20.0)
        if isinstance(chunk, str):
            chunk = chunk.encode("iso-8859-1")
        return chunk or b""

    def close(self) -> None:
        try:
            self._ws.close()
        except Exception:
            pass


class Client:
    def __init__(self, transport: Transport, password: str | None = None,
                 shared: bool = True, verbose: bool = True) -> None:
        self.transport = transport
        self.password = password
        self.shared = shared
        self.verbose = verbose
        self.width = 0
        self.height = 0
        self.name = ""
        self.pixel_format = {}
        self._frames = 0

    def _log(self, message: str) -> None:
        if self.verbose:
            print("  [rfb] %s" % message, flush=True)

    # -- handshake --------------------------------------------------------
    def handshake(self) -> None:
        self.transport.send(b"RFB 003.008\n")
        version = self.transport.read(12)
        if not version.startswith(b"RFB 003.00"):
            raise RFBError("unexpected protocol version %r" % version)
        self._log("server version %s" % version.decode().strip())

        count = self.transport.read(1)[0]
        if count == 0:
            reason_length = struct.unpack("!I", self.transport.read(4))[0]
            reason = self.transport.read(reason_length).decode("utf-8", "replace")
            raise RFBError("server refused the connection: %s" % reason)
        security_types = list(self.transport.read(count))
        self._log("security types offered: %s" % security_types)
        if SEC_TYPE_VNC_AUTH not in security_types:
            raise RFBError("server does not offer VNC authentication (%s)" % security_types)
        self.transport.send(bytes([SEC_TYPE_VNC_AUTH]))

        challenge = self.transport.read(16)
        if not self.password:
            raise RFBError("a VNC password is required but none was supplied")
        response = vnc_auth_response(self.password, challenge)
        self.transport.send(response)

        result = struct.unpack("!I", self.transport.read(4))[0]
        if result != 0:
            raise RFBError("authentication failed (SecurityResult=%d)" % result)
        self._log("authenticated")

        self.transport.send(bytes([1 if self.shared else 0]))  # ClientInit

        width, height = struct.unpack("!HH", self.transport.read(4))
        pixel_format = self.transport.read(16)
        name_length = struct.unpack("!I", self.transport.read(4))[0]
        self.name = self.transport.read(name_length).decode("utf-8", "replace")
        (bpp, depth, big_endian, true_colour, red_max, green_max, blue_max,
         red_shift, green_shift, blue_shift) = struct.unpack("!BBBBHHHBBB", pixel_format[:13])
        self.width, self.height = width, height
        self.pixel_format = {
            "bpp": bpp, "depth": depth, "big_endian": bool(big_endian),
            "true_colour": bool(true_colour), "red_max": red_max, "green_max": green_max,
            "blue_max": blue_max, "red_shift": red_shift, "green_shift": green_shift,
            "blue_shift": blue_shift,
        }
        self._log("desktop %dx%d, name=%r, %s" % (width, height, self.name, self.pixel_format))

        # Ask for raw pixels: slow over a network, perfect for a test.
        encodings = struct.pack("!ii", ENCODING_RAW, ENCODING_COPY_RECT)
        self.transport.send(struct.pack("!BBH", 2, 0, 2) + encodings)

    # -- messages ---------------------------------------------------------
    def request_update(self, incremental: bool = False) -> None:
        self.transport.send(struct.pack("!BBHHHH", 3, 1 if incremental else 0, 0, 0,
                                        self.width, self.height))

    def _read_message(self):
        """Read one server message.

        Returns ``("update", rgb-or-None)``, ``("clipboard", bytes)`` or
        ``("noop", None)`` for messages that carry no data we care about.
        """
        message_type = self.transport.read(1)[0]
        if message_type == 0:  # FramebufferUpdate: the caller reads the header
            return "update", None
        if message_type == 1:  # SetColourMapEntries
            self.transport.read(3)
            colours = struct.unpack("!H", self.transport.read(2))[0]
            self.transport.read(colours * 6)
            return "noop", None
        if message_type == 2:  # Bell
            return "noop", None
        if message_type == 3:  # ServerCutText
            self.transport.read(3)
            length = struct.unpack("!I", self.transport.read(4))[0]
            return "clipboard", self.transport.read(length)
        raise RFBError("unexpected server message type %d" % message_type)

    def screenshot(self, incremental: bool = False, timeout: float = 25.0,
                   collect_clipboard: float = 0.0):
        """Request a framebuffer update and return ``(rgb, clipboard)``.

        ``collect_clipboard`` > 0 additionally waits that many seconds for a
        ServerCutText message (the desktop clipboard) after the screen update.
        """
        self.request_update(incremental=incremental)
        deadline = time.time() + timeout
        image = None
        clipboard = None
        while time.time() < deadline:
            kind, payload = self._read_message()
            if kind == "clipboard":
                clipboard = payload
                continue
            if kind != "update":
                continue

            padding, rectangles = struct.unpack("!BH", self.transport.read(3))
            del padding
            if image is None:
                image = bytearray(self.width * self.height * 3)
            for _ in range(rectangles):
                image = self._read_rectangle(image)
            self._frames += 1
            break
        if image is None:
            raise RFBError("timed out waiting for a framebuffer update")

        if collect_clipboard > 0:
            self.transport.set_timeout(collect_clipboard)
            try:
                while True:
                    kind, payload = self._read_message()
                    if kind == "clipboard":
                        clipboard = payload
                        break
                    if kind == "update":
                        # A stray update: drain its rectangles and keep waiting.
                        padding, rectangles = struct.unpack("!BH", self.transport.read(3))
                        del padding
                        for _ in range(rectangles):
                            image = self._read_rectangle(image)
            except RFBError:
                pass  # nothing arrived within the grace period
            finally:
                self.transport.set_timeout(20.0)
        return bytes(image), clipboard

    def _read_rectangle(self, image: bytearray) -> bytearray:
        x, y, width, height, encoding = struct.unpack("!HHHHi", self.transport.read(12))
        if encoding == ENCODING_RAW:
            row_bytes = width * (self.pixel_format["bpp"] // 8)
            pixels = self.transport.read(row_bytes * height)
            self._blit(image, x, y, width, height, pixels)
            return image
        if encoding == ENCODING_COPY_RECT:
            source_x, source_y = struct.unpack("!HH", self.transport.read(4))
            for row in range(height):
                start = ((source_y + row) * self.width + source_x) * 3
                block = image[start:start + width * 3]
                target = ((y + row) * self.width + x) * 3
                image[target:target + width * 3] = block
            return image
        if encoding == ENCODING_DESKTOP_SIZE:
            self.width, self.height = struct.unpack("!HH", self.transport.read(4))
            self._log("desktop resized to %dx%d" % (self.width, self.height))
            image = bytearray(self.width * self.height * 3)
            return image
        raise RFBError("server used unsupported encoding %d" % encoding)

    def _blit(self, image: bytearray, x: int, y: int, width: int, height: int,
              pixels: bytes) -> None:
        fmt = self.pixel_format
        bytes_per_pixel = fmt["bpp"] // 8
        order = "big" if fmt["big_endian"] else "little"
        red_max, green_max, blue_max = fmt["red_max"], fmt["green_max"], fmt["blue_max"]
        red_shift, green_shift, blue_shift = fmt["red_shift"], fmt["green_shift"], fmt["blue_shift"]
        for row in range(height):
            offset = row * width * bytes_per_pixel
            target_row = ((y + row) * self.width + x) * 3
            for column in range(width):
                start = offset + column * bytes_per_pixel
                value = int.from_bytes(pixels[start:start + bytes_per_pixel], order)
                red = ((value >> red_shift) & red_max) * 255 // max(red_max, 1)
                green = ((value >> green_shift) & green_max) * 255 // max(green_max, 1)
                blue = ((value >> blue_shift) & blue_max) * 255 // max(blue_max, 1)
                position = target_row + column * 3
                image[position] = red
                image[position + 1] = green
                image[position + 2] = blue

    # -- input ------------------------------------------------------------
    def pointer(self, x: int, y: int, mask: int = 0) -> None:
        self.transport.send(struct.pack("!BBHH", 5, mask, x, y))

    def click(self, x: int, y: int, hold: float = 0.1) -> None:
        self.pointer(x, y, 0)
        time.sleep(0.05)
        self.pointer(x, y, 1)  # button 1 down
        time.sleep(hold)
        self.pointer(x, y, 0)
        self._log("clicked at %d,%d" % (x, y))

    def double_click(self, x: int, y: int) -> None:
        for _ in range(2):
            self.click(x, y, hold=0.05)
            time.sleep(0.05)

    def key(self, keysym: int, down: bool = True) -> None:
        self.transport.send(struct.pack("!BBHI", 4, 1 if down else 0, 0, keysym))

    def press(self, keysym: int) -> None:
        self.key(keysym, True)
        time.sleep(0.03)
        self.key(keysym, False)
        time.sleep(0.03)

    def combo(self, *names: str) -> None:
        keysyms = [KEYSYMS[name.lower()] for name in names]
        for keysym in keysyms:
            self.key(keysym, True)
            time.sleep(0.05)
        for keysym in reversed(keysyms):
            self.key(keysym, False)
            time.sleep(0.05)
        self._log("pressed %s" % "+".join(names))

    def type_text(self, text: str, delay: float = 0.04) -> None:
        for char in text:
            keysym = keysym_for(char)
            self.key(keysym, True)
            time.sleep(delay)
            self.key(keysym, False)
            time.sleep(delay)
        self._log("typed %d characters" % len(text))

    def set_clipboard(self, text: str) -> None:
        payload = text.encode("iso-8859-1", "replace")
        self.transport.send(struct.pack("!BBBB", 6, 0, 0, 0) + struct.pack("!I", len(payload)) + payload)
        self._log("sent %d bytes of clipboard" % len(payload))


def vnc_auth_response(password: str, challenge: bytes) -> bytes:
    """DES-encrypt the challenge with the bit-reversed VNC password."""
    key = (password + "\0" * 8).encode("latin-1")[:8]
    reversed_bits = bytes(int("{:08b}".format(byte)[::-1], 2) for byte in key)
    try:
        from Crypto.Cipher import DES  # pycryptodome
    except ImportError:  # pragma: no cover
        print("pycryptodome is required for VNC authentication: "
              "pip install pycryptodome", file=sys.stderr)
        raise SystemExit(3)
    return DES.new(reversed_bits, DES.MODE_ECB).encrypt(challenge)


def save_image(path: str, width: int, height: int, rgb: bytes) -> str:
    try:
        from PIL import Image  # type: ignore
    except ImportError:
        path = path.rsplit(".", 1)[0] + ".ppm"
        with open(path, "wb") as handle:
            handle.write(b"P6\n%d %d\n255\n" % (width, height))
            handle.write(rgb)
        return path
    image = Image.frombytes("RGB", (width, height), rgb)  # type: ignore[attr-defined]
    buffer = io.BytesIO()
    image.save(buffer, format="PNG")
    with open(path, "wb") as handle:
        handle.write(buffer.getvalue())
    return path


def main() -> int:
    parser = argparse.ArgumentParser(description="RFB/noVNC end-to-end probe")
    parser.add_argument("--url", required=True, help="ws:// or wss:// gateway URL")
    parser.add_argument("--cookie", default="", help="session cookie header value")
    parser.add_argument("--origin", default=None, help="Origin header to send")
    parser.add_argument("--subprotocol", default=None, help="offer this WebSocket sub-protocol")
    parser.add_argument("--password", default="", help="VNC password")
    parser.add_argument("--out", help="write a screenshot PNG here")
    parser.add_argument("--out2", help="write a second screenshot after the input events")
    parser.add_argument("--click", action="append", default=[],
                        help="click at X,Y (repeatable)")
    parser.add_argument("--combo", action="append", default=[],
                        help="key combination, e.g. ctrl-alt-t (repeatable)")
    parser.add_argument("--type", dest="text", default="", help="type this text")
    parser.add_argument("--clipboard", default="", help="send this text as the client clipboard")
    parser.add_argument("--read-clipboard", action="store_true",
                        help="print the desktop clipboard (ServerCutText)")
    parser.add_argument("--pause", type=float, default=0.0,
                        help="seconds to wait after clicking/pressing keys and before "
                             "typing (opening a terminal takes a moment)")
    parser.add_argument("--settle", type=float, default=1.5,
                        help="seconds to wait after input before the second screenshot")
    parser.add_argument("--json", action="store_true", help="machine readable summary")
    args = parser.parse_args()

    transport = Transport(args.url, args.cookie, args.origin,
                          [args.subprotocol] if args.subprotocol else None)
    client = Client(transport, password=args.password, verbose=not args.json)
    summary = {"ok": False}
    try:
        client.handshake()
        if args.subprotocol:
            summary["subprotocol"] = transport.subprotocol
            if transport.subprotocol != args.subprotocol:
                raise RFBError("server did not echo the sub-protocol %r (got %r)"
                               % (args.subprotocol, transport.subprotocol))
        rgb, _ = client.screenshot()
        summary.update({"width": client.width, "height": client.height,
                        "desktop_name": client.name})
        if args.out:
            summary["image"] = save_image(args.out, client.width, client.height, rgb)

        if args.click or args.combo or args.text or args.clipboard:
            for target in args.click:
                x, _, y = target.partition(",")
                client.click(int(x), int(y))
            for combo in args.combo:
                client.combo(*combo.split("-"))
            if args.pause > 0:
                time.sleep(args.pause)
            if args.text:
                client.type_text(args.text)
            if args.clipboard:
                client.set_clipboard(args.clipboard)
            time.sleep(args.settle)

            if args.out2:
                rgb2, _ = client.screenshot(incremental=True)
                summary["image2"] = save_image(args.out2, client.width, client.height, rgb2)
                summary["changed_pixels_estimate"] = sum(
                    1 for index in range(0, len(rgb), 3 * 97) if rgb[index] != rgb2[index])

        if args.read_clipboard:
            _, clipboard = client.screenshot(collect_clipboard=10.0)
            if clipboard is None:
                raise RFBError("the desktop did not offer any clipboard data")
            summary["clipboard"] = clipboard.decode("latin-1")

        summary["ok"] = True
    except Exception as exc:  # noqa: BLE001 - the CLI reports every failure the same way
        summary["error"] = "%s: %s" % (type(exc).__name__, exc)
        if not args.json:
            print("FAILED: %s" % summary["error"], file=sys.stderr)
    finally:
        transport.close()

    if args.json:
        import json
        print(json.dumps(summary, indent=2, sort_keys=True))
    else:
        print("probe result: %s" % ("OK" if summary["ok"] else summary.get("error")))
    return 0 if summary["ok"] else 1


if __name__ == "__main__":
    sys.exit(main())
