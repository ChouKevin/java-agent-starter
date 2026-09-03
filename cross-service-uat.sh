#!/usr/bin/env bash
# Offline MCP recovery acceptance for the disposable Semantic and Runtime deployment.
set -euo pipefail

if [[ "${CROSS_SERVICE_UAT_LOADED:-false}" == true ]]; then
    return 0
fi
CROSS_SERVICE_UAT_LOADED=true

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
ENV_FILE="${ROOT}/.env"
CROSS_SERVICE_EVIDENCE_ROOT="${ROOT}/.runtime/evidence/cross-service-mcp"
CROSS_SERVICE_WAIT_SECONDS="${CROSS_SERVICE_UAT_WAIT_SECONDS:-240}"

source "${ROOT}/deploy.sh"
source "${ROOT}/semantic-index-uat.sh"

cross_service_uat_fail() {
    printf 'cross-service-uat: %s\n' "$*" >&2
    return 1
}

cross_evidence() {
    printf '%s\n' "$*" >> "${CROSS_SERVICE_EVIDENCE_DIRECTORY}/stages.log"
}

prepare_cross_service_evidence() {
    local timestamp
    timestamp="$(date -u +%Y%m%dT%H%M%SZ)-$$"
    umask 077
    mkdir -p "${CROSS_SERVICE_EVIDENCE_ROOT}"
    chmod 0700 "${CROSS_SERVICE_EVIDENCE_ROOT}"
    CROSS_SERVICE_EVIDENCE_DIRECTORY="${CROSS_SERVICE_EVIDENCE_ROOT}/${timestamp}"
    mkdir -p "${CROSS_SERVICE_EVIDENCE_DIRECTORY}"
    chmod 0700 "${CROSS_SERVICE_EVIDENCE_DIRECTORY}"
    : > "${CROSS_SERVICE_EVIDENCE_DIRECTORY}/stages.log"
    chmod 0600 "${CROSS_SERVICE_EVIDENCE_DIRECTORY}/stages.log"
}

copy_fixture_evidence() {
    [[ -d "${EVIDENCE_DIRECTORY}" ]] || return 0
    [[ ! -e "${CROSS_SERVICE_EVIDENCE_DIRECTORY}/semantic-fixture-evidence" ]] || return 0
    cp -R "${EVIDENCE_DIRECTORY}" "${CROSS_SERVICE_EVIDENCE_DIRECTORY}/semantic-fixture-evidence"
    find "${CROSS_SERVICE_EVIDENCE_DIRECTORY}/semantic-fixture-evidence" -type d -exec chmod 0700 {} +
    find "${CROSS_SERVICE_EVIDENCE_DIRECTORY}/semantic-fixture-evidence" -type f -exec chmod 0600 {} +
}

capture_cross_service_failure() {
    local runtime_port
    runtime_port="$(env_or_default SESSION_AGENT_HOST_PORT 8090)"
    cross_evidence "stage=${CROSS_SERVICE_UAT_STAGE:-unknown} result=failed"
    "${COMPOSE[@]}" logs --no-color session-agent-runtime semantic-query \
        > "${CROSS_SERVICE_EVIDENCE_DIRECTORY}/component-logs.txt" 2>&1 || true
    curl --fail --silent --show-error --connect-timeout 5 --max-time 10 \
        "http://127.0.0.1:${runtime_port}/actuator/mcpConnections" \
        > "${CROSS_SERVICE_EVIDENCE_DIRECTORY}/runtime-mcp-connections.json" 2>&1 || true
    [[ -f "${DEPLOYMENT_RECORD_FILE}" ]] && cp "${DEPLOYMENT_RECORD_FILE}" \
        "${CROSS_SERVICE_EVIDENCE_DIRECTORY}/deployment-record.txt" || true
    copy_fixture_evidence || true
    printf 'stage=%s\n' "${CROSS_SERVICE_UAT_STAGE:-unknown}" > "${CROSS_SERVICE_EVIDENCE_DIRECTORY}/failure.txt"
    find "${CROSS_SERVICE_EVIDENCE_DIRECTORY}" -type d -exec chmod 0700 {} +
    find "${CROSS_SERVICE_EVIDENCE_DIRECTORY}" -type f -exec chmod 0600 {} +
}

run_cross_service_stage() {
    local stage="$1" stage_status
    shift
    CROSS_SERVICE_UAT_STAGE="${stage}"
    set +e
    (
        set -eE -o pipefail
        "$@"
    )
    stage_status=$?
    set -e
    if (( stage_status == 0 )); then
        cross_evidence "stage=${stage} result=complete"
        return 0
    fi
    capture_cross_service_failure
    cross_service_uat_fail "stage failed: ${stage}"
}

wait_for_runtime_health() {
    local runtime_port="$1" deadline response
    deadline=$((SECONDS + CROSS_SERVICE_WAIT_SECONDS))
    while (( SECONDS < deadline )); do
        if response="$(curl --fail --silent --show-error --connect-timeout 5 --max-time 30 \
            "http://127.0.0.1:${runtime_port}/actuator/health")" \
            && jq -e '.status == "UP"' <<< "${response}" >/dev/null; then
            return 0
        fi
        sleep 2
    done
    cross_service_uat_fail "Runtime health did not become ready within ${CROSS_SERVICE_WAIT_SECONDS}s"
}

