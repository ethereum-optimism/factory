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
| `default_branch_tags` | no | Alias tags, for example `latest`, published with the sha and ref tags on trusted default-branch runs. Letters, digits, dot, dash only. Default `[]`. See Default branch aliases. |
| `tag_template` | no | Template for the commit tag. Default `{sha}`. See Tag templates. |
| `ref_tag_template` | no | Template for the ref tag. Default `{ref}`. See Tag templates. |
| `release` | no | Release tag mapping (see below). |
| `shared_paths` | no | Changed-file patterns that plan every image and package. |
| `packages` | no | Melange packages (see below). Names match `^[a-z0-9][a-z0-9._-]*$`. |
| `hooks.pre_build` | no | Repository script run during planning. Its stdout must be `KEY=VALUE` lines, and any other line fails the plan. It runs without `GITHUB_ENV`, `GITHUB_OUTPUT`, `GITHUB_PATH`, `GITHUB_STEP_SUMMARY`, and `GITHUB_STATE` set. The pairs are added to package build environments and to docker build arguments. |
| `apk_registry` | with lock files | APK registry that lock files may reference. See Lock files. |
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

## Commit and date build arguments

Set `git_build_args: true` on a `build` or `ko` docker builder to receive the
commit being built. The planner adds two values:

- `GIT_COMMIT`: the full SHA the workflow checked out. It is the same SHA used
  for the `sha` tag.
- `GIT_DATE`: the committer date of that commit, as `git show -s --format=%cI`
  prints it: strict ISO 8601 with its offset, for example
  `2026-11-19T13:00:00+01:00`. For UTC commits git writes `+00:00`, not `Z`.

In `build` mode both are added to `build_args`. In `ko` mode both are added to
`env`. Untrusted and trusted runs get them alike. A Dockerfile reads them only
after declaring `ARG GIT_COMMIT` and `ARG GIT_DATE`.

Either value replaces a catalog entry or a `hooks.pre_build` pair with the same
name. The planner reads the commit from the caller checkout, which the plan
job already has with full history. `bake` mode does not read `build_args`, so
`git_build_args: true` with `mode: "bake"` fails the plan. The default is
`false`, and a catalog without the key plans the same matrices as before.

A tag that does not match `tag_regex`, or names an image that is not in the
catalog, plans nothing and succeeds. The planner prints a `::notice::` that
names the tag.

## Packages

Each entry under `packages` describes one melange build. A package is built
once per architecture in `archs`. Untrusted runs build `x86_64` only. Every
event builds a package on the runner that `runner_profile` selects for its
architecture.

| Field | Default | Meaning |
| --- | --- | --- |
| `config` | `melange/<name>.yaml` | Melange configuration path. |
| `runner_profile` | `standard` | `standard` or `large`. Selects the runner per architecture on every event. Builders take the same key, see Images and builders. |
| `source` | none | Repository checked out before the build, with `repository`, `ref`, `path`, `root`. Omit `repository` to check out the calling repository. |
| `source.root` | `true` when `path` is `"."`, else `false` | Builds as if the checkout were the workspace root. The melange configuration, the pipelines directory, `cache_key_files` and the source directory resolve inside the checkout instead of the calling repository. Not valid for the calling repository checkout. |
| `source_submodules` | `"false"` | `"false"`, `"true"`, or `"recursive"`. Submodules of the `source` checkout. |
| `submodules` | `false` | `false`, `true`, or `"recursive"`. Submodules of the calling repository checkout. Only valid when `source` is omitted. Public submodules over https are fetched without credentials. A private submodule needs the app-token mechanism on trusted runs only, and such a package must not depend on it in untrusted runs. |
| `use_gha_cache` | `false` | Restores the melange cache. Saves it only on trusted default-branch runs. |
| `cache_key_files` | `[]` | Files, relative to the workspace, hashed into the cache key. |
| `archs` | `["x86_64", "aarch64"]` | Melange architectures. |
| `cargo_profile` | `{}` | `{trusted, untrusted}` profile names exported to pipelines. |
| `build_env` | `""` | `KEY=VALUE` lines added to the melange environment. |
| `build_version` | `""` | Exported as `GIT_VERSION`. Release tags override it. |
| `env_lockfile` | `""` | melange environment lock file written by `melange lock`. See Lock files. |

A `source` with `repository` set to the calling repository, `path` `"."`, and no `ref` is the calling repository checkout. It plans as an omitted `source`, and its `source_submodules` maps to `submodules`. Legacy v1 catalogs follow the same rule. A `source` with `path` `"."` for any other repository, or with a `ref` on the calling repository, is checked out under `.package-sources/<package>` with `root` set, so the checkout never replaces the calling repository's files. `root: false` with `path` `"."` is rejected.

