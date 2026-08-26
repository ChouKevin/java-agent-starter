#!/usr/bin/env bash
# Run the external Session Agent Runtime live acceptance suite against the UAT stack.
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
ENV_FILE="${ROOT}/.env"
RUNTIME_SOURCE="${ROOT}/.runtime/sources/session-agent-runtime"

source "${ROOT}/deploy.sh"
source "${ROOT}/semantic-index-uat.sh"

runtime_uat_fail() {
    printf 'runtime-uat: %s\n' "$*" >&2
    exit 1
}

env_value() {
    local key="$1"
    local line

    line="$(grep -m1 -E "^${key}=" "${ENV_FILE}" 2>/dev/null || true)"
    printf '%s' "${line#*=}"
}

env_or_default() {
    local key="$1"
    local default_value="$2"
    local configured

    configured="$(env_value "${key}")"
    if [[ -n "${configured}" ]]; then
        printf '%s' "${configured}"
    else
        printf '%s' "${default_value}"
    fi
}

runtime_uat_impl() {
    local google_key
    local model
    local runtime_port

    export SEMANTIC_UAT_PROFILE=uat

    google_key="$(env_value GOOGLE_API_KEY)"
    model="$(env_or_default GOOGLE_GENAI_MODEL gemini-3.1-flash-lite)"
    runtime_port="$(env_or_default SESSION_AGENT_HOST_PORT 8090)"
    [[ -n "${google_key}" ]] || runtime_uat_fail "GOOGLE_API_KEY is blank"

    export SESSION_AGENT_LIVE=true
    export SESSION_AGENT_BASE_URL="http://127.0.0.1:${runtime_port}"
    export SESSION_AGENT_HISTORY_KEY="semantic-git-uat-$(date +%s%N)-$$"
    export GOOGLE_API_KEY="${google_key}"
    export GOOGLE_GENAI_MODEL="${model}"
    unset SEMANTIC_BASE_URL SEMANTIC_API_TOKEN

    semantic_uat_deploy_initial_r1_impl
    [[ -f "${RUNTIME_SOURCE}/pom.xml" ]] || runtime_uat_fail "Session Agent Runtime source is unavailable after deployment"
    JAVA_HOME=/usr/lib/jvm/java-21-openjdk-amd64 \
        mvn -q -f "${RUNTIME_SOURCE}/pom.xml" -Dtest=SessionAgentLiveIT#records_repository_catalog_at_r1 test
    semantic_uat_cold_r1_and_rebuild_impl
    semantic_uat_gated_payment_transition_impl session
    JAVA_HOME=/usr/lib/jvm/java-21-openjdk-amd64 \
        mvn -q -f "${RUNTIME_SOURCE}/pom.xml" -Dtest=SessionAgentLiveIT#recovers_payment_query_at_r2 test
    JAVA_HOME=/usr/lib/jvm/java-21-openjdk-amd64 \
        mvn -q -f "${RUNTIME_SOURCE}/pom.xml" -Dtest=SessionAgentLiveIT#completes_five_real_conversation_scenarios_through_http_and_worker test
    semantic_uat_reset_payment_to_v1_impl
    semantic_uat_gated_payment_transition_impl repeat
    evidence 'runtime-uat=complete'
}

runtime_uat_main() {
    [[ "$#" -eq 0 ]] || runtime_uat_fail "usage: ./runtime-uat.sh"
    command -v jq >/dev/null 2>&1 || runtime_uat_fail "jq is required"
    with_deploy_lock runtime_uat_impl
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    runtime_uat_main "$@"
fi
