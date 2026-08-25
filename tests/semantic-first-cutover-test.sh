#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
TEMPORARY_DIRECTORY="$(mktemp -d)"
CALL_LOG="${TEMPORARY_DIRECTORY}/calls.log"
trap 'rm -rf "${TEMPORARY_DIRECTORY}"' EXIT

grep -Fq "SEMANTIC_LEGACY_REF=366f870c269df27a22ab26e4becdc08359573ff1" "${ROOT}/.env.example"
grep -Fq 'prepare_legacy_cutover_image' "${ROOT}/deploy.sh"
grep -Fq 'checkout --detach' "${ROOT}/deploy.sh"
grep -Fq 'semantic-repository-data' "${ROOT}/compose.yaml"
grep -Fq 'semantic-indexer-repository-data' "${ROOT}/compose.yaml"
grep -Fq 'restart_legacy_on_query_failure' "${ROOT}/deploy.sh"

source "${ROOT}/deploy.sh"

compose_fake() {
    printf 'compose:%s\n' "$*" >> "${CALL_LOG}"
}

docker() {
    printf 'docker:%s\n' "$*" >> "${CALL_LOG}"
    if [[ "$1 $2" == 'image inspect' ]]; then
        printf 'sha256:pinned-image'
    elif [[ "$1" == inspect ]]; then
        printf 'sha256:pinned-image'
    fi
}

curl() {
    printf 'curl:%s\n' "$*" >> "${CALL_LOG}"
    printf '[]'
}

detect_legacy_cutover() { LEGACY_CONTAINER_ID='pinned-container'; }
env_value() { printf 'read-token'; }
env_or_default() { printf '%s' "$2"; }

COMPOSE=(compose_fake)
LEGACY_CONTAINER_ID='untrusted-container'
activate_pinned_legacy_cutover

grep -Fq 'compose:--profile legacy-cutover up -d --force-recreate --no-deps semantic-service' "${CALL_LOG}"
grep -Fq 'docker:image inspect --format {{.Id}} java-agent-semantic-legacy' "${CALL_LOG}"
grep -Fq 'docker:inspect --format {{.Image}} pinned-container' "${CALL_LOG}"
grep -Fq 'curl:--fail --silent --show-error' "${CALL_LOG}"
[[ "${LEGACY_CONTAINER_ID}" == pinned-container ]]
