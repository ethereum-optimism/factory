# factory

GitHub CI workflows and composite actions to build container artifacts securely
and validate them with service-owned integration tests.

## What's here

- `actions/plan` — reads a consumer repo's `.github/images.json`, decides which
  images to build, and emits a matrix consumable by the build and
  integration-test workflows.
- `.github/workflows/docker.yaml` — reusable build workflow with `build`,
  `bake`, and `ko` modes. Pushes by digest, merges a multi-arch manifest, and
  attests build provenance.
- `.github/workflows/integration-test.yaml` — reusable integration-test
  workflow. Runs one or more service-owned test suites against a built image,
  with optional per-suite kind clusters.
- `.github/workflows/agent-approval-check.yaml`: reusable workflow. Reports the
  `agent-approval-check` status: pull requests opened by agent accounts need two
  distinct human approvals.
- `.github/workflows/policy-bot-policy.yaml`: reusable workflow. Checks the
  caller's policy-bot `.policy.yml` with the policy-bot v1.42.1 policy package
  and the approval gate invariants, and optionally that it equals the rendering
  of a values file. See [actions/policy-bot-policy](actions/policy-bot-policy/README.md).
- `.github/workflows/goreleaser.yaml`: reusable GoReleaser release workflow. Runs
  `goreleaser release` for a tag and attests build provenance for the checksums
  of the produced artifacts. See [GoReleaser release](#goreleaser-release).
- `.github/workflows/renovate.yaml` — reusable self-hosted Renovate workflow.
  `renovate-config.json` — shared CVE-only Renovate baseline preset. See
  [Renovate](#renovate).
- `actions/install-op-apko` and `actions/install-op-melange`: install pinned
  op-apko and op-melange releases on linux/amd64, linux/arm64 and darwin/arm64
  runners. Each release archive is checked against a pinned sha256. See
  [Installing op-apko and op-melange](#installing-op-apko-and-op-melange).
- `actions/parse-tag`: legacy composite action retained for compatibility;
  new consumers should use `actions/plan`.
- `actions/agent-approval-check`: dependency-free approval gate for pull
  requests opened by agent accounts. Requires distinct write-capable human
  approvals and publishes the `agent-approval-check` commit status.
- `actions/release-notes` — publishes customer-facing Markdown as an OCI 1.1
  attachment to an image digest. Customers can retrieve the notes using their
  Artifact Registry access. See [publishing and downloading release notes](actions/release-notes/README.md).
- `.github/workflows/release-notes.yaml` — automatically attaches the calling
  repository's GitHub Release notes to its published image. The standard OP Labs
  setup needs only the image path; authentication, tag mapping, and waiting for
  the image build are handled centrally. See the [minimal caller](actions/release-notes/README.md#automatic-publishing-from-github-releases-recommended).

## Unified image builds

`.github/workflows/build-images.yaml` is a reusable workflow that builds and
publishes the Dockerfile and apko images declared in a repository's catalog.
The catalog format is in [docs/images-catalog.md](docs/images-catalog.md), and
[templates/build-images.yaml](templates/build-images.yaml) is a minimal caller.

Pin the workflow by full commit SHA and pass no secrets:

```yaml
jobs:
  build-images:
    permissions:
      contents: read
      id-token: write
      attestations: write
    uses: ethereum-optimism/factory/.github/workflows/build-images.yaml@0000000000000000000000000000000000000000
```

Replace the placeholder with the factory commit SHA. Publishing needs a GitHub
environment named `release` in the calling repository, and it authenticates
through the `github-release` workload identity provider, which accepts only jobs
that run in that environment. Require the `result` job as the status check.

The run is either trusted or untrusted, decided once by
`actions/fork-context`:

- Trusted: a push, schedule, or dispatch on the default branch, or a tag push.
  A push plans the images its diff affects, a schedule plans every image, and
  a dispatch plans every image or only its `target`. These runs publish,
  attest, and smoke test every architecture of the pushed digest.
- Untrusted: pull requests, merge groups, forks, and dispatches from other
  branches. These runs plan only the affected images, build `amd64` images and
  `x86_64` packages on the runner their `runner_profile` selects, and smoke test
  them. They have `contents: read` only and no access to secrets or an OIDC
  token, except the `fetch-apks` job described below.

When the catalog names lock files, the `fetch-apks` job
(`actions/fetch-apks`) downloads the packages and indexes they pin from the
catalog's `apk_registry` into an apko cache layout, verifies every package
against the whole-file sha256 in its lock, and uploads the result as the
`apk-cache` artifact. It is the only job outside the `release` environment that
may hold `id-token: write`, used to exchange the OIDC token for a registry token
when `apk_registry.chainguard_identity` is set (chainctl from
`actions/install-chainctl`, pinned by sha256). It reads lock files as data and
runs only factory code. See Lock files in the catalog reference.

The planner is `actions/plan-images`. The step actions are
`actions/build-packages`, `actions/stage-packages`, `actions/build-image`,
`actions/smoke-test`, `actions/local-registry`, `actions/publish-image`, and
`actions/promote-image`. Trusted runs build into a local staging registry,
smoke test the staged digest, and only then copy that exact digest to the
registry, verifying it after the copy. Published digests get a build
provenance attestation and an SPDX SBOM attestation, and the workflow output
`published` lists every published image and digest for follow-up jobs such as
scanning. Packages are built with
op-melange from `actions/install-op-melange`, so package SBOMs list the Go
modules compiled into Go binaries as `pkg:golang` purls. apko runs in the
pinned Wolfi SDK image with the op-apko binary from `actions/install-op-apko`
mounted read-only over `/usr/bin/apko`. The self-test workflow
`.github/workflows/build-images-selftest.yaml` runs the untrusted path on every
pull request against the fixtures in `test/fixtures/`, and
`scripts/lint-untrusted-permissions.sh` checks the permission and credential
rules of the workflow and the actions it reaches, including that the
`fetch-apks` job runs no repository script or action.

## GoReleaser release

`.github/workflows/goreleaser.yaml` runs GoReleaser for a release tag and
attests build provenance for the artifacts listed in the `Checksum` entry of
`artifacts.json`. Pin the workflow by full commit SHA:

```yaml
on:
  push:
    tags:
      - "v*"

jobs:
  release:
    permissions:
      contents: write
      id-token: write
      attestations: write
    uses: ethereum-optimism/factory/.github/workflows/goreleaser.yaml@0000000000000000000000000000000000000000
    with:
      tag: ${{ github.ref_name }}
    secrets:
      GORELEASER_KEY: ${{ secrets.GORELEASER_KEY }}
```

Replace the placeholder with the factory commit SHA. The job runs in the
GitHub environment named by the `environment` input (default `goreleaser`) in the
calling repository, so that environment must hold the `GORELEASER_KEY` secret. Keep
it separate from the `release` environment used for image publishing.
The calling repository's mise configuration must provide `goreleaser`, or the
`mise-install-args` input must name it.


## Installing op-apko and op-melange

`actions/install-op-apko` and `actions/install-op-melange` install the
op-apko release from `ethereum-optimism/apko` and the op-melange release from
`ethereum-optimism/melange`. Each action pins one version and one sha256 per
platform, downloads the release archive over HTTPS, verifies the sha256 before
extracting, adds the binary to `PATH`, and fails unless `<binary> version`
reports the pinned version. Supported runners are linux/amd64, linux/arm64 and
darwin/arm64; any other platform fails.

Pin the actions by full commit SHA:

```yaml
jobs:
  build:
    runs-on: ubuntu-24.04
    permissions:
      contents: read
    steps:
      - uses: ethereum-optimism/factory/actions/install-op-apko@0000000000000000000000000000000000000000
      - uses: ethereum-optimism/factory/actions/install-op-melange@0000000000000000000000000000000000000000
      - run: |
          op-apko version
          op-melange version
```

Replace the placeholders with the factory commit SHA. The actions take no
inputs and use no token, so the job needs no permissions beyond
`contents: read`. Each action sets the output `path` to the absolute path of the
installed binary.

To bump a version, run `scripts/bump-op-tool.sh <apko|melange> <tag>`. It
requires the release to be immutable, runs `gh release verify`, and checks every
archive with `gh release verify-asset` and `gh attestation verify` against the
factory GoReleaser workflow and the tag. It then prints the `env` block for the
action. The `install-op-tools tests` workflow repeats this check for the pinned
values on every change.

To install a release locally on an Apple silicon Mac:

```sh
tool=apko
tag=v1.5.3-op.6
asset="op-${tool}_${tag#v}_darwin_arm64.tar.gz"
gh release download "$tag" --repo "ethereum-optimism/${tool}" --pattern "$asset"
gh attestation verify "$asset" \
  --repo "ethereum-optimism/${tool}" \
  --signer-workflow ethereum-optimism/factory/.github/workflows/goreleaser.yaml \
  --source-ref "refs/tags/${tag}" \
  --deny-self-hosted-runners
tar -xzf "$asset" "op-${tool}"
./op-${tool} version
```

Use `tool=melange` and `tag=v0.66.0-op.2` for op-melange.

## `images.json`

Consumer repos declare their images in `.github/images.json`:

```json
{
  "shared_paths": ["go.mod", "go.sum"],
  "shared_ko_paths": ["common/**"],
  "images": {
    "my-service": {
      "mode": "ko",
      "type": "ko",
      "registry": "us-docker.pkg.dev/my-project/my-repo",
      "gcp_project_id": "my-project",
      "ko_working_directory": "my-service",
      "ko_importpath": "./cmd",
      "paths": ["my-service/**"],
      "tests": ["smoke", "parity"]
    }
  }
}
```

Per-image fields are passed through to `docker.yaml` as inputs. Two fields are
interpreted by `actions/plan` itself:

- `paths` — PR-diff globs used to decide whether this image is affected by the
  change. Stripped from the emitted matrix entry.
- `tests` — optional array of integration-test suite names. Propagated to the
  matrix entry as a normalized array (defaults to `[]`). Consumers pass this
  to `integration-test.yaml`.

Top-level fields:

- `shared_paths` — any match triggers a full rebuild of every image.
- `shared_<type>_paths` — any match triggers a rebuild of every image whose
  per-image `type` equals `<type>` (e.g. `shared_ko_paths` for `type: "ko"`).

## Integration-test contract

A service opts into integration tests by committing a `tests/` tree at the
root of its build context:

```
<build-context>/
  tests/
    smoke/
      run.sh          # required entrypoint
      kind            # optional marker; if present, provision a kind cluster
      ...             # manifests, fixtures, helper scripts
    parity/
      run.sh
    <custom>/
      run.sh
```

Each suite's `run.sh` is invoked by the reusable workflow under a fixed
environment-variable contract:

| Variable | Meaning |
|---|---|
| `IMAGE` | Fully-qualified image under test (`registry/name:tag` or `registry/name@sha256:...`). Already pulled into the runner's docker daemon, and loaded into the kind cluster if the suite opted in. |
| `REFERENCE_IMAGE` | Optional reference image (e.g. the current `:main` build) for parity suites. Pulled and loaded alongside `IMAGE` when the caller passes `reference_image`. |
| `KIND_CLUSTER` | Name of the kind cluster when the suite opted in via the `kind` marker file; otherwise empty. The kubeconfig context is `kind-<KIND_CLUSTER>`. |
| `ARTIFACTS_DIR` | Writable directory the suite can write logs, diffs, SBOMs, and reports into. Uploaded as a GitHub Actions artifact regardless of suite outcome. |

Exit `0` = pass. Any non-zero exit = fail. No other coupling to CI.

### Calling the integration-test workflow

After building an image with `docker.yaml`, pass the same matrix entry to
`integration-test.yaml`:

```yaml
jobs:
  plan:
    runs-on: ubuntu-latest
    outputs:
      matrix_json: ${{ steps.plan.outputs.matrix_json }}
      has_builds: ${{ steps.plan.outputs.has_builds }}
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0
      - id: plan
        uses: ethereum-optimism/factory/actions/plan@main

  build:
    needs: plan
    if: needs.plan.outputs.has_builds == 'true'
    strategy:
      matrix:
        include: ${{ fromJson(needs.plan.outputs.matrix_json) }}
    uses: ethereum-optimism/factory/.github/workflows/docker.yaml@main
    with:
      mode: ${{ matrix.mode }}
      registry: ${{ matrix.registry }}
      image_name: ${{ matrix.image_name }}
      gcp_project_id: ${{ matrix.gcp_project_id }}
      tag: ${{ matrix.tag }}
      # ...pass through the rest of the matrix fields as needed

  integration-test:
    needs: [plan, build]
    if: needs.plan.outputs.has_builds == 'true'
    strategy:
      matrix:
        include: ${{ fromJson(needs.plan.outputs.matrix_json) }}
    uses: ethereum-optimism/factory/.github/workflows/integration-test.yaml@main
    with:
      image: ${{ matrix.registry }}/${{ matrix.image_name }}:${{ github.sha }}
      image_name: ${{ matrix.image_name }}
      registry: ${{ matrix.registry }}
      gcp_project_id: ${{ matrix.gcp_project_id }}
      suites: ${{ toJson(matrix.tests) }}
```

Callers that do not care about the plan action can invoke
`integration-test.yaml` directly with a hand-written `suites` JSON array.

### Suite matrix behaviour

- Each suite is a separate matrix job, so failures are isolated and suites run
  in parallel.
- `fail-fast` is disabled, so a failing smoke suite does not cancel a running
  parity suite.
- Artifacts are uploaded per suite as
  `integration-<image_name>-<suite>-<run_id>-<run_attempt>`.

### Kind-compat patterns library

Reusable shims for services that want to run under kind without reaching into
real cloud backends. Each pattern is a small, copy-pasteable chunk that lives
in the service's suite directory.

#### GCP metadata shim

For services that expect a GCE metadata endpoint at startup, set these env
vars in the pod spec to dummy values so the pod can start under kind without
reaching a real metadata server:

```yaml
env:
  - name: GCP_PROJECT_ID
    value: kind-test
  - name: GCP_ZONE
    value: us-central1-a
  - name: GCE_METADATA_HOST
    value: 169.254.169.254.nip.io
```

## Tag format

Release tags are `<image_name>/v<semver>`, e.g. `my-service/v1.2.3`. Repos
with a single image in `images.json` may use a bare `v<semver>` tag. `plan`
rejects malformed tags and tags that do not match any image in the config.

## Renovate

Shared self-hosted Renovate delivery: a reusable workflow plus a CVE-only
config baseline, so each consumer repo carries only a thin caller and a thin
`renovate.json`.

- `.github/workflows/renovate.yaml` reusable workflow (`workflow_call`) that
  mints a short-lived Renovate token through the token exchange service and
  runs the Renovate engine against the calling repo. Execution stays in our
  infra.
- `renovate-config.json`: the org baseline preset. Disables all generic
  version updates and raises PRs only for GitHub + OSV vulnerability advisories
  (CVE-only). npm major updates are blocked, including vulnerability fixes, so
  a CVE whose only fix is a new major needs a manual upgrade. Consume it from a
  repo's `renovate.json` via `extends`.

The `schedule` / `workflow_dispatch` triggers live in each consumer's caller
(a reusable workflow cannot own a `schedule`). The caller grants `id-token:
write` to the job and passes the `NOVE_RENOVATE_URL` secret, the host of the
token exchange service without scheme (no `https://`). The workflow uses the
octo-sts action against that host to exchange the job's OIDC token for a
Renovate token.

```yaml
# .github/workflows/renovate.yaml in each consumer repo
name: Renovate
on:
  schedule:
    - cron: "0 6 * * *" # daily 06:00 UTC
  workflow_dispatch:
    inputs:
      logLevel:
        type: string
        default: "info"
      dryRun:
        type: boolean
        default: false
jobs:
  renovate:
    permissions:
      contents: read
      id-token: write
    uses: ethereum-optimism/factory/.github/workflows/renovate.yaml@<pinned-sha>
    secrets:
      NOVE_RENOVATE_URL: ${{ secrets.NOVE_RENOVATE_URL }}
    with:
      logLevel: ${{ inputs.logLevel || 'info' }}
      dryRun: ${{ inputs.dryRun || false }}
```

The token exchange service checks the calling workflow's OIDC claims against a
trust policy that each consumer repo commits at
`.github/chainguard/renovate.sts.yaml`. Replace `<repo>` and `<default-branch>`
with the consumer's repository name and default branch:

```yaml
# .github/chainguard/renovate.sts.yaml in each consumer repo
issuer: https://token.actions.githubusercontent.com
subject: repo:ethereum-optimism/<repo>:ref:refs/heads/<default-branch>
audience: <token exchange service host>
claim_pattern:
  repository: ethereum-optimism/<repo>
  ref: refs/heads/<default-branch>
  event_name: (schedule|workflow_dispatch)
  workflow_ref: ethereum-optimism/<repo>/\.github/workflows/renovate\.yaml@refs/heads/<default-branch>
  job_workflow_ref: ethereum-optimism/factory/\.github/workflows/renovate\.yaml@[0-9a-f]{40}
permissions:
  contents: write
  pull_requests: write
  issues: write
  checks: read
  statuses: read
  vulnerability_alerts: read
```

```json
// renovate.json in each consumer repo: extend the baseline, then add any
// repo-specific tweaks (grouping, extra labels, etc.)
{
  "$schema": "https://docs.renovatebot.com/renovate-schema.json",
  "extends": ["github>ethereum-optimism/factory:renovate-config"]
}
```

## Non-goals

- Functional end-to-end testing against real cloud backends. The framework
  proves "the image is substitutable" (binary starts, serves its interface,
  returns the expected shape) and stops there.
- Signing and provenance for integration-test runs. Handled by the build
  workflow.

## policy-bot policy check

`actions/policy-bot-policy` renders a policy-bot `.policy.yml` from a values
file and checks it. Call the reusable workflow on pull requests that touch the
policy, pinned by full commit SHA:

```yaml
name: policy-bot-policy

on:
  pull_request:
    paths:
      - .policy.yml
      - .github/policy-bot-values.yml
      - .github/workflows/policy-bot-policy.yaml

permissions:
  contents: read

jobs:
  check:
    uses: ethereum-optimism/factory/.github/workflows/policy-bot-policy.yaml@0000000000000000000000000000000000000000
    with:
      values: .github/policy-bot-values.yml
```
