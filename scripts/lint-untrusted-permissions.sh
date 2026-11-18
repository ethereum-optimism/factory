#!/usr/bin/env bash
# Checks that the untrusted jobs of build-images.yaml stay read-only and free of
# credentials: the plan, packages, and build jobs declare only contents: read,
# and neither those jobs nor the composite actions they call reference secrets
# or an OIDC token.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKFLOW="${1:-$ROOT/.github/workflows/build-images.yaml}"

python3 - "$WORKFLOW" "$ROOT" <<'PY'
import os
import re
import sys

workflow_path, root = sys.argv[1], sys.argv[2]
untrusted_jobs = ["plan", "packages", "build"]
forbidden = ["secrets.", "id-token"]
errors = []

lines = open(workflow_path, encoding="utf-8").read().splitlines()
jobs = {}
in_jobs = False
current = None
for line in lines:
    if re.match(r"^jobs:\s*$", line):
        in_jobs = True
        continue
    if in_jobs and re.match(r"^\S", line):
        in_jobs = False
    if not in_jobs:
        continue
    match = re.match(r"^  ([A-Za-z0-9_-]+):\s*$", line)
    if match:
        current = match.group(1)
        jobs[current] = []
        continue
    if current is not None:
        jobs[current].append(line)

composite_names = set()
for job in untrusted_jobs:
    if job not in jobs:
        errors.append(f"job {job} is missing from {workflow_path}")
        continue
    body = jobs[job]
    perm_index = None
    for i, line in enumerate(body):
        if re.match(r"^    permissions:", line):
            perm_index = i
            break
    if perm_index is None:
        errors.append(f"job {job} declares no permissions block")
    elif body[perm_index].strip() != "permissions:":
        errors.append(f"job {job} uses an inline permissions value: {body[perm_index].strip()}")
    else:
        entries = []
        for line in body[perm_index + 1:]:
            if line.strip() == "":
                continue
            if not line.startswith("      "):
                break
            entries.append(line.strip())
        if entries != ["contents: read"]:
            errors.append(f"job {job} permissions must be exactly 'contents: read', found {entries}")

    text = "\n".join(body)
    for token in forbidden:
        if token in text:
            errors.append(f"job {job} references '{token}'")
    for line in body:
        match = re.search(r"uses:\s*\./(?:\.factory/)?actions/([A-Za-z0-9_-]+)", line)
        if match:
            composite_names.add(match.group(1))

for name in sorted(composite_names):
    action_dir = os.path.join(root, "actions", name)
    if not os.path.isdir(action_dir):
        errors.append(f"composite action directory not found: actions/{name}")
        continue
    for dirpath, _, filenames in os.walk(action_dir):
        for filename in filenames:
            path = os.path.join(dirpath, filename)
            with open(path, encoding="utf-8", errors="replace") as handle:
                content = handle.read()
            for token in forbidden:
                if token in content:
                    rel = os.path.relpath(path, root)
                    errors.append(f"{rel} references '{token}'")

if errors:
    for error in errors:
        print(f"::error::{error}", file=sys.stderr)
    sys.exit(1)
print(f"untrusted permissions lint passed for jobs {', '.join(untrusted_jobs)} and actions {', '.join(sorted(composite_names))}")
PY
