#!/usr/bin/env bash
# Clone, build, and start the UAT stack from one repository.
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
ENV_FILE="${ROOT}/.env"
SOURCES_DIR="${ROOT}/.runtime/sources"
STARTUP_WAIT_SECONDS=240

fail() {
    printf 'deploy: %s\n' "$*" >&2
    exit 1
}

env_value() {
    local key="$1"
    local line

    line="$(grep -m1 -E "^${key}=" "${ENV_FILE}" 2>/dev/null || true)"
    printf '%s' "${line#*=}"
}

create_env_if_missing() {
    local token

    if [[ -e "${ENV_FILE}" ]]; then
        [[ -s "${ENV_FILE}" ]] || fail "${ENV_FILE} exists but is empty"
        return
    fi
    token="$(od -An -N32 -tx1 /dev/urandom | tr -d ' \n')"
    sed "s/^SEMANTIC_API_TOKEN=$/SEMANTIC_API_TOKEN=${token}/" \
        "${ROOT}/.env.example" > "${ENV_FILE}"
    chmod 0600 "${ENV_FILE}"
    printf 'deploy: generated %s with a random shared API token\n' "${ENV_FILE}"
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

sync_source() {
    local label="$1"
    local url="$2"
    local branch="$3"
    local directory="$4"
    local actual

    if [[ ! -e "${directory}" ]]; then
        git clone --branch "${branch}" --single-branch "${url}" "${directory}"
    fi
    [[ -d "${directory}/.git" ]] || fail "${label} source is not a Git checkout: ${directory}"

    actual="$(git -C "${directory}" remote get-url origin)"
    [[ "${actual}" == "${url}" ]] \
        || fail "${label} origin mismatch: expected ${url}, found ${actual}"
    actual="$(git -C "${directory}" symbolic-ref --quiet --short HEAD || true)"
    [[ "${actual}" == "${branch}" ]] \
        || fail "${label} branch mismatch: expected ${branch}, found ${actual:-detached HEAD}"
    [[ -z "$(git -C "${directory}" status --porcelain)" ]] \
        || fail "${label} source has local changes: ${directory}"

    git -C "${directory}" fetch origin "${branch}"
    git -C "${directory}" merge --ff-only "origin/${branch}"
    [[ "$(git -C "${directory}" rev-parse HEAD)" == "$(git -C "${directory}" rev-parse "origin/${branch}")" ]] \
        || fail "${label} source contains commits not present on origin/${branch}"
}

prepare_host_paths() {
    local log_directory

    mkdir -p \
        "${SOURCES_DIR}" \
        "${ROOT}/backups" \
        "${ROOT}/data/repositories" \
        "${ROOT}/data/jdtls-workspaces"
    for log_directory in "${ROOT}/logs/agent" "${ROOT}/logs/semantic"; do
        if [[ ! -d "${log_directory}" ]]; then
            mkdir -p "${log_directory}"
            chmod 0755 "${log_directory}"
        fi
    done
    chmod 0700 "${ROOT}/backups"
    chmod 0644 "${ROOT}/config/semantic-repositories.yml"
}

write_deployment_record() {
    {
        printf 'deployment timestamp: %s\n' "$(date --iso-8601=seconds)"
        printf 'Agent source SHA: %s\n' "$(git -C "${SOURCES_DIR}/java-system-agent" rev-parse HEAD)"
        printf 'Semantic source SHA: %s\n' "$(git -C "${SOURCES_DIR}/java-code-intelligence" rev-parse HEAD)"
    } > "${ROOT}/deployment-record.txt"
}

main() {
    local agent_url
    local agent_ref
    local semantic_url
    local semantic_ref
    local token
    local -a compose

    command -v git >/dev/null 2>&1 || fail "git is required"
    command -v docker >/dev/null 2>&1 || fail "docker is required"
    docker compose version >/dev/null 2>&1 || fail "docker compose is required"
    create_env_if_missing
    token="$(env_value SEMANTIC_API_TOKEN)"
    [[ -n "${token}" ]] || fail "SEMANTIC_API_TOKEN is blank in ${ENV_FILE}"

    agent_url="$(env_or_default AGENT_GIT_URL git@github.com:ChouKevin/java-system-agent.git)"
    agent_ref="$(env_or_default AGENT_GIT_REF uat)"
    semantic_url="$(env_or_default SEMANTIC_GIT_URL git@github.com:ChouKevin/java-code-intelligence.git)"
    semantic_ref="$(env_or_default SEMANTIC_GIT_REF uat)"

    prepare_host_paths
    sync_source "Java System Agent" "${agent_url}" "${agent_ref}" "${SOURCES_DIR}/java-system-agent"
    sync_source "Java Code Intelligence" "${semantic_url}" "${semantic_ref}" "${SOURCES_DIR}/java-code-intelligence"

    export STARTER_ROOT="${ROOT}"
    compose=(docker compose --project-name java-agent-uat --env-file "${ENV_FILE}" -f "${ROOT}/compose.yaml")
    "${compose[@]}" build java-system-agent semantic-service
    "${compose[@]}" --profile setup run --rm permissions-init
    "${compose[@]}" up -d --wait --wait-timeout "${STARTUP_WAIT_SECONDS}"
    "${compose[@]}" --profile tools run --rm network-probe
    write_deployment_record
    printf 'deploy: UAT stack started; see %s\n' "${ROOT}/deployment-record.txt"
}

main "$@"
