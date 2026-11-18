# Images catalog (version 2)

`.github/workflows/build-images.yaml` builds and publishes the images a
repository declares in its catalog. The catalog lives at `.github/images.json`
in the calling repository by default. The format is described by
[`schemas/images.v2.schema.json`](../schemas/images.v2.schema.json). A minimal
caller is in [`templates/build-images.yaml`](../templates/build-images.yaml).

Publishing jobs run in the GitHub environment named `release`, so the calling
repository must define that environment and its protection rules. The workflow
has no environment input.

Publishing authenticates to Google Cloud through the `github-release` workload
identity provider. That provider accepts only jobs that run in the `release`
environment, so pull request and other untrusted runs cannot obtain a
publishing credential.

Require the `result` job of the caller run as the single status check. It fails
when any job failed, and when the plan reported work that neither the build nor
the publish job completed.

## Example

```json
{
  "version": 2,
  "registry": "us-docker.pkg.dev/example-project/example-images",
  "shared_paths": ["go.mod", "go.sum"],
  "packages": {
    "tools": {
      "config": "melange/tools.yaml",
      "runner_profile": "standard",
      "archs": ["x86_64", "aarch64"],
      "source": {"repository": "example-org/tools", "ref": "v1.4.0", "path": "src/tools"},
      "use_gha_cache": true,
      "cache_key_files": ["src/tools/go.sum"]
    }
  },
  "images": {
    "api": {
      "builders": {
        "docker": {"context": ".", "dockerfile": "api/Dockerfile", "target": "api"}
      },
      "paths": ["api/**"],
      "smoke": {"commands": ["api --version"], "verify_version": true}
    },
    "worker": {
      "builders": {
        "apko": {
          "needs_packages": ["tools"],
          "tag_prefix": "apko-",
          "configs": [
            {"config": "apko/worker.yaml"},
            {"config": "apko/worker-dev.yaml", "tag_suffix": "-dev"}
          ]
        }
      },
      "paths": ["worker/**"],
      "smoke": {"commands": ["worker --help"]}
    },
    "gateway": {
      "builders": {
        "docker": {"dockerfile": "gateway/Dockerfile"},
        "apko": {"config": "apko/gateway.yaml"}
      },
      "primary": "docker",
      "paths": ["gateway/**"],
      "smoke": {"commands": ["gateway --help"]}
    }
  }
}
```

## Top level

| Field | Required | Meaning |
| --- | --- | --- |
| `version` | yes | Must be `2`. A catalog without `version` is read as legacy (see below). |
| `registry` | when publishing | Registry prefix, no trailing slash. Trusted runs fail when it is missing and there is something to publish. |
| `tag_prefix` | no | Prefix on every published tag. Letters, digits, dot, dash. |
| `release` | no | Release tag mapping (see below). |
| `shared_paths` | no | Changed-file patterns that plan every image and package. |
| `packages` | no | Melange packages (see below). Names match `^[a-z0-9][a-z0-9._-]*$`. |
| `hooks.pre_build` | no | Repository script run during planning. Its stdout must be `KEY=VALUE` lines, and any other line fails the plan. It runs without `GITHUB_ENV`, `GITHUB_OUTPUT`, `GITHUB_PATH`, `GITHUB_STEP_SUMMARY`, and `GITHUB_STATE` set. The pairs are added to package build environments and to docker build arguments. |
| `images` | yes | Object keyed by image name. Names match `^[a-z0-9][a-z0-9._-]*$`. |

Patterns: a pattern ending in `/**` matches any file below that directory. Any
other pattern matches exactly one path.

### Release tags

A tag `<image>/v<semver>` plans only that image, and its version is passed to
packages and to `verify_version` smoke tests.

The published ref tag is the sanitized full ref name, the same formula the
existing workflows use. For example `svc/v1.2.3` publishes `svc-v1.2.3`.
Sanitizing replaces every character outside `[a-zA-Z0-9.]` with `-`. Set
`release.publish_tag` to change it (for example `${version}` publishes
`v1.2.3`).

Defaults: `tag_regex` `^([^/]+)/(v.+)$`, `service_match` 1, `version_match` 2,
`publish_tag` `${ref_name}`, `source_ref` `${ref_name}`.

A tag that does not match `tag_regex`, or names an image that is not in the
catalog, plans nothing and succeeds. The planner prints a `::notice::` that
names the tag.

## Packages

Each entry under `packages` describes one melange build. A package is built
once per architecture in `archs`. Untrusted runs build `x86_64` only, on the
standard hosted runner regardless of `runner_profile`.

| Field | Default | Meaning |
| --- | --- | --- |
| `config` | `melange/<name>.yaml` | Melange configuration path. |
| `runner_profile` | `standard` | `standard` or `large`. Selects the runner per architecture on trusted runs. |
| `source` | none | Repository checked out before the build, with `repository`, `ref`, `path`. `path` must be a subdirectory, never `.`. Omit `repository` to check out the calling repository. |
| `source_submodules` | `"false"` | `"false"`, `"true"`, or `"recursive"`. |
| `use_gha_cache` | `false` | Restores the melange cache. Saves it only on trusted default-branch runs. |
| `cache_key_files` | `[]` | Files, relative to the workspace, hashed into the cache key. |
| `archs` | `["x86_64", "aarch64"]` | Melange architectures. |
| `cargo_profile` | `{}` | `{trusted, untrusted}` profile names exported to pipelines. |
| `build_env` | `""` | `KEY=VALUE` lines added to the melange environment. |
| `build_version` | `""` | Exported as `GIT_VERSION`. Release tags override it. |

