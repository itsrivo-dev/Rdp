#!/usr/bin/env python3
"""Unit tests for the build-time tools.

`docker/tools/make_icons.py` and `docker/tools/build_novnc_page.py` run inside
the Docker build, where a failure is slow and expensive to discover. These tests
exercise them here instead, including the assertions that are supposed to make
the build fail when noVNC's page changes shape.
"""

from __future__ import annotations

import contextlib
import io
import os
import struct
import subprocess
import sys
import tempfile
import unittest

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
TOOLS = os.path.join(REPO, "docker", "tools")
sys.path.insert(0, TOOLS)

import build_novnc_page  # noqa: E402

# A miniature stand-in for noVNC's vnc.html: just the markers the patcher checks.
FAKE_VNC_HTML = """<!DOCTYPE html>
<html lang="en" class="noVNC_loading">
<head>
    <title>noVNC</title>
    <meta name="theme-color" content="#313131">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <script type="module">
        import UI from "./app/ui.js";
        let defaults = {};
        let mandatory = {};
        UI.start({ settings: { defaults: defaults, mandatory: mandatory } });
    </script>
</head>
<body>
    <div id="noVNC_container"></div>
    <select id="noVNC_setting_resize" name="vncResize">
        <option value="off">None</option>
    </select>
</body>
</html>
"""


class IconTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()

    def tearDown(self):
        self.tmp.cleanup()

    def test_generates_valid_png_and_ico(self):
        result = subprocess.run(
            [sys.executable, os.path.join(TOOLS, "make_icons.py"), self.tmp.name],
            capture_output=True, text=True, check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)

        expected = {"icon-192.png": (192, 192), "icon-512.png": (512, 512),
                    "icon-maskable-512.png": (512, 512)}
        for name, (width, height) in expected.items():
            path = os.path.join(self.tmp.name, name)
            self.assertTrue(os.path.exists(path), name)
            with open(path, "rb") as handle:
                data = handle.read()
            self.assertEqual(data[:8], b"\x89PNG\r\n\x1a\n", "%s is not a PNG" % name)
            self.assertEqual(struct.unpack(">II", data[16:24]), (width, height), name)
            self.assertGreater(len(data), 500, "%s looks empty" % name)

        ico = os.path.join(self.tmp.name, "favicon.ico")
        with open(ico, "rb") as handle:
            data = handle.read()
        self.assertEqual(data[:4], b"\x00\x00\x01\x00", "not an ICO file")
        self.assertEqual(struct.unpack("<H", data[4:6])[0], 1, "ICO should hold one image")

    def test_icons_differ_between_sizes(self):
        subprocess.run([sys.executable, os.path.join(TOOLS, "make_icons.py"), self.tmp.name],
                       capture_output=True, check=True)
        with open(os.path.join(self.tmp.name, "icon-192.png"), "rb") as handle:
            small = handle.read()
        with open(os.path.join(self.tmp.name, "icon-512.png"), "rb") as handle:
            large = handle.read()
        self.assertNotEqual(small, large)


class NovncPatchTests(unittest.TestCase):
    def make_tree(self, html: str, with_lite: bool = True) -> str:
        root = tempfile.mkdtemp(prefix="novnc-fixture-")
        with open(os.path.join(root, "vnc.html"), "w", encoding="utf-8") as handle:
            handle.write(html)
        if with_lite:
            with open(os.path.join(root, "vnc_lite.html"), "w", encoding="utf-8") as handle:
                handle.write("<!DOCTYPE html><title>lite</title>")
        self.addCleanup(lambda: __import__("shutil").rmtree(root, ignore_errors=True))
        return root

    def test_replaces_the_bootstrap_and_renames_the_page(self):
        root = self.make_tree(FAKE_VNC_HTML)
        original_argv = sys.argv
        sys.argv = ["build_novnc_page.py", root]
        try:
            with contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(build_novnc_page.main(), 0, "the patch should succeed")
        finally:
            sys.argv = original_argv

        index = os.path.join(root, "index.html")
        self.assertTrue(os.path.exists(index), "index.html was not written")
        self.assertFalse(os.path.exists(os.path.join(root, "vnc.html")),
                         "vnc.html should be removed after patching")
        self.assertFalse(os.path.exists(os.path.join(root, "vnc_lite.html")),
                         "vnc_lite.html should be removed")

        with open(index, encoding="utf-8") as handle:
            html = handle.read()
        self.assertIn("<title>Ubuntu Desktop</title>", html)
        self.assertIn("api/session", html)
        self.assertIn("autoconnect: true", html)
        self.assertIn("mandatory: {}", html)
        self.assertIn('id="noVNC_container"', html, "the noVNC interface must be preserved")
        self.assertNotIn("UI.start({ settings: { defaults: defaults", html,
                         "the original bootstrap must be gone")
        self.assertIn("manifest.webmanifest", html, "the PWA manifest link should be added")

    def test_refuses_a_page_without_the_expected_markers(self):
        root = self.make_tree("<!DOCTYPE html><title>something else</title>")
        original_argv = sys.argv
        sys.argv = ["build_novnc_page.py", root]
        try:
            with self.assertRaises(SystemExit) as ctx:
                build_novnc_page.main()
            self.assertNotEqual(ctx.exception.code, 0)
        finally:
            sys.argv = original_argv
        self.assertFalse(os.path.exists(os.path.join(root, "index.html")))

    def test_refuses_when_there_is_no_ui_start(self):
        html = FAKE_VNC_HTML.replace("UI.start({ settings: { defaults: defaults, mandatory: mandatory } });",
                                     "// nothing here")
        root = self.make_tree(html)
        original_argv = sys.argv
        sys.argv = ["build_novnc_page.py", root]
        try:
            with self.assertRaises(SystemExit) as ctx:
                build_novnc_page.main()
            self.assertNotEqual(ctx.exception.code, 0)
        finally:
            sys.argv = original_argv

    def test_missing_page_is_an_error(self):
        with tempfile.TemporaryDirectory() as root:
            original_argv = sys.argv
            sys.argv = ["build_novnc_page.py", root]
            try:
                with self.assertRaises(SystemExit):
                    build_novnc_page.main()
            finally:
                sys.argv = original_argv


if __name__ == "__main__":
    unittest.main()
