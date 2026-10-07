"""Exercise the publisher with real ORAS against an offline OCI image layout."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).with_name("publish.sh")
ORAS = shutil.which("oras")
TYPE = "application/vnd.oplabs.release-notes.v1"


@unittest.skipUnless(ORAS, "ORAS is required")
class ReleaseNotesTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.layout = self.root / "layout"
        self.image = "example.test/customer/service:v1"
        self.oras("push", "--artifact-type", "application/vnd.test.image", self.image)
        digest = self.oras("resolve", self.image).strip()
        self.subject = self.image.rsplit(":", 1)[0] + "@" + digest
        self.notes = self.root / "notes with spaces.md"
        self.notes.write_text("# v1.0.0\n\nFixed customer issue.\n", encoding="utf-8")
        self.output = self.root / "output"
        self.summary = self.root / "summary"
        # Only redirect transport to disk; the real CLI handles manifests,
        # content hashing, referrer discovery, and payload retrieval.
        bindir = self.root / "bin"
        bindir.mkdir()
        wrapper = bindir / "oras"
        wrapper.write_text(
            '#!/usr/bin/env bash\nset -euo pipefail\n'
            'command="$1"; shift\n'
            'args=()\n'
            'for arg in "$@"; do\n'
            '  if [[ "$arg" == *@sha256:* ]]; then arg="${arg##*@}"; fi\n'
            '  args+=("$arg")\n'
            'done\n'
            'exec "$REAL_ORAS" "$command" --oci-layout-path "$TEST_LAYOUT" "${args[@]}"\n'
        )
        wrapper.chmod(0o755)
        self.env = dict(
            os.environ,
            PATH=str(bindir) + os.pathsep + os.environ["PATH"],
            REAL_ORAS=ORAS,
            TEST_LAYOUT=str(self.layout),
            RELEASE_NOTES_IMAGE=self.subject,
            RELEASE_NOTES_FILE=str(self.notes),
            GITHUB_OUTPUT=str(self.output),
            GITHUB_STEP_SUMMARY=str(self.summary),
        )

    def oras(self, command, *args):
        args = [a.split("@", 1)[1] if "@sha256:" in a else a for a in args]
        return subprocess.check_output(
            [ORAS, command, "--oci-layout-path", str(self.layout), *args], text=True
        )

    def publish(self, **overrides):
        return subprocess.run(
            ["bash", str(SCRIPT)], env=dict(self.env, **overrides),
            text=True, capture_output=True,
        )

    def test_round_trip(self):
        result = self.publish()
        self.assertEqual(result.returncode, 0, result.stderr)
        reference = self.output.read_text().strip().removeprefix("reference=")
        manifest = json.loads(self.oras("manifest", "fetch", reference))
        self.assertEqual(manifest["subject"]["digest"], self.subject.split("@")[1])
        self.assertEqual(manifest["artifactType"], TYPE)
        self.assertEqual(manifest["layers"][0]["mediaType"], "text/markdown")
        found = json.loads(self.oras("discover", "--format", "json", "--artifact-type", TYPE, self.subject))
        self.assertIn(reference.split("@")[1], [r["digest"] for r in found["referrers"]])
        destination = self.root / "download"
        self.oras("pull", "-o", str(destination), reference)
        self.assertEqual((destination / "RELEASE_NOTES.md").read_bytes(), self.notes.read_bytes())
        self.assertIn(reference, self.summary.read_text())

    def test_rejects_tag_and_invalid_digest(self):
        for image in (self.image, "example.test/service@sha256:bad"):
            with self.subTest(image=image):
                self.assertNotEqual(self.publish(RELEASE_NOTES_IMAGE=image).returncode, 0)
        self.assertFalse(self.output.exists())

    def test_rejects_missing_empty_and_directory(self):
        empty = self.root / "empty.md"
        empty.touch()
        for path in (self.root / "missing.md", empty, self.root):
            with self.subTest(path=path):
                self.assertNotEqual(self.publish(RELEASE_NOTES_FILE=str(path)).returncode, 0)
        self.assertFalse(self.output.exists())

    def test_failed_upload_does_not_report_success(self):
        result = self.publish(RELEASE_NOTES_IMAGE="example.test/service@sha256:" + "0" * 64)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.output.exists())


if __name__ == "__main__":
    unittest.main()
