#!/usr/bin/env python3
"""Exercise the shell helpers the container's startup depends on.

Two helpers carry most of the weight of the boot, and both are invisible to the
Python tests:

  * ``cloudpc_home`` resolves the desktop user's home directory and refuses to
    continue when that account cannot use it. The first version of the helper
    tried to ``mkdir -p`` the home as the unprivileged desktop user, so a volume
    whose root was not traversable produced the useless message "does not exist
    and cannot be created" instead of naming the real problem.
  * ``grant_traverse`` opens the path to the home directory for unprivileged
    accounts. A volume is mounted by the platform and can arrive as 0700
    root:root - the desktop user then cannot even stat its own home, and every
    graphical program dies with "Permission denied".

The tests below run the real functions in bash against temporary directories.
"""

from __future__ import annotations

import os
import shutil
import stat
import subprocess
import tempfile
import unittest

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
COMMON = os.path.join(REPO, "docker", "lib", "common.sh")
ENTRYPOINT = os.path.join(REPO, "docker", "entrypoint.sh")

BASH = shutil.which("bash")


def run_bash(script: str, home_dir: str | None = None) -> subprocess.CompletedProcess:
    environment = dict(os.environ)
    environment["CLOUDPC_ROOT"] = os.path.join(REPO, "docker")
    if home_dir is None:
        environment.pop("HOME_DIR", None)
    else:
        environment["HOME_DIR"] = home_dir
    return subprocess.run(
        ["bash", "-c", '. "${CLOUDPC_ROOT}/lib/common.sh"\n' + script],
        env=environment,
        capture_output=True,
        text=True,
        timeout=30,
    )


def mode_of(path: str) -> int:
    return stat.S_IMODE(os.stat(path).st_mode)


@unittest.skipUnless(BASH, "bash is required")
class CommonShellTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="cloudpc-common-")
        self.addCleanup(shutil.rmtree, self.tmp, True)

    def test_grant_traverse_opens_a_private_directory_without_granting_read(self):
        # This is the shape of a Railway/docker volume root: 0700 root:root.
        private = os.path.join(self.tmp, "volume")
        home = os.path.join(private, "home", "ubuntu")
        os.makedirs(home)
        os.chmod(private, 0o700)

        result = run_bash('grant_traverse "%s"' % home)
        self.assertEqual(result.returncode, 0, result.stderr)

        mode = mode_of(private)
        self.assertTrue(mode & stat.S_IXOTH, "unprivileged accounts still cannot traverse the volume root")
        self.assertFalse(mode & stat.S_IROTH, "grant_traverse must not make directories listable")
        self.assertTrue(result.stdout.strip(), "the change must be logged, not silent")

    def test_grant_traverse_leaves_directories_that_are_already_open_alone(self):
        open_dir = os.path.join(self.tmp, "open")
        home = os.path.join(open_dir, "home", "ubuntu")
        os.makedirs(home)
        # mkdtemp creates its directory 0700; make the whole path open so that
        # nothing needs changing.
        os.chmod(self.tmp, 0o755)
        os.chmod(open_dir, 0o755)

        result = run_bash('grant_traverse "%s"' % home)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(mode_of(open_dir), 0o755)
        self.assertEqual(result.stdout.strip(), "", "no change means no log line")

    def test_grant_traverse_never_touches_system_directories(self):
        # The walk stops at "/": neither / nor /tmp may lose or gain modes.
        home = os.path.join(self.tmp, "home", "ubuntu")
        os.makedirs(home)
        before = {path: mode_of(path) for path in ("/", "/tmp")}
        result = run_bash('grant_traverse "%s"' % home)
        self.assertEqual(result.returncode, 0, result.stderr)
        for path in ("/", "/tmp"):
            self.assertEqual(mode_of(path), before[path], "%s was modified" % path)

    def test_cloudpc_home_returns_the_home_from_home_dir(self):
        result = run_bash('echo "HOME=$(cloudpc_home)"', home_dir=self.tmp)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("HOME=%s" % self.tmp, result.stdout)

    def test_cloudpc_home_explains_an_unusable_home(self):
        missing = os.path.join(self.tmp, "no-such-home")
        result = run_bash('cloudpc_home', home_dir=missing)
        self.assertNotEqual(result.returncode, 0, "an unusable home must stop the program")
        self.assertIn("not usable", result.stderr)
        self.assertIn(missing, result.stderr)
        self.assertFalse(os.path.exists(missing), "the helper must not try to create the home itself")

    def test_the_entrypoint_grants_traverse_access_before_starting_supervisord(self):
        with open(ENTRYPOINT, encoding="utf-8") as handle:
            source = handle.read()
        self.assertIn('grant_traverse "${HOME_DIR}"', source)
        self.assertLess(
            source.index('grant_traverse "${HOME_DIR}"'),
            source.index("exec /usr/bin/supervisord"),
            "the path to the home directory has to be opened before the desktop starts",
        )


if __name__ == "__main__":
    unittest.main()