Package artifacts are named `apks-<package>-<arch>`. The package build uses no
secrets and no OIDC token.

## Images and builders

`builders` holds one or both of `docker` and `apko`.

`docker`:

- `mode`: `build` (Dockerfile, default), `bake` (bake file), or `ko` (Go package built with ko).
- `context`, `dockerfile`, `target`, `build_args` (object), `bake_file`, `set` (bake variables as `KEY=VALUE` strings).
- `git_build_args`: boolean, default `false`. Passes the commit and its date to the build. See Commit and date build arguments.
- `tag_prefix`: see Tags.
- `archs`: `amd64`, `arm64`. Overrides the image `archs` for this builder only.
- `smoke`: same fields as the image `smoke`. Overrides it for this builder only, see Smoke per builder.
- `runner_profile`: `standard` (default) or `large`, as for packages. Selects
  the runner of this builder's build legs on untrusted runs and of its publish
  legs on trusted runs, per architecture. An apko or ko builder uses one leg,
  which runs on the amd64 runner of the profile.
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
- `configs`: variants, each `{config, tag_suffix, smoke, allow_packages, lockfile}`. A
  variant with an empty `tag_suffix` is the default variant. Every variant is
  smoke tested against its own digest. Without `configs`, `config` (default
  `apko/<image>.yaml`) is used. See Variants.
- `lockfile`: apko lock file for `config`, written by `apko lock`. With
  `configs`, set `lockfile` on each variant instead. See Lock files.
- `tag_prefix`: see Tags.
- `archs`: `amd64`, `arm64`. Overrides the image `archs` for this builder only.
- `smoke`: same fields as the image `smoke`. Overrides it for this builder only, see Smoke per builder.
- `runner_profile`: `standard` (default) or `large`, as for packages. Selects
  the runner of this builder's build legs on untrusted runs and of its publish
  legs on trusted runs, per architecture. An apko or ko builder uses one leg,
  which runs on the amd64 runner of the profile.
- `events`: contexts in which the builder is planned. See Builder events.

When an image has both builders, `primary` is required. Other image fields:

- `archs`: `amd64`, `arm64`. Defaults to both. Each builder uses its own `archs` when set, otherwise these. Untrusted runs build `amd64` only.
- `paths`: changed-file patterns for pull requests and pushes. Each apko
  variant's `config` file is a changed path of the image too, even when `paths`
  does not list it.
- `smoke`: `commands` (each string split on whitespace into entrypoint and
  arguments), `tests` (runs with exit code and output assertions, see Smoke
  tests), `script` (repository script run with `IMAGE` and `IMAGE_ARCH`),
  `verify_version` (on release tags, a command or test must print the version).
- `default_branch_tags`: overrides the top-level list for this image. An empty array publishes no alias tags for this image.
- `repository`: registry path under `registry`, for example `group/name`.
  Defaults to the image name. See Several versions in one repository.
- `version`: label for the `{version}` tag placeholder, for example `v1.16`.
  Letters, digits, dot, dash, starting with a letter or digit.
- `tag_template`, `ref_tag_template`: override the top-level templates for this
  image. See Tag templates.

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
disables smoke for that builder only. An apko variant can override the builder
smoke the same way, see Variants. Example: the apko image puts `mytool` on
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

Smoke scripts run from the caller checkout, at the path given in the catalog, on
both untrusted and trusted runs. `IMAGE` is a local tag on untrusted runs, the
staged digest reference (`localhost:<port>/<repository>@sha256:...`) before
publishing on trusted runs, and the published digest reference
(`<registry>/<repository>@sha256:...`) after publishing.

### Smoke tests

`smoke.tests` is an array of runs of the image. Each run is checked for its
exit code and, optionally, for a substring of its output:

| Field | Default | Meaning |
| --- | --- | --- |
| `args` | `[]` | Arguments passed to the image, each one argument with no shell splitting. |
| `entrypoint` | image entrypoint, or `/bin/sh` with `shell` | Entrypoint override (`docker run --entrypoint`). |
| `shell` | none | A command line, run as `<entrypoint> -c <shell>`. Cannot be combined with `args`. |
| `expected_exit` | `0` | Exit code the run must return, 0 to 255. |
| `expected_output` | `""` | Substring that stdout and stderr together must contain. Empty skips the check. |

A test needs at least one of `args`, `entrypoint`, or `shell`. Unknown fields
fail the plan. `commands` keep their behavior: each passes when the entrypoint
can run, whatever its exit code. With `verify_version`, the release version
may be printed by a command or by a test.

