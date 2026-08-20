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
prepare_host_paths() { :; }
prepare_sources() {
    printf 'sources:%s:%s:%s:%s\n' "$1" "$2" "$3" "$4" >> "${call_log}"
}
clear_deployment_record() { printf 'record-clear\n' >> "${call_log}"; }
write_deployment_record() { printf 'record\n' >> "${call_log}"; }

semantic_probe_fails=0
docker() {
    local -a arguments=("$@")
    local index

    if [[ "$*" == "compose version" ]]; then
        return
    fi
    for ((index = 0; index < ${#arguments[@]}; index++)); do
        case "${arguments[${index}]}" in
            build|down|up|--profile)
                printf 'compose:%s\n' "${arguments[*]:${index}}" >> "${call_log}"
                if [[ "${semantic_probe_fails}" -eq 1 && "${arguments[*]:${index}}" == "--profile semantic-check run --rm semantic-probe" ]]; then
                    return 1
                fi
                return
                ;;
        esac
    done
}

main > "${temporary_directory}/output.log"

expected=$'sources:git@github.com:ChouKevin/session-agent-runtime.git:main:git@github.com:ChouKevin/java-code-intelligence.git:uat\ncompose:build semantic-service session-agent-runtime\nrecord-clear\ncompose:down --remove-orphans --volumes\ncompose:up -d --wait --wait-timeout 240 session-agent-postgres\ncompose:--profile setup run --rm fixture-init\ncompose:up -d --wait --wait-timeout 240 semantic-service\ncompose:--profile semantic-check run --rm semantic-probe\ncompose:up -d --wait --wait-timeout 240 session-agent-runtime\ncompose:--profile runtime-check run --rm runtime-probe\nrecord'
actual="$(<"${call_log}")"
[[ "${actual}" == "${expected}" ]] || {
    printf 'unexpected deployment calls\nexpected:\n%s\nactual:\n%s\n' \
        "${expected}" "${actual}" >&2
    exit 1
}
grep -Fq 'Session Agent UAT stack started' "${temporary_directory}/output.log"

: > "${call_log}"
eval "exec ${DEPLOY_LOCK_FD}>&-"
semantic_probe_fails=1
set +e
(set -e; main) > "${temporary_directory}/semantic-probe-failure.log" 2>&1
failure_status=$?
set -e
[[ "${failure_status}" -ne 0 ]] || {
    printf 'semantic probe failure unexpectedly succeeded\n' >&2
    exit 1
}
actual="$(<"${call_log}")"
expected_failure=$'sources:git@github.com:ChouKevin/session-agent-runtime.git:main:git@github.com:ChouKevin/java-code-intelligence.git:uat\ncompose:build semantic-service session-agent-runtime\nrecord-clear\ncompose:down --remove-orphans --volumes\ncompose:up -d --wait --wait-timeout 240 session-agent-postgres\ncompose:--profile setup run --rm fixture-init\ncompose:up -d --wait --wait-timeout 240 semantic-service\ncompose:--profile semantic-check run --rm semantic-probe'
[[ "${actual}" == "${expected_failure}" ]] || {
    printf 'semantic probe failure started Runtime, probed Runtime, or wrote a record\nactual:\n%s\n' "${actual}" >&2
    exit 1
}
