#!/usr/bin/env python3
"""Lint build-images.yaml and the composite actions it reaches.

Every job in the build-images workflow must be one of:

- privileged: environment is exactly "release" and the if condition requires
  needs.plan.outputs.trusted == 'true';
- unprivileged: permissions is exactly {contents: read} (or {} for the result
  job), it has no environment, and neither the job nor any composite action it
  reaches mentions a credential or login primitive.

Every job that reaches the smoke-test action must check out the caller
repository.

Across the checked workflows, every uses: must be pinned to a 40-character
commit SHA unless it is a local ./ path, and no ":latest" image reference may
appear in the checked workflows or the actions they reach.
"""

import argparse
import json
import os
import re
import sys

import yaml

FORBIDDEN_IN_UNPRIVILEGED = [
    "google-github-actions/",
    "docker/login-action",
    "chainctl",
    "id-token",
    "ACTIONS_ID_TOKEN",
    "gcloud",
    "secrets.",
]
SHA_PIN = re.compile(r"^[0-9a-f]{40}$")
PRIVILEGED_IF = "needs.plan.outputs.trusted == 'true'"
LOCAL_ACTION = re.compile(r"^\./(?:\.factory/)?actions/([A-Za-z0-9_-]+)$")

DEFAULT_WORKFLOWS = [
    ".github/workflows/build-images.yaml",
    ".github/workflows/build-images-selftest.yaml",
    ".github/workflows/plan-images-test.yaml",
]
JOB_WORKFLOW = "build-images.yaml"


def load_yaml(path):
    with open(path, encoding="utf-8") as handle:
        return yaml.safe_load(handle)


def action_files(root, name):
    directory = os.path.join(root, "actions", name)
    if not os.path.isdir(directory):
        return None
    collected = []
    for dirpath, _, filenames in os.walk(directory):
        for filename in sorted(filenames):
            collected.append(os.path.join(dirpath, filename))
    return collected


def scan_text(path, text, errors, scope):
    for token in FORBIDDEN_IN_UNPRIVILEGED:
        if token in text:
            errors.append(f"{scope}: references '{token}' ({path})")


def check_uses(value, where, errors):
    if value.startswith("./"):
        return
    if value.startswith("docker://"):
        if ":latest" in value:
            errors.append(f"{where}: image reference uses :latest ({value})")
        return
    if "@" not in value:
        errors.append(f"{where}: uses is not pinned: {value}")
        return
    ref = value.rsplit("@", 1)[1]
    if not SHA_PIN.match(ref):
        errors.append(f"{where}: uses is not pinned to a 40-hex SHA: {value}")


def walk_uses(node, where, errors):
    if isinstance(node, dict):
        for key, value in node.items():
            if key == "uses" and isinstance(value, str):
                check_uses(value, where, errors)
            else:
                walk_uses(value, where, errors)
    elif isinstance(node, list):
        for item in node:
            walk_uses(item, where, errors)


def reached_actions(root, job_nodes, errors):
    """Return the set of local action names reached from the given nodes, recursively."""
    names = set()
    pending = []

    def collect(node):
        if isinstance(node, dict):
            for key, value in node.items():
                if key == "uses" and isinstance(value, str):
                    match = LOCAL_ACTION.match(value)
                    if match:
                        pending.append(match.group(1))
                else:
                    collect(value)
        elif isinstance(node, list):
            for item in node:
                collect(item)

    collect(job_nodes)
    while pending:
        name = pending.pop()
        if name in names:
            continue
        names.add(name)
        files = action_files(root, name)
        if files is None:
            errors.append(f"composite action not found: actions/{name}")
            continue
        for path in files:
            if path.endswith((".yml", ".yaml")):
                try:
                    document = load_yaml(path)
                except yaml.YAMLError as exc:
                    errors.append(f"{path}: cannot parse ({exc})")
                    continue
                collect(document)
    return names


def check_action_contents(root, names, errors):
    for name in sorted(names):
        for path in action_files(root, name) or []:
            rel = os.path.relpath(path, root)
            with open(path, encoding="utf-8", errors="replace") as handle:
                text = handle.read()
            scan_text(rel, text, errors, f"action {name}")
            if path.endswith((".yml", ".yaml")):
                document = load_yaml(path)
                walk_uses(document, rel, errors)
            if ":latest" in text:
                errors.append(f"{rel}: contains a :latest image reference")


def check_checkout_order(where, job, errors):
    """A caller checkout (no path) must precede the factory checkout (path .factory).

    Checking out the caller after factory cleans the untracked .factory directory.
    """
    caller_index = None
    factory_index = None
    for index, step in enumerate(job.get("steps") or []):
        if not isinstance(step, dict) or not str(step.get("uses", "")).startswith("actions/checkout@"):
            continue
        path = (step.get("with") or {}).get("path")
        if path == ".factory":
            factory_index = index if factory_index is None else factory_index
        elif path is None and caller_index is None:
            caller_index = index
    if factory_index is not None and caller_index is not None and caller_index > factory_index:
        errors.append(f"{where}: caller checkout must precede the factory checkout")


