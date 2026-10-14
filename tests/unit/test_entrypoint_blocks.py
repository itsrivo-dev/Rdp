#!/usr/bin/env python3
"""Guard the embedded Python blocks in docker/entrypoint.sh.

The entrypoint runs small Python programs to write the password hash, the
session key and the runtime facts file. They read the shell's environment, and
a variable that is *set* but never **exported** is invisible to them - shell
variables only reach a child process through the environment.

That exact mistake (a missing `export DATA_DIR`) cost two CI cycles: the
container died with `KeyError: 'DATA_DIR'` before it ever started the desktop,
and every check after it failed for the wrong reason. These tests make the
class of bug impossible to reintroduce:

  * every ``os.environ["NAME"]`` used by a block must be exported by the
    entrypoint, passed inline on the command line, or provided by Railway
  * the blocks are actually executed with a synthetic environment, so a
    KeyError, a bad path or a syntax error fails here instead of in a container
"""

from __future__ import annotations

import json
import os
import re
import subprocess
import sys
import tempfile
import unittest

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
ENTRYPOINT = os.path.join(REPO, "docker", "entrypoint.sh")

#: Variables the block may read without the entrypoint exporting them: they are
#: set inline on the command line, or injected by Railway itself.
INLINE_OR_EXTERNAL = {
    "CLOUDPC_VERSION",
    "CLOUDPC_STORAGE_NOTE",
    "CLOUDPC_PASSWORD_SOURCE",
    "CLOUDPC_PASSWORD_FOR_HASH",
}

BLOCK_PATTERN = re.compile(r"<<'PY'\n(.*?)\nPY\n", re.DOTALL)
# `export A B C` / `export A=1` / `A=1 B=2 export ...` are all handled by
# collecting every name that appears in an export statement.
EXPORT_PATTERN = re.compile(r"^\s*export\s+([A-Za-z_][A-Za-z0-9_ ]*)$", re.MULTILINE)
ASSIGN_PATTERN = re.compile(r"^\s*([A-Z_][A-Z0-9_]*)=", re.MULTILINE)
ENV_USAGE = re.compile(r"""os\.environ(?:\.get)?[\(\[]\s*["']([A-Z0-9_]+)["']""")


def read_entrypoint() -> str:
    with open(ENTRYPOINT, encoding="utf-8") as handle:
        return handle.read()


def blocks(source: str) -> list[str]:
    return BLOCK_PATTERN.findall(source)


