#!/usr/bin/env bash
# Run a closed live knowledge acceptance scenario.
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
KNOWLEDGE_SEED=""
FIXTURE_ID=""
TEST_CLASS=""

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

operator_value() {
    local key="$1"

    if [[ -v "${key}" ]]; then
        printf '%s' "${!key}"
    else
        env_value "${key}"
    fi
}

preflight() {
    [[ -s "${ENV_FILE}" ]] || fail "${ENV_FILE} is missing; run ./deploy.sh and configure GOOGLE_API_KEY"
}

read_live_configuration() {
    local api_key
    local validation_key
    local normalized_key

    api_key="$(operator_value GOOGLE_API_KEY)"
    validation_key="${api_key#"${api_key%%[![:space:]]*}"}"
    validation_key="${validation_key%"${validation_key##*[![:space:]]}"}"
    normalized_key="$(tr '[:upper:]' '[:lower:]' <<< "${validation_key}")"
    [[ -n "${validation_key}" ]] \
        || fail "GOOGLE_API_KEY must be configured for a live knowledge run"
    case "${normalized_key}" in
        poc-*|example|example-*|replace-me|replace-*|your-*|changeme|change-me|test-*|fake-*|dummy-*)
            fail "GOOGLE_API_KEY must be a live provider credential, not a placeholder"
            ;;
    esac

    GOOGLE_MODEL="$(operator_value GOOGLE_GENAI_MODEL)"
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
    export M7_RUN_ID="${RUN_ID}"
    export KNOWLEDGE_RUN_ID="${RUN_ID}"
    export KNOWLEDGE_REPORT_DIRECTORY="${RUN_DIRECTORY}"
}

select_knowledge_scenario() {
    local requested_scenario

    requested_scenario="${1:-$(operator_value KNOWLEDGE_SCENARIO)}"
    case "${requested_scenario:-m7}" in
        m7)
            KNOWLEDGE_SCENARIO=m7
            FIXTURE_ID=m7-knowledge-query
            TEST_CLASS=M7KnowledgeQueryLiveIT
            M7_KNOWLEDGE_LIVE=true
            PAYMENT_KNOWLEDGE_LIVE=false
            ;;
        payment)
            KNOWLEDGE_SCENARIO=payment
            FIXTURE_ID=payment-knowledge-query
            TEST_CLASS=PaymentKnowledgeLiveIT
            M7_KNOWLEDGE_LIVE=false
            PAYMENT_KNOWLEDGE_LIVE=true
            ;;
        *)
            fail "KNOWLEDGE_SCENARIO must be one of: m7, payment"
            ;;
    esac

    case "${KNOWLEDGE_SCENARIO}:${FIXTURE_ID}:${TEST_CLASS}:${M7_KNOWLEDGE_LIVE}:${PAYMENT_KNOWLEDGE_LIVE}" in
        m7:m7-knowledge-query:M7KnowledgeQueryLiveIT:true:false|payment:payment-knowledge-query:PaymentKnowledgeLiveIT:false:true)
            ;;
        *)
            fail "knowledge scenario selection is invalid"
            ;;
    esac
    export KNOWLEDGE_SCENARIO FIXTURE_ID TEST_CLASS M7_KNOWLEDGE_LIVE PAYMENT_KNOWLEDGE_LIVE
    export KNOWLEDGE_FIXTURE_ID="${FIXTURE_ID}"
    export KNOWLEDGE_TEST_CLASS="${TEST_CLASS}"
}

select_knowledge_seed() {
    local supplied_seed
    local canonical_seed

    supplied_seed="$(operator_value M7_KNOWLEDGE_SEED)"
    if [[ -n "${supplied_seed}" ]]; then
        [[ "${supplied_seed}" =~ ^[0-9]+$ ]] \
            || fail "M7_KNOWLEDGE_SEED must be a nonnegative integer"
        canonical_seed="$(sed 's/^0*//' <<< "${supplied_seed}")"
        [[ -n "${canonical_seed}" ]] || canonical_seed=0
        [[ "${#canonical_seed}" -lt 19 \
            || ( "${#canonical_seed}" -eq 19 && "${canonical_seed}" < "9223372036854775807" ) \
            || "${canonical_seed}" == "9223372036854775807" ]] \
            || fail "M7_KNOWLEDGE_SEED must be in decimal range 0..9223372036854775807"
        KNOWLEDGE_SEED="${canonical_seed}"
    else
        KNOWLEDGE_SEED="$(cksum <<< "${RUN_ID}" | awk '{print $1}')"
    fi
    export M7_KNOWLEDGE_SEED="${KNOWLEDGE_SEED}"
}

deploy_stack() {
    local deployment_state

    deployment_state="$(active_deployment_state)"
    case "${deployment_state}" in
        ABSENT)
            "${ROOT}/deploy.sh"
            ;;
        ACTIVE_HEALTHY)
            printf 'knowledge-uat: active UAT stack is healthy; reusing exact deployment\n'
            ;;
        ACTIVE_DEGRADED|ACTIVE_INCONSISTENT)
            fail "active UAT stack is ${deployment_state#ACTIVE_}; refusing to mutate it"
            ;;
        *)
            fail "unsupported active deployment state: ${deployment_state}"
            ;;
    esac
}