def check_smoke_caller(where, job, names, errors):
    """A job that reaches smoke-test must check out the caller repository."""
    if "smoke-test" not in names:
        return
    for step in job.get("steps") or []:
        if not isinstance(step, dict) or not str(step.get("uses", "")).startswith("actions/checkout@"):
            continue
        if (step.get("with") or {}).get("path") is None:
            return
    errors.append(f"{where}: runs smoke-test without a caller checkout")


def check_job_workflow(root, path, errors):
    document = load_yaml(path)
    rel = os.path.relpath(path, root)
    if "permissions" in document and document["permissions"] not in ({}, None):
        errors.append(f"{rel}: workflow-level permissions must be absent or {{}}")
    jobs = document.get("jobs") or {}
    if not jobs:
        errors.append(f"{rel}: no jobs found")
    job_nodes = []
    for job_id, job in jobs.items():
        where = f"{rel} job {job_id}"
        if not isinstance(job, dict):
            errors.append(f"{where}: job is not a mapping")
            continue
        job_nodes.append(job)
        check_checkout_order(where, job, errors)
        names = reached_actions(root, job, errors)
        check_smoke_caller(where, job, names, errors)
        permissions = job.get("permissions")
        environment = job.get("environment")
        condition = str(job.get("if", ""))
        privileged = environment == "release" and PRIVILEGED_IF in condition
        if privileged:
            if permissions is None or not isinstance(permissions, dict):
                errors.append(f"{where}: privileged job needs explicit permissions")
            elif permissions.get("contents") != "read" or not set(permissions) <= {
                "contents", "id-token", "attestations"
            }:
                errors.append(f"{where}: privileged permissions must be contents: read plus id-token/attestations, found {permissions}")
        else:
            if environment is not None:
                errors.append(f"{where}: unprivileged job must not declare an environment")
            allowed = [{"contents": "read"}]
            if job_id == "result":
                allowed.append({})
            if permissions not in allowed:
                errors.append(f"{where}: unprivileged permissions must be {{contents: read}}, found {permissions}")
            text = json.dumps(job, sort_keys=True)
            scan_text(rel, text, errors, where)
            check_action_contents(root, names, errors)
        text = json.dumps(job, sort_keys=True)
        if "secrets." in text:
            errors.append(f"{where}: references secrets")
        walk_uses(job, f"{rel} job {job_id}", errors)
    return jobs


SELFTEST_WORKFLOW = "build-images-selftest.yaml"
SELFTEST_GRANT = {"contents": "read", "id-token": "write", "attestations": "write"}


def check_selftest_caller(rel, document, errors):
    for job_id, job in (document.get("jobs") or {}).items():
        uses = job.get("uses", "") if isinstance(job, dict) else ""
        if uses.endswith("build-images.yaml"):
            if job.get("permissions") != SELFTEST_GRANT:
                errors.append(f"{rel} job {job_id}: caller must grant exactly {SELFTEST_GRANT}, found {job.get('permissions')}")
            return
    errors.append(f"{rel}: no job calls build-images.yaml")


def check_other_workflow(root, path, errors):
    rel = os.path.relpath(path, root)
    document = load_yaml(path)
    walk_uses(document, rel, errors)
    if os.path.basename(path) == SELFTEST_WORKFLOW:
        check_selftest_caller(rel, document, errors)
    with open(path, encoding="utf-8") as handle:
        if ":latest" in handle.read():
            errors.append(f"{rel}: contains a :latest image reference")
    for name in sorted(reached_actions(root, document, errors)):
        for action_path in action_files(root, name) or []:
            with open(action_path, encoding="utf-8", errors="replace") as handle:
                if ":latest" in handle.read():
                    errors.append(f"{os.path.relpath(action_path, root)}: contains a :latest image reference")


def main(argv):
    script_root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--root", default=script_root, help="repository root holding actions/")
    parser.add_argument("workflows", nargs="*", help="workflow files, relative to --root")
    args = parser.parse_args(argv)
    root = os.path.abspath(args.root)
    workflows = args.workflows or DEFAULT_WORKFLOWS

    errors = []
    checked_jobs = []
    for workflow in workflows:
        path = os.path.join(root, workflow)
        if not os.path.isfile(path):
            errors.append(f"workflow not found: {workflow}")
            continue
        if os.path.basename(path) == JOB_WORKFLOW:
            jobs = check_job_workflow(root, path, errors)
            checked_jobs.extend(sorted(jobs))
        else:
            check_other_workflow(root, path, errors)
            walk_uses(load_yaml(path), workflow, errors)

    if errors:
        for error in errors:
            print(f"::error::{error}", file=sys.stderr)
        return 1
    print(f"lint passed: jobs {', '.join(checked_jobs)}; workflows {', '.join(workflows)}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
