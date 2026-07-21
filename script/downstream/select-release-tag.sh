#!/usr/bin/env bash

set -euo pipefail

official_releases_file="${1:?Usage: select-release-tag.sh OFFICIAL_RELEASES_JSON DOWNSTREAM_RELEASES_JSON [REQUESTED_TAG]}"
downstream_releases_file="${2:?Usage: select-release-tag.sh OFFICIAL_RELEASES_JSON DOWNSTREAM_RELEASES_JSON [REQUESTED_TAG]}"
requested_tag="${3:-}"

is_stable_v3_tag() {
    [[ "$1" =~ ^v3\.[0-9]+\.[0-9]+$ ]]
}

for releases_file in "${official_releases_file}" "${downstream_releases_file}"; do
    if [ ! -f "${releases_file}" ] || ! jq --exit-status 'type == "array"' "${releases_file}" >/dev/null; then
        echo "Release history is missing or invalid: ${releases_file}" >&2
        exit 1
    fi
done

if [ -n "${requested_tag}" ]; then
    if ! is_stable_v3_tag "${requested_tag}" \
        || ! git rev-parse --verify --quiet "refs/tags/${requested_tag}^{commit}" >/dev/null \
        || ! jq --exit-status --arg tag "${requested_tag}" \
            'any(.[]; .draft == false and .prerelease == false and .tag_name == $tag)' \
            "${official_releases_file}" >/dev/null; then
        echo "Requested tag is not an official stable Traefik v3 release: ${requested_tag}" >&2
        exit 1
    fi

    printf '%s\n' "${requested_tag}"
    exit 0
fi

# Completed release manifests form a publication-time watermark. This catches
# later backports whose version is lower than the current production release.
# If no new upstream release is pending, the highest v3 version is selected so
# a changed downstream patchset rebuilds the current production line.
selected_tag="$(
    jq --null-input --raw-output \
        --slurpfile official "${official_releases_file}" \
        --slurpfile downstream "${downstream_releases_file}" '
      def official_v3:
        . as $release
        | select($release.draft == false and $release.prerelease == false)
        | select(($release.published_at | type) == "string" and ($release.published_at | length) > 0)
        | try ($release.tag_name | capture("^v(?<major>[0-9]+)\\.(?<minor>[0-9]+)\\.(?<patch>[0-9]+)$")) catch empty
        | select((.major | tonumber) == 3)
        | {
            tag: $release.tag_name,
            published: $release.published_at,
            major: (.major | tonumber),
            minor: (.minor | tonumber),
            patch: (.patch | tonumber)
          };
      def completed_upstream_tag:
        select(.draft == false and .prerelease == false)
        | select(any(.assets[]?; .name == "downstream-release.json"))
        | .tag_name
        | try capture("^downstream-(?<upstream>v3\\.[0-9]+\\.[0-9]+)-recursive\\.[0-9a-f]{12}$").upstream catch empty;

      [$official[0][] | official_v3] as $stable
      | ([$downstream[0][] | completed_upstream_tag] | unique) as $completed
      | if ($stable | length) == 0 then
          empty
        else
          ([$stable[] | . as $release | select($completed | index($release.tag)) | $release.published] | max // "") as $watermark
          | if $watermark == "" then
              ($stable | sort_by([.major, .minor, .patch, .published, .tag]) | last | .tag)
            else
              ([$stable[]
                | . as $release
                | select(($completed | index($release.tag)) == null)
                | select($release.published > $watermark)]
                | sort_by([.published, .major, .minor, .patch, .tag])) as $pending
              | if ($pending | length) > 0 then
                  $pending[0].tag
                else
                  ($stable | sort_by([.major, .minor, .patch, .published, .tag]) | last | .tag)
                end
            end
        end
    '
)"

if ! is_stable_v3_tag "${selected_tag}" \
    || ! git rev-parse --verify --quiet "refs/tags/${selected_tag}^{commit}" >/dev/null; then
    echo "No official stable Traefik v3 release tag was selected." >&2
    exit 1
fi

printf '%s\n' "${selected_tag}"
