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
other pattern matches exactly one path. A pattern starting with `!` is a
negative pattern that excludes the paths it matches (`!docs/**`,
`!svc/README.md`). A changed file matches a list of patterns when it matches at
least one positive pattern and no negative pattern. A file under only a negated
path therefore selects nothing, and a change set that mixes a negated file with
a positive one still selects through the positive file. A list with only
negative patterns selects nothing. This applies to `paths` and `shared_paths`.

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

On a release tag the planner sets `VERSION` to the tag's version (for example
`v1.2.3`) for the tagged image. In `build` mode the value is added to
`build_args`, and in `ko` mode it is added to `env`. Either one replaces a
`VERSION` entry from the catalog for that run. `bake` mode does not read
`build_args`, so it gets no `VERSION`. Runs that are not release tags are
unchanged, and catalog values pass through as before.

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
| `runner_profile` | `standard` | `standard` or `large`. Selects the runner per architecture on trusted runs. Builders take the same key, see Images and builders. |
| `source` | none | Repository checked out before the build, with `repository`, `ref`, `path`. `path` must be a subdirectory, never `.`. Omit `repository` to check out the calling repository. |
| `source_submodules` | `"false"` | `"false"`, `"true"`, or `"recursive"`. Submodules of the `source` checkout. |
| `submodules` | `false` | `false`, `true`, or `"recursive"`. Submodules of the calling repository checkout. Only valid when `source` is omitted. Public submodules over https are fetched without credentials. A private submodule needs the app-token mechanism on trusted runs only, and such a package must not depend on it in untrusted runs. |
| `use_gha_cache` | `false` | Restores the melange cache. Saves it only on trusted default-branch runs. |
| `cache_key_files` | `[]` | Files, relative to the workspace, hashed into the cache key. |
| `archs` | `["x86_64", "aarch64"]` | Melange architectures. |
| `cargo_profile` | `{}` | `{trusted, untrusted}` profile names exported to pipelines. |
| `build_env` | `""` | `KEY=VALUE` lines added to the melange environment. |
| `build_version` | `""` | Exported as `GIT_VERSION`. Release tags override it. |

A `source` with `repository` set to the calling repository, `path` `"."`, and no `ref` is the calling repository checkout. It plans as an omitted `source`, and its `source_submodules` maps to `submodules`. Legacy v1 catalogs follow the same rule. A `source` with `path` `"."` for any other repository is rejected.

Package artifacts are named `apks-<package>-<arch>`. The package build uses no
secrets and no OIDC token.

## Images and builders

`builders` holds one or both of `docker` and `apko`.

`docker`:

- `mode`: `build` (Dockerfile, default), `bake` (bake file), or `ko` (Go package built with ko).
- `context`, `dockerfile`, `target`, `build_args` (object), `bake_file`, `set` (bake variables as `KEY=VALUE` strings).
- `tag_prefix`: see Tags.
- `archs`: `amd64`, `arm64`. Overrides the image `archs` for this builder only.
- `smoke`: same fields as the image `smoke`. Overrides it for this builder only, see Smoke per builder.
- `runner_profile`: `standard` (default) or `large`, as for packages. Selects
  the runner of this builder's publish legs on trusted runs, per architecture.
  An apko or ko builder publishes in one leg, which uses the amd64 runner of the
  profile. Untrusted runs ignore it and use the standard runner.
- `events`: contexts in which the builder is planned. See Builder events.

ko mode fields (`dockerfile`, `target`, `build_args`, `bake_file`, and `set` do
not apply to ko):

- `context`: the Go module directory, relative to the repository root. ko runs from it.
- `importpath`: the Go package to build, relative to `context` (default `./cmd`).
- `ko_config`: a ko configuration file, relative to the repository root, for
  example `.ko.yaml`. Empty (the default) uses ko's own defaults. The base
  image comes from `defaultBaseImage` in that file, as before.
- `go_version_file`: the `go.mod` that selects the Go toolchain, relative to the
  repository root (default `<context>/go.mod`).
- `ldflags`: array of `go build` ldflags values. Each entry is passed as one
  `--ldflags` value. ko splits a value on commas, so entries must not contain commas.
- `env`: array of `KEY=VALUE` strings exported for the ko build. The pairs from
  `hooks.pre_build` are exported too, before these.

Untrusted runs build ko images for `linux/amd64` into a tarball with
`--push=false`, load it into the Docker daemon, and smoke test it. The build
uses no registry login and no credentials. ko pulls its base image anonymously,
the same way a Dockerfile pulls `FROM`.

`apko`:

- `needs_packages`: package names whose APK repositories the build uses.
- `configs`: variants, each `{config, tag_suffix}`. A variant with an empty
  `tag_suffix` is the default variant. Only the default variant is smoke
  tested. Without `configs`, `config` (default `apko/<image>.yaml`) is used.
