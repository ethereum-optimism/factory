# Image release notes

Publish a Markdown file alongside a container image using OCI 1.1 referrers.
The attachment lives in the same registry image path and refers to the final
image digest, including the multi-platform index when applicable. Publishing
notes does not modify the image digest or its existing provenance.

Google Artifact Registry supports this mechanism in Docker repositories.
Customers with `roles/artifactregistry.reader` on the repository can discover
and download attachments; they do not need access to the source GitHub repo.
The publisher needs registry write access. Notes are visible to readers of the
repository, so supply customer-facing content.

## Automatic publishing from GitHub Releases (recommended)

Use `.github/workflows/release-notes.yaml` to keep release-note publishing in
Factory. Each consuming repository only needs this caller:

```yaml
name: Publish release notes

on:
  release:
    types: [published]

permissions:
  contents: read
  id-token: write

jobs:
  release-notes:
    uses: ethereum-optimism/factory/.github/workflows/release-notes.yaml@<pinned-sha>
    with:
      image: us-docker.pkg.dev/oplabs-tools-artifacts/internal-images/op-monitorism
```

The reusable workflow reads the **calling repository's GitHub Release body**,
including notes generated through GitHub's release UI. It does not generate its
own changelog. No Markdown file, authentication steps, or scripts are needed in
the consuming repository.

It maps `op-monitorism/v0.0.13` or `v0.0.13` to image tag `v0.0.13`, waits up to
15 minutes for that image to become available, then resolves its immutable digest
and attaches the notes. It creates no container image and changes no image tags,
image bytes, or existing image signatures. The image's signature does not cover
the separate release-notes attachment.

Authentication defaults to the existing `oplabs-tools-artifacts` GitHub workload
identity provider. The calling repository must already be trusted by that
provider and have Artifact Registry write access. Other GCP setups can override
the authentication inputs below; this workflow does not grant access.

| Workflow input | Default / purpose |
|---|---|
| `image` | Required Artifact Registry image path, **without** tag or digest. |
| `release_tag` | The caller's release event tag. Set explicitly for manual backfills. |
| `image_tag` | Release tag with the matching image-name prefix removed. Override for tags such as `apko-v0.0.13`. |
| `gcp_project_id` | `oplabs-tools-artifacts`. |
| `workload_identity_provider` | `projects/441280564867/locations/global/workloadIdentityPools/github/providers/github-oidc`. |
| `service_account` | Empty for direct workload identity federation; optionally impersonate a service account. |
| `wait_seconds` | `900`; accepts 0–1800. Zero performs one image lookup without retries. |

The workflow returns `image` (the immutable image reference) and `reference`
(the attachment reference). It verifies referrer discovery and downloads the
attachment to compare the exact Markdown bytes. Both references and the image's
Artifact Registry link are included in the run summary. Missing or
empty release notes, drafts, mismatched image-name prefixes, and invalid image
tags fail before authentication. Only missing images are retried; authentication
and other registry errors fail immediately.

For a manual backfill, add a `workflow_dispatch` trigger to the caller with a
required string input named `release_tag`, then pass
`release_tag: ${{ inputs.release_tag || github.event.release.tag_name }}` in the
job's `with` block. The referenced GitHub Release and image must already exist
or become available within the wait period. To publish edited notes, include
`edited` in the caller's release event types or run a backfill. Repeated publishing
can create additional attachments, as described below.

For repositories with releases for multiple images, filter each caller job to
its own release tags, for example
`if: startsWith(github.event.release.tag_name, 'op-monitorism/')` for the
release-event caller above. The workflow rejects a different image-name prefix
unless `image_tag` is explicitly supplied.

## Composite action contract

| Input | Required | Meaning |
|---|---|---|
| `image` | Yes | Fully qualified image reference ending in `@sha256:<64 hex characters>`. Tags are rejected to avoid attaching notes to a concurrently updated release. |
| `file` | Yes | Nonempty Markdown file on the runner. Relative paths are relative to the current working directory. |

The action installs a pinned ORAS version through mise and uses existing Docker/ORAS registry
credentials. Run on Linux with Bash and Python 3 (available on GitHub's Ubuntu
runners). Missing files, invalid references, and failed uploads fail the step.
The `reference` output is the attachment's full digest reference, ready for
`oras pull`. It is also recorded in the job summary.

The file is stored as `RELEASE_NOTES.md` with layer media type `text/markdown`.
Its artifact type is `application/vnd.oplabs.release-notes.v1`: this is a Factory
convention, not an OCI-defined release-notes type. OCI standardizes the manifest,
subject relationship, and discovery protocol. The manifest uses the standard
`org.opencontainers.image.title` annotation with the value `Release notes`.

Each invocation publishes an attachment. Re-running can produce additional
attachments; discovery does not define which is the latest. Retain the returned
`reference` when distributing a particular revision of the notes.

