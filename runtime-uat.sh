#!/usr/bin/env bash
# Run the external Session Agent Runtime live acceptance suite against the UAT stack.
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
ENV_FILE="${ROOT}/.env"
RUNTIME_SOURCE="${ROOT}/.runtime/sources/session-agent-runtime"

source "${ROOT}/deploy.sh"

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

runtime_uat_main() {
    local semantic_token
    local google_key
    local model
    local runtime_port
    local semantic_port

    [[ "$#" -eq 0 ]] || runtime_uat_fail "usage: ./runtime-uat.sh"
    main
    [[ -f "${RUNTIME_SOURCE}/pom.xml" ]] || runtime_uat_fail "Session Agent Runtime source is unavailable"

    semantic_token="$(env_value SEMANTIC_API_TOKEN)"
    google_key="$(env_value GOOGLE_API_KEY)"
    model="$(env_or_default GOOGLE_GENAI_MODEL gemini-3.1-flash-lite)"
    runtime_port="$(env_or_default SESSION_AGENT_HOST_PORT 8090)"
    semantic_port="$(env_or_default SEMANTIC_HOST_PORT 8080)"
    [[ -n "${semantic_token}" ]] || runtime_uat_fail "SEMANTIC_API_TOKEN is blank"
    [[ -n "${google_key}" ]] || runtime_uat_fail "GOOGLE_API_KEY is blank"

    export SESSION_AGENT_LIVE=true
    export SESSION_AGENT_BASE_URL="http://127.0.0.1:${runtime_port}"
    export SEMANTIC_BASE_URL="http://127.0.0.1:${semantic_port}"
    export SEMANTIC_API_TOKEN="${semantic_token}"
    export GOOGLE_API_KEY="${google_key}"
    export GOOGLE_GENAI_MODEL="${model}"

    JAVA_HOME=/usr/lib/jvm/java-21-openjdk-amd64 \
        mvn -q -f "${RUNTIME_SOURCE}/pom.xml" -Dtest=SessionAgentLiveIT test
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    runtime_uat_main "$@"
fi