- `tag_prefix`: see Tags.
- `archs`: `amd64`, `arm64`. Overrides the image `archs` for this builder only.
- `smoke`: same fields as the image `smoke`. Overrides it for this builder only, see Smoke per builder.
- `runner_profile`: `standard` (default) or `large`, as for packages. Selects
  the runner of this builder's publish legs on trusted runs, per architecture.
  An apko or ko builder publishes in one leg, which uses the amd64 runner of the
  profile. Untrusted runs ignore it and use the standard runner.
- `events`: contexts in which the builder is planned. See Builder events.

When an image has both builders, `primary` is required. Other image fields:

- `archs`: `amd64`, `arm64`. Defaults to both. Each builder uses its own `archs` when set, otherwise these. Untrusted runs build `amd64` only.
- `paths`: changed-file patterns for pull requests and pushes.
- `smoke`: `commands` (each string split on whitespace into entrypoint and
  arguments), `script` (repository script run with `IMAGE` and `IMAGE_ARCH`),
  `verify_version` (on release tags, a command must print the version).

Resolution order for each builder's architectures: the builder's `archs`, then
the image `archs`, then both architectures. Example: an image still built with
Docker on amd64 only, while apko already publishes amd64 and arm64:

```json
"widget": {
  "builders": {
    "docker": {"dockerfile": "Dockerfile", "archs": ["amd64"]},
    "apko": {"config": "apko/widget.yaml"}
  },
  "primary": "docker",
  "smoke": {"commands": ["widget --version"]}
}
```

Smoke per builder: a builder's `smoke` replaces the image `smoke` entirely for
that builder, with no merging of fields. Resolution: the builder's `smoke`, else
the image `smoke`, else no smoke. An empty object (`{}` or `{"commands": []}`)
disables smoke for that builder only. Example: the apko image puts `mytool` on
PATH while the Dockerfile image ships `/bin/tool`:

```json
"widget": {
  "builders": {
    "docker": {"dockerfile": "Dockerfile", "smoke": {"commands": ["/bin/tool --version"]}},
    "apko": {"config": "apko/widget.yaml", "smoke": {"commands": ["mytool --version"]}}
  },
  "primary": "docker"
}
```

### Builder events

`events` is an array of contexts. Each value is one of:

- `pull_request`: pull requests, and merge queue builds (`merge_group`);
- `push`: every push event, including pushes to a branch other than the default branch (those run untrusted);
- `schedule`;
- `release`: runs on a release tag;
- `workflow_dispatch`.

The default is all five, so a builder without `events` is planned in every
context. The context of a run is `release` on a tag ref. Otherwise it is the
event name, with `pull_request`, `pull_request_target`, and `merge_group` all
mapped to `pull_request`. An empty array, an unknown value, or a value that is
not a string fails the plan.

A builder is planned only when its `events` include the context. An image with
no builder planned for the context is skipped without error. Packages are
planned as before, from the images that remain and from changed package files.

The primary builder stays the one named by `primary`, even when it is filtered
out. The other builder keeps the tag prefix it has when both run. For example,
with `primary` set to `docker` and the docker builder filtered out on a push,
the apko builder still publishes `apko-<sha>`:

```json
"api": {
  "builders": {
    "docker": {"dockerfile": "api/Dockerfile", "runner_profile": "large", "events": ["release", "workflow_dispatch"]},
    "apko": {"config": "apko/api.yaml"}
  },
  "primary": "docker",
  "smoke": {"commands": ["api --version"]}
}
```

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
  architectures in one `apko publish`, and ko images are published for all
  catalog architectures in one `ko build --platform` (no manifest job);
- merge docker manifest lists and attest apko and ko images and manifest lists;
- smoke test every architecture of the pushed digest (amd64 on the standard
  runner, arm64 on the arm runner), pulling by digest.

A ko image publishes `<registry>/<image>` with no path suffix, under the
`<sha_tag>` and `<ref_tag>` tags.

## Legacy catalogs

A catalog without `version` is read as a legacy `images.json` (docker). When
`.github/images.apko.json` exists, it is merged in memory with that file. If
`images.json` is absent but `images.apko.json` exists, the apko file is read
alone.

- An image in both files becomes a dual-builder image with `docker` primary.
- `melange` becomes `packages`, `needs_melange` becomes `needs_packages`,
  `apko_configs` becomes `configs`, and `nexus_paths` join `paths`.
- `mode: ko` becomes a ko builder: `ko_working_directory` becomes `context`,
  `ko_importpath` becomes `importpath` (default `./cmd`), `ko_go_version_file`
  becomes `go_version_file`, and `env` becomes `env`. `ko_config` is set to
  `.ko.yaml` at the repository root, which is where the legacy workflow read
  the ko configuration.
- `shared_<type>_paths` apply to images whose `type` matches.
- Legacy release tags keep the legacy publish formula: legacy release
  configuration that sets `publish_tag` to `${version}` still publishes
  `v1.2.3`. Set `release.publish_tag` explicitly when converting a catalog.

Not supported, and rejected with an error: `apko_images`, `groups`, `mode`
values other than `build`, `bake`, and `ko` in `images.json`, the `env` field
in `images.json` for any mode other than `ko`, `default_runners`, and `runners`
on a melange entry. A version 2 catalog ignores `images.apko.json`.

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
