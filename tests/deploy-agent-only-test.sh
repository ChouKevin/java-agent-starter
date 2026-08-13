#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
TEMPORARY_DIRECTORY="$(mktemp -d)"
CALL_LOG="${TEMPORARY_DIRECTORY}/calls.log"

cleanup() {
    rm -rf "${TEMPORARY_DIRECTORY}"
}

trap cleanup EXIT

source "${ROOT}/deploy.sh"

create_env_if_missing() {
    :
}

env_value() {
    printf 'test-token'
}

env_or_default() {
    printf '%s' "$2"
}

preflight_active_deployment() {
    printf 'preflight-full\n' >> "${CALL_LOG}"
}

preflight_agent_only_deployment() {
    printf 'preflight-agent-only\n' >> "${CALL_LOG}"
}

prepare_host_paths() {
    printf 'prepare-host-paths\n' >> "${CALL_LOG}"
}

sync_source() {
    printf 'sync:%s\n' "$1" >> "${CALL_LOG}"
}

write_deployment_record() {
    printf 'record\n' >> "${CALL_LOG}"
}

docker() {
    local -a arguments=("$@")
    local argument
    local index

    if [[ "$*" == "compose version" ]]; then
        return
    fi

    for ((index = 0; index < ${#arguments[@]}; index++)); do
        argument="${arguments[${index}]}"
        case "${argument}" in
            ps)
                printf 'postgres|running|healthy\nsemantic-service|running|\njava-system-agent|running|healthy\n'
                return
                ;;
            build|up|--profile)
                printf 'compose:%s\n' "${arguments[*]:${index}}" >> "${CALL_LOG}"
                return
                ;;
        esac
    done
}

main --agent-only > "${TEMPORARY_DIRECTORY}/output.log"

EXPECTED_CALLS=$'preflight-agent-only\nsync:Java System Agent\ncompose:build java-system-agent\ncompose:up -d --no-deps --force-recreate --wait --wait-timeout 240 java-system-agent\nrecord'
ACTUAL_CALLS="$(<"${CALL_LOG}")"

if [[ "${ACTUAL_CALLS}" != "${EXPECTED_CALLS}" ]]; then
    printf 'unexpected agent-only deployment calls\nexpected:\n%s\nactual:\n%s\n' \
        "${EXPECTED_CALLS}" "${ACTUAL_CALLS}" >&2
    exit 1
fi

grep -Fq 'Agent-only UAT update completed' "${TEMPORARY_DIRECTORY}/output.log"

