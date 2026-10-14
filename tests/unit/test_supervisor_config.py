#!/usr/bin/env python3
"""Guard the process-supervision contract of the container.

The second end-to-end run booted a container in which *every* long-running
program died within seconds, each for its own small reason:

  * ``gateway``  - ``/opt/cloudpc/gateway`` was mode 0750, so the unprivileged
    ``cloudpc`` account could not even open ``server.py``
  * ``vnc``      - supervisord runs as root and passes its own environment on,
    so the desktop user started with ``HOME=/root`` ("not writable by ubuntu")
  * ``session``  - same, and ``/root/.Xauthority`` was not writable either

None of that is visible in the source of the programs involved; it lives in the
interaction between ``supervisord.conf``, the entrypoint's exports and the
Dockerfile's modes. These tests pin those interactions down:

  * every ``%(ENV_X)s`` supervisord interpolates must be exported by the
    entrypoint (an unset one makes supervisord refuse to start at all)
  * every program supervisord runs as the desktop user must be given that
    user's HOME/USER/LOGNAME/SHELL explicitly
  * the gateway must run as an unprivileged account, and the Dockerfile must
    not take read access to its code away from that account
  * the start order (dbus -> vnc -> session -> gateway -> watchdog) is fixed
"""

from __future__ import annotations

import configparser
import os
import re
import unittest

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SUPERVISOR_CONF = os.path.join(REPO, "docker", "supervisor", "supervisord.conf")
ENTRYPOINT = os.path.join(REPO, "docker", "entrypoint.sh")
DOCKERFILE = os.path.join(REPO, "Dockerfile")

#: Variables supervisord may interpolate without the entrypoint exporting them:
#: they are injected by Docker/Railway itself and are never given a shell-side
#: default that could differ from the environment.
PLATFORM_VARIABLES = {"PORT"}

ENV_REFERENCE = re.compile(r"%\(ENV_([A-Z0-9_]+)\)s")
EXPORT_LINE = re.compile(r"^\s*export\s+([A-Za-z_][A-Za-z0-9_ ]*)$", re.MULTILINE)
#: `KEY="value"` pairs inside a supervisord environment= option.
ENV_OPTION = re.compile(r"([A-Za-z_][A-Za-z0-9_]*)=\"([^\"]*)\"")
DESKTOP_SCRIPTS = (
    os.path.join("docker", "bin", "cloudpc-vnc"),
    os.path.join("docker", "bin", "cloudpc-session"),
)


def read(path: str) -> str:
    with open(path, encoding="utf-8") as handle:
        return handle.read()


def load_supervisor_config() -> configparser.RawConfigParser:
    # Raw: the file is full of %(ENV_x)s placeholders that supervisord, not
    # configparser, resolves.
    parser = configparser.RawConfigParser(allow_no_value=True)
    parser.optionxform = str  # keep keys as written
    parser.read_string(read(SUPERVISOR_CONF))
    return parser


def entrypoint_exports() -> set[str]:
    exported: set[str] = set()
    for match in EXPORT_LINE.finditer(read(ENTRYPOINT)):
        exported.update(match.group(1).split())
    return exported


def programs(parser: configparser.RawConfigParser) -> dict[str, dict[str, str]]:
    return {
        section.split(":", 1)[1]: dict(parser.items(section))
        for section in parser.sections()
        if section.startswith("program:")
    }