class EntrypointBlockTests(unittest.TestCase):
    def setUp(self):
        self.source = read_entrypoint()
        self.blocks = blocks(self.source)
        self.assertTrue(self.blocks, "no embedded Python blocks found in the entrypoint")

        exported: set[str] = set()
        for match in EXPORT_PATTERN.finditer(self.source):
            # `export A B` (possibly split over continuation lines)
            exported.update(match.group(1).split())
        # Variables assigned and used by the inline-environment form
        # (`NAME=value python3 ...`) are covered by INLINE_OR_EXTERNAL.
        self.exported = exported

    def test_every_variable_a_block_reads_is_available(self):
        missing = []
        for index, block in enumerate(self.blocks):
            for name in sorted(set(ENV_USAGE.findall(block))):
                if name in self.exported or name in INLINE_OR_EXTERNAL:
                    continue
                if name.startswith("RAILWAY_") or name.startswith("CLOUDPC_"):
                    continue  # provided by the platform or by the image
                missing.append("block %d reads $%s" % (index, name))
        self.assertEqual(missing, [], "unexported variables: %s" % "; ".join(missing))

    def test_the_exports_are_still_there(self):
        # A regression guard for the specific variables the blocks need.
        for name in ("DESKTOP_USER", "HOME_DIR", "DATA_DIR", "PERSISTENT",
                     "HTTP_PORT", "VNC_PORT", "DESKTOP_DISPLAY", "DESKTOP_RESOLUTION",
                     "DESKTOP_DEPTH", "SESSION_TTL_HOURS", "SECRETS_DIR"):
            self.assertIn(name, self.exported, "%s is no longer exported" % name)

    @staticmethod
    def classify(block: str) -> str:
        """Identify which embedded program a block is, by what it does."""
        if "scrypt" in block:
            return "auth"
        if "token_bytes(32)" in block:
            return "session_key"
        if "storage_note" in block or "railway_service" in block:
            return "runtime"
        if "secrets.choice" in block:
            return "generator"
        return "unknown"

    def test_blocks_run_with_a_synthetic_environment(self):
        """Execute every block for real, with the environment it expects."""
        with tempfile.TemporaryDirectory() as tmp:
            run_dir = os.path.join(tmp, "run")
            home = os.path.join(tmp, "data", "home", "ubuntu")
            os.makedirs(run_dir, exist_ok=True)
            os.makedirs(home, exist_ok=True)

            environment = dict(os.environ)
            environment.update({
                "DESKTOP_USER": "ubuntu",
                "DESKTOP_UID": "1000",
                "DESKTOP_GID": "1000",
                "HTTP_PORT": "8080",
                "VNC_PORT": "5900",
                "DESKTOP_DISPLAY": "1",
                "DESKTOP_RESOLUTION": "1280x720",
                "DESKTOP_DEPTH": "24",
                "VNC_FRAME_RATE": "30",
                "DESKTOP_NAME": "Ubuntu Cloud Desktop",
                "SESSION_TTL_HOURS": "168",
                "DATA_DIR": os.path.join(tmp, "data"),
                "HOME_DIR": home,
                "SECRETS_DIR": os.path.join(tmp, "data", ".secrets"),
                "PERSISTENT": "true",
                "CLOUDPC_RUN_DIR": run_dir,
                "CLOUDPC_VERSION": "2.0.0",
                "CLOUDPC_STORAGE_NOTE": "persistent volume at %s" % os.path.join(tmp, "data"),
                "CLOUDPC_PASSWORD_SOURCE": "test",
                "CLOUDPC_PASSWORD_FOR_HASH": "test-password-123456",
            })
            os.makedirs(environment["SECRETS_DIR"], exist_ok=True)

            auth_path = os.path.join(run_dir, "auth.json")
            key_path = os.path.join(environment["SECRETS_DIR"], "session.key")
            runtime_path = os.path.join(run_dir, "runtime.json")
            argv_by_kind = {
                "auth": [auth_path, "ubuntu"],
                "session_key": [key_path],
                "runtime": [runtime_path],
                "generator": [],
            }

            seen = set()
            for index, block in enumerate(self.blocks):
                kind = self.classify(block)
                seen.add(kind)
                self.assertNotEqual(kind, "unknown", "unrecognised block %d" % index)
                result = subprocess.run(
                    [sys.executable, "-", *argv_by_kind[kind]],
                    input=block, text=True, capture_output=True,
                    env=environment, timeout=60, check=False,
                )
                self.assertEqual(result.returncode, 0,
                                 "%s block failed:\n%s\n%s" % (kind, result.stdout, result.stderr))
                if kind == "generator":
                    password = result.stdout.strip()
                    self.assertGreaterEqual(len(password), 8, "generator produced nothing")
                    self.assertEqual(len(password.split()), 1, "unexpected generator output")
                    self.assertNotIn(" ", password)

            self.assertEqual(seen, {"generator", "auth", "session_key", "runtime"},
                             "one of the entrypoint's programs disappeared")

            # The artefacts must be valid and free of the plaintext password.
            with open(auth_path, encoding="utf-8") as handle:
                auth = json.load(handle)
            self.assertEqual(auth["username"], "ubuntu")
            self.assertEqual(auth["algorithm"], "scrypt")
            self.assertNotIn("test-password-123456", json.dumps(auth))

            with open(key_path, encoding="ascii") as handle:
                session_key = handle.read().strip()
            self.assertGreater(len(session_key), 20)

            with open(runtime_path, encoding="utf-8") as handle:
                runtime = json.load(handle)
            for key in ("username", "home", "data_dir", "http_port", "vnc_port",
                        "display", "resolution", "depth", "session_ttl_hours"):
                self.assertIn(key, runtime)
            self.assertEqual(runtime["data_dir"], environment["DATA_DIR"])
            self.assertEqual(runtime["resolution"], "1280x720")
            self.assertNotIn("test-password-123456", json.dumps(runtime))

    def test_no_block_writes_a_password_to_disk_in_clear(self):
        """The password hash block must never write the plaintext password."""
        source = self.source
        self.assertNotIn('json.dump({"password"', source)
        self.assertIn('"hash":', source)


if __name__ == "__main__":
    unittest.main()
