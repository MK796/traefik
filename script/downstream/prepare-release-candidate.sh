#!/usr/bin/env bash

set -euo pipefail

upstream_url="${UPSTREAM_URL:-https://github.com/traefik/traefik.git}"
upstream_branch="${UPSTREAM_BRANCH:-master}"
upstream_tag="${UPSTREAM_TAG:?UPSTREAM_TAG is required}"
candidate_branch="${CANDIDATE_BRANCH:-automation/release-candidate}"
script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"

write_output() {
    if [ -n "${GITHUB_OUTPUT:-}" ]; then
        printf '%s=%s\n' "$1" "$2" >> "${GITHUB_OUTPUT}"
    fi
}

if ! [[ "${upstream_tag}" =~ ^v3\.[0-9]+\.[0-9]+$ ]]; then
    echo "Only stable Traefik v3 release tags are accepted: ${upstream_tag}" >&2
    exit 1
fi

if git remote get-url upstream >/dev/null 2>&1; then
    git remote set-url upstream "${upstream_url}"
else
    git remote add upstream "${upstream_url}"
fi

git fetch --no-tags upstream "${upstream_branch}"
git fetch upstream "refs/tags/${upstream_tag}:refs/tags/${upstream_tag}"

upstream_ref="refs/remotes/upstream/${upstream_branch}"
release_sha="$(git rev-parse "refs/tags/${upstream_tag}^{commit}")"
patch_base_sha="$(git merge-base HEAD "${upstream_ref}")"
patchset_id="$("${script_directory}/patchset-id.sh" "${patch_base_sha}" HEAD)"

mapfile -t patch_commits < <(git rev-list --reverse "${patch_base_sha}..HEAD")
if [ "${#patch_commits[@]}" -eq 0 ]; then
    echo "The downstream branch does not contain a patch queue." >&2
    exit 1
fi
if git rev-list --merges "${patch_base_sha}..HEAD" | grep -q .; then
    echo "The downstream patch queue must not contain merge commits." >&2
    exit 1
fi

worktree="$(mktemp -d "${RUNNER_TEMP:-/tmp}/traefik-release-candidate.XXXXXX")"
cleanup() {
    git worktree remove --force "${worktree}" >/dev/null 2>&1 || true
}
trap cleanup EXIT

git worktree add --detach "${worktree}" "${release_sha}"
for commit in "${patch_commits[@]}"; do
    author_date="$(git show --no-patch --format=%aI "${commit}")"
    GIT_COMMITTER_DATE="${author_date}" git -C "${worktree}" cherry-pick "${commit}"
done

candidate_sha="$(git -C "${worktree}" rev-parse HEAD)"
git -C "${worktree}" push --force origin "HEAD:refs/heads/${candidate_branch}"

write_output upstream_tag "${upstream_tag}"
write_output upstream_sha "${release_sha}"
write_output upstream_short "${release_sha:0:12}"
write_output patchset_id "${patchset_id}"
write_output patchset_short "${patchset_id:0:12}"
write_output patch_count "${#patch_commits[@]}"
write_output candidate_sha "${candidate_sha}"
write_output candidate_short "${candidate_sha:0:12}"

echo "Prepared ${candidate_branch} at ${candidate_sha} for ${upstream_tag}."
