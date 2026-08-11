#!/usr/bin/env bash
# Run the exact-revision cross-service compatibility gate against the UAT stack.
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
RUN_ID=""
RUN_DIRECTORY=""
AGENT_SHA=""
SEMANTIC_SHA=""
AGENT_FIXTURE_SHA=""
DISCOVERY_FIXTURE_REVISION=""

fail() {
    printf 'contract-uat: %s\n' "$*" >&2
    exit 1
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

repository_revision() {
    local response="$1"
    local matches
    local revision

    [[ "${response}" == \{*\} ]] || fail "repository response is not compact JSON"
    matches="$(grep -oE '"currentRevision":"[0-9a-f]{40}"' <<< "${response}" || true)"
    [[ -n "${matches}" && "${matches}" != *$'\n'* ]] \
        || fail "repository response does not contain one exact currentRevision"
    revision="${matches#*:\"}"
    revision="${revision%\"}"
    [[ "${revision}" =~ ^[0-9a-f]{40}$ ]] \
        || fail "repository response does not contain an exact currentRevision"
    printf '%s' "${revision}"
}

create_run_directory() {
    RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"
    RUN_DIRECTORY="${ROOT}/reports/contract-uat/${RUN_ID}"
    mkdir -p "${RUN_DIRECTORY}"
}

write_manifest() {
    {
        printf 'runId=%s\n' "${RUN_ID}"
        printf 'agentSourceSha=%s\n' "${AGENT_SHA}"
        printf 'semanticSourceSha=%s\n' "${SEMANTIC_SHA}"
        printf 'agentFixtureSha=%s\n' "${AGENT_FIXTURE_SHA}"
        printf 'discoveryFixtureId=m6-semantic-contract\n'
        printf 'discoveryFixtureRevision=%s\n' "${DISCOVERY_FIXTURE_REVISION}"
    } > "${RUN_DIRECTORY}/manifest.txt"
}

write_testcase() {
    local name="$1"
    local status="$2"

    case "${status}" in
        PASS)
            printf '  <testcase classname="contract-uat" name="%s"/>\n' "${name}"
            ;;
        FAIL)
            printf '  <testcase classname="contract-uat" name="%s">\n' "${name}"
            printf '    <failure message="%s contract failed"/>\n' "${name}"
            printf '  </testcase>\n'
            ;;
        SKIPPED)
            printf '  <testcase classname="contract-uat" name="%s">\n' "${name}"
            printf '    <skipped message="not run because semantic-mcp failed"/>\n'
            printf '  </testcase>\n'
            ;;
        *)
            fail "unsupported JUnit status for ${name}: ${status}"
            ;;
    esac
}

write_summary_junit() {
    local semantic_status="$1"
    local agent_status="$2"
    local failures=0
    local skipped=0

    [[ "${semantic_status}" == "PASS" || "${semantic_status}" == "FAIL" ]] \
        || fail "invalid Semantic JUnit status: ${semantic_status}"
    [[ "${agent_status}" == "PASS" || "${agent_status}" == "FAIL" \
        || "${agent_status}" == "SKIPPED" ]] \
        || fail "invalid Agent JUnit status: ${agent_status}"
    [[ "${semantic_status}" == "PASS" ]] || failures=$((failures + 1))
    if [[ "${agent_status}" == "FAIL" ]]; then
        failures=$((failures + 1))
    elif [[ "${agent_status}" == "SKIPPED" ]]; then
        skipped=$((skipped + 1))
    fi

    {
        printf '<testsuite name="contract-uat" tests="3" failures="%s" skipped="%s">\n' \
            "${failures}" "${skipped}"
        printf '  <properties>\n'
        printf '    <property name="runId" value="%s"/>\n' "${RUN_ID}"
        printf '    <property name="agentSha" value="%s"/>\n' "${AGENT_SHA}"
        printf '    <property name="semanticSha" value="%s"/>\n' "${SEMANTIC_SHA}"
        printf '    <property name="agentFixtureSha" value="%s"/>\n' "${AGENT_FIXTURE_SHA}"
        printf '    <property name="discoveryFixtureId" value="m6-semantic-contract"/>\n'
        printf '    <property name="discoveryFixtureRevision" value="%s"/>\n' \
            "${DISCOVERY_FIXTURE_REVISION}"
        printf '  </properties>\n'
        write_testcase fixture PASS
        write_testcase semantic-mcp "${semantic_status}"
        write_testcase agent-http "${agent_status}"
        printf '</testsuite>\n'
    } > "${RUN_DIRECTORY}/summary.xml"
}

