#!/usr/bin/env bash
# Deploy the offline Semantic Indexer, Query, and Session Runtime without implicit data loss.
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
ENV_FILE="${ROOT}/.env"
SOURCES_DIR="${ROOT}/.runtime/sources"
STARTUP_WAIT_SECONDS=240
REQUIRED_RUNTIME_COMMIT='1e273dd41c0592a6a7abd6f9def0160caf9b7561'
DEPLOYMENT_RECORD_FILE="${ROOT}/deployment-record.txt"
DEPLOYMENT_RUNTIME_URL=""
DEPLOYMENT_RUNTIME_REF=""
DEPLOYMENT_RUNTIME_TARGET_SHA=""
DEPLOYMENT_SEMANTIC_URL=""
DEPLOYMENT_SEMANTIC_REF=""
DEPLOYMENT_SEMANTIC_TARGET_SHA=""
COMPOSE=()
STAGING_DIRECTORIES=()
QUERY_BACKUP_IMAGE="java-agent-semantic-query:pre-deploy"
QUERY_BACKUP_CAPTURED=false
DEPLOY_LOCK_FILE="${ROOT}/.runtime/deploy.lock"

cleanup_staging_directories() {
    local staging_directory
    for staging_directory in "${STAGING_DIRECTORIES[@]}"; do
        rm -rf -- "${staging_directory}"
    done
    STAGING_DIRECTORIES=()
}

fail() { cleanup_staging_directories; printf 'deploy: %s\n' "$*" >&2; exit 1; }

env_value() {
    local key="$1"
    local line
    line="$(grep -m1 -E "^${key}=" "${ENV_FILE}" 2>/dev/null || true)"
    printf '%s' "${line#*=}"
}

env_or_default() {
    local configured
    configured="$(env_value "$1")"
    [[ -n "${configured}" ]] && printf '%s' "${configured}" || printf '%s' "$2"
}

with_deploy_lock() (
    local operation_lock_fd
    mkdir -p "${ROOT}/.runtime"
    exec {operation_lock_fd}>"${DEPLOY_LOCK_FILE}"
    flock -n "${operation_lock_fd}" || fail "another starter deployment holds ${DEPLOY_LOCK_FILE}"
    "$@"
)

create_env_if_missing() {
    local semantic_token indexer_token postgres_password root_password bootstrap_password indexer_password query_password
    [[ ! -e "${ENV_FILE}" ]] || { [[ -s "${ENV_FILE}" ]] || fail "${ENV_FILE} exists but is empty"; return; }
    semantic_token="$(od -An -N32 -tx1 /dev/urandom | tr -d ' \n')"
    indexer_token="$(od -An -N32 -tx1 /dev/urandom | tr -d ' \n')"
    postgres_password="$(od -An -N32 -tx1 /dev/urandom | tr -d ' \n')"
    root_password="$(od -An -N32 -tx1 /dev/urandom | tr -d ' \n')"
    bootstrap_password="$(od -An -N32 -tx1 /dev/urandom | tr -d ' \n')"
    indexer_password="$(od -An -N32 -tx1 /dev/urandom | tr -d ' \n')"
    query_password="$(od -An -N32 -tx1 /dev/urandom | tr -d ' \n')"
    sed -e "s/^SEMANTIC_QUERY_API_TOKEN=$/SEMANTIC_QUERY_API_TOKEN=${semantic_token}/" \
        -e "s/^SEMANTIC_INDEXER_ADMIN_TOKEN=$/SEMANTIC_INDEXER_ADMIN_TOKEN=${indexer_token}/" \
        -e "s/^SESSION_AGENT_POSTGRES_PASSWORD=$/SESSION_AGENT_POSTGRES_PASSWORD=${postgres_password}/" \
        -e "s/^SEMANTIC_MONGO_ROOT_PASSWORD=$/SEMANTIC_MONGO_ROOT_PASSWORD=${root_password}/" \
        -e "s/^SEMANTIC_MONGO_BOOTSTRAP_PASSWORD=$/SEMANTIC_MONGO_BOOTSTRAP_PASSWORD=${bootstrap_password}/" \
        -e "s/^SEMANTIC_MONGO_INDEXER_PASSWORD=$/SEMANTIC_MONGO_INDEXER_PASSWORD=${indexer_password}/" \
        -e "s/^SEMANTIC_MONGO_QUERY_PASSWORD=$/SEMANTIC_MONGO_QUERY_PASSWORD=${query_password}/" \
        "${ROOT}/.env.example" > "${ENV_FILE}"
    chmod 0600 "${ENV_FILE}"
    printf 'deploy: generated %s with local deployment secrets\n' "${ENV_FILE}"
}

