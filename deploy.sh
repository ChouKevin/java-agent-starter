#!/usr/bin/env bash
# Clone, build, and start the UAT stack from one repository.
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
ENV_FILE="${ROOT}/.env"
SOURCES_DIR="${ROOT}/.runtime/sources"
STARTUP_WAIT_SECONDS=240
DEPLOYMENT_RECORD_FILE="${ROOT}/deployment-record.txt"
INVOCATION_STAGING_ROOT=""
DEPLOYMENT_RECORD_TEMP_FILE=""

cleanup_temporary_files() {
    if [[ -n "${INVOCATION_STAGING_ROOT}" ]]; then
        rm -rf -- "${INVOCATION_STAGING_ROOT}"
        INVOCATION_STAGING_ROOT=""
    fi
    if [[ -n "${DEPLOYMENT_RECORD_TEMP_FILE}" ]]; then
        rm -f -- "${DEPLOYMENT_RECORD_TEMP_FILE}"
        DEPLOYMENT_RECORD_TEMP_FILE=""
    fi
}

fail() {
    cleanup_temporary_files
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

acquire_deploy_lock() {
    local lock_file="${ROOT}/.runtime/deploy.lock"

    mkdir -p "${ROOT}/.runtime"
    exec {DEPLOY_LOCK_FD}>"${lock_file}"
    flock -n "${DEPLOY_LOCK_FD}" || fail "another starter deployment holds ${lock_file}"
}

validate_requested_source() {
    local label="$1"
    local url="$2"
    local branch="$3"

    [[ -n "${url}" ]] || fail "${label} repository URL is blank"
    [[ -n "${branch}" ]] || fail "${label} repository ref is blank"
}

remote_branch_sha() {
    local label="$1"
    local url="$2"
    local branch="$3"
    local result

    result="$(git ls-remote --heads "${url}" "refs/heads/${branch}")" \
        || fail "${label} remote branch could not be resolved: ${branch}"
    [[ "${result}" =~ ^[0-9a-f]{40}[[:space:]]refs/heads/ ]] \
        || fail "${label} remote branch is missing or ambiguous: ${branch}"
    printf '%s' "${result%%[[:space:]]*}"
}

validate_source_checkout() {
    local label="$1"
    local url="$2"
    local branch="$3"
    local directory="$4"
    local actual

    [[ -d "${directory}/.git" ]] || fail "${label} source is not a Git checkout: ${directory}"

    actual="$(git -C "${directory}" remote get-url origin)" \
        || fail "${label} source has no origin remote: ${directory}"
    [[ "${actual}" == "${url}" ]] \
        || fail "${label} origin mismatch: expected ${url}, found ${actual}"
    actual="$(git -C "${directory}" symbolic-ref --quiet --short HEAD || true)"
    [[ "${actual}" == "${branch}" ]] \
        || fail "${label} branch mismatch: expected ${branch}, found ${actual:-detached HEAD}"
    [[ -z "$(git -C "${directory}" status --porcelain)" ]] \
        || fail "${label} source has local changes: ${directory}"
}

existing_source_sha() {
    local label="$1"
    local url="$2"
    local branch="$3"
    local directory="$4"

    if [[ -e "${directory}" ]]; then
        validate_source_checkout "${label}" "${url}" "${branch}" "${directory}"
        git -C "${directory}" rev-parse HEAD || fail "${label} source HEAD could not be resolved"
    else
        printf 'ABSENT'
    fi
}

stage_source_at_target() {
    local label="$1"
    local url="$2"
    local branch="$3"
    local staging_directory="$4"
    local target_sha="$5"

    git clone --branch "${branch}" --single-branch "${url}" "${staging_directory}" \
        || fail "${label} target could not be staged"
    validate_source_checkout "${label}" "${url}" "${branch}" "${staging_directory}"
    [[ "$(git -C "${staging_directory}" rev-parse "origin/${branch}")" == "${target_sha}" ]] \
        || fail "${label} remote branch changed during validation: ${branch}"
    git -C "${staging_directory}" reset --hard "${target_sha}" >/dev/null \
        || fail "${label} staged target could not be checked out"
}

validate_fast_forward() {
    local label="$1"
    local existing_sha="$2"
    local staging_directory="$3"
    local target_sha="$4"

    if [[ "${existing_sha}" != 'ABSENT' ]]; then
        git -C "${staging_directory}" merge-base --is-ancestor "${existing_sha}" "${target_sha}" \
            || fail "${label} update is not fast-forward eligible"
    fi
}

promote_staged_source() {
    local label="$1"
    local directory="$2"
    local staging_directory="$3"
    local branch="$4"
    local target_sha="$5"
    local actual_sha

    if [[ -e "${directory}" ]]; then
        git -C "${directory}" fetch --no-tags "${staging_directory}" "refs/heads/${branch}" >/dev/null \
            || fail "${label} staged target could not be promoted"
        git -C "${directory}" merge --ff-only "${target_sha}" >/dev/null \
            || fail "${label} staged target could not be fast-forwarded"
    else
        mv "${staging_directory}" "${directory}" \
            || fail "${label} staged target could not be promoted"
    fi
    actual_sha="$(git -C "${directory}" rev-parse HEAD)" \
        || fail "${label} promoted source HEAD could not be resolved"
    [[ "${actual_sha}" == "${target_sha}" ]] \
        || fail "${label} source changed during promotion"
}

prepare_sources() {
    local runtime_url="$1"
    local runtime_ref="$2"
    local semantic_url="$3"
    local semantic_ref="$4"
    local runtime_directory="${SOURCES_DIR}/session-agent-runtime"
    local semantic_directory="${SOURCES_DIR}/java-code-intelligence"
    local runtime_staging
    local semantic_staging
    local runtime_target_sha
    local semantic_target_sha
    local runtime_existing_sha
    local semantic_existing_sha

    validate_requested_source "Session Agent Runtime" "${runtime_url}" "${runtime_ref}"
    validate_requested_source "Semantic" "${semantic_url}" "${semantic_ref}"
    runtime_existing_sha="$(existing_source_sha "Session Agent Runtime" "${runtime_url}" "${runtime_ref}" "${runtime_directory}")"
    semantic_existing_sha="$(existing_source_sha "Semantic" "${semantic_url}" "${semantic_ref}" "${semantic_directory}")"
    runtime_target_sha="$(remote_branch_sha "Session Agent Runtime" "${runtime_url}" "${runtime_ref}")"
    semantic_target_sha="$(remote_branch_sha "Semantic" "${semantic_url}" "${semantic_ref}")"

    mkdir -p "${SOURCES_DIR}" || fail "source staging directory could not be created"
    INVOCATION_STAGING_ROOT="$(mktemp -d "${SOURCES_DIR}/.staging.XXXXXX")" \
        || fail "source staging directory could not be created"
    runtime_staging="${INVOCATION_STAGING_ROOT}/session-agent-runtime"
    semantic_staging="${INVOCATION_STAGING_ROOT}/java-code-intelligence"
    stage_source_at_target "Session Agent Runtime" "${runtime_url}" "${runtime_ref}" \
        "${runtime_staging}" "${runtime_target_sha}"
    stage_source_at_target "Semantic" "${semantic_url}" "${semantic_ref}" \
        "${semantic_staging}" "${semantic_target_sha}"
    validate_fast_forward "Session Agent Runtime" "${runtime_existing_sha}" "${runtime_staging}" "${runtime_target_sha}"
    validate_fast_forward "Semantic" "${semantic_existing_sha}" "${semantic_staging}" "${semantic_target_sha}"

    promote_staged_source "Session Agent Runtime" "${runtime_directory}" "${runtime_staging}" \
        "${runtime_ref}" "${runtime_target_sha}"
    promote_staged_source "Semantic" "${semantic_directory}" "${semantic_staging}" \
        "${semantic_ref}" "${semantic_target_sha}"
    cleanup_temporary_files
}

prepare_host_paths() {
    mkdir -p \
        "${SOURCES_DIR}" \
        "${ROOT}/data/repositories" \
        "${ROOT}/data/jdtls-workspaces"
    chmod 0644 "${ROOT}/config/semantic-repositories.yml"
}

clear_deployment_record() {
    rm -f "$DEPLOYMENT_RECORD_FILE"
}

write_deployment_record() {
    local runtime_sha
    local semantic_sha

    runtime_sha="$(git -C "${SOURCES_DIR}/session-agent-runtime" rev-parse HEAD)" \
        || fail "Runtime source HEAD could not be resolved for the deployment record"
    semantic_sha="$(git -C "${SOURCES_DIR}/java-code-intelligence" rev-parse HEAD)" \
        || fail "Semantic source HEAD could not be resolved for the deployment record"
    DEPLOYMENT_RECORD_TEMP_FILE="$(mktemp "${DEPLOYMENT_RECORD_FILE}.tmp.XXXXXX")" \
        || fail "deployment record temporary file could not be created"
    chmod 0600 "${DEPLOYMENT_RECORD_TEMP_FILE}" \
        || fail "deployment record temporary file permissions could not be set"
    {
        printf 'deployment timestamp: %s\n' "$(date --iso-8601=seconds)"
        printf 'Session Agent source SHA: %s\n' "${runtime_sha}"
        printf 'Semantic source SHA: %s\n' "${semantic_sha}"
    } > "${DEPLOYMENT_RECORD_TEMP_FILE}" || fail "deployment record could not be written"
    mv -f "${DEPLOYMENT_RECORD_TEMP_FILE}" "${DEPLOYMENT_RECORD_FILE}" \
        || fail "deployment record could not be finalized"
    DEPLOYMENT_RECORD_TEMP_FILE=""
}

main() {
    local runtime_url
    local runtime_ref
    local semantic_url
    local semantic_ref
    local token
    local google_key
    local -a compose

    [[ "$#" -eq 0 ]] || fail "usage: ./deploy.sh"
    command -v flock >/dev/null 2>&1 || fail "flock is required"
    acquire_deploy_lock
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
    prepare_host_paths
    prepare_sources "${runtime_url}" "${runtime_ref}" "${semantic_url}" "${semantic_ref}"

    "${compose[@]}" build semantic-service session-agent-runtime || fail "image build failed"
    clear_deployment_record || fail "deployment record could not be cleared"
    "${compose[@]}" down --remove-orphans --volumes || fail "existing stack could not be removed"
    "${compose[@]}" up -d --wait --wait-timeout "${STARTUP_WAIT_SECONDS}" session-agent-postgres \
        || fail "PostgreSQL did not become ready"
    "${compose[@]}" --profile setup run --rm fixture-init || fail "fixture initialization failed"
    "${compose[@]}" up -d --wait --wait-timeout "${STARTUP_WAIT_SECONDS}" semantic-service \
        || fail "Semantic did not become ready"
    "${compose[@]}" --profile semantic-check run --rm semantic-probe || fail "Semantic probe failed"
    "${compose[@]}" up -d --wait --wait-timeout "${STARTUP_WAIT_SECONDS}" session-agent-runtime \
        || fail "Runtime did not become ready"
    "${compose[@]}" --profile runtime-check run --rm runtime-probe || fail "Runtime probe failed"
    write_deployment_record
    printf 'deploy: Session Agent UAT stack started; see %s\n' "${DEPLOYMENT_RECORD_FILE}"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
