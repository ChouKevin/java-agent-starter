#!/usr/bin/env bash
# Clone, build, and start the UAT stack from one repository.
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
ENV_FILE="${ROOT}/.env"
SOURCES_DIR="${ROOT}/.runtime/sources"
STARTUP_WAIT_SECONDS=240
PREPARED_DEPLOYMENT_FILE="${ROOT}/prepared-deployment.txt"
DEPLOYMENT_RECORD_FILE="${ROOT}/deployment-record.txt"

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

acquire_deploy_lock() {
    local lock_file="${ROOT}/.runtime/deploy.lock"

    mkdir -p "${ROOT}/.runtime"
    exec {DEPLOY_LOCK_FD}>"${lock_file}"
    flock -n "${DEPLOY_LOCK_FD}" || fail "another starter deployment holds ${lock_file}"
}

remote_branch_sha() {
    local label="$1"
    local url="$2"
    local branch="$3"
    local result

    result="$(git ls-remote --heads "${url}" "refs/heads/${branch}")" || fail "${label} remote branch could not be resolved: ${branch}"
    [[ "${result}" =~ ^[0-9a-f]{40}[[:space:]]refs/heads/ ]] || fail "${label} remote branch is missing or ambiguous: ${branch}"
    printf '%s' "${result%%[[:space:]]*}"
}

validate_source_checkout() {
    local label="$1"
    local url="$2"
    local branch="$3"
    local directory="$4"
    local actual

    [[ -d "${directory}/.git" ]] || fail "${label} source is not a Git checkout: ${directory}"

    actual="$(git -C "${directory}" remote get-url origin)"
    [[ "${actual}" == "${url}" ]] \
        || fail "${label} origin mismatch: expected ${url}, found ${actual}"
    actual="$(git -C "${directory}" symbolic-ref --quiet --short HEAD || true)"
    [[ "${actual}" == "${branch}" ]] \
        || fail "${label} branch mismatch: expected ${branch}, found ${actual:-detached HEAD}"
    [[ -z "$(git -C "${directory}" status --porcelain)" ]] \
        || fail "${label} source has local changes: ${directory}"

}

stage_source_at_target() {
    local label="$1"
    local url="$2"
    local branch="$3"
    local existing_directory="$4"
    local staging_directory="$5"
    local target_sha="$6"
    local existing_sha=""

    if [[ -e "${existing_directory}" ]]; then
        validate_source_checkout "${label}" "${url}" "${branch}" "${existing_directory}"
        existing_sha="$(git -C "${existing_directory}" rev-parse HEAD)"
    fi
    git clone --branch "${branch}" --single-branch "${url}" "${staging_directory}"
    validate_source_checkout "${label}" "${url}" "${branch}" "${staging_directory}"
    [[ "$(git -C "${staging_directory}" rev-parse "origin/${branch}")" == "${target_sha}" ]] \
        || fail "${label} remote branch changed during validation: ${branch}"
    if [[ -n "${existing_sha}" ]]; then
        git -C "${staging_directory}" merge-base --is-ancestor "${existing_sha}" "${target_sha}" \
            || fail "${label} update is not fast-forward eligible"
    fi
    printf '%s' "${existing_sha:-ABSENT}"
}

prepared_value() {
    local key="$1"
    local line

    [[ -f "${PREPARED_DEPLOYMENT_FILE}" ]] || return 1
    line="$(grep -E -x "${key}: .+" "${PREPARED_DEPLOYMENT_FILE}" || true)"
    [[ -n "${line}" && "${line}" != *$'\n'* ]] || return 1
    printf '%s' "${line#*: }"
}

write_prepared_deployment() {
    local runtime_url="$1"
    local runtime_ref="$2"
    local runtime_old_sha="$3"
    local runtime_target_sha="$4"
    local semantic_url="$5"
    local semantic_ref="$6"
    local semantic_old_sha="$7"
    local semantic_target_sha="$8"
    local temporary_file="${PREPARED_DEPLOYMENT_FILE}.tmp.$$"
    local fixture_suffix="${runtime_target_sha:0:12}-${semantic_target_sha:0:12}"

    {
        printf 'runtime URL: %s\n' "${runtime_url}"
        printf 'runtime ref: %s\n' "${runtime_ref}"
        printf 'runtime old SHA: %s\n' "${runtime_old_sha}"
        printf 'runtime target SHA: %s\n' "${runtime_target_sha}"
        printf 'semantic URL: %s\n' "${semantic_url}"
        printf 'semantic ref: %s\n' "${semantic_ref}"
        printf 'semantic old SHA: %s\n' "${semantic_old_sha}"
        printf 'semantic target SHA: %s\n' "${semantic_target_sha}"
        printf 'fixture suffix: %s\n' "${fixture_suffix}"
    } > "${temporary_file}"
    mv -f "${temporary_file}" "${PREPARED_DEPLOYMENT_FILE}"
}

