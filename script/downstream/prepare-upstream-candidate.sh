#!/usr/bin/env bash

set -euo pipefail

upstream_url="${UPSTREAM_URL:-https://github.com/traefik/traefik.git}"
upstream_branch="${UPSTREAM_BRANCH:-master}"
candidate_branch="${CANDIDATE_BRANCH:-automation/upstream-candidate}"
force_candidate="${FORCE_CANDIDATE:-false}"

write_output() {
    if [ -n "${GITHUB_OUTPUT:-}" ]; then
        printf '%s=%s\n' "$1" "$2" >> "${GITHUB_OUTPUT}"
    fi
}

if git remote get-url upstream >/dev/null 2>&1; then
    git remote set-url upstream "${upstream_url}"
else
    git remote add upstream "${upstream_url}"
fi

git fetch --no-tags upstream "${upstream_branch}"
upstream_ref="refs/remotes/upstream/${upstream_branch}"
upstream_sha="$(git rev-parse "${upstream_ref}")"
downstream_sha="$(git rev-parse HEAD)"
patch_base_sha="$(git merge-base HEAD "${upstream_ref}")"
patch_count="$(git rev-list --count "${patch_base_sha}..HEAD")"

if [ "${patch_count}" -eq 0 ]; then
    echo "The downstream branch does not contain a patch queue." >&2
    exit 1
fi

write_output upstream_sha "${upstream_sha}"
write_output upstream_short "${upstream_sha:0:12}"
write_output downstream_sha "${downstream_sha}"
write_output patch_base_sha "${patch_base_sha}"
write_output patch_count "${patch_count}"

# Keep the fork's master branch as an exact fast-forward-only upstream mirror.
git push origin "${upstream_ref}:refs/heads/master"

if [ "${patch_base_sha}" = "${upstream_sha}" ] && [ "${force_candidate}" != "true" ]; then
    echo "Downstream is already based on upstream ${upstream_sha}."
    write_output changed false
    write_output candidate_sha "${downstream_sha}"
    exit 0
fi

worktree="$(mktemp -d "${RUNNER_TEMP:-/tmp}/traefik-upstream-candidate.XXXXXX")"
cleanup() {
    git worktree remove --force "${worktree}" >/dev/null 2>&1 || true
}
trap cleanup EXIT

git worktree add --detach "${worktree}" "${downstream_sha}"
git -C "${worktree}" rebase --onto "${upstream_ref}" "${patch_base_sha}"

candidate_sha="$(git -C "${worktree}" rev-parse HEAD)"
candidate_base_sha="$(git -C "${worktree}" merge-base HEAD "${upstream_ref}")"
candidate_patch_count="$(git -C "${worktree}" rev-list --count "${upstream_ref}..HEAD")"

if [ "${candidate_base_sha}" != "${upstream_sha}" ]; then
    echo "Candidate is not based directly on the requested upstream commit." >&2
    exit 1
fi
if [ "${candidate_patch_count}" -ne "${patch_count}" ]; then
    echo "Rebase changed the patch count from ${patch_count} to ${candidate_patch_count}." >&2
    exit 1
fi
if git -C "${worktree}" rev-list --merges "${upstream_ref}..HEAD" | grep -q .; then
    echo "The downstream patch queue must not contain merge commits." >&2
    exit 1
fi

git -C "${worktree}" push --force origin "HEAD:refs/heads/${candidate_branch}"

write_output changed true
write_output candidate_sha "${candidate_sha}"
write_output candidate_short "${candidate_sha:0:12}"

echo "Prepared ${candidate_branch} at ${candidate_sha} on upstream ${upstream_sha}."