assert_required_secrets() {
    local key
    for key in SEMANTIC_QUERY_API_TOKEN SEMANTIC_INDEXER_ADMIN_TOKEN GOOGLE_API_KEY SESSION_AGENT_POSTGRES_PASSWORD \
        SEMANTIC_MONGO_ROOT_PASSWORD SEMANTIC_MONGO_BOOTSTRAP_PASSWORD SEMANTIC_MONGO_INDEXER_PASSWORD SEMANTIC_MONGO_QUERY_PASSWORD; do
        [[ -n "$(env_value "${key}")" ]] || fail "${key} is blank in ${ENV_FILE}"
    done
}

remote_branch_sha() {
    local url="$1"
    local branch="$2"
    local result
    result="$(git ls-remote --heads "${url}" "refs/heads/${branch}")" || fail "remote branch could not be resolved: ${branch}"
    [[ "${result}" =~ ^[0-9a-f]{40}[[:space:]]refs/heads/ ]] || fail "remote branch is missing or ambiguous: ${branch}"
    printf '%s' "${result%%[[:space:]]*}"
}

stage_branch_source() (
    local label="$1" url="$2" branch="$3" required_commit="${4:-}"
    local target staging_parent staging actual staged=false
    target="$(remote_branch_sha "${url}" "${branch}")"
    staging_parent="$(mktemp -d "${SOURCES_DIR}/.staging.XXXXXX")" || fail "${label} staging directory could not be created"
    trap '[[ "${staged}" == true ]] || rm -rf -- "${staging_parent}"' EXIT
    staging="${staging_parent}/${label}"
    git clone --branch "${branch}" --single-branch "${url}" "${staging}" || fail "${label} source could not be staged"
    actual="$(git -C "${staging}" rev-parse HEAD)"
    [[ "${actual}" == "${target}" ]] || fail "${label} changed while being staged"
    if [[ -n "${required_commit}" ]]; then
        git -C "${staging}" merge-base --is-ancestor "${required_commit}" "${target}" \
            || fail "Session Agent Runtime target ${target} does not contain required compatible commit ${required_commit}"
    fi
    staged=true
    printf '%s' "${staging}"
)

validate_staged_source() {
    local label="$1" url="$2" branch="$3" destination="$4" staging="$5"
    local existing_sha origin existing_branch target
    target="$(git -C "${staging}" rev-parse HEAD)"
    if [[ -e "${destination}" ]]; then
        [[ -d "${destination}/.git" ]] || fail "${label} source is not a Git checkout: ${destination}"
        origin="$(git -C "${destination}" remote get-url origin)" || fail "${label} source has no origin remote"
        [[ "${origin}" == "${url}" ]] || fail "${label} origin mismatch: expected ${url}, found ${origin}"
        existing_branch="$(git -C "${destination}" symbolic-ref --quiet --short HEAD || true)"
        [[ "${existing_branch}" == "${branch}" ]] || fail "${label} branch mismatch: expected ${branch}"
        [[ -z "$(git -C "${destination}" status --porcelain)" ]] || fail "${label} source has local changes: ${destination}"
        existing_sha="$(git -C "${destination}" rev-parse HEAD)"
        git -C "${staging}" merge-base --is-ancestor "${existing_sha}" "${target}" \
            || fail "${label} update is not fast-forward eligible"
    fi
}

promote_staged_source() {
    local destination="$1" staging="$2"
    if [[ -e "${destination}" ]]; then
        mv "${destination}" "${destination}.previous"
        mv "${staging}" "${destination}"
        rm -rf -- "${destination}.previous"
    else
        mv "${staging}" "${destination}"
    fi
}