deploy_stack() {
    "${ROOT}/deploy.sh"
}

read_deployed_revisions() {
    AGENT_SHA="$(deployment_sha 'Agent source SHA')"
    SEMANTIC_SHA="$(deployment_sha 'Semantic source SHA')"
}

pin_agent_fixture() {
    local repository_response
    local repository_sha

    "${ROOT}/repository.sh" ensure java-system-agent
    "${ROOT}/repository.sh" sync java-system-agent
    "${ROOT}/repository.sh" checkout java-system-agent "${AGENT_SHA}"
    repository_response="$("${ROOT}/repository.sh" revision java-system-agent)"
    repository_sha="$(repository_revision "${repository_response}")"
    [[ "${repository_sha}" == "${AGENT_SHA}" ]] \
        || fail "fixture revision mismatch: expected ${AGENT_SHA}, found ${repository_sha}"
    AGENT_FIXTURE_SHA="${repository_sha}"
}

ensure_discovery_fixture() {
    local response

    "${ROOT}/repository.sh" ensure m6-semantic-contract
    response="$("${ROOT}/repository.sh" revision m6-semantic-contract)"
    [[ "${response}" == *'"currentRevision":"FIXTURE"'* ]] \
        || fail "discovery fixture revision must be FIXTURE"
    DISCOVERY_FIXTURE_REVISION=FIXTURE
}

prepare_contract_environment() {
    export M6_AGENT_REPO_ID=java-system-agent
    export M6_AGENT_EXPECTED_REVISION="${AGENT_SHA}"
    export M6_DISCOVERY_REPO_ID=m6-semantic-contract
    export M6_DISCOVERY_EXPECTED_REVISION="${DISCOVERY_FIXTURE_REVISION}"
    export M6_RUN_ID="${RUN_ID}"
    export HOST_UID="$(id -u)"
    export HOST_GID="$(id -g)"
    export STARTER_ROOT="${ROOT}"
    export KNOWLEDGE_REPORT_DIRECTORY="${RUN_DIRECTORY}"
}

run_contract_phase() {
    local phase="$1"
    local service

    case "${phase}" in
        semantic-mcp)
            service=semantic-contract
            ;;
        agent-http)
            service=agent-contract
            ;;
        *)
            fail "unknown contract phase: ${phase}"
            ;;
    esac
    docker compose \
        --project-name java-agent-uat \
        --env-file "${ROOT}/.env" \
        -f "${ROOT}/compose.yaml" \
        --profile contract \
        run --rm "${service}"
}

print_failure_context() {
    local phase="$1"

    printf 'contract-uat: FAIL phase=%s agent=%s semantic=%s agentFixture=%s discoveryFixture=%s report=%s\n' \
        "${phase}" "${AGENT_SHA}" "${SEMANTIC_SHA}" "${AGENT_FIXTURE_SHA}" \
        "${DISCOVERY_FIXTURE_REVISION}" "${RUN_DIRECTORY}" >&2
    printf '%s\n' \
        'docker compose --project-name java-agent-uat --env-file .env -f compose.yaml logs semantic-service' \
        'docker compose --project-name java-agent-uat --env-file .env -f compose.yaml logs java-system-agent' >&2
}

finish_failure() {
    local phase="$1"

    case "${phase}" in
        semantic-mcp)
            write_summary_junit FAIL SKIPPED
            ;;
        agent-http)
            write_summary_junit PASS FAIL
            ;;
        *)
            fail "unknown failed phase: ${phase}"
            ;;
    esac
    print_failure_context "${phase}"
    return 1
}

main() {
    create_run_directory
    if ! deploy_stack; then
        return 1
    fi
    read_deployed_revisions
    pin_agent_fixture
    ensure_discovery_fixture
    write_manifest
    prepare_contract_environment

    if ! run_contract_phase semantic-mcp; then
        finish_failure semantic-mcp || return 1
    fi
    if ! run_contract_phase agent-http; then
        finish_failure agent-http || return 1
    fi

    write_summary_junit PASS PASS
    printf 'contract-uat: PASS agent=%s semantic=%s fixture=%s discoveryFixture=%s report=%s\n' \
        "${AGENT_SHA}" "${SEMANTIC_SHA}" "${AGENT_FIXTURE_SHA}" \
        "${DISCOVERY_FIXTURE_REVISION}" "${RUN_DIRECTORY}"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
