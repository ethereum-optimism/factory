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
- `actions/detect-changes`, `actions/parse-tag` — legacy composite actions
  retained for compatibility; new consumers should use `actions/plan`.

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

## Non-goals

- Functional end-to-end testing against real cloud backends. The framework
  proves "the image is substitutable" (binary starts, serves its interface,
  returns the expected shape) and stops there.
- Signing and provenance for integration-test runs. Handled by the build
  workflow.
