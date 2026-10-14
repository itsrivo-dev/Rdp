#!/usr/bin/env python3
"""Structural checks for the GitHub Actions workflows.

Workflow files have no compiler: a misspelled input, a step without a command,
or a script path that does not exist only shows up when the workflow is meant to
run. For the manually started ``verify-deployment`` workflow that could be weeks
later - on the day someone finally has a public URL to check.

These tests load every workflow and check the parts that fail silently:

  * name, trigger and jobs are present; every job has ``runs-on`` and steps
  * every step has exactly one of ``uses`` / ``run``, and ``uses`` is pinned
  * every ``${{ inputs.X }}`` refers to a declared dispatch input
  * every project script mentioned in a step exists in the repository
  * every workflow declares permissions (least privilege, stated explicitly)
"""

from __future__ import annotations

import os
import re
import unittest

try:
    import yaml
except ImportError:  # pragma: no cover - the static CI job installs PyYAML
    yaml = None

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
WORKFLOW_DIR = os.path.join(REPO, ".github", "workflows")

INPUT_REFERENCE = re.compile(r"\$\{\{\s*inputs\.([A-Za-z0-9_-]+)")
PATH_REFERENCE = re.compile(r"\b((?:tests|scripts|docker)/[A-Za-z0-9_./-]+\.(?:sh|py))\b")


def read(path: str) -> str:
    with open(path, encoding="utf-8") as handle:
        return handle.read()


def trigger_block(document: dict):
    # PyYAML resolves the `on:` key to the boolean True.
    return document.get("on", document.get(True)) or {}


@unittest.skipUnless(yaml, "PyYAML is required: pip install pyyaml")
class WorkflowTests(unittest.TestCase):
    def setUp(self):
        self.files = sorted(
            os.path.join(WORKFLOW_DIR, name)
            for name in os.listdir(WORKFLOW_DIR)
            if name.endswith((".yml", ".yaml"))
        )
        self.assertTrue(self.files, "no workflow files found")

    def test_every_workflow_is_structurally_sound(self):
        for path in self.files:
            name = os.path.basename(path)
            with self.subTest(workflow=name):
                document = yaml.safe_load(read(path))
                self.assertIsInstance(document, dict, name)
                self.assertTrue(document.get("name"), f"{name}: no name")
                self.assertTrue(trigger_block(document), f"{name}: no trigger")
                jobs = document.get("jobs")
                self.assertIsInstance(jobs, dict, f"{name}: no jobs")
                for job_name, job in jobs.items():
                    self.assertIn("runs-on", job, f"{name}:{job_name}")
                    steps = job.get("steps")
                    self.assertIsInstance(steps, list, f"{name}:{job_name}")
                    self.assertTrue(steps, f"{name}:{job_name} has no steps")
                    for index, step in enumerate(steps):
                        label = step.get("name", f"step {index + 1}")
                        has_run, has_uses = "run" in step, "uses" in step
                        self.assertNotEqual(
                            has_run, has_uses,
                            f"{name}:{job_name}: {label} needs exactly one of run/uses",
                        )
                        if has_uses:
                            self.assertRegex(step["uses"], r"^[\w.-]+/[\w.-]+@",
                                             f"{name}:{job_name}: {label} is not pinned")

    def test_dispatch_inputs_are_declared(self):
        for path in self.files:
            name = os.path.basename(path)
            document = yaml.safe_load(read(path))
            declared: set[str] = set()
            for trigger, options in trigger_block(document).items():
                if trigger == "workflow_dispatch" and isinstance(options, dict):
                    declared.update((options.get("inputs") or {}).keys())
            for reference in sorted(set(INPUT_REFERENCE.findall(read(path)))):
                self.assertIn(
                    reference, declared,
                    f"{name} reads inputs.{reference}, which the trigger does not declare",
                )

    def test_referenced_project_scripts_exist(self):
        for path in self.files:
            for reference in sorted(set(PATH_REFERENCE.findall(read(path)))):
                self.assertTrue(
                    os.path.exists(os.path.join(REPO, reference)),
                    f"{os.path.basename(path)} mentions {reference}, which is not in the repository",
                )

    def test_permissions_are_declared_explicitly(self):
        for path in self.files:
            document = yaml.safe_load(read(path))
            self.assertIn("permissions", document, f"{os.path.basename(path)}: no permissions block")
            for job_name, job in document["jobs"].items():
                self.assertIn("permissions", job, f"{os.path.basename(path)}:{job_name}")


if __name__ == "__main__":
    unittest.main()