promote_staged_source() {
    local directory="$1"
    local staging_directory="$2"
    local label="$3"
    local backup_directory

    if [[ -e "${directory}" ]]; then
        backup_directory="${ROOT}/backups/${label}-$(date +%s)-$$"
        mv "${directory}" "${backup_directory}"
    fi
    mv "${staging_directory}" "${directory}"
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
    local postgres_seen=0
    local semantic_seen=0
    local runtime_seen=0

    if [[ -z "${rows//[[:space:]]/}" ]]; then
        printf 'ABSENT'
        return
    fi

    while IFS='|' read -r service state health; do
        case "${service}" in
            session-agent-postgres)
                ((postgres_seen += 1))
                postgres_state="${state}"
                postgres_health="${health}"
                ;;
            semantic-service)
                ((semantic_seen += 1))
                semantic_state="${state}"
                semantic_health="${health}"
                ;;
            session-agent-runtime)
                ((runtime_seen += 1))
                runtime_state="${state}"
                runtime_health="${health}"
                ;;
            *)
                printf 'ACTIVE_UNRECOGNIZED'
                return
                ;;
        esac
    done <<< "${rows}"

    [[ "${postgres_seen}" -eq 1 && "${semantic_seen}" -eq 1 && "${runtime_seen}" -eq 1 ]] || {
        printf 'ACTIVE_UNRECOGNIZED'
        return
    }

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

recorded_fixture_suffix() {
    local record_file="$1"
    local record_line

    [[ -f "${record_file}" ]] || return 1
    record_line="$(grep -E -x 'Fixture volume suffix: [0-9a-f]{12}-[0-9a-f]{12}' "${record_file}" || true)"
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

deployment_record_matches_prepared_sources() {
    local record_file="$1"
    local runtime_old_sha
    local semantic_old_sha
    local recorded_runtime_sha
    local recorded_semantic_sha

    runtime_old_sha="$(prepared_value 'runtime old SHA')" || return 1
    semantic_old_sha="$(prepared_value 'semantic old SHA')" || return 1
    recorded_runtime_sha="$(recorded_source_sha "${record_file}" 'Session Agent')" || return 1
    recorded_semantic_sha="$(recorded_source_sha "${record_file}" Semantic)" || return 1
    [[ "${runtime_old_sha}" != "ABSENT" && "${semantic_old_sha}" != "ABSENT" ]] \
        && [[ "${recorded_runtime_sha}" == "${runtime_old_sha}" ]] \
        && [[ "${recorded_semantic_sha}" == "${semantic_old_sha}" ]]
}

prepared_deployment_is_committed() {
    local rows="$1"
    local record_file="$2"
    local runtime_directory="$3"
    local semantic_directory="$4"
    local prepared_fixture_suffix
    local recorded_fixture_suffix

    prepared_fixture_suffix="$(prepared_value 'fixture suffix')" || return 1
    recorded_fixture_suffix="$(recorded_fixture_suffix "${record_file}")" || return 1
    [[ -f "${PREPARED_DEPLOYMENT_FILE}" ]] \
        && [[ "$(classify_compose_rows "${rows}")" == "ACTIVE_HEALTHY" ]] \
        && [[ "${prepared_fixture_suffix}" == "${recorded_fixture_suffix}" ]] \
        && deployment_record_matches_sources "${record_file}" "${runtime_directory}" "${semantic_directory}"
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
        if deployment_record_matches_prepared_sources "${record_file}"; then
            printf 'PREPARED_RECOVERY'
        else
            printf 'ACTIVE_INCONSISTENT'
        fi
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
        PREPARED_RECOVERY)
            printf 'deploy: resuming prepared replacement after an earlier post-promotion failure\n'
            ;;
        ACTIVE_DEGRADED)
            printf 'deploy: active UAT stack is degraded:\n%s\n' "${rows}" >&2
            printf 'deploy: inspect logs with: docker compose --project-name java-agent-uat logs session-agent-postgres semantic-service session-agent-runtime\n' >&2
            return 1
            ;;
        ACTIVE_UNRECOGNIZED)
            printf 'deploy: refusing unrecognized or mixed Compose project rows:\n%s\n' "${rows}" >&2
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