```json
"smoke": {
  "tests": [
    {"entrypoint": "/usr/local/bin/geth", "args": ["version"], "expected_output": "Geth"},
    {"shell": "geth --help | head -n 1"},
    {"args": ["--no-such-flag"], "expected_exit": 2, "expected_output": "flag provided but not defined"}
  ]
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

## Variants

Each entry in `builders.apko.configs` is a variant. A variant has its own apko
configuration, publish leg, digest, multi-arch manifest, provenance attestation,
and tags. Variants are built from the same packages, so a variant with a
different `config` costs one apko assembly, not a rebuild of the packages.

- `smoke`: the variant's smoke test. Resolution: the variant's `smoke`, else the
  builder `smoke`, else the image `smoke`. It replaces the inherited smoke
  entirely, and an empty object disables smoke for that variant. Untrusted runs
  smoke the local amd64 build. Trusted runs smoke the staged amd64 digest
  before publishing, then the pushed digest of every architecture.
  `verify_version` applies on release tags.
- `allow_packages`: package names exempt from the `-slim` guard below. Version
  constraints are ignored. Give a reason for each entry in the PR description.
- Change detection: each variant's `config` file counts as a changed path of
  its image.

The `-slim` guard: when a variant's `tag_suffix` ends in `-slim`, its apko file
must not list `apk-tools`, `busybox`, or a package whose name starts with
`openssl` under `contents.packages`, unless `allow_packages` names it. The
planner fails with an error that names the file and the package. The guard
checks every image of the catalog on every run, and a `-slim` config file that
does not exist also fails the plan. Variants without the `-slim` suffix are not
checked.

Example, with `apko/foo.yaml` (the default variant, which keeps `busybox` and
`apk-tools`) and `apko/foo-slim.yaml` (which lists only `ca-certificates-bundle`
and `foo-bin`):

```json
"foo": {
  "builders": {
    "apko": {
      "needs_packages": ["stack"],
      "configs": [
        {"config": "apko/foo.yaml"},
        {"config": "apko/foo-slim.yaml", "tag_suffix": "-slim"}
      ]
    }
  },
  "paths": ["foo/**"],
  "smoke": {"commands": ["foo --version"], "verify_version": true}
}
```

Both variants inherit `foo --version`. A variant can use its own command:
`{"config": "apko/foo-slim.yaml", "tag_suffix": "-slim", "smoke": {"commands": ["/usr/bin/foo --version"]}}`.
A variant that needs a package from the guard list names it in
`allow_packages`, for example `"allow_packages": ["openssl"]`.

## Lock files

An apko variant's `lockfile` and a package's `env_lockfile` name lock files in
the calling repository. When planned images or packages name lock files, the
`fetch-apks` job downloads every package and repository index they pin into an
apko cache directory and uploads it as the `apk-cache` artifact. The lock files
are read as data, and nothing from the calling repository runs in that job.

`apk_registry` is required when any lock file is set:

| Field | Required | Meaning |
| --- | --- | --- |
| `host` | yes | Registry host name, without scheme, port, or path. |
| `path_prefix` | yes | Path every locked URL must start with, beginning and ending with `/`. Matched by whole path segments. |
| `chainguard_identity` | no | Chainguard identity the job assumes with its OIDC token. The token is sent only to `host`. Omit it for an anonymous registry. |
| `redirect_hosts` | no | Hosts the registry may redirect package downloads to, such as blob storage. A leading `*.` matches subdomains only. Default `[]`: redirects off `host` are refused. |

The job fails, listing every problem, when:

- a non-local package URL or a remote repository index URL is not https on
  `host` under `path_prefix`, or has a port, credentials, query, or `..`;
- a non-local package has no whole-file `sha256` in its lock (`apko lock` from
  op-apko writes it), or two lock files pin one URL to different digests;
- a lock file records `unverified_indexes`;
- a downloaded package does not match its `sha256`, or a download is redirected
  off `host` to a host that `redirect_hosts` does not name, or redirected twice.

Local packages (`local: true`) are skipped. Untrusted runs fetch `x86_64`
entries only. The plan fails when a lock file is missing from the checkout.

An apko variant with a `lockfile` builds and publishes from the `apk-cache`
artifact with `apko --lockfile --offline --cache-dir --require-strong-checksums`
instead of resolving packages from the network: every package is checked
against the sha256 in the lock, and keys come from the lock. Untrusted builds
run apko in a container without network. A variant with a `lockfile` cannot
use `needs_packages` yet; the plan rejects that combination.

Example:

```json
"apk_registry": {
  "host": "apk.example.dev",
  "path_prefix": "/example-org/",
  "chainguard_identity": "0123456789abcdef0123456789abcdef01234567/0123456789abcdef",
  "redirect_hosts": ["*.storage.example.net"]
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

Published tags for a prefix `P`, with the default tag templates:

- `P<commit sha>` and `P<sanitized ref>`. On release tags the sanitized ref is
  the rendered `publish_tag` (see Release tags).
- apko variants append their `tag_suffix` to both tags. With `tag_suffix`
  `-slim`, a commit publishes `<sha>-slim`, the default branch publishes
  `develop-slim` (or `latest-slim` for the alias), and a release publishes
  `<publish_tag>-slim`. With `release.publish_tag` `${version}`, `v1.2.3-slim`.
- Docker images are pushed by digest per architecture, then merged into a
  manifest list under those tags.

### Tag templates

`tag_template` renders the commit tag and `ref_tag_template` renders the ref
tag. Both are set at the top level and can be overridden per image. The
defaults, `{sha}` and `{ref}`, publish the tags described above, so a catalog
without these keys publishes the same tags as before.

| Placeholder | Value |
| --- | --- |
| `{version}` | The image `version`. A template that uses it needs `version` on the image. |
| `{date}` | UTC date of the plan job, `YYYYMMDD`. |
| `{sha12}` | First 12 characters of the commit SHA. |
| `{sha}` | Full commit SHA. |
| `{ref}` | The sanitized ref name, or the rendered `publish_tag` on release tags. |

Outside placeholders a template may contain letters, digits, dot, and dash.
`tag_template` must contain `{sha}` or `{sha12}`, so every commit publishes its
own tag. The builder prefix and the apko variant suffix are added around the
rendered value as for the default tags, and every rendered tag must be a valid
OCI tag (at most 128 characters).

Example: `"tag_template": "{version}-{date}-{sha12}"` with `"version": "v1.16"`
publishes tags such as `v1.16-20261127-0123456789ab`, which match
`(.+)-\d{8}-[0-9a-f]{12}` with the version as the first group.

### Several versions in one repository

Several catalog entries can publish to one registry path by setting the same
`repository`. Each entry is its own image in the catalog, with its own
builders, paths, configuration directory, and smoke test. Because the entries
share tags in one repository:

- each entry must set `version`, and the versions must differ;
- `tag_template` and `ref_tag_template` of each entry must contain `{version}`;
- the entries cannot publish `default_branch_tags`; set
  `"default_branch_tags": []` on each when the top level declares aliases.

The planner fails the run when any of these does not hold.

```json
{
  "version": 2,
  "registry": "us-docker.pkg.dev/example-project/example-images",
  "tag_template": "{version}-{date}-{sha12}",
  "ref_tag_template": "{version}",
  "images": {
    "geth-v1-16": {
      "repository": "example/geth",
      "version": "v1.16",
      "builders": {"apko": {"config": "geth/v1.16/apko.yaml"}},
      "paths": ["geth/v1.16/**"]
    },
    "geth-v1-17": {
      "repository": "example/geth",
      "version": "v1.17",
      "builders": {"apko": {"config": "geth/v1.17/apko.yaml"}},
      "paths": ["geth/v1.17/**"]
    }
  }
}
```

Both entries publish to `example/geth`. A main commit publishes
`v1.16-<date>-<sha12>` and `v1.17-<date>-<sha12>`, and moves the `v1.16` and
`v1.17` ref tags. Release tags still name the catalog entry, for example
`geth-v1-17/v1.17.2`.

### Default branch aliases

The top-level `default_branch_tags` (or the image's own list) names alias tags such as
`latest`. On a trusted run whose ref is the default branch, each alias is published for
every builder of the image, next to the sha and ref tags: `P<alias>`, with the apko
variant `tag_suffix` appended. For example, a primary docker builder publishes
`latest`, and an apko builder with `tag_prefix` `apko-` publishes `apko-latest`.
Aliases are never published on untrusted runs, on release tags, or on other branches.
Without the key, nothing changes.

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
- build `x86_64` packages and the amd64 image builds on the runner their
  `runner_profile` selects;
- run with `contents: read` only, and never reference secrets or an OIDC
  token, except the `fetch-apks` job, which may request an OIDC token to
  authenticate to `apk_registry` and runs no code from the calling repository.

Trusted runs:

- on a default-branch push, plan only the images and packages affected by the
  push, from the event's `before` and `after` commits, with the same rules as
  pull requests (a change to the catalog or a shared path plans the full
  catalog). When the push has no usable `before` commit (a new branch, or a
  commit no longer in the repository), the full catalog is planned;
- on a schedule, plan every image and package in the catalog. A scheduled
  run is the full rebuild that also catches anything a failed push run left
  unpublished;
- on a workflow dispatch, plan every image and package, or only the `target`
  image (see Dispatching one image);
- build into a local staging registry with the `release` environment: docker
  architectures are built natively and pushed by digest, apko images are
  published for all catalog architectures in one `apko publish`, and ko images
  are published for all catalog architectures in one `ko build --platform`.
  The staging registry runs on the publish runner, bound to `127.0.0.1`, and
  receives no credentials;
- smoke test the staged digest before anything reaches the registry: each
  docker architecture on its native runner, and the amd64 image of apko and ko
  builds (an apko or ko build without amd64 is only smoke tested after
  publishing). A failing smoke test publishes nothing for that leg;
- copy the exact tested digest to the registry with `crane copy`, add the
  tags, copy the `sha256-*` attachment tags (such as SBOMs that apko and ko
  attach), and fail unless the published manifest and every tag resolve to the
  tested digest (`actions/promote-image`). Docker architectures are copied by
  digest only, and the manifest job tags the manifest list;
- merge docker manifest lists and attest apko and ko images and manifest lists:
  a build provenance attestation and an SPDX SBOM attestation (generated with
  syft from the published digest, `actions/attest` with `sbom-path`), both
  pushed to the registry next to the image;
- smoke test every architecture of the pushed digest (amd64 on the standard
  runner, arm64 on the arm runner), pulling by digest.

A ko image publishes `<registry>/<repository>` with no path suffix, under the
`<sha_tag>` and `<ref_tag>` tags.

## Dispatching one image

The reusable workflow takes a `target` input: a catalog image name. On a
`workflow_dispatch` run with a non-empty `target`, the planner plans only that
image and the packages it needs, in every context rule that applies otherwise
(trust, builder `events`, architectures). An empty `target` plans the full
catalog. A `target` that is not a catalog image, or a non-empty `target` on any
other event or on a tag ref, fails the plan.

The caller passes its own dispatch input through, as in
[`templates/build-images.yaml`](../templates/build-images.yaml):

```yaml
on:
  workflow_dispatch:
    inputs:
      target:
        type: string
        default: ''
jobs:
  build-images:
    uses: ethereum-optimism/factory/.github/workflows/build-images.yaml@<FULL_SHA>
    with:
      target: ${{ inputs.target || '' }}
```

## Workflow outputs

The reusable workflow has one output, `published`: a JSON array with one entry
per apko or ko variant and per docker manifest list that the run published.

| Field | Meaning |
| --- | --- |
| `id` | Publish leg id, for example `api-docker` or `worker-apko-dev`. |
| `image` | Catalog image name. |
| `name` | `<registry>/<repository>`. |
| `ref` | `name:<commit tag>`. |
| `digest` | Published digest, `sha256:...`. |

The output is an empty string on untrusted runs, where the job that sets it
does not run, and `[]` on a trusted run that published nothing. A caller
can add jobs that use it, for example a vulnerability scan of every published
digest:

```yaml
jobs:
  build-images:
    permissions:
      contents: read
      id-token: write
      attestations: write
    uses: ethereum-optimism/factory/.github/workflows/build-images.yaml@<FULL_SHA>
  scan:
    needs: build-images
    if: needs.build-images.outputs.published != '' && needs.build-images.outputs.published != '[]'
    strategy:
      matrix:
        include: ${{ fromJSON(needs.build-images.outputs.published) }}
    runs-on: ubuntu-24.04
    steps:
      - run: echo "scan ${{ matrix.name }}@${{ matrix.digest }}"
```

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

`actions/smoke-test/smoke-test.test.sh` runs the smoke action against a fake
`docker` to check commands, tests, exit codes, and output assertions, and
`actions/promote-image/promote.test.sh` checks the copy and digest
verification against a fake `crane`. The self-test workflow builds a docker,
an apko, and a ko fixture into a staging registry, smoke tests the staged
digest, promotes it to a second local registry, and smoke tests the copy.
`actions/plan-images/published-output.test.sh` checks the `published` output
built from the plan and the published digests.
`actions/plan-images/plan-images.test.sh` covers normalization, validation,
tag templates, shared repositories, tag and runner selection, legacy merging, hooks, notices, and change detection.
`scripts/lint-untrusted-permissions.test.sh` runs the lint against the real
files and against planted violations. Both run in the factory self-test
workflows.
