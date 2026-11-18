# Images catalog (version 2)

`.github/workflows/build-images.yaml` builds and publishes the images a
repository declares in its catalog. The catalog lives at `.github/images.json`
in the calling repository by default. The format is described by
[`schemas/images.v2.schema.json`](../schemas/images.v2.schema.json). A minimal
caller is in [`templates/build-images.yaml`](../templates/build-images.yaml).

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
| `release` | no | Release tag mapping. Defaults: `tag_regex` `^([^/]+)/(v.+)$`, `service_match` 1, `version_match` 2, `publish_tag` `${version}`, `source_ref` `${ref_name}`. |
| `shared_paths` | no | Changed-file patterns that plan every image and package. |
| `packages` | no | Melange packages (see below). |
| `hooks.pre_build` | no | Repository script run during planning. Its stdout must be `KEY=VALUE` lines. The pairs are added to package build environments and to docker build arguments. Any other stdout line fails the plan. |
| `images` | yes | Object keyed by image name. Names match `^[a-z0-9][a-z0-9._-]*$`. |

Patterns: a pattern ending in `/**` matches any file below that directory. Any
other pattern matches exactly one path.

## Packages

Each entry under `packages` describes one melange build. A package is built
once per architecture in `archs`. Untrusted runs build `x86_64` only.

| Field | Default | Meaning |
| --- | --- | --- |
| `config` | `melange/<name>.yaml` | Melange configuration path. |
| `runner_profile` | `standard` | `standard` or `large`. Selects the runner per architecture. |
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

`apko`:

- `needs_packages`: package names whose APK repositories the build uses.
- `configs`: variants, each `{config, tag_suffix}`. A variant with an empty
  `tag_suffix` is the default variant. Only the default variant is smoke
  tested. Without `configs`, `config` (default `apko/<image>.yaml`) is used.

When an image has both builders, `primary` is required. The primary builder
publishes the canonical tags. The other builder publishes tags prefixed with
its name and a dash (for example `apko-<sha>` when docker is primary).

Other image fields:

- `archs`: `amd64`, `arm64`. Defaults to both.
- `paths`: changed-file patterns for pull requests and pushes.
- `smoke`: `commands` (each string split on whitespace into entrypoint and
  arguments), `script` (repository script run with `IMAGE` and `IMAGE_ARCH`),
  `verify_version` (on release tags, a command must print the version).

## Tags

For a builder with prefix `P` (the `tag_prefix` plus the builder prefix where
applicable):

- `P<commit sha>` and `P<sanitized ref>` for docker images, where the sanitized
  ref is the branch or tag name, or the release version on release tags.
- apko variants add their `tag_suffix` after both tags.
- Docker multi-architecture images are merged into a manifest list under those
  tags.

## Trusted and untrusted runs

`actions/fork-context` decides the trust level once per run:

- **Trusted** when the event is `push`, `schedule`, or `workflow_dispatch` and the ref is the
  repository default branch, or the event ref is any tag.
- **Untrusted** for everything else: `pull_request`, `merge_group`, forks,
  and dispatches from other branches.

Untrusted runs:

- plan only affected images and packages (the diff against the base, or the
  full catalog when a shared path or the catalog itself changed);
- build `amd64` images locally and smoke test them;
- build `x86_64` packages;
- run with `contents: read` only, and never reference secrets or an OIDC token.

Trusted runs:

- build and smoke test `amd64` before pushing;
- push by digest per architecture for docker images, and merge a manifest list;
- publish apko images for all catalog architectures in one `apko publish`;
- attest apko images and docker manifest lists;
- smoke test the `arm64` digest on an arm64 runner after publishing;
- run publish jobs in the `environment` input (default `release`).

Release tags `<image>/v<semver>` plan only that image, with the version
exported to packages and checked by `verify_version` smoke tests. A tag that
does not match, or names an image that is not in the catalog, plans nothing
and succeeds.

## Legacy catalogs

A catalog without `version` is read as a legacy `images.json` (docker) and,
when `.github/images.apko.json` exists, merged in memory with it:

- an image in both files becomes a dual-builder image with `docker` primary;
- `melange` becomes `packages`, `needs_melange` becomes `needs_packages`,
  `apko_configs` becomes `configs`, and `nexus_paths` join `paths`;
- `shared_<type>_paths` apply to images whose `type` matches.

Not supported, and rejected with an error: `apko_images`, `groups`, `mode`
values `ko` and `apko` in `images.json`, the `env` field in `images.json`,
`default_runners`, and `runners` on a melange entry. Legacy `images.apko.json`
is read only when the catalog is legacy; a version 2 catalog ignores it.

Legacy apko-only images publish canonical tags (no `apko-` prefix), because
the primary builder rule applies. Consumers that pin the old `apko-` tags need
to read the new tags.

## Tests

`actions/plan-images/plan-images.test.sh` covers normalization, validation,
tag and runner selection, legacy merging, hooks, and change detection.
`scripts/lint-untrusted-permissions.sh` checks the untrusted jobs. Both run in
factory CI.