prepare_target_fixture_volumes() {
    local target_suffix
    local active_suffix=""
    local fixture_volume
    local attached_containers
    local -a fixture_volumes

    target_suffix="$(prepared_value 'fixture suffix')" || fail "prepared deployment is missing fixture identity"
    active_suffix="$(recorded_fixture_suffix "${DEPLOYMENT_RECORD_FILE}" 2>/dev/null || true)"
    [[ "${target_suffix}" != "${active_suffix}" ]] \
        || fail "prepared fixture volume is referenced by the active deployment"
    fixture_volumes=(
        "java-agent-uat-payment-fixture-${target_suffix}"
        "java-agent-uat-order-fixture-${target_suffix}"
    )
    for fixture_volume in "${fixture_volumes[@]}"; do
        attached_containers="$(docker ps -aq --filter "volume=${fixture_volume}")"
        [[ -z "${attached_containers}" ]] \
            || fail "prepared fixture volume is attached to an existing container: ${fixture_volume}"
        docker volume rm "${fixture_volume}" >/dev/null 2>&1 || true
    done
}

write_deployment_record() {
    local temporary_file="${DEPLOYMENT_RECORD_FILE}.tmp.$$"

    {
        printf 'deployment timestamp: %s\n' "$(date --iso-8601=seconds)"
        printf 'Session Agent source SHA: %s\n' \
            "$(git -C "${SOURCES_DIR}/session-agent-runtime" rev-parse HEAD)"
        printf 'Semantic source SHA: %s\n' "$(git -C "${SOURCES_DIR}/java-code-intelligence" rev-parse HEAD)"
        printf 'Fixture volume suffix: %s\n' "$(prepared_value 'fixture suffix')"
    } > "${temporary_file}"
    mv -f "${temporary_file}" "${DEPLOYMENT_RECORD_FILE}"
}

prepared_request_matches() {
    local runtime_url="$1"
    local runtime_ref="$2"
    local semantic_url="$3"
    local semantic_ref="$4"

    [[ "$(prepared_value 'runtime URL')" == "${runtime_url}" ]] \
        && [[ "$(prepared_value 'runtime ref')" == "${runtime_ref}" ]] \
        && [[ "$(prepared_value 'semantic URL')" == "${semantic_url}" ]] \
        && [[ "$(prepared_value 'semantic ref')" == "${semantic_ref}" ]]
}

stage_prepared_target() {
    local label="$1"
    local url="$2"
    local branch="$3"
    local staging_directory="$4"
    local target_sha="$5"

    git clone --branch "${branch}" --single-branch "${url}" "${staging_directory}"
    validate_source_checkout "${label}" "${url}" "${branch}" "${staging_directory}"
    git -C "${staging_directory}" reset --hard "${target_sha}" >/dev/null \
        || fail "${label} prepared target is no longer available from ${branch}"
}

source_head_matches() {
    local directory="$1"
    local target_sha="$2"

    [[ -d "${directory}/.git" ]] \
        && [[ "$(git -C "${directory}" rev-parse HEAD 2>/dev/null)" == "${target_sha}" ]]
}