## Publish from a consuming workflow

Commit a release-specific file, or generate one before calling the action.
For example, after a **single-image** reusable build job named `build`:

```yaml
  release-notes:
    needs: build
    if: startsWith(github.ref, 'refs/tags/')
    runs-on: ubuntu-latest
    permissions:
      contents: read
      id-token: write
    steps:
      - uses: actions/checkout@71cf2267d89c5cb81562390fa70a37fa40b1305e
        with:
          persist-credentials: false
      - uses: google-github-actions/auth@7c6bc770dae815cd3e89ee6cdf493a5fab2cc093
        with:
          project_id: my-project
          workload_identity_provider: projects/123456789/locations/global/workloadIdentityPools/github/providers/github-oidc
          create_credentials_file: true
      - name: Configure registry credentials
        run: gcloud auth configure-docker us-docker.pkg.dev --quiet
      - uses: ethereum-optimism/factory/actions/release-notes@<pinned-sha>
        id: notes
        with:
          image: ${{ needs.build.outputs.image }}
          file: releases/my-service-v1.2.3.md
```

Replace the project, identity provider, registry hostname, file path, and action
revision with your values. The publishing identity must have write access to
the target repository. Gate the job on your release event or promotion policy;
the action itself does not impose an event filter.

`docker.yaml` (all build modes) and `apko-publish.yaml` expose `image` and
`digest` workflow outputs. `apko.yaml` exposes `services_json` and a `digests`
JSON object keyed by service name; construct each reference as
`registry/service@digest`. A matrix invoking a reusable workflow does not
aggregate its outputs: publish per image with its exact digest, rather than
using a single `needs.build.outputs.image` for an entire matrix.

To use a GitHub Release body instead, export it in the same job before invoking
the action (the GitHub Release must already exist):

```yaml
      - name: Export GitHub release notes
        env:
          GH_TOKEN: ${{ github.token }}
          RELEASE_TAG: ${{ github.ref_name }}
        run: gh release view "$RELEASE_TAG" --repo "$GITHUB_REPOSITORY" --json body --jq .body > RELEASE_NOTES.md
```

Then pass `file: RELEASE_NOTES.md`. For private source repositories, the token
used to export the release needs read access; customers still need only registry
access to retrieve the published copy.

## Customer retrieval

`docker pull` downloads the container image, **not its attachments**. Customers
can find the notes in Google Cloud Console under **Artifact Registry → repository
→ image → version → Attachments**. They can download them using ORAS or gcloud.
This is an attachment, not a dedicated rendered release-notes page in the UI.

With ORAS installed and a Google identity that has repository reader access:

```sh
gcloud auth configure-docker us-docker.pkg.dev --quiet

# Discover the release-notes attachments for the image version.
oras discover --distribution-spec v1.1-referrers-api \
  --artifact-type application/vnd.oplabs.release-notes.v1 \
  us-docker.pkg.dev/my-project/my-repo/my-service:v1.2.3

# Use an ATTACHMENT digest from discovery, or the action's reference output.
oras pull -o ./release-notes \
  us-docker.pkg.dev/my-project/my-repo/my-service@sha256:<attachment-digest>
```

The downloaded file is `release-notes/RELEASE_NOTES.md`. An image's digest and
its attachment's digest are different.

When copying a release into another customer repository, copy its referrers too,
for example with `oras cp --recursive SOURCE DESTINATION`. A Docker pull/tag/push
does not transfer them. Artifact Registry removes attachments when their subject
image is deleted; retain release images through your cleanup policy.

## Validation and references

Run `python3 -m unittest discover -s actions/release-notes -p 'test_*.py' -v`
with ORAS and PyYAML 6.0.3 installed. Workflow tests execute its actual preparation
and resolution scripts with mocked GitHub and registry responses to verify tag
mapping, exact release-body bytes, error handling, and image-build retries.
Attachment tests use real ORAS and an offline OCI layout to verify
attachment discovery, digest identity, downloaded file contents, invalid inputs,
and failed uploads. They do not exercise live Artifact Registry IAM or its UI.

- [Artifact Registry OCI 1.1 support (GA)](https://docs.cloud.google.com/artifact-registry/docs/release-notes#October_03_2024)
- [Store metadata in attachments](https://docs.cloud.google.com/artifact-registry/docs/store-artifact-metadata-in-attachments)
- [Find and download attachments; required roles](https://docs.cloud.google.com/artifact-registry/docs/manage-metadata-with-attachments)
- [OCI artifact manifest and subject specification](https://github.com/opencontainers/image-spec/blob/v1.1.0/manifest.md)
- [ORAS attachment commands](https://oras.land/docs/commands/oras_attach/)

Google's broader attachment-management documentation is marked Preview; Docker
repository OCI 1.1 support is separately documented as generally available.
