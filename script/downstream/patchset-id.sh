#!/usr/bin/env bash

set -euo pipefail

base_ref="${1:?Usage: patchset-id.sh BASE_REF [TIP_REF]}"
tip_ref="${2:-HEAD}"

if ! git merge-base --is-ancestor "${base_ref}" "${tip_ref}"; then
    echo "${base_ref} is not an ancestor of ${tip_ref}." >&2
    exit 1
fi

mapfile -t commits < <(git rev-list --reverse "${base_ref}..${tip_ref}")
if [ "${#commits[@]}" -eq 0 ]; then
    echo "The requested range does not contain a patch queue." >&2
    exit 1
fi

{
    for commit in "${commits[@]}"; do
        patch_id="$(git show --pretty=format: --binary "${commit}" | git patch-id --stable | awk 'NR == 1 { print $1 }')"
        if [ -z "${patch_id}" ]; then
            echo "Unable to calculate a stable patch ID for ${commit}." >&2
            exit 1
        fi
        printf '%s\n' "${patch_id}"
    done
} | sha256sum | awk '{ print $1 }'