prepare_sources() {
    local runtime_url="$1" runtime_ref="$2" semantic_url="$3" semantic_ref="$4" runtime_staging semantic_staging
    mkdir -p "${SOURCES_DIR}"
    runtime_staging="$(stage_branch_source session-agent-runtime "${runtime_url}" "${runtime_ref}" "${REQUIRED_RUNTIME_COMMIT}")" \
        || fail "Session Agent Runtime source could not be staged"
    STAGING_DIRECTORIES+=("${runtime_staging%/*}")
    semantic_staging="$(stage_branch_source java-code-intelligence "${semantic_url}" "${semantic_ref}")" \
        || fail "Semantic source could not be staged"
    STAGING_DIRECTORIES+=("${semantic_staging%/*}")
    validate_staged_source "Session Agent Runtime" "${runtime_url}" "${runtime_ref}" "${SOURCES_DIR}/session-agent-runtime" "${runtime_staging}"
    validate_staged_source "Semantic" "${semantic_url}" "${semantic_ref}" "${SOURCES_DIR}/java-code-intelligence" "${semantic_staging}"
    promote_staged_source "${SOURCES_DIR}/session-agent-runtime" "${runtime_staging}"
    promote_staged_source "${SOURCES_DIR}/java-code-intelligence" "${semantic_staging}"
    cleanup_staging_directories
    DEPLOYMENT_RUNTIME_URL="${runtime_url}"
    DEPLOYMENT_RUNTIME_REF="${runtime_ref}"
    DEPLOYMENT_RUNTIME_TARGET_SHA="$(git -C "${SOURCES_DIR}/session-agent-runtime" rev-parse HEAD)"
    DEPLOYMENT_SEMANTIC_URL="${semantic_url}"
    DEPLOYMENT_SEMANTIC_REF="${semantic_ref}"
    DEPLOYMENT_SEMANTIC_TARGET_SHA="$(git -C "${SOURCES_DIR}/java-code-intelligence" rev-parse HEAD)"
    local fixture
    for fixture in payment-service order-service video-service; do
        [[ -f "${SOURCES_DIR}/java-code-intelligence/semantic-indexer/fixtures/uat/${fixture}/pom.xml" ]] || fail "Semantic UAT fixture is missing: ${fixture}"
    done
}

validate_source_at_target() {
    local label="$1" url="$2" branch="$3" directory="$4" target="$5"
    [[ "$(git -C "${directory}" remote get-url origin)" == "${url}" ]] || fail "${label} origin changed during deployment"
    [[ "$(git -C "${directory}" symbolic-ref --quiet --short HEAD || true)" == "${branch}" ]] || fail "${label} branch changed during deployment"
    [[ -z "$(git -C "${directory}" status --porcelain)" ]] || fail "${label} source changed during deployment"
    [[ "$(git -C "${directory}" rev-parse HEAD)" == "${target}" ]] || fail "${label} source changed during deployment"
}

validate_deployment_sources() {
    validate_source_at_target "Session Agent Runtime" "${DEPLOYMENT_RUNTIME_URL}" "${DEPLOYMENT_RUNTIME_REF}" \
        "${SOURCES_DIR}/session-agent-runtime" "${DEPLOYMENT_RUNTIME_TARGET_SHA}"
    validate_source_at_target "Semantic" "${DEPLOYMENT_SEMANTIC_URL}" "${DEPLOYMENT_SEMANTIC_REF}" \
        "${SOURCES_DIR}/java-code-intelligence" "${DEPLOYMENT_SEMANTIC_TARGET_SHA}"
}

write_deployment_record() {
    local temporary_record
    validate_deployment_sources
    temporary_record="$(mktemp "${DEPLOYMENT_RECORD_FILE}.tmp.XXXXXX")" || fail "deployment record temporary file could not be created"
    chmod 0600 "${temporary_record}"
    {
        printf 'deployment timestamp: %s\n' "$(date --iso-8601=seconds)"
        printf 'Session Agent source SHA: %s\n' "${DEPLOYMENT_RUNTIME_TARGET_SHA}"
        printf 'Semantic source SHA: %s\n' "${DEPLOYMENT_SEMANTIC_TARGET_SHA}"
    } > "${temporary_record}"
    mv -f "${temporary_record}" "${DEPLOYMENT_RECORD_FILE}"
}

configured_repositories() {
    awk '/^    [a-z0-9][a-z0-9._-]*:$/ { value=$1; sub(/:$/, "", value); print value }' "${ROOT}/config/semantic-repositories.yml"
}

bootstrap_schema() {
    "${COMPOSE[@]}" --profile schema-maintenance run --rm semantic-mongo-users \
        || { printf 'deploy: Mongo user and role bootstrap failed\n' >&2; return 1; }
    "${COMPOSE[@]}" --profile schema-maintenance run --rm semantic-mongo-init \
        || { printf 'deploy: versioned schema bootstrap failed\n' >&2; return 1; }
}

