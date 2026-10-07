"""Execute the reusable workflow's Python steps with GitHub/registry responses."""

import contextlib
import io
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import yaml


WORKFLOW = Path(__file__).resolve().parents[2] / ".github/workflows/release-notes.yaml"
STEPS = yaml.safe_load(WORKFLOW.read_text())["jobs"]["publish"]["steps"]


def script(step_id):
    step = next(step for step in STEPS if step.get("id") == step_id)
    return step["run"].split("<<'PY'\n", 1)[1].rsplit("\nPY", 1)[0]


class ReleaseWorkflowTest(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)
        self.output = self.root / "output"
        self.env = {
            "IMAGE": "us-docker.pkg.dev/oplabs-tools-artifacts/internal-images/op-monitorism",
            "RELEASE_REPOSITORY": "ethereum-optimism/monitorism",
            "RELEASE_TAG": "op-monitorism/v0.0.13",
            "IMAGE_TAG": "",
            "WAIT_SECONDS": "900",
            "RUNNER_TEMP": str(self.root),
            "GITHUB_OUTPUT": str(self.output),
            "GITHUB_STEP_SUMMARY": str(self.root / "summary"),
            "TAGGED_IMAGE": "us-docker.pkg.dev/oplabs-tools-artifacts/internal-images/op-monitorism:v0.0.13",
        }
        self.release = {
            "tagName": self.env["RELEASE_TAG"], "isDraft": False,
            "body": "# Release\r\n\r\nFixes `commands` and $variables — café.\r\n",
        }

    def execute(self, step_id, responses, **env):
        with patch.dict(os.environ, dict(self.env, **env)), \
                patch("subprocess.run", side_effect=responses) as run, \
                contextlib.redirect_stdout(io.StringIO()):
            exec(compile(script(step_id), str(WORKFLOW), "exec"), {})
        return run

    def prepare(self, **env):
        return self.execute("release", [subprocess.CompletedProcess([], 0, json.dumps(self.release))], **env)

    def outputs(self):
        return dict(line.split("=", 1) for line in self.output.read_text().splitlines())

    def test_namespaced_release_preserves_notes_and_uses_caller(self):
        run = self.prepare()
        outputs = self.outputs()
        self.assertEqual(outputs["tagged_image"], self.env["TAGGED_IMAGE"])
        self.assertEqual(Path(outputs["file"]).read_bytes(), self.release["body"].encode())
        args = run.call_args.args[0]
        self.assertEqual(args[args.index("--repo") + 1], "ethereum-optimism/monitorism")

    def test_bare_release_and_explicit_apko_tag(self):
        self.release["tagName"] = "v1.2.3"
        self.prepare(RELEASE_TAG="v1.2.3")
        self.assertTrue(self.outputs()["tagged_image"].endswith(":v1.2.3"))
        self.prepare(RELEASE_TAG="v1.2.3", IMAGE_TAG="apko-v1.2.3")
        self.assertTrue(self.outputs()["tagged_image"].endswith(":apko-v1.2.3"))

    def test_rejects_ambiguous_or_invalid_targets_before_api_call(self):
        for env in (
            {"RELEASE_TAG": ""}, {"RELEASE_TAG": "-bad"},
            {"RELEASE_TAG": "other-service/v1.2.3"},
            {"IMAGE": self.env["IMAGE"] + ":latest"},
            {"IMAGE": self.env["IMAGE"] + "@sha256:" + "a" * 64},
            {"IMAGE_TAG": "value\ninjected=output"},
            {"WAIT_SECONDS": "-1"}, {"WAIT_SECONDS": "1801"},
            {"WAIT_SECONDS": "nan"},
        ):
            with self.subTest(env=env), self.assertRaises(SystemExit):
                self.execute("release", [], **env)
        self.assertFalse(self.output.exists())

    def test_rejects_draft_mismatched_and_empty_releases(self):
        for change in ({"isDraft": True}, {"tagName": "v9.9.9"}, {"body": " \n\t"}, {"body": None}):
            with self.subTest(change=change), self.assertRaises(SystemExit):
                response = dict(self.release, **change)
                self.execute("release", [subprocess.CompletedProcess([], 0, json.dumps(response))])
        self.assertFalse(self.output.exists())

    def test_missing_github_release_fails(self):
        with self.assertRaises(subprocess.CalledProcessError):
            self.execute("release", [subprocess.CalledProcessError(1, "gh")])
        self.assertFalse(self.output.exists())

    def test_resolve_waits_for_build_then_pins_digest(self):
        digest = "sha256:" + "a" * 64
        with patch("time.sleep") as sleep:
            run = self.execute("resolve", [
                subprocess.CompletedProcess([], 1, "", "manifest unknown: not found"),
                subprocess.CompletedProcess([], 0, digest + "\n", ""),
            ])
        self.assertEqual(run.call_count, 2)
        sleep.assert_called_once_with(15)
        self.assertEqual(self.outputs()["image"], self.env["IMAGE"] + "@" + digest)
        self.assertIn("/oplabs-tools-artifacts/us/internal-images/op-monitorism/" + digest,
                      self.outputs()["console_url"])

    def test_resolve_fails_immediately_on_auth_and_other_errors(self):
        for error in ("403 denied: not found", "401 unauthorized", "TLS certificate error"):
            with self.subTest(error=error), patch("time.sleep") as sleep:
                with self.assertRaises(SystemExit):
                    self.execute("resolve", [subprocess.CompletedProcess([], 1, "", error)])
                sleep.assert_not_called()
        self.assertFalse(self.output.exists())

    def test_resolve_timeout_and_bad_digest_do_not_publish(self):
        for response in (
            subprocess.CompletedProcess([], 1, "", "404 not found"),
            subprocess.CompletedProcess([], 0, "not-a-digest\n", ""),
        ):
            with self.subTest(response=response), self.assertRaises(SystemExit):
                self.execute("resolve", [response], WAIT_SECONDS="0")
        self.assertFalse(self.output.exists())


if __name__ == "__main__":
    unittest.main()
