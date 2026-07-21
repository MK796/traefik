#!/usr/bin/env bash

set -euo pipefail

image="${1:?Usage: recursive-watch-container-e2e.sh IMAGE}"
wait_seconds="${E2E_TIMEOUT_SECONDS:-20}"

for command in curl docker jq; do
    if ! command -v "${command}" >/dev/null 2>&1; then
        echo "Required command is missing: ${command}" >&2
        exit 1
    fi
done

workspace="$(mktemp -d "${RUNNER_TEMP:-/tmp}/traefik-recursive-e2e.XXXXXX")"
dynamic_directory="${workspace}/dynamic"
staging_directory="${workspace}/staging"
container_name="traefik-recursive-e2e-${RANDOM}-$$"
api_url=""

dump_state() {
    echo "--- Traefik API state ---" >&2
    if [ -n "${api_url}" ]; then
        curl -fsS "${api_url}/api/http/services" >&2 || true
        echo >&2
    fi
    echo "--- Traefik logs ---" >&2
    docker logs "${container_name}" >&2 || true
}

cleanup() {
    docker rm --force "${container_name}" >/dev/null 2>&1 || true
    rm -rf "${workspace}"
}
trap cleanup EXIT

write_configuration() {
    local filename="$1"
    local service_name="$2"

    mkdir -p "$(dirname "${filename}")"
    printf 'http:\n  services:\n    %s:\n      loadBalancer:\n        servers:\n          - url: http://127.0.0.1\n' "${service_name}" > "${filename}"
}

service_exists() {
    local service_name="$1"

    curl -fsS "${api_url}/api/http/services" \
        | jq -e --arg name "${service_name}@file" 'any(.[]; .name == $name)' >/dev/null
}

wait_for_service() {
    local service_name="$1"
    local deadline=$((SECONDS + wait_seconds))

    while [ "${SECONDS}" -lt "${deadline}" ]; do
        if service_exists "${service_name}"; then
            return 0
        fi
        sleep 0.1
    done

    echo "Timed out waiting for service ${service_name}@file." >&2
    dump_state
    return 1
}

wait_for_missing_service() {
    local service_name="$1"
    local deadline=$((SECONDS + wait_seconds))

    while [ "${SECONDS}" -lt "${deadline}" ]; do
        if ! service_exists "${service_name}"; then
            return 0
        fi
        sleep 0.1
    done

    echo "Timed out waiting for service ${service_name}@file to disappear." >&2
    dump_state
    return 1
}

mkdir -p "${dynamic_directory}"
existing_file="${dynamic_directory}/existing/nested/config.yml"
write_configuration "${existing_file}" existing

docker run --detach \
    --name "${container_name}" \
    --publish 127.0.0.1::8080 \
    --volume "${dynamic_directory}:/dynamic:ro" \
    "${image}" \
    --api.insecure=true \
    --entryPoints.traefik.address=:8080 \
    --log.level=DEBUG \
    --providers.file.directory=/dynamic \
    --providers.file.watch=true >/dev/null

published_address="$(docker port "${container_name}" 8080/tcp)"
api_url="http://127.0.0.1:${published_address##*:}"

wait_for_service existing

write_configuration "${existing_file}" updated
wait_for_service updated
wait_for_missing_service existing

created_file="${dynamic_directory}/created/deep/config.yml"
write_configuration "${created_file}" created
wait_for_service created

replacement_file="${created_file}.replacement"
write_configuration "${replacement_file}" atomic
mv "${replacement_file}" "${created_file}"
wait_for_service atomic
wait_for_missing_service created

staged_file="${staging_directory}/nested/config.yml"
write_configuration "${staged_file}" imported
mv "${staging_directory}" "${dynamic_directory}/imported"
imported_file="${dynamic_directory}/imported/nested/config.yml"
wait_for_service imported

write_configuration "${imported_file}" imported-updated
wait_for_service imported-updated
wait_for_missing_service imported

rm -rf "${dynamic_directory}/imported"
wait_for_missing_service imported-updated

recreated_file="${dynamic_directory}/imported/nested/config.yml"
write_configuration "${recreated_file}" recreated
wait_for_service recreated

write_configuration "${recreated_file}" recreated-updated
wait_for_service recreated-updated
wait_for_missing_service recreated

echo "Recursive file-provider container E2E passed for ${image}."