wait_for_indexer_admin() {
    local port deadline status
    port="$(env_or_default SEMANTIC_INDEXER_HOST_PORT 8081)"
    deadline=$((SECONDS + STARTUP_WAIT_SECONDS))
    while (( SECONDS < deadline )); do
        status="$(curl --silent --show-error --output /dev/null --write-out '%{http_code}' \
            --connect-timeout 2 --max-time 5 "http://127.0.0.1:${port}/" || true)"
        if [[ -n "${status}" && "${status}" != 000 ]]; then
            return
        fi
        sleep 2
    done
    printf 'deploy: Indexer admin endpoint did not become ready within %ss\n' "${STARTUP_WAIT_SECONDS}" >&2
    return 1
}

poll_index_job() {
    local repository="$1" job_id="$2" token="$3" port="$4"
    local deadline response active phase failure
    deadline=$((SECONDS + STARTUP_WAIT_SECONDS))
    while (( SECONDS < deadline )); do
        response="$(curl --fail --silent --show-error --connect-timeout 5 --max-time 10 \
            -H "X-Api-Token: ${token}" "http://127.0.0.1:${port}/index/repositories/${repository}/jobs/${job_id}")" \
            || { printf 'deploy: Indexer job status is unavailable: %s\n' "${job_id}" >&2; return 1; }
        active="$(jq -r '.active' <<< "${response}")"
        phase="$(jq -r '.phase' <<< "${response}")"
        failure="$(jq -r '.failureCategory // empty' <<< "${response}")"
        [[ -z "${failure}" ]] || { printf 'deploy: Indexer job %s failed: %s\n' "${job_id}" "${failure}" >&2; return 1; }
        if [[ "${active}" == false ]]; then
            [[ "${phase}" == COMPLETE ]] || { printf 'deploy: Indexer job %s ended without a sealed publication: %s\n' "${job_id}" "${phase}" >&2; return 1; }
            printf '%s' "${response}"
            return
        fi
        sleep 2
    done
    printf 'deploy: Indexer job did not finish within %ss: %s\n' "${STARTUP_WAIT_SECONDS}" "${job_id}" >&2
    return 1
}

ensure_all_repositories() {
    local repository token port response job_id
    token="$(env_value SEMANTIC_INDEXER_ADMIN_TOKEN)"
    port="$(env_or_default SEMANTIC_INDEXER_HOST_PORT 8081)"
    wait_for_indexer_admin || fail "Indexer startup did not expose its admin endpoint"
    while IFS= read -r repository; do
        response="$(curl --fail --silent --show-error --connect-timeout 5 --max-time 30 -X POST \
            -H "X-Api-Token: ${token}" "http://127.0.0.1:${port}/index/repositories/${repository}/ensure")" \
            || fail "Indexer rejected ${repository}; run ./deploy.sh schema-rebuild for incompatible schemas"
        job_id="$(jq -er '.jobId' <<< "${response}")" || fail "Indexer returned no job id for ${repository}"
        poll_index_job "${repository}" "${job_id}" "${token}" "${port}" || fail "Indexer job did not complete: ${job_id}"
    done < <(configured_repositories)
}

wait_for_compatible_manifests() {
    "${COMPOSE[@]}" up -d --force-recreate --no-deps semantic-query \
        || { printf 'deploy: Query cannot start: schema-rebuild required\n' >&2; return 1; }
    "${COMPOSE[@]}" up -d --force-recreate --no-deps semantic-query-gateway \
        || { printf 'deploy: Query loopback gateway cannot start\n' >&2; return 1; }
    "${COMPOSE[@]}" --profile semantic-query-check run --rm semantic-query-probe \
        || { printf 'deploy: Query did not observe compatible sealed manifests; run ./deploy.sh schema-rebuild\n' >&2; return 1; }
}

SCHEMA_REBUILD_POINTERS="${ROOT}/.runtime/schema-rebuild-pointers"

