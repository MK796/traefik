#!/usr/bin/env bash

set -euo pipefail

releases_file="${1:?Usage: select-release-tag.sh RELEASES_JSON [REQUESTED_TAG]}"
requested_tag="${2:-}"

is_stable_v3_tag() {
    [[ "$1" =~ ^v3\.[0-9]+\.[0-9]+$ ]]
}

if [ -n "${requested_tag}" ]; then
    if ! is_stable_v3_tag "${requested_tag}" || ! git rev-parse --verify --quiet "refs/tags/${requested_tag}^{commit}" >/dev/null; then
        echo "Requested tag is not an existing stable Traefik v3 release: ${requested_tag}" >&2
        exit 1
    fi

    printf '%s\n' "${requested_tag}"
    exit 0
fi

mapfile -t stable_tags < <(git tag --list 'v3.*' --sort=version:refname | while IFS= read -r tag; do
    if is_stable_v3_tag "${tag}"; then
        printf '%s\n' "${tag}"
    fi
done)

if [ "${#stable_tags[@]}" -eq 0 ]; then
    echo "No stable Traefik v3 release tag exists." >&2
    exit 1
fi
if [ ! -f "${releases_file}" ]; then
    echo "Release history does not exist: ${releases_file}" >&2
    exit 1
fi

newest_index=$((${#stable_tags[@]} - 1))
selected_tag="${stable_tags[${newest_index}]}"
highest_completed="$(
    jq --raw-output '
      .[]
      | select(.draft == false and .prerelease == false)
      | select(any(.assets[]?; .name == "downstream-release.json"))
      | .tag_name
      | try capture("^downstream-(?<upstream>v3\\.[0-9]+\\.[0-9]+)-recursive\\.[0-9a-f]{12}$").upstream catch empty
    ' "${releases_file}" | sort --version-sort --unique | tail -n 1
)"

if [ -n "${highest_completed}" ]; then
    for candidate_tag in "${stable_tags[@]}"; do
        newest_of_pair="$(printf '%s\n%s\n' "${highest_completed}" "${candidate_tag}" | sort --version-sort | tail -n 1)"
        if [ "${candidate_tag}" != "${highest_completed}" ] && [ "${newest_of_pair}" = "${candidate_tag}" ]; then
            selected_tag="${candidate_tag}"
            break
        fi
    done
fi

printf '%s\n' "${selected_tag}"