Package artifacts are named `apks-<package>-<arch>`. The package build uses no
secrets and no OIDC token.

## Images and builders

`builders` holds one or both of `docker` and `apko`.

`docker`:

- `mode`: `build` (Dockerfile, default) or `bake` (bake file).
- `context`, `dockerfile`, `target`, `build_args` (object), `bake_file`, `set` (bake variables as `KEY=VALUE` strings).
- `tag_prefix`: see Tags.

`apko`:

- `needs_packages`: package names whose APK repositories the build uses.
- `configs`: variants, each `{config, tag_suffix}`. A variant with an empty
  `tag_suffix` is the default variant. Only the default variant is smoke
  tested. Without `configs`, `config` (default `apko/<image>.yaml`) is used.
- `tag_prefix`: see Tags.

When an image has both builders, `primary` is required. Other image fields:

- `archs`: `amd64`, `arm64`. Defaults to both. Untrusted runs build `amd64` only.
- `paths`: changed-file patterns for pull requests and pushes.
- `smoke`: `commands` (each string split on whitespace into entrypoint and
  arguments), `script` (repository script run with `IMAGE` and `IMAGE_ARCH`),
  `verify_version` (on release tags, a command must print the version).

## Tags

For a builder, the tag prefix is:

- the builder's `tag_prefix` when set;
- otherwise empty for the primary builder, and `<builder>-` (for example
  `apko-`) for the other builder of a dual-builder image.

The full prefix is the top-level `tag_prefix` followed by that value. An
apko-only image that must keep publishing `apko-<sha>` tags sets
`builders.apko.tag_prefix` to `apko-`.

Published tags for a prefix `P`:

- `P<commit sha>` and `P<sanitized ref>`. On release tags the sanitized ref is
  the rendered `publish_tag` (see Release tags).
- apko variants append their `tag_suffix` to both tags.
- Docker images are pushed by digest per architecture, then merged into a
  manifest list under those tags.

## Trusted and untrusted runs

`actions/fork-context` decides the trust level once per run:

- **Trusted** when the event is `push`, `schedule`, or `workflow_dispatch` and the ref is the
  repository default branch, or the event ref is any tag.
- **Untrusted** for everything else: `pull_request`, `pull_request_target`,
  `merge_group`, forks, and dispatches from other branches.

Untrusted runs:

- plan only affected images and packages (the diff against the base, or the
  full catalog when a shared path or the catalog itself changed);
- build `amd64` images locally and smoke test them;
- build `x86_64` packages on the standard hosted runner;
- run with `contents: read` only, and never reference secrets or an OIDC token.

Trusted runs:

- publish with the `release` environment: docker architectures are built
  natively and pushed by digest, apko images are published for all catalog
  architectures in one `apko publish`;
- merge docker manifest lists and attest apko images and manifest lists;
- smoke test every architecture of the pushed digest (amd64 on the standard
  runner, arm64 on the arm runner), pulling by digest.

## Legacy catalogs

A catalog without `version` is read as a legacy `images.json` (docker). When
`.github/images.apko.json` exists, it is merged in memory with that file. If
`images.json` is absent but `images.apko.json` exists, the apko file is read
alone.

- An image in both files becomes a dual-builder image with `docker` primary.
- `melange` becomes `packages`, `needs_melange` becomes `needs_packages`,
  `apko_configs` becomes `configs`, and `nexus_paths` join `paths`.
- `shared_<type>_paths` apply to images whose `type` matches.
- Legacy release tags keep the legacy publish formula: legacy release
  configuration that sets `publish_tag` to `${version}` still publishes
  `v1.2.3`. Set `release.publish_tag` explicitly when converting a catalog.

Not supported, and rejected with an error: `apko_images`, `groups`, `mode`
values `ko` and `apko` in `images.json`, the `env` field in `images.json`,
`default_runners`, and `runners` on a melange entry. A version 2 catalog
ignores `images.apko.json`.

### Migration note: apko tag prefix in legacy catalogs

Legacy apko images get the tag prefix `apko-` when the legacy `images.json`
declares at least one image, so their tags keep the names the old workflow
published (`apko-<sha>`). When only `images.apko.json` exists, the prefix is
empty, and tags are the canonical `<sha>` and `<ref>` tags. When converting to
version 2, set `builders.apko.tag_prefix` explicitly to keep or drop the
prefix.

## Tests

`actions/plan-images/plan-images.test.sh` covers normalization, validation,
tag and runner selection, legacy merging, hooks, notices, and change detection.
`scripts/lint-untrusted-permissions.test.sh` runs the lint against the real
files and against planted violations. Both run in the factory self-test
workflows.
