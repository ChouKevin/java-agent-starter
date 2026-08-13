#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
TEMPORARY_DIRECTORY="$(mktemp -d)"

cleanup() {
    rm -rf "${TEMPORARY_DIRECTORY}"
}

trap cleanup EXIT

assert_equals() {
    local expected="$1"
    local actual="$2"
    local description="$3"

    [[ "${actual}" == "${expected}" ]] \
        || {
            printf 'expected %s, got %s: %s\n' "${expected}" "${actual}" "${description}" >&2
            exit 1
        }
}

assert_fails_without_sync() {
    local rows="$1"
    local record_file="$2"
    local agent_directory="$3"
    local semantic_directory="$4"
    local expected_hint="$5"
    local sync_marker="${TEMPORARY_DIRECTORY}/sync-called"
    local output

    sync_source() {
        touch "${sync_marker}"
    }

    if output="$(preflight_active_deployment \
        "${rows}" "${record_file}" "${agent_directory}" "${semantic_directory}" 2>&1)"; then
        printf 'expected preflight to fail\n' >&2
        exit 1
    fi
    [[ "${output}" == *"${expected_hint}"* ]] || {
        printf 'preflight did not provide the expected recovery hint\n' >&2
        exit 1
    }
    [[ ! -e "${sync_marker}" ]] || {
        printf 'preflight invoked sync_source\n' >&2
        exit 1
    }
}

grep -Fq 'if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then' "${ROOT}/deploy.sh" || {
    printf 'deploy.sh must guard main when sourced\n' >&2
    exit 1
}

source "${ROOT}/deploy.sh"

HEALTHY_ROWS=$'postgres|running|healthy\nsemantic-service|running|\njava-system-agent|running|healthy'

if preflight_agent_only_deployment \
    "" \
    "${TEMPORARY_DIRECTORY}/missing-record.txt" \
    "${TEMPORARY_DIRECTORY}/missing-agent" \
    "${TEMPORARY_DIRECTORY}/missing-semantic" >/dev/null 2>&1; then
    printf 'expected agent-only preflight to reject an absent stack\n' >&2
    exit 1
fi

assert_equals "ABSENT" "$(classify_compose_rows "")" "empty Compose rows are absent"
assert_equals "ACTIVE_HEALTHY" "$(classify_compose_rows "${HEALTHY_ROWS}")" "required running services are healthy"
assert_equals "ACTIVE_DEGRADED" \
    "$(classify_compose_rows $'postgres|running|healthy\nsemantic-service|running|healthy')" \
    "missing required service is degraded"
assert_equals "ACTIVE_DEGRADED" \
    "$(classify_compose_rows $'postgres|running|unhealthy\nsemantic-service|running|healthy\njava-system-agent|running|healthy')" \
    "unhealthy service is degraded"
assert_equals "ACTIVE_DEGRADED" \
    "$(classify_compose_rows $'postgres|restarting|\nsemantic-service|running|healthy\njava-system-agent|running|healthy')" \
    "restarting service is degraded"
assert_fails_without_sync \
    $'postgres|restarting|\nsemantic-service|running|healthy\njava-system-agent|running|healthy' \
    "${TEMPORARY_DIRECTORY}/missing-record.txt" \
    "${TEMPORARY_DIRECTORY}/missing-agent" \
    "${TEMPORARY_DIRECTORY}/missing-semantic" \
    'docker compose --project-name java-agent-uat logs postgres semantic-service java-system-agent'

AGENT_DIRECTORY="${TEMPORARY_DIRECTORY}/agent"
SEMANTIC_DIRECTORY="${TEMPORARY_DIRECTORY}/semantic"
RECORD_FILE="${TEMPORARY_DIRECTORY}/deployment-record.txt"
for repository_directory in "${AGENT_DIRECTORY}" "${SEMANTIC_DIRECTORY}"; do
    git init --quiet "${repository_directory}"
    git -C "${repository_directory}" config user.email deploy-state-test@example.invalid
    git -C "${repository_directory}" config user.name deploy-state-test
    git -C "${repository_directory}" commit --quiet --allow-empty -m initial
done

AGENT_SHA="$(git -C "${AGENT_DIRECTORY}" rev-parse HEAD)"
SEMANTIC_SHA="$(git -C "${SEMANTIC_DIRECTORY}" rev-parse HEAD)"
printf 'Agent source SHA: %s\nSemantic source SHA: %s\n' "${AGENT_SHA}" "${SEMANTIC_SHA}" > "${RECORD_FILE}"

deployment_record_matches_sources "${RECORD_FILE}" "${AGENT_DIRECTORY}" "${SEMANTIC_DIRECTORY}"
preflight_agent_only_deployment \
    "${HEALTHY_ROWS}" "${RECORD_FILE}" "${AGENT_DIRECTORY}" "${SEMANTIC_DIRECTORY}" >/dev/null
assert_equals "ACTIVE_HEALTHY" \
    "$(classify_active_deployment_state "${HEALTHY_ROWS}" "${RECORD_FILE}" "${AGENT_DIRECTORY}" "${SEMANTIC_DIRECTORY}")" \
    "matching deployment record keeps a healthy stack healthy"
assert_fails_without_sync \
    "${HEALTHY_ROWS}" "${TEMPORARY_DIRECTORY}/missing-record.txt" "${AGENT_DIRECTORY}" "${SEMANTIC_DIRECTORY}" \
    'docker compose --project-name java-agent-uat ps --all'

printf 'Agent source SHA: %s\nSemantic source SHA: %040d\n' "${AGENT_SHA}" 0 > "${RECORD_FILE}"
if deployment_record_matches_sources "${RECORD_FILE}" "${AGENT_DIRECTORY}" "${SEMANTIC_DIRECTORY}"; then
    printf 'expected mismatching deployment record to fail\n' >&2
    exit 1
fi
assert_equals "ACTIVE_INCONSISTENT" \
    "$(classify_active_deployment_state "${HEALTHY_ROWS}" "${RECORD_FILE}" "${AGENT_DIRECTORY}" "${SEMANTIC_DIRECTORY}")" \
    "mismatching deployment record is inconsistent"
assert_fails_without_sync \
    "${HEALTHY_ROWS}" "${RECORD_FILE}" "${AGENT_DIRECTORY}" "${SEMANTIC_DIRECTORY}" \
    'docker compose --project-name java-agent-uat ps --all'
