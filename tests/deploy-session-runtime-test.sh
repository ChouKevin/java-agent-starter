#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
temporary_directory="$(mktemp -d)"
call_log="${temporary_directory}/calls.log"

cleanup() {
    rm -rf "${temporary_directory}"
}
trap cleanup EXIT

source "${ROOT}/deploy.sh"

create_env_if_missing() { :; }
env_value() {
    case "$1" in
        SEMANTIC_API_TOKEN) printf 'semantic-contract-token' ;;
        GOOGLE_API_KEY) printf 'google-contract-token' ;;
        *) printf '' ;;
    esac
}
env_or_default() { printf '%s' "$2"; }
preflight_active_deployment() { printf 'preflight\n' >> "${call_log}"; }
prepare_host_paths() { printf 'prepare\n' >> "${call_log}"; }
sync_source() { printf 'sync:%s\n' "$1" >> "${call_log}"; }
write_deployment_record() { printf 'record\n' >> "${call_log}"; }

docker() {
    local -a arguments=("$@")
    local index
    if [[ "$*" == "compose version" ]]; then
        return
    fi
    for ((index = 0; index < ${#arguments[@]}; index++)); do
        case "${arguments[${index}]}" in
            ps)
                printf 'session-agent-postgres|running|healthy\n'
                printf 'semantic-service|running|\n'
                printf 'session-agent-runtime|running|\n'
                return
                ;;
            build|up|--profile)
                printf 'compose:%s\n' "${arguments[*]:${index}}" >> "${call_log}"
                return
                ;;
        esac
    done
}

main > "${temporary_directory}/output.log"

expected=$'preflight\nprepare\nsync:Session Agent Runtime\nsync:Java Code Intelligence\ncompose:build session-agent-runtime semantic-service\ncompose:--profile setup run --rm fixture-init\ncompose:up -d --remove-orphans --wait --wait-timeout 240\ncompose:--profile tools run --rm network-probe\nrecord'
actual="$(<"${call_log}")"
[[ "${actual}" == "${expected}" ]] || {
    printf 'unexpected deployment calls\nexpected:\n%s\nactual:\n%s\n' \
        "${expected}" "${actual}" >&2
    exit 1
}
grep -Fq 'Session Agent UAT stack started' "${temporary_directory}/output.log"
