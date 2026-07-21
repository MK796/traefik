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
git -C "${upstream_work}" tag v3.0.1
git -C "${upstream_work}" tag v3.1.0

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

official_releases="${workspace}/official-releases.json"
jq --null-input '[
  {draft:false,prerelease:false,tag_name:"v3.0.0",published_at:"2026-01-01T00:00:00Z"},
  {draft:false,prerelease:false,tag_name:"v3.1.0",published_at:"2026-02-01T00:00:00Z"},
  {draft:false,prerelease:false,tag_name:"v3.0.1",published_at:"2026-03-01T00:00:00Z"},
  {draft:false,prerelease:true,tag_name:"v3.2.0-rc1",published_at:"2026-04-01T00:00:00Z"},
  {draft:false,prerelease:false,tag_name:"v4.0.0",published_at:"2026-05-01T00:00:00Z"}
]' > "${official_releases}"

empty_releases="${workspace}/empty-releases.json"
printf '[]\n' > "${empty_releases}"
selected_tag="$(cd "${downstream_work}" && "${script_directory}/select-release-tag.sh" "${official_releases}" "${empty_releases}")"
test "${selected_tag}" = v3.1.0

incomplete_releases="${workspace}/incomplete-releases.json"
jq --null-input '[
  {draft:false,prerelease:false,tag_name:"downstream-v3.1.0-recursive.aaaaaaaaaaaa",assets:[]}
]' > "${incomplete_releases}"
selected_tag="$(cd "${downstream_work}" && "${script_directory}/select-release-tag.sh" "${official_releases}" "${incomplete_releases}")"
test "${selected_tag}" = v3.1.0

completed_releases="${workspace}/completed-releases.json"
jq --null-input '[
  {draft:false,prerelease:false,tag_name:"downstream-v3.0.0-recursive.aaaaaaaaaaaa",assets:[{name:"downstream-release.json"}]}
]' > "${completed_releases}"
selected_tag="$(cd "${downstream_work}" && "${script_directory}/select-release-tag.sh" "${official_releases}" "${completed_releases}")"
test "${selected_tag}" = v3.1.0

backport_releases="${workspace}/backport-releases.json"
jq --null-input '[
  {draft:false,prerelease:false,tag_name:"downstream-v3.1.0-recursive.aaaaaaaaaaaa",assets:[{name:"downstream-release.json"}]}
]' > "${backport_releases}"
selected_tag="$(cd "${downstream_work}" && "${script_directory}/select-release-tag.sh" "${official_releases}" "${backport_releases}")"
test "${selected_tag}" = v3.0.1

latest_releases="${workspace}/latest-releases.json"
jq --null-input '[
  {draft:false,prerelease:false,tag_name:"downstream-v3.1.0-recursive.aaaaaaaaaaaa",assets:[{name:"downstream-release.json"}]},
  {draft:false,prerelease:false,tag_name:"downstream-v3.0.1-recursive.aaaaaaaaaaaa",assets:[{name:"downstream-release.json"}]}
]' > "${latest_releases}"
selected_tag="$(cd "${downstream_work}" && "${script_directory}/select-release-tag.sh" "${official_releases}" "${latest_releases}")"
test "${selected_tag}" = v3.1.0

selected_tag="$(cd "${downstream_work}" && "${script_directory}/select-release-tag.sh" "${official_releases}" "${empty_releases}" v3.0.0)"
test "${selected_tag}" = v3.0.0
if (cd "${downstream_work}" && "${script_directory}/select-release-tag.sh" "${official_releases}" "${empty_releases}" v3.9.9 >/dev/null 2>&1); then
    echo "Release selection accepted a missing requested tag." >&2
    exit 1
fi

echo "Downstream candidate script tests passed."
