"""Exercise the selector embedded in the reusable workflow, without a checkout."""

import os
from pathlib import Path
import re
import subprocess
import tempfile
import textwrap
import unittest


WORKFLOW = Path(__file__).resolve().parents[2] / ".github/workflows/melange-build.yaml"


class RunnerSelectionTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        workflow = WORKFLOW.read_text()
        selector = workflow.split("  select-runner:\n", 1)[1].split("\n  build:\n", 1)[0]
        match = re.search(r"        run: \|\n((?:          .*\n|\n)+)", selector)
        if not match:
            raise AssertionError("Missing inline runner selector")
        cls.script = textwrap.dedent(match.group(1))

    def select(self, profile, arch):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "output"
            output.touch()
            result = subprocess.run(
                ["bash", "--noprofile", "--norc", "-c", self.script],
                cwd=directory,
                env={
                    "PATH": os.environ["PATH"],
                    "RUNNER_PROFILE": profile,
                    "BUILD_ARCH": arch,
                    "GITHUB_OUTPUT": str(output),
                },
                capture_output=True,
                text=True,
                timeout=5,
            )
            self.assertFalse((Path(directory) / "injected").exists())
            return result, output.read_text()

    def test_supported_profiles_and_architectures(self):
        for profile, arch, runner in (
            ("standard", "x86_64", "ubuntu-24.04"),
            ("standard", "aarch64", "ubuntu-24.04-arm"),
            ("large", "x86_64", "oplabs-ubuntu-x86"),
            ("large", "aarch64", "oplabs-ubuntu-arm"),
        ):
            with self.subTest(profile=profile, arch=arch):
                result, output = self.select(profile, arch)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(output, f"runner={runner}\n")

    def test_rejects_invalid_values_without_runner_output(self):
        for profile, arch in (
            ("", "x86_64"),
            ("standard", ""),
            ("audit-test-runner", "x86_64"),
            ("oplabs-ubuntu-x86", "x86_64"),
            ("standard", "amd64"),
            ("large", "arm64"),
            ("standard", "riscv64"),
            ("Standard", "x86_64"),
            ("standard ", "x86_64"),
            ("standard", "x86_64\n"),
            ("standard:x86_64", ""),
            ("standard\nrunner=audit-test-runner", "x86_64"),
            ("$(touch injected)", "x86_64"),
            ("standard", "`touch injected`"),
            ('standard"; touch injected; #', "x86_64"),
        ):
            with self.subTest(profile=profile, arch=arch):
                result, output = self.select(profile, arch)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("::error::Unsupported runner profile or architecture", result.stdout)
                self.assertEqual(output, "")