record_current_pointers() {
    local repository token port response pointer
    token="$(env_value SEMANTIC_INDEXER_ADMIN_TOKEN)"
    port="$(env_or_default SEMANTIC_INDEXER_HOST_PORT 8081)"
    rm -rf -- "${SCHEMA_REBUILD_POINTERS}"
    mkdir -p "${SCHEMA_REBUILD_POINTERS}"
    while IFS= read -r repository; do
        response="$(curl --fail --silent --show-error --connect-timeout 5 --max-time 10 \
            -H "X-Api-Token: ${token}" "http://127.0.0.1:${port}/index/repositories/${repository}/publication")" \
            || fail "could not record Indexer publication for ${repository} before schema-rebuild"
        pointer="$(jq -ce '.currentPointer // error("missing current pointer")' <<< "${response}")" \
            || fail "Indexer returned an invalid publication pointer for ${repository}"
        printf '%s\n' "${pointer}" > "${SCHEMA_REBUILD_POINTERS}/${repository}.previous.json"
    done < <(configured_repositories)
}

rebuild_all_repositories() {
    local repository token port response job_id pointer publication request previous_file rebuilt_file
    token="$(env_value SEMANTIC_INDEXER_ADMIN_TOKEN)"
    port="$(env_or_default SEMANTIC_INDEXER_HOST_PORT 8081)"
    while IFS= read -r repository; do
        previous_file="${SCHEMA_REBUILD_POINTERS}/${repository}.previous.json"
        rebuilt_file="${SCHEMA_REBUILD_POINTERS}/${repository}.rebuilt.json"
        request="$(jq -n -ce --slurpfile previous "${previous_file}" \
            '{authorizeIncompatibleSchema:true, expectedCurrent: $previous[0]}')" || return 1
        response="$(curl --fail --silent --show-error --connect-timeout 5 --max-time 30 -X POST \
            -H "X-Api-Token: ${token}" -H 'Content-Type: application/json' \
            --data "${request}" "http://127.0.0.1:${port}/index/repositories/${repository}/rebuild")" \
            || return 1
        job_id="$(jq -er '.jobId' <<< "${response}")" || return 1
        poll_index_job "${repository}" "${job_id}" "${token}" "${port}" >/dev/null || return 1
        publication="$(curl --fail --silent --show-error --connect-timeout 5 --max-time 10 \
            -H "X-Api-Token: ${token}" "http://127.0.0.1:${port}/index/repositories/${repository}/publication")" || return 1
        pointer="$(jq -ce '.currentPointer // error("missing published pointer")' <<< "${publication}")" || return 1
        printf '%s\n' "${pointer}" > "${rebuilt_file}"
        jq -e --slurpfile previous "${previous_file}" \
            '.currentPointer != null and .rollbackPointer == $previous[0]' <<< "${publication}" >/dev/null || return 1
    done < <(configured_repositories)
}

