#!/usr/bin/env bash

set -euo pipefail

script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
workspace="$(mktemp -d "${RUNNER_TEMP:-/tmp}/traefik-candidate-script-test.XXXXXX")"

cleanup() {
    rm -rf "${workspace}"
}
trap cleanup EXIT

upstream_work="${workspace}/upstream-work"
upstream_bare="${workspace}/upstream.git"
origin_bare="${workspace}/origin.git"
downstream_work="${workspace}/downstream-work"

git init --quiet --initial-branch=master "${upstream_work}"
git -C "${upstream_work}" config user.name Test
git -C "${upstream_work}" config user.email test@example.invalid
printf 'base\n' > "${upstream_work}/base.txt"
git -C "${upstream_work}" add base.txt
git -C "${upstream_work}" commit --quiet --message base
git -C "${upstream_work}" tag v3.0.0

git clone --quiet --bare "${upstream_work}" "${upstream_bare}"
git clone --quiet "${upstream_bare}" "${downstream_work}"
git -C "${downstream_work}" config user.name Test
git -C "${downstream_work}" config user.email test@example.invalid
fixture_base_sha="$(git -C "${downstream_work}" rev-parse HEAD)"
printf 'downstream\n' > "${downstream_work}/downstream.txt"
git -C "${downstream_work}" add downstream.txt
git -C "${downstream_work}" commit --quiet --message downstream

git clone --quiet --bare "${upstream_work}" "${origin_bare}"
git -C "${downstream_work}" remote set-url origin "${origin_bare}"

initial_patchset_id="$(
    cd "${downstream_work}"
    "${script_directory}/patchset-id.sh" "${fixture_base_sha}" HEAD
)"

printf 'upstream\n' > "${upstream_work}/upstream.txt"
git -C "${upstream_work}" add upstream.txt
git -C "${upstream_work}" commit --quiet --message upstream
git -C "${upstream_work}" push --quiet "${upstream_bare}" master

sync_output="${workspace}/sync-output"
(
    cd "${downstream_work}"
    GITHUB_OUTPUT="${sync_output}" \
    UPSTREAM_URL="${upstream_bare}" \
    CANDIDATE_BRANCH=automation/test-candidate \
        "${script_directory}/prepare-upstream-candidate.sh"
)

grep -qx 'changed=true' "${sync_output}"
upstream_sha="$(git --git-dir="${upstream_bare}" rev-parse master)"
mirrored_sha="$(git --git-dir="${origin_bare}" rev-parse master)"
test "${upstream_sha}" = "${mirrored_sha}"
git --git-dir="${origin_bare}" show automation/test-candidate:upstream.txt >/dev/null
git --git-dir="${origin_bare}" show automation/test-candidate:downstream.txt >/dev/null

git -C "${downstream_work}" fetch --quiet origin automation/test-candidate
git -C "${downstream_work}" reset --quiet --hard FETCH_HEAD
rebased_patchset_id="$(
    cd "${downstream_work}"
    "${script_directory}/patchset-id.sh" "${upstream_sha}" HEAD
)"
test "${initial_patchset_id}" = "${rebased_patchset_id}"
noop_output="${workspace}/noop-output"
(
    cd "${downstream_work}"
    GITHUB_OUTPUT="${noop_output}" \
    UPSTREAM_URL="${upstream_bare}" \
    CANDIDATE_BRANCH=automation/test-candidate \
        "${script_directory}/prepare-upstream-candidate.sh"
)
grep -qx 'changed=false' "${noop_output}"

release_output="${workspace}/release-output"
(
    cd "${downstream_work}"
    GITHUB_OUTPUT="${release_output}" \
    UPSTREAM_URL="${upstream_bare}" \
    UPSTREAM_TAG=v3.0.0 \
    CANDIDATE_BRANCH=automation/test-release \
        "${script_directory}/prepare-release-candidate.sh"
)

git --git-dir="${origin_bare}" show automation/test-release:downstream.txt >/dev/null
if git --git-dir="${origin_bare}" show automation/test-release:upstream.txt >/dev/null 2>&1; then
    echo "Release candidate unexpectedly contains a post-release upstream file." >&2
    exit 1
fi

first_release_sha="$(git --git-dir="${origin_bare}" rev-parse automation/test-release)"
second_release_output="${workspace}/second-release-output"
(
    cd "${downstream_work}"
    GITHUB_OUTPUT="${second_release_output}" \
    UPSTREAM_URL="${upstream_bare}" \
    UPSTREAM_TAG=v3.0.0 \
    CANDIDATE_BRANCH=automation/test-release-repeat \
        "${script_directory}/prepare-release-candidate.sh"
)
second_release_sha="$(git --git-dir="${origin_bare}" rev-parse automation/test-release-repeat)"
test "${first_release_sha}" = "${second_release_sha}"
grep -qx "patchset_id=${initial_patchset_id}" "${release_output}"
grep -qx "patchset_id=${initial_patchset_id}" "${second_release_output}"

echo "Downstream candidate script tests passed."