active_deployment_state() {
    local rows

    export STARTER_ROOT="${ROOT}"
    rows="$(docker compose \
        --project-name java-agent-uat \
        --env-file "${ENV_FILE}" \
        -f "${ROOT}/compose.yaml" \
        ps --all --format '{{.Service}}|{{.State}}|{{.Health}}')" \
        || fail "could not inspect the active UAT stack"
    bash -c '
        source "$1"
        classify_active_deployment_state "$2" "$3" "$4" "$5"
    ' bash \
        "${ROOT}/deploy.sh" \
        "${rows}" \
        "${ROOT}/deployment-record.txt" \
        "${ROOT}/.runtime/sources/java-system-agent" \
        "${ROOT}/.runtime/sources/java-code-intelligence"
}

read_deployed_revisions() {
    STARTER_SHA="$(starter_sha)"
    AGENT_SHA="$(deployment_sha 'Agent source SHA')"
    SEMANTIC_SHA="$(deployment_sha 'Semantic source SHA')"
    export M7_AGENT_SOURCE_SHA="${AGENT_SHA}"
    export M7_SEMANTIC_SOURCE_SHA="${SEMANTIC_SHA}"
    export KNOWLEDGE_AGENT_SOURCE_SHA="${AGENT_SHA}"
    export KNOWLEDGE_SEMANTIC_SOURCE_SHA="${SEMANTIC_SHA}"
    export KNOWLEDGE_STARTER_SOURCE_SHA="${STARTER_SHA}"
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

knowledge_compose() {
    docker compose \
        --project-name java-agent-uat \
        --env-file "${ENV_FILE}" \
        -f "${ROOT}/compose.yaml" \
        --profile knowledge \
        "$@"
}

knowledge_compose_run() {
    local service="$1"

    knowledge_compose run --rm "${service}"
}

reset_knowledge_runtime() {
    knowledge_compose stop semantic-service
    if ! knowledge_compose_run knowledge-fixture-init; then
        knowledge_compose up --detach --wait semantic-service || true
        fail "could not reset the knowledge fixtures and JDT workspaces"
    fi
    knowledge_compose up --detach --wait semantic-service
    knowledge_compose --profile tools run --rm network-probe
}

ensure_knowledge_fixture_and_database() {
    local response

    export HOST_UID="$(id -u)"
    export HOST_GID="$(id -g)"
    export STARTER_ROOT="${ROOT}"
    reset_knowledge_runtime
    knowledge_compose_run knowledge-db-init
    "${ROOT}/repository.sh" ensure "${FIXTURE_ID}"
    response="$("${ROOT}/repository.sh" revision "${FIXTURE_ID}")"
    FIXTURE_REVISION="$(fixture_revision "${response}")"
}

run_live_scenario() {
    docker compose \
        --project-name java-agent-uat \
        --env-file "${ENV_FILE}" \
        -f "${ROOT}/compose.yaml" \
        --profile knowledge \
        run --rm --no-deps agent-knowledge
}

validate_junit() {
    local junit_file="${RUN_DIRECTORY}/TEST-com.java.system.agent.${TEST_CLASS}.xml"

    [[ -f "${junit_file}" ]] || fail "knowledge JUnit report is missing: ${junit_file}"
    command -v python3 >/dev/null 2>&1 || fail "python3 is required to validate the knowledge JUnit report"
    if ! python3 - "${junit_file}" <<'PY'
import sys
import xml.etree.ElementTree as element_tree

try:
    root = element_tree.parse(sys.argv[1]).getroot()
except element_tree.ParseError:
    sys.exit(1)

if root.tag != "testsuite":
    sys.exit(1)

expected_attributes = {"tests": "1", "failures": "0", "errors": "0", "skipped": "0"}
sys.exit(0 if all(root.attrib.get(key) == value for key, value in expected_attributes.items()) else 1)
PY
    then
        fail "knowledge JUnit testsuite must be exactly tests=1 failures=0 errors=0 skipped=0"
    fi
}

write_manifest() {
    {
        printf 'runId=%s\n' "${RUN_ID}"
        printf 'starterSourceSha=%s\n' "${STARTER_SHA}"
        printf 'agentSourceSha=%s\n' "${AGENT_SHA}"
        printf 'semanticSourceSha=%s\n' "${SEMANTIC_SHA}"
        printf 'scenario=%s\n' "${KNOWLEDGE_SCENARIO}"
        printf 'fixtureId=%s\n' "${FIXTURE_ID}"
        printf 'fixtureRevision=%s\n' "${FIXTURE_REVISION}"
        printf 'model=%s\n' "${GOOGLE_MODEL}"
        printf 'knowledgeSeed=%s\n' "${KNOWLEDGE_SEED}"
    } > "${RUN_DIRECTORY}/manifest.txt"
}

main() {
    preflight
    select_knowledge_scenario "${1:-}"
    read_live_configuration
    create_run_directory
    select_knowledge_seed
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