prepare_or_resume_sources() {
    local runtime_url="$1"
    local runtime_ref="$2"
    local semantic_url="$3"
    local semantic_ref="$4"
    local staging_root
    local runtime_staging
    local semantic_staging
    local runtime_target_sha
    local semantic_target_sha
    local runtime_old_sha
    local semantic_old_sha
    local fixture_suffix

    staging_root="$(mktemp -d "${SOURCES_DIR}/.staging.XXXXXX")"
    runtime_staging="${staging_root}/session-agent-runtime"
    semantic_staging="${staging_root}/java-code-intelligence"
    if [[ -f "${PREPARED_DEPLOYMENT_FILE}" ]]; then
        prepared_request_matches "${runtime_url}" "${runtime_ref}" "${semantic_url}" "${semantic_ref}" \
            || fail "prepared deployment does not match the requested repository URLs and refs"
        runtime_target_sha="$(prepared_value 'runtime target SHA')" || fail "prepared deployment is incomplete"
        semantic_target_sha="$(prepared_value 'semantic target SHA')" || fail "prepared deployment is incomplete"
        [[ "${runtime_target_sha}" =~ ^[0-9a-f]{40}$ && "${semantic_target_sha}" =~ ^[0-9a-f]{40}$ ]] \
            || fail "prepared deployment contains invalid target SHA"
        if [[ -e "${SOURCES_DIR}/session-agent-runtime" ]]; then
            validate_source_checkout "Session Agent Runtime" "${runtime_url}" "${runtime_ref}" \
                "${SOURCES_DIR}/session-agent-runtime"
        fi
        if ! source_head_matches "${SOURCES_DIR}/session-agent-runtime" "${runtime_target_sha}"; then
            stage_prepared_target "Session Agent Runtime" "${runtime_url}" "${runtime_ref}" "${runtime_staging}" "${runtime_target_sha}"
            promote_staged_source "${SOURCES_DIR}/session-agent-runtime" "${runtime_staging}" session-agent-runtime
        fi
        if [[ -e "${SOURCES_DIR}/java-code-intelligence" ]]; then
            validate_source_checkout "Java Code Intelligence" "${semantic_url}" "${semantic_ref}" \
                "${SOURCES_DIR}/java-code-intelligence"
        fi
        if ! source_head_matches "${SOURCES_DIR}/java-code-intelligence" "${semantic_target_sha}"; then
            stage_prepared_target "Java Code Intelligence" "${semantic_url}" "${semantic_ref}" "${semantic_staging}" "${semantic_target_sha}"
            promote_staged_source "${SOURCES_DIR}/java-code-intelligence" "${semantic_staging}" java-code-intelligence
        fi
    else
        runtime_target_sha="$(remote_branch_sha "Session Agent Runtime" "${runtime_url}" "${runtime_ref}")"
        semantic_target_sha="$(remote_branch_sha "Java Code Intelligence" "${semantic_url}" "${semantic_ref}")"
        runtime_old_sha="$(stage_source_at_target "Session Agent Runtime" "${runtime_url}" "${runtime_ref}" \
            "${SOURCES_DIR}/session-agent-runtime" "${runtime_staging}" "${runtime_target_sha}")"
        semantic_old_sha="$(stage_source_at_target "Java Code Intelligence" "${semantic_url}" "${semantic_ref}" \
            "${SOURCES_DIR}/java-code-intelligence" "${semantic_staging}" "${semantic_target_sha}")"
        write_prepared_deployment "${runtime_url}" "${runtime_ref}" "${runtime_old_sha}" "${runtime_target_sha}" \
            "${semantic_url}" "${semantic_ref}" "${semantic_old_sha}" "${semantic_target_sha}"
        promote_staged_source "${SOURCES_DIR}/session-agent-runtime" "${runtime_staging}" session-agent-runtime
        promote_staged_source "${SOURCES_DIR}/java-code-intelligence" "${semantic_staging}" java-code-intelligence
    fi
    fixture_suffix="$(prepared_value 'fixture suffix')" || fail "prepared deployment is missing fixture identity"
    [[ "${fixture_suffix}" =~ ^[0-9a-f]{12}-[0-9a-f]{12}$ ]] || fail "prepared deployment contains invalid fixture identity"
    export FIXTURE_VOLUME_SUFFIX="${fixture_suffix}"
    rmdir "${staging_root}" 2>/dev/null || true
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
    command -v flock >/dev/null 2>&1 || fail "flock is required"
    docker compose version >/dev/null 2>&1 || fail "docker compose is required"
    acquire_deploy_lock
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
    export FIXTURE_VOLUME_SUFFIX=preflight
    compose=(docker compose --project-name java-agent-uat --env-file "${ENV_FILE}" -f "${ROOT}/compose.yaml")
    compose_rows="$("${compose[@]}" ps --all --format '{{.Service}}|{{.State}}|{{.Health}}')"
    preflight_active_deployment \
        "${compose_rows}" \
        "${DEPLOYMENT_RECORD_FILE}" \
        "${SOURCES_DIR}/session-agent-runtime" \
        "${SOURCES_DIR}/java-code-intelligence"
    if prepared_deployment_is_committed "${compose_rows}" "${DEPLOYMENT_RECORD_FILE}" \
        "${SOURCES_DIR}/session-agent-runtime" "${SOURCES_DIR}/java-code-intelligence"; then
        rm -f "${PREPARED_DEPLOYMENT_FILE}"
        printf 'deploy: prepared deployment was already recorded and remains active\n'
        return
    fi

    prepare_host_paths
    prepare_or_resume_sources "${runtime_url}" "${runtime_ref}" "${semantic_url}" "${semantic_ref}"

    "${compose[@]}" build session-agent-runtime semantic-service
    prepare_target_fixture_volumes
    "${compose[@]}" --profile setup run --rm fixture-init
    "${compose[@]}" up -d --wait --wait-timeout "${STARTUP_WAIT_SECONDS}"
    "${compose[@]}" --profile tools run --rm network-probe
    write_deployment_record
    rm -f "${PREPARED_DEPLOYMENT_FILE}"
    printf 'deploy: Session Agent UAT stack started; see %s\n' "${DEPLOYMENT_RECORD_FILE}"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
