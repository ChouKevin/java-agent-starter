#!/usr/bin/env bash
# Run the one-shot M7 live knowledge query acceptance scenario.
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
ENV_FILE="${ROOT}/.env"
RUN_ID=""
RUN_DIRECTORY=""
STARTER_SHA=""
AGENT_SHA=""
SEMANTIC_SHA=""
GOOGLE_MODEL=""
FIXTURE_REVISION=""
LIVE_BUDGET_HANDLE_COUNT=1

fail() {
    printf 'knowledge-uat: %s\n' "$*" >&2
    exit 1
}

env_value() {
    local key="$1"
    local line

    line="$(grep -m1 -E "^${key}=" "${ENV_FILE}" 2>/dev/null || true)"
    printf '%s' "${line#*=}"
}

preflight() {
    [[ -s "${ENV_FILE}" ]] || fail "${ENV_FILE} is missing; run ./deploy.sh and configure GOOGLE_API_KEY"
}

read_live_configuration() {
    local api_key
    local normalized_key

    api_key="$(env_value GOOGLE_API_KEY)"
    normalized_key="$(tr '[:upper:]' '[:lower:]' <<< "${api_key}")"
    [[ -n "${api_key}" ]] || fail "GOOGLE_API_KEY must be configured for a live M7 run"
    case "${normalized_key}" in
        poc-*|example|replace-me|your-google-api-key|changeme)
            fail "GOOGLE_API_KEY must be a live provider credential, not a placeholder"
            ;;
    esac

    GOOGLE_MODEL="$(env_value GOOGLE_GENAI_MODEL)"
    [[ -n "${GOOGLE_MODEL}" ]] || GOOGLE_MODEL=gemini-3.1-flash-lite
    [[ "${GOOGLE_MODEL}" =~ ^[A-Za-z0-9._:-]+$ ]] \
        || fail "GOOGLE_GENAI_MODEL contains unsupported characters"

    export GOOGLE_API_KEY="${api_key}"
    export GOOGLE_GENAI_MODEL="${GOOGLE_MODEL}"
}

deployment_sha() {
    local label="$1"
    local record_file="${2:-${ROOT}/deployment-record.txt}"
    local record_line

    case "${label}" in
        'Agent source SHA'|'Semantic source SHA')
            ;;
        *)
            fail "unsupported deployment SHA label: ${label}"
            ;;
    esac
    [[ -f "${record_file}" ]] || fail "deployment record is missing: ${record_file}"
    record_line="$(grep -E -x "${label}: [0-9a-f]{40}" "${record_file}" || true)"
    [[ -n "${record_line}" && "${record_line}" != *$'\n'* ]] \
        || fail "deployment record must contain one exact ${label}"
    printf '%s' "${record_line##*: }"
}

starter_sha() {
    local sha

    sha="$(git -C "${ROOT}" rev-parse HEAD 2>/dev/null)" \
        || fail "Starter worktree does not have a readable Git revision"
    [[ "${sha}" =~ ^[0-9a-f]{40}$ ]] || fail "Starter Git revision is malformed"
    printf '%s' "${sha}"
}

create_run_directory() {
    RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"
    RUN_DIRECTORY="${ROOT}/reports/knowledge-uat/${RUN_ID}"
    mkdir -p "${RUN_DIRECTORY}"
}

deploy_stack() {
    "${ROOT}/deploy.sh"
}

read_deployed_revisions() {
    STARTER_SHA="$(starter_sha)"
    AGENT_SHA="$(deployment_sha 'Agent source SHA')"
    SEMANTIC_SHA="$(deployment_sha 'Semantic source SHA')"
}

fixture_revision() {
    local response="$1"
    local matches

    [[ "${response}" == \{*\} ]] || fail "knowledge fixture response is not compact JSON"
    matches="$(grep -oE '"currentRevision":"[^"]+"' <<< "${response}" || true)"
    [[ "${matches}" == '"currentRevision":"FIXTURE"' ]] \
        || fail "knowledge fixture revision must be exactly FIXTURE"
    printf 'FIXTURE'
}

knowledge_compose_run() {
    local service="$1"

    docker compose \
        --project-name java-agent-uat \
        --env-file "${ENV_FILE}" \
        -f "${ROOT}/compose.yaml" \
        --profile knowledge \
        run --rm "${service}"
}

ensure_knowledge_fixture_and_database() {
    local response

    export M7_RUN_ID="${RUN_ID}"
    export HOST_UID="$(id -u)"
    export HOST_GID="$(id -g)"
    export STARTER_ROOT="${ROOT}"
    knowledge_compose_run knowledge-fixture-init
    knowledge_compose_run knowledge-db-init
    "${ROOT}/repository.sh" ensure m7-knowledge-query
    response="$("${ROOT}/repository.sh" revision m7-knowledge-query)"
    FIXTURE_REVISION="$(fixture_revision "${response}")"
}

run_live_scenario() {
    docker compose \
        --project-name java-agent-uat \
        --env-file "${ENV_FILE}" \
        -f "${ROOT}/compose.yaml" \
        --profile knowledge \
        run --rm agent-knowledge
}

require_junit_attribute() {
    local attribute="$1"
    local expected="$2"
    local matches

    matches="$(grep -oE "[[:space:]]${attribute}=\"${expected}\"" "${RUN_DIRECTORY}/TEST-com.java.system.agent.M7KnowledgeQueryLiveIT.xml" || true)"
    [[ -n "${matches}" && "${matches}" != *$'\n'* ]] \
        || fail "M7 JUnit must contain exactly one ${attribute}=${expected}"
}

validate_junit() {
    local junit_file="${RUN_DIRECTORY}/TEST-com.java.system.agent.M7KnowledgeQueryLiveIT.xml"

    [[ -f "${junit_file}" ]] || fail "M7 JUnit report is missing: ${junit_file}"
    require_junit_attribute tests 1
    require_junit_attribute failures 0
    require_junit_attribute errors 0
    require_junit_attribute skipped 0
}

write_manifest() {
    {
        printf 'runId=%s\n' "${RUN_ID}"
        printf 'starterSourceSha=%s\n' "${STARTER_SHA}"
        printf 'agentSourceSha=%s\n' "${AGENT_SHA}"
        printf 'semanticSourceSha=%s\n' "${SEMANTIC_SHA}"
        printf 'fixtureId=m7-knowledge-query\n'
        printf 'fixtureRevision=%s\n' "${FIXTURE_REVISION}"
        printf 'model=%s\n' "${GOOGLE_MODEL}"
        printf 'budgetHandleCount=%s\n' "${LIVE_BUDGET_HANDLE_COUNT}"
    } > "${RUN_DIRECTORY}/manifest.txt"
}

main() {
    preflight
    read_live_configuration
    create_run_directory
    deploy_stack
    read_deployed_revisions
    ensure_knowledge_fixture_and_database
    write_manifest
    run_live_scenario
    validate_junit
    printf 'knowledge-uat: PASS starter=%s agent=%s semantic=%s fixture=%s model=%s report=%s\n' \
        "${STARTER_SHA}" "${AGENT_SHA}" "${SEMANTIC_SHA}" "${FIXTURE_REVISION}" \
        "${GOOGLE_MODEL}" "${RUN_DIRECTORY}"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