class SupervisorConfigTests(unittest.TestCase):
    def setUp(self):
        self.parser = load_supervisor_config()
        self.programs = programs(self.parser)
        self.assertTrue(self.programs, "no [program:*] sections in supervisord.conf")

    def test_every_interpolated_variable_is_exported(self):
        missing = []
        for name in sorted(set(ENV_REFERENCE.findall(read(SUPERVISOR_CONF)))):
            if name in PLATFORM_VARIABLES:
                continue
            if name not in entrypoint_exports():
                missing.append(name)
        self.assertEqual(
            missing,
            [],
            "supervisord.conf interpolates the variables "
            + ", ".join("%(ENV_" + name + ")s" for name in missing)
            + " but the entrypoint never exports them: supervisord exits at "
            "startup with KeyError",
        )

    def test_programs_running_as_the_desktop_user_get_that_users_environment(self):
        checked = 0
        for name, options in self.programs.items():
            if not options.get("user", "").startswith("%(ENV_"):
                continue
            checked += 1
            environment = dict(ENV_OPTION.findall(options.get("environment", "")))
            self.assertEqual(
                environment.get("HOME"),
                "%(ENV_HOME_DIR)s",
                f"{name} runs as the desktop user but keeps root's HOME",
            )
            self.assertEqual(environment.get("USER"), options["user"], name)
            self.assertEqual(environment.get("LOGNAME"), options["user"], name)
            self.assertTrue(environment.get("SHELL", "").startswith("/"), name)
        self.assertGreaterEqual(checked, 2, "expected vnc and session to run as the desktop user")

    def test_the_desktop_scripts_resolve_home_before_using_it(self):
        for relative in DESKTOP_SCRIPTS:
            source = read(os.path.join(REPO, relative))
            resolve = source.find('HOME="$(cloudpc_home)"')
            self.assertNotEqual(resolve, -1, f"{relative} does not resolve HOME through cloudpc_home")
            first_use = source.find("${HOME}")
            self.assertGreater(
                first_use,
                resolve,
                f"{relative} uses $HOME before resolving it from HOME_DIR",
            )

    def test_the_gateway_runs_unprivileged(self):
        gateway = self.programs["gateway"]
        self.assertEqual(gateway["user"], "cloudpc")
        self.assertNotEqual(gateway["user"], "root")

    def test_the_gateway_can_read_its_own_code(self):
        # A directory mode without the "other" bits stops the unprivileged
        # gateway account from traversing into it (this happened in CI with
        # 0750): look at every chmod the Dockerfile applies to that path.
        modes = re.findall(r"chmod\s+([0-7]{3,4})\s+(\S*?/opt/cloudpc/gateway\S*)", read(DOCKERFILE))
        self.assertTrue(modes, "the Dockerfile does not set the gateway directory modes explicitly")
        for mode, path in modes:
            self.assertIn(
                mode[-1],
                "57",
                f"{path} is set to {mode}: the unprivileged gateway account cannot traverse it",
            )

    def test_start_order_is_fixed(self):
        order = ["dbus", "vnc", "session", "gateway", "watchdog"]
        priorities = [int(self.programs[name]["priority"]) for name in order]
        self.assertEqual(priorities, sorted(priorities), f"unexpected start order: {dict(zip(order, priorities))}")
        self.assertEqual(len(set(priorities)), len(priorities), "priorities must be unique")
        for name in order:
            self.assertEqual(self.programs[name].get("autostart"), "true", name)

    def test_no_secret_reaches_the_supervisor_environment(self):
        allowed = {"HOME", "USER", "LOGNAME", "SHELL", "CLOUDPC_ROOT", "PATH"}
        for name, options in self.programs.items():
            for key, _ in ENV_OPTION.findall(options.get("environment", "")):
                self.assertIn(key, allowed, f"{name} passes {key} through the supervisor environment")
        # No program may be started with a password on its command line: the
        # command line is world readable in /proc.
        for name, options in self.programs.items():
            command = options.get("command", "")
            self.assertNotIn("PASSWORD", command.upper(), f"{name} has a credential in its command")
            self.assertNotIn("PASSWD", command.upper(), f"{name} has a credential in its command")

    def test_the_gateway_is_the_only_public_listener(self):
        # Xtigervnc must stay on loopback; the gateway binds 0.0.0.0:$PORT.
        vnc = read(os.path.join(REPO, "docker", "bin", "cloudpc-vnc"))
        flags = [item.strip() for item in vnc.splitlines()]
        # -localhost is a boolean flag: a value after it (the old bug)
        # makes Xtigervnc treat it as a file name and listen publicly.
        self.assertIn("-localhost \\", flags, "Xtigervnc must be started with -localhost")
        server = read(os.path.join(REPO, "docker", "gateway", "server.py"))
        self.assertIn("0.0.0.0", server, "the gateway must bind every interface (Railway routes to it)")


if __name__ == "__main__":
    unittest.main()