rollback_rebuilt_repositories() {
    local rebuilt token port repository request response job_id publication
    token="$(env_value SEMANTIC_INDEXER_ADMIN_TOKEN)"
    port="$(env_or_default SEMANTIC_INDEXER_HOST_PORT 8081)"
    shopt -s nullglob
    for rebuilt in "${SCHEMA_REBUILD_POINTERS}"/*.rebuilt.json; do
        repository="$(basename "${rebuilt}" .rebuilt.json)"
        request="$(jq -n -ce --slurpfile current "${rebuilt}" --slurpfile rollback "${SCHEMA_REBUILD_POINTERS}/${repository}.previous.json" \
            '{expectedCurrent: $current[0], expectedRollback: $rollback[0]}')" || return 1
        response="$(curl --fail --silent --show-error --connect-timeout 5 --max-time 30 -X POST \
            -H "X-Api-Token: ${token}" -H 'Content-Type: application/json' --data "${request}" \
            "http://127.0.0.1:${port}/index/repositories/${repository}/rollback")" || return 1
        job_id="$(jq -er '.jobId' <<< "${response}")" || return 1
        poll_index_job "${repository}" "${job_id}" "${token}" "${port}" >/dev/null || return 1
        publication="$(curl --fail --silent --show-error --connect-timeout 5 --max-time 10 \
            -H "X-Api-Token: ${token}" "http://127.0.0.1:${port}/index/repositories/${repository}/publication")" || return 1
        jq -e --slurpfile previous "${SCHEMA_REBUILD_POINTERS}/${repository}.previous.json" --slurpfile rebuilt "${rebuilt}" \
            '.currentPointer == $previous[0] and .rollbackPointer == $rebuilt[0]' <<< "${publication}" >/dev/null || return 1
    done
    shopt -u nullglob
}

capture_query_image() {
    local required="$1" container image
    container="$("${COMPOSE[@]}" ps -q semantic-query)"
    if [[ -z "${container}" ]]; then
        [[ "${required}" != true ]] || { printf 'deploy: schema-rebuild requires a running Query to preserve\n' >&2; return 1; }
        return
    fi
    image="$(docker inspect --format '{{.Image}}' "${container}")" || return 1
    docker image tag "${image}" "${QUERY_BACKUP_IMAGE}" || return 1
    QUERY_BACKUP_CAPTURED=true
}

restore_previous_query() {
    [[ "${QUERY_BACKUP_CAPTURED}" == true ]] || return 1
    docker image tag "${QUERY_BACKUP_IMAGE}" java-agent-semantic-query:latest || return 1
    "${COMPOSE[@]}" up -d --force-recreate --no-deps semantic-query || return 1
    "${COMPOSE[@]}" up -d --force-recreate --no-deps semantic-query-gateway || return 1
    "${COMPOSE[@]}" --profile semantic-query-check run --rm semantic-query-probe || return 1
    "${COMPOSE[@]}" up -d --wait --wait-timeout "${STARTUP_WAIT_SECONDS}" session-agent-runtime || return 1
    "${COMPOSE[@]}" --profile runtime-check run --rm runtime-probe || return 1
}

cleanup_query_backup() {
    if [[ "${QUERY_BACKUP_CAPTURED}" == true ]]; then
        docker image rm "${QUERY_BACKUP_IMAGE}" >/dev/null 2>&1 || true
        QUERY_BACKUP_CAPTURED=false
    fi
}

recover_schema_rebuild() {
    "${COMPOSE[@]}" stop session-agent-runtime semantic-query-gateway semantic-query >/dev/null 2>&1 || return 1
    rollback_rebuilt_repositories || return 1
    restore_previous_query
}

stop_existing_indexer() {
    "${COMPOSE[@]}" --profile uat-evidence down --remove-orphans || fail "existing stack teardown failed"
    [[ -z "$("${COMPOSE[@]}" ps -q semantic-indexer)" ]] \
        || fail "old Indexer is still running after teardown"
}

normal_deploy() {
    "${COMPOSE[@]}" up -d --wait --wait-timeout "${STARTUP_WAIT_SECONDS}" session-agent-postgres semantic-mongodb || fail "database startup failed"
    bootstrap_schema || fail "schema bootstrap failed"
    "${COMPOSE[@]}" up -d --wait --wait-timeout "${STARTUP_WAIT_SECONDS}" semantic-indexer || fail "Indexer startup failed"
    ensure_all_repositories
    wait_for_compatible_manifests || {
        restore_previous_query || fail "Query update failed and the previous Query could not be restored"
        fail "Query update failed"
    }
    "${COMPOSE[@]}" up -d --wait --wait-timeout "${STARTUP_WAIT_SECONDS}" session-agent-runtime || fail "Runtime startup failed"
    "${COMPOSE[@]}" --profile runtime-check run --rm runtime-probe || fail "Runtime probe failed"
    cleanup_query_backup
}

schema_rebuild() {
    if ! bootstrap_schema; then
        recover_schema_rebuild || fail "schema bootstrap failed and the previous Query could not be restored"
        fail "schema bootstrap failed; the previous Query was restored"
    fi
    if ! "${COMPOSE[@]}" up -d --wait --wait-timeout "${STARTUP_WAIT_SECONDS}" semantic-indexer \
            || ! wait_for_indexer_admin; then
        recover_schema_rebuild || fail "Indexer startup failed and the previous Query could not be restored"
        fail "Indexer startup failed; the previous Query was restored"
    fi
    if ! rebuild_all_repositories; then
        recover_schema_rebuild || fail "schema-rebuild failed and verified recovery could not complete"
        fail "schema-rebuild failed; rebuilt pointers were rolled back and the previous Query was restored"
    fi
    if ! wait_for_compatible_manifests; then
        recover_schema_rebuild || fail "schema-rebuild Query failed and verified recovery could not complete"
        fail "schema-rebuild requires compatible sealed manifests; the previous Query was restored"
    fi
    if ! "${COMPOSE[@]}" up -d --wait --wait-timeout "${STARTUP_WAIT_SECONDS}" session-agent-runtime \
            || ! "${COMPOSE[@]}" --profile runtime-check run --rm runtime-probe; then
        recover_schema_rebuild || fail "Runtime failed after schema-rebuild and verified recovery could not complete"
        fail "Runtime failed after schema-rebuild; rebuilt pointers were rolled back and the previous stack was restored"
    fi
    cleanup_query_backup
}

reset_deploy() {
    printf 'deploy: RESET WILL DELETE ALL NAMED VOLUMES.\n' >&2
    "${COMPOSE[@]}" --profile uat-evidence down --remove-orphans --volumes || fail "reset teardown failed"
    "${COMPOSE[@]}" up -d --wait --wait-timeout "${STARTUP_WAIT_SECONDS}" session-agent-postgres semantic-mongodb \
        || fail "database startup failed"
    bootstrap_schema || fail "schema bootstrap failed"
    "${COMPOSE[@]}" up -d --wait --wait-timeout "${STARTUP_WAIT_SECONDS}" semantic-indexer || fail "Indexer startup failed"
    ensure_all_repositories
    "${COMPOSE[@]}" stop semantic-indexer || fail "could not stop Indexer before cold Query startup"
    wait_for_compatible_manifests || fail "cold Query did not observe compatible sealed manifests"
    "${COMPOSE[@]}" up -d --wait --wait-timeout "${STARTUP_WAIT_SECONDS}" semantic-indexer || fail "Indexer restart failed"
    wait_for_indexer_admin || fail "restarted Indexer did not expose its admin endpoint"
    "${COMPOSE[@]}" up -d --wait --wait-timeout "${STARTUP_WAIT_SECONDS}" session-agent-runtime || fail "Runtime startup failed"
    "${COMPOSE[@]}" --profile runtime-check run --rm runtime-probe || fail "Runtime probe failed"
}

validate_deploy_arguments() {
    local mode="${1:-normal}"
    [[ "$#" -le 1 ]] || fail "usage: ./deploy.sh [schema-rebuild|reset]"
    case "${mode}" in normal|schema-rebuild|reset) ;; *) fail "usage: ./deploy.sh [schema-rebuild|reset]" ;; esac
}

deploy_impl() {
    local mode="$1" runtime_url runtime_ref semantic_url semantic_ref
    command -v git >/dev/null 2>&1 || fail "git is required"
    command -v docker >/dev/null 2>&1 || fail "docker is required"
    command -v jq >/dev/null 2>&1 || fail "jq is required"
    command -v flock >/dev/null 2>&1 || fail "flock is required"
    docker compose version >/dev/null 2>&1 || fail "docker compose is required"
    create_env_if_missing
    assert_required_secrets
    [[ "$(env_or_default SEMANTIC_DISPOSABLE_UAT false)" == true ]] \
        || fail "this compose uses plaintext Mongo only for disposable UAT; use an external TLS Mongo deployment"
    runtime_url="$(env_or_default SESSION_AGENT_GIT_URL git@github.com:ChouKevin/session-agent-runtime.git)"
    runtime_ref="$(env_or_default SESSION_AGENT_GIT_REF main)"
    semantic_url="$(env_or_default SEMANTIC_GIT_URL git@github.com:ChouKevin/java-code-intelligence.git)"
    semantic_ref="$(env_or_default SEMANTIC_GIT_REF main)"
    export STARTER_ROOT="${ROOT}"
    declare -F fixture_prepare_impl >/dev/null || source "${ROOT}/fixture.sh"
    COMPOSE=(docker compose --project-name java-agent-uat --env-file "${ENV_FILE}" -f "${ROOT}/compose.yaml")
    prepare_sources "${runtime_url}" "${runtime_ref}" "${semantic_url}" "${semantic_ref}"
    fixture_prepare_impl
    case "${mode}" in
        normal) capture_query_image false || fail "could not preserve the current Query image" ;;
        schema-rebuild)
            capture_query_image true || fail "could not preserve the current Query image"
            record_current_pointers
            ;;
        reset) ;;
    esac
    stop_existing_indexer
    "${COMPOSE[@]}" build semantic-mongo-init semantic-indexer semantic-query session-agent-runtime || fail "image build failed"
    validate_deployment_sources
    case "${mode}" in
        normal) normal_deploy ;;
        schema-rebuild) schema_rebuild ;;
        reset) reset_deploy ;;
    esac
    write_deployment_record
    printf 'deploy: offline Semantic index services started\n'
}

deploy_main() {
    validate_deploy_arguments "$@"
    with_deploy_lock deploy_impl "${1:-normal}"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then deploy_main "$@"; fi
