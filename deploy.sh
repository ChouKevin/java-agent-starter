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
    local semantic_token
    local postgres_password

    if [[ -e "${ENV_FILE}" ]]; then
        [[ -s "${ENV_FILE}" ]] || fail "${ENV_FILE} exists but is empty"
        return
    fi
    semantic_token="$(od -An -N32 -tx1 /dev/urandom | tr -d ' \n')"
    postgres_password="$(od -An -N32 -tx1 /dev/urandom | tr -d ' \n')"
    sed \
        -e "s/^SEMANTIC_API_TOKEN=$/SEMANTIC_API_TOKEN=${semantic_token}/" \
        -e "s/^SESSION_AGENT_POSTGRES_PASSWORD=$/SESSION_AGENT_POSTGRES_PASSWORD=${postgres_password}/" \
        "${ROOT}/.env.example" > "${ENV_FILE}"
    chmod 0600 "${ENV_FILE}"
    printf 'deploy: generated %s with local Semantic and PostgreSQL secrets\n' "${ENV_FILE}"
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

compose_service_is_healthy() {
    local state="$1"
    local health="$2"

    [[ "${state}" == "running" ]] \
        && [[ -z "${health}" || "${health}" == "healthy" ]]
}

classify_compose_rows() {
    local rows="$1"
    local service
    local state
    local health
    local postgres_state=""
    local postgres_health=""
    local semantic_state=""
    local semantic_health=""
    local runtime_state=""
    local runtime_health=""

    if [[ -z "${rows//[[:space:]]/}" ]]; then
        printf 'ABSENT'
        return
    fi

    while IFS='|' read -r service state health; do
        case "${service}" in
            session-agent-postgres)
                postgres_state="${state}"
                postgres_health="${health}"
                ;;
            semantic-service)
                semantic_state="${state}"
                semantic_health="${health}"
                ;;
            session-agent-runtime)
                runtime_state="${state}"
                runtime_health="${health}"
                ;;
        esac
    done <<< "${rows}"

    if compose_service_is_healthy "${postgres_state}" "${postgres_health}" \
        && compose_service_is_healthy "${semantic_state}" "${semantic_health}" \
        && compose_service_is_healthy "${runtime_state}" "${runtime_health}"; then
        printf 'ACTIVE_HEALTHY'
    else
        printf 'ACTIVE_DEGRADED'
    fi
}

recorded_source_sha() {
    local record_file="$1"
    local source="$2"
    local record_line

    [[ -f "${record_file}" ]] || return 1
    case "${source}" in
        'Session Agent'|Semantic)
            ;;
        *)
            return 1
            ;;
    esac

    record_line="$(grep -E -x "${source} source SHA: [0-9a-f]{40}" "${record_file}" || true)"
    [[ -n "${record_line}" && "${record_line}" != *$'\n'* ]] || return 1
    printf '%s' "${record_line##*: }"
}

deployment_record_matches_sources() {
    local record_file="$1"
    local runtime_directory="$2"
    local semantic_directory="$3"
    local recorded_runtime_sha
    local recorded_semantic_sha
    local runtime_sha
    local semantic_sha

    [[ -e "${runtime_directory}/.git" && -e "${semantic_directory}/.git" ]] || return 1
    recorded_runtime_sha="$(recorded_source_sha "${record_file}" 'Session Agent')" || return 1
    recorded_semantic_sha="$(recorded_source_sha "${record_file}" Semantic)" || return 1
    runtime_sha="$(git -C "${runtime_directory}" rev-parse HEAD 2>/dev/null)" || return 1
    semantic_sha="$(git -C "${semantic_directory}" rev-parse HEAD 2>/dev/null)" || return 1
    [[ "${recorded_runtime_sha}" == "${runtime_sha}" && "${recorded_semantic_sha}" == "${semantic_sha}" ]]
}

classify_active_deployment_state() {
    local rows="$1"
    local record_file="$2"
    local runtime_directory="$3"
    local semantic_directory="$4"
    local compose_state

    compose_state="$(classify_compose_rows "${rows}")"
    if [[ "${compose_state}" == "ACTIVE_HEALTHY" ]] \
        && ! deployment_record_matches_sources \
            "${record_file}" "${runtime_directory}" "${semantic_directory}"; then
        printf 'ACTIVE_INCONSISTENT'
    else
        printf '%s' "${compose_state}"
    fi
}