wait_for_semantic_catalog() {
    local runtime_port="$1" deadline response
    deadline=$((SECONDS + CROSS_SERVICE_WAIT_SECONDS))
    while (( SECONDS < deadline )); do
        if response="$(curl --fail --silent --show-error --connect-timeout 5 --max-time 30 \
            "http://127.0.0.1:${runtime_port}/actuator/mcpConnections")" \
            && jq -e '.connections.semantic.state == "AVAILABLE" and .connections.semantic.toolCount == 12' \
                <<< "${response}" >/dev/null; then
            return 0
        fi
        sleep 2
    done
    cross_service_uat_fail "Runtime Semantic MCP catalog did not become available within ${CROSS_SERVICE_WAIT_SECONDS}s"
}

force_recreate_runtime_without_semantic() {
    "${COMPOSE[@]}" up -d --force-recreate --no-deps session-agent-runtime
}

start_semantic_without_runtime_recreation() {
    "${COMPOSE[@]}" up -d --no-recreate semantic-query semantic-query-gateway
}

capture_runtime_container_before() {
    local runtime_container_before
    runtime_container_before="$("${COMPOSE[@]}" ps -q session-agent-runtime)" || {
        cross_service_uat_fail 'Runtime container id could not be read before Semantic recovery'
        return 1
    }
    [[ -n "${runtime_container_before}" ]] \
        || cross_service_uat_fail 'Runtime container id is unavailable before Semantic recovery'
    printf '%s\n' "${runtime_container_before}" > "${CROSS_SERVICE_EVIDENCE_DIRECTORY}/runtime-container-before.txt"
    cross_evidence "stage=runtime-container-before id=${runtime_container_before}"
}

verify_runtime_container_stable() {
    local runtime_container_before runtime_container_after
    [[ -f "${CROSS_SERVICE_EVIDENCE_DIRECTORY}/runtime-container-before.txt" ]] \
        || cross_service_uat_fail 'Runtime container id is unavailable before Semantic recovery'
    runtime_container_before="$(<"${CROSS_SERVICE_EVIDENCE_DIRECTORY}/runtime-container-before.txt")"
    runtime_container_after="$("${COMPOSE[@]}" ps -q session-agent-runtime)" || {
        cross_service_uat_fail 'Runtime container id could not be read after Semantic recovery'
        return 1
    }
    [[ "${runtime_container_before}" == "${runtime_container_after}" ]] \
        || cross_service_uat_fail 'Runtime container changed during Semantic recovery'
    cross_evidence 'stage=runtime-container-stable result=complete'
}

run_semantic_deployed_it() {
    local semantic_port semantic_token
    semantic_port="$(env_or_default SEMANTIC_HOST_PORT 8080)"
    semantic_token="$(env_value SEMANTIC_QUERY_API_TOKEN)"
    [[ -n "${semantic_token}" ]] || cross_service_uat_fail 'SEMANTIC_QUERY_API_TOKEN is blank'
    [[ -f "${SOURCES_DIR}/java-code-intelligence/pom.xml" ]] \
        || cross_service_uat_fail 'Semantic source is unavailable after deployment'
    mvn -q -f "${SOURCES_DIR}/java-code-intelligence/pom.xml" -pl semantic-query -am -DskipTests install
    SEMANTIC_BASE_URL="http://127.0.0.1:${semantic_port}" \
        SEMANTIC_API_TOKEN="${semantic_token}" \
        SEMANTIC_UAT_REPOSITORY=payment-service \
        mvn -q -f "${SOURCES_DIR}/java-code-intelligence/pom.xml" -pl semantic-query \
            -Pdeployed-it -Dtest=SemanticDeploymentIT -DfailIfNoTests=true \
            test
}

run_runtime_fake_backed_tests() {
    [[ -f "${SOURCES_DIR}/session-agent-runtime/pom.xml" ]] \
        || cross_service_uat_fail 'Session Agent Runtime source is unavailable after deployment'
    env -u SEMANTIC_BASE_URL -u SEMANTIC_API_TOKEN -u GOOGLE_API_KEY \
        mvn -q -f "${SOURCES_DIR}/session-agent-runtime/pom.xml" \
            -Dtest=McpToolCatalogTest,ConversationHistoryProjectorTest,MessageJobServiceTest \
            -DfailIfNoTests=true test
}

cross_service_uat_impl() {
    local runtime_port
    prepare_cross_service_evidence
    runtime_port="$(env_or_default SESSION_AGENT_HOST_PORT 8090)"
    COMPOSE=(docker compose --project-name java-agent-uat --env-file "${ENV_FILE}" -f "${ROOT}/compose.yaml")

    run_cross_service_stage clean-deploy-and-fixtures semantic_uat_deploy_initial_r1_impl
    run_cross_service_stage fixture-evidence copy_fixture_evidence
    run_cross_service_stage stop-semantic "${COMPOSE[@]}" stop semantic-query-gateway semantic-query
    run_cross_service_stage recreate-runtime force_recreate_runtime_without_semantic
    run_cross_service_stage runtime-health wait_for_runtime_health "${runtime_port}"
    run_cross_service_stage runtime-container-before capture_runtime_container_before
    run_cross_service_stage start-semantic start_semantic_without_runtime_recreation
    run_cross_service_stage semantic-catalog wait_for_semantic_catalog "${runtime_port}"
    run_cross_service_stage runtime-container-stable verify_runtime_container_stable
    run_cross_service_stage semantic-deployed-it run_semantic_deployed_it
    run_cross_service_stage runtime-fake-backed-tests run_runtime_fake_backed_tests
    cross_evidence 'cross-service-mcp=complete'
}

cross_service_uat_main() {
    [[ "$#" -eq 0 ]] || {
        cross_service_uat_fail 'usage: ./cross-service-uat.sh'
        return 1
    }
    command -v jq >/dev/null 2>&1 || cross_service_uat_fail 'jq is required'
    with_deploy_lock cross_service_uat_impl
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    cross_service_uat_main "$@"
fi
