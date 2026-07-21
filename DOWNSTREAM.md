# Traefik Recursive-Watch Downstream

This fork temporarily carries automatic recursive watching for the existing
Traefik file-provider `directory` when `watch` is enabled. It is a downstream
compatibility branch, not a separate Traefik distribution.

## Branches

- `master` is a fast-forward-only mirror of `traefik/traefik:master`.
- `downstream/recursive-watch` is the last fully verified upstream commit plus
  the linear downstream patch queue.
- `automation/*` branches are disposable candidates produced by GitHub Actions.

The default branch is `downstream/recursive-watch` because scheduled workflows
only execute from a repository's default branch.

## Automation

`downstream-sync.yaml` checks upstream hourly, rebases the complete patch queue,
and verifies the result. A candidate is promoted only after upstream validation,
all file-provider tests, repeated lifecycle and exhaustion tests, the race
detector, all Traefik release-target compile checks, the container E2E contract,
the upstream sunset probe, and the final image build have succeeded.

`downstream-release.yaml` applies the same patch queue to every new stable
Traefik `v3.x.y` tag. Images are published to GHCR with immutable tags containing
both the upstream version and a rebase-stable patchset ID. An existing tag is
reused only when its candidate and upstream labels match exactly; it is never
overwritten. Release cherry-picks use deterministic commit metadata, so a retry
reconstructs the same candidate. The image carries the exact upstream and
candidate commits as OCI metadata and is published with BuildKit provenance and
an SBOM.

The corresponding GitHub release is the completion marker. Its
`downstream-release.json` asset records the immutable image reference, digest,
candidate, upstream commit, and patchset ID. A source tag without that release
asset is treated as incomplete and resumed on the next run.

Failures leave the known-good branch and existing images untouched and are
reported as GitHub issues.

## macOS kqueue status

The current downstream test matrix applies
`.github/test-patches/fsnotify-kqueue-register-before-create.patch` only to the
temporary Go module cache on the macOS GitHub runner. The patch is visible in
the workflow and is not included in published Linux images. It isolates a known
kqueue event-ordering problem while fsnotify decides its recursive-watch API.

## Ingress updates

Production must use a stable `v3.x.y-recursive.<patch>` image pinned by digest.
Master images are compatibility artifacts and must not be deployed.

The ingress repository polls completed downstream GitHub releases and validates
their `downstream-release.json` assets before opening a reviewable digest-update
PR. No cross-repository write token is required, and releases never deploy
automatically.

## Retirement

Every candidate runs the container contract against unmodified upstream. If
upstream passes, promotion stops and reports that the downstream patch should be
retired. After the behavior is available in an official Traefik release,
production returns to the official image and this branch can be archived.

No builds or stress tests for this downstream run on ingress cluster nodes.