preflight_active_deployment() {
    local rows="$1"
    local record_file="$2"
    local runtime_directory="$3"
    local semantic_directory="$4"
    local deployment_state

    deployment_state="$(classify_active_deployment_state \
        "${rows}" "${record_file}" "${runtime_directory}" "${semantic_directory}")"
    case "${deployment_state}" in
        ABSENT)
            printf 'deploy: no active UAT stack found; proceeding with first deployment\n'
            ;;
        ACTIVE_HEALTHY)
            printf 'deploy: active UAT stack is healthy; continuing idempotent deployment\n'
            ;;
        ACTIVE_DEGRADED)
            printf 'deploy: active UAT stack is degraded:\n%s\n' "${rows}" >&2
            printf 'deploy: inspect logs with: docker compose --project-name java-agent-uat logs session-agent-postgres semantic-service session-agent-runtime\n' >&2
            return 1
            ;;
        ACTIVE_INCONSISTENT)
            printf 'deploy: active UAT stack is inconsistent; inspect with: docker compose --project-name java-agent-uat ps --all\n' >&2
            return 1
            ;;
    esac
}

prepare_host_paths() {
    mkdir -p \
        "${SOURCES_DIR}" \
        "${ROOT}/backups" \
        "${ROOT}/data/repositories" \
        "${ROOT}/data/jdtls-workspaces"
    chmod 0700 "${ROOT}/backups"
    chmod 0644 "${ROOT}/config/semantic-repositories.yml"
}

write_deployment_record() {
    {
        printf 'deployment timestamp: %s\n' "$(date --iso-8601=seconds)"
        printf 'Session Agent source SHA: %s\n' \
            "$(git -C "${SOURCES_DIR}/session-agent-runtime" rev-parse HEAD)"
        printf 'Semantic source SHA: %s\n' "$(git -C "${SOURCES_DIR}/java-code-intelligence" rev-parse HEAD)"
    } > "${ROOT}/deployment-record.txt"
}

main() {
    local runtime_url
    local runtime_ref
    local semantic_url
    local semantic_ref
    local token
    local google_key
    local compose_rows
    local -a compose

    [[ "$#" -eq 0 ]] || fail "usage: ./deploy.sh"
    command -v git >/dev/null 2>&1 || fail "git is required"
    command -v docker >/dev/null 2>&1 || fail "docker is required"
    docker compose version >/dev/null 2>&1 || fail "docker compose is required"
    create_env_if_missing
    token="$(env_value SEMANTIC_API_TOKEN)"
    google_key="$(env_value GOOGLE_API_KEY)"
    [[ -n "${token}" ]] || fail "SEMANTIC_API_TOKEN is blank in ${ENV_FILE}"
    [[ -n "${google_key}" ]] || fail "GOOGLE_API_KEY is blank in ${ENV_FILE}"

    runtime_url="$(env_or_default SESSION_AGENT_GIT_URL git@github.com:ChouKevin/session-agent-runtime.git)"
    runtime_ref="$(env_or_default SESSION_AGENT_GIT_REF main)"
    semantic_url="$(env_or_default SEMANTIC_GIT_URL git@github.com:ChouKevin/java-code-intelligence.git)"
    semantic_ref="$(env_or_default SEMANTIC_GIT_REF uat)"

    export STARTER_ROOT="${ROOT}"
    compose=(docker compose --project-name java-agent-uat --env-file "${ENV_FILE}" -f "${ROOT}/compose.yaml")
    compose_rows="$("${compose[@]}" ps --all --format '{{.Service}}|{{.State}}|{{.Health}}')"
    preflight_active_deployment \
        "${compose_rows}" \
        "${ROOT}/deployment-record.txt" \
        "${SOURCES_DIR}/session-agent-runtime" \
        "${SOURCES_DIR}/java-code-intelligence"

    prepare_host_paths
    sync_source "Session Agent Runtime" "${runtime_url}" "${runtime_ref}" "${SOURCES_DIR}/session-agent-runtime"
    sync_source "Java Code Intelligence" "${semantic_url}" "${semantic_ref}" "${SOURCES_DIR}/java-code-intelligence"

    "${compose[@]}" build session-agent-runtime semantic-service
    "${compose[@]}" --profile setup run --rm fixture-init
    "${compose[@]}" up -d --remove-orphans --wait --wait-timeout "${STARTUP_WAIT_SECONDS}"
    "${compose[@]}" --profile tools run --rm network-probe
    write_deployment_record
    printf 'deploy: Session Agent UAT stack started; see %s\n' "${ROOT}/deployment-record.txt"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
