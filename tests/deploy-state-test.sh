#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
TEMPORARY_DIRECTORY="$(mktemp -d)"

cleanup() {
    rm -rf "${TEMPORARY_DIRECTORY}"
}

trap cleanup EXIT

assert_equals() {
    local expected="$1"
    local actual="$2"
    local description="$3"

    [[ "${actual}" == "${expected}" ]] \
        || {
            printf 'expected %s, got %s: %s\n' "${expected}" "${actual}" "${description}" >&2
            exit 1
        }
}

assert_fails_without_sync() {
    local rows="$1"
    local record_file="$2"
    local runtime_directory="$3"
    local semantic_directory="$4"
    local expected_hint="$5"
    local sync_marker="${TEMPORARY_DIRECTORY}/sync-called"
    local output

    sync_source() {
        touch "${sync_marker}"
    }

    if output="$(preflight_active_deployment \
        "${rows}" "${record_file}" "${runtime_directory}" "${semantic_directory}" 2>&1)"; then
        printf 'expected preflight to fail\n' >&2
        exit 1
    fi
    [[ "${output}" == *"${expected_hint}"* ]] || {
        printf 'preflight did not provide the expected recovery hint\n' >&2
        exit 1
    }
    [[ ! -e "${sync_marker}" ]] || {
        printf 'preflight invoked sync_source\n' >&2
        exit 1
    }
}

grep -Fq 'if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then' "${ROOT}/deploy.sh" || {
    printf 'deploy.sh must guard main when sourced\n' >&2
    exit 1
}

source "${ROOT}/deploy.sh"

LOCK_FILE="${ROOT}/.runtime/deploy.lock"
mkdir -p "$(dirname "${LOCK_FILE}")"
flock -n "${LOCK_FILE}" sleep 1 &
LOCK_HOLDER_PID=$!
sleep 0.1
if (acquire_deploy_lock) >/dev/null 2>&1; then
    printf 'second deployment invocation acquired the exclusive deployment lock\n' >&2
    exit 1
fi
wait "${LOCK_HOLDER_PID}"

HEALTHY_ROWS=$'session-agent-postgres|running|healthy\nsemantic-service|running|\nsession-agent-runtime|running|'

assert_equals "ABSENT" "$(classify_compose_rows "")" "empty Compose rows are absent"
assert_equals "ACTIVE_HEALTHY" "$(classify_compose_rows "${HEALTHY_ROWS}")" "required running services are healthy"
assert_equals "ACTIVE_UNRECOGNIZED" \
    "$(classify_compose_rows $'session-agent-postgres|running|healthy\nsemantic-service|running|healthy')" \
    "missing required service is rejected"
assert_equals "ACTIVE_UNRECOGNIZED" \
    "$(classify_compose_rows $'session-agent-postgres|running|healthy\nsemantic-service|running|healthy\nsession-agent-runtime|running|healthy\njava-system-agent|running|healthy')" \
    "legacy mixed project service is rejected"
assert_equals "ACTIVE_DEGRADED" \
    "$(classify_compose_rows $'session-agent-postgres|running|unhealthy\nsemantic-service|running|healthy\nsession-agent-runtime|running|healthy')" \
    "unhealthy service is degraded"
assert_equals "ACTIVE_DEGRADED" \
    "$(classify_compose_rows $'session-agent-postgres|restarting|\nsemantic-service|running|healthy\nsession-agent-runtime|running|healthy')" \
    "restarting service is degraded"
assert_fails_without_sync \
    $'session-agent-postgres|restarting|\nsemantic-service|running|healthy\nsession-agent-runtime|running|healthy' \
    "${TEMPORARY_DIRECTORY}/missing-record.txt" \
    "${TEMPORARY_DIRECTORY}/missing-runtime" \
    "${TEMPORARY_DIRECTORY}/missing-semantic" \
    'docker compose --project-name java-agent-uat logs session-agent-postgres semantic-service session-agent-runtime'

RUNTIME_DIRECTORY="${TEMPORARY_DIRECTORY}/runtime"
SEMANTIC_DIRECTORY="${TEMPORARY_DIRECTORY}/semantic"
RECORD_FILE="${TEMPORARY_DIRECTORY}/deployment-record.txt"
for repository_directory in "${RUNTIME_DIRECTORY}" "${SEMANTIC_DIRECTORY}"; do
    git init --quiet "${repository_directory}"
    git -C "${repository_directory}" config user.email deploy-state-test@example.invalid
    git -C "${repository_directory}" config user.name deploy-state-test
    git -C "${repository_directory}" commit --quiet --allow-empty -m initial
done

RUNTIME_SHA="$(git -C "${RUNTIME_DIRECTORY}" rev-parse HEAD)"
SEMANTIC_SHA="$(git -C "${SEMANTIC_DIRECTORY}" rev-parse HEAD)"
printf 'Session Agent source SHA: %s\nSemantic source SHA: %s\n' "${RUNTIME_SHA}" "${SEMANTIC_SHA}" > "${RECORD_FILE}"

deployment_record_matches_sources "${RECORD_FILE}" "${RUNTIME_DIRECTORY}" "${SEMANTIC_DIRECTORY}"
preflight_active_deployment \
    "${HEALTHY_ROWS}" "${RECORD_FILE}" "${RUNTIME_DIRECTORY}" "${SEMANTIC_DIRECTORY}" >/dev/null
assert_equals "ACTIVE_HEALTHY" \
    "$(classify_active_deployment_state "${HEALTHY_ROWS}" "${RECORD_FILE}" "${RUNTIME_DIRECTORY}" "${SEMANTIC_DIRECTORY}")" \
    "matching deployment record keeps a healthy stack healthy"
assert_fails_without_sync \
    "${HEALTHY_ROWS}" "${TEMPORARY_DIRECTORY}/missing-record.txt" "${RUNTIME_DIRECTORY}" "${SEMANTIC_DIRECTORY}" \
    'docker compose --project-name java-agent-uat ps --all'

git -C "${RUNTIME_DIRECTORY}" commit --quiet --allow-empty -m runtime-update
assert_equals "ACTIVE_INCONSISTENT" \
    "$(classify_active_deployment_state "${HEALTHY_ROWS}" "${RECORD_FILE}" "${RUNTIME_DIRECTORY}" "${SEMANTIC_DIRECTORY}")" \
    "a newer Session Agent source differs from the active deployment record"
assert_fails_without_sync \
    "${HEALTHY_ROWS}" "${RECORD_FILE}" "${RUNTIME_DIRECTORY}" "${SEMANTIC_DIRECTORY}" \
    'docker compose --project-name java-agent-uat ps --all'

PREPARED_DEPLOYMENT_FILE="${TEMPORARY_DIRECTORY}/prepared-deployment.txt"
cat > "${PREPARED_DEPLOYMENT_FILE}" <<EOF
runtime URL: test-runtime-url
runtime ref: main
runtime old SHA: ${RUNTIME_SHA}
runtime target SHA: $(git -C "${RUNTIME_DIRECTORY}" rev-parse HEAD)
semantic URL: test-semantic-url
semantic ref: main
semantic old SHA: ${SEMANTIC_SHA}
semantic target SHA: ${SEMANTIC_SHA}
fixture suffix: 0123456789ab-cdef01234567
EOF
assert_equals "PREPARED_RECOVERY" \
    "$(classify_active_deployment_state "${HEALTHY_ROWS}" "${RECORD_FILE}" "${RUNTIME_DIRECTORY}" "${SEMANTIC_DIRECTORY}")" \
    "post-promotion sources with an old active record resume from prepared deployment state"
preflight_active_deployment "${HEALTHY_ROWS}" "${RECORD_FILE}" "${RUNTIME_DIRECTORY}" "${SEMANTIC_DIRECTORY}" >/dev/null

RUNTIME_TARGET_SHA="$(git -C "${RUNTIME_DIRECTORY}" rev-parse HEAD)"
printf 'Session Agent source SHA: %s\nSemantic source SHA: %s\nFixture volume suffix: 0123456789ab-cdef01234567\n' \
    "${RUNTIME_TARGET_SHA}" "${SEMANTIC_SHA}" > "${RECORD_FILE}"
prepared_deployment_is_committed "${HEALTHY_ROWS}" "${RECORD_FILE}" "${RUNTIME_DIRECTORY}" "${SEMANTIC_DIRECTORY}" || {
    printf 'prepared deployment matching the active record was not recognized as committed\n' >&2
    exit 1
}

printf 'Session Agent source SHA: %s\nSemantic source SHA: %s\nFixture volume suffix: aaaaaaaaaaaa-bbbbbbbbbbbb\n' \
    "${RUNTIME_TARGET_SHA}" "${SEMANTIC_SHA}" > "${RECORD_FILE}"
if prepared_deployment_is_committed "${HEALTHY_ROWS}" "${RECORD_FILE}" "${RUNTIME_DIRECTORY}" "${SEMANTIC_DIRECTORY}"; then
    printf 'prepared deployment with a mismatched active fixture identity was accepted\n' >&2
    exit 1
fi

FIXTURE_DOCKER_LOG="${TEMPORARY_DIRECTORY}/fixture-volume-removals.txt"
docker() {
    if [[ "$1" == "ps" ]]; then
        return
    fi
    if [[ "$1" == "volume" && "$2" == "rm" ]]; then
        printf '%s\n' "$3" >> "${FIXTURE_DOCKER_LOG}"
    fi
}
DEPLOYMENT_RECORD_FILE="${RECORD_FILE}"
prepare_target_fixture_volumes
[[ "$(<"${FIXTURE_DOCKER_LOG}")" == $'java-agent-uat-payment-fixture-0123456789ab-cdef01234567\njava-agent-uat-order-fixture-0123456789ab-cdef01234567' ]] || {
    printf 'fixture recovery did not reset only target-keyed volumes\n' >&2
    exit 1
}

VALIDATION_DIRECTORY="${TEMPORARY_DIRECTORY}/source-validation"
VALIDATION_SOURCES="${VALIDATION_DIRECTORY}/sources"
mkdir -p "${VALIDATION_SOURCES}"
for name in runtime semantic; do
    git init --bare --quiet "${VALIDATION_DIRECTORY}/${name}.git"
    git clone --quiet "${VALIDATION_DIRECTORY}/${name}.git" "${VALIDATION_DIRECTORY}/${name}-seed"
    git -C "${VALIDATION_DIRECTORY}/${name}-seed" config user.email deploy-state-test@example.invalid
    git -C "${VALIDATION_DIRECTORY}/${name}-seed" config user.name deploy-state-test
    touch "${VALIDATION_DIRECTORY}/${name}-seed/${name}.txt"
    git -C "${VALIDATION_DIRECTORY}/${name}-seed" add .
    git -C "${VALIDATION_DIRECTORY}/${name}-seed" commit --quiet -m initial
    git -C "${VALIDATION_DIRECTORY}/${name}-seed" push --quiet origin HEAD:main
done
git clone --quiet --branch main "${VALIDATION_DIRECTORY}/runtime.git" "${VALIDATION_SOURCES}/session-agent-runtime"
git clone --quiet --branch main "${VALIDATION_DIRECTORY}/semantic.git" "${VALIDATION_SOURCES}/java-code-intelligence"
RUNTIME_SOURCE_SHA="$(git -C "${VALIDATION_SOURCES}/session-agent-runtime" rev-parse HEAD)"
SEMANTIC_SOURCE_SHA="$(git -C "${VALIDATION_SOURCES}/java-code-intelligence" rev-parse HEAD)"
touch "${VALIDATION_SOURCES}/java-code-intelligence/dirty.txt"
SOURCES_DIR="${VALIDATION_SOURCES}"
PREPARED_DEPLOYMENT_FILE="${VALIDATION_DIRECTORY}/prepared-deployment.txt"
if bash -c '
    source "$1"
    SOURCES_DIR="$2"
    PREPARED_DEPLOYMENT_FILE="$3"
    prepare_or_resume_sources "$4" main "$5" main
' _ "${ROOT}/deploy.sh" "${VALIDATION_SOURCES}" "${PREPARED_DEPLOYMENT_FILE}" \
    "${VALIDATION_DIRECTORY}/runtime.git" "${VALIDATION_DIRECTORY}/semantic.git" >/dev/null 2>&1; then
    printf 'expected paired source validation to reject dirty second checkout\n' >&2
    exit 1
fi
assert_equals "${RUNTIME_SOURCE_SHA}" \
    "$(git -C "${VALIDATION_SOURCES}/session-agent-runtime" rev-parse HEAD)" \
    "dirty second source leaves the first managed checkout unchanged"
[[ ! -e "${PREPARED_DEPLOYMENT_FILE}" ]] || {
    printf 'failed paired validation persisted prepared deployment state\n' >&2
    exit 1
}

cat > "${PREPARED_DEPLOYMENT_FILE}" <<EOF
runtime URL: ${VALIDATION_DIRECTORY}/runtime.git
runtime ref: main
runtime old SHA: ${RUNTIME_SOURCE_SHA}
runtime target SHA: ${RUNTIME_SOURCE_SHA}
semantic URL: ${VALIDATION_DIRECTORY}/semantic.git
semantic ref: main
semantic old SHA: ${SEMANTIC_SOURCE_SHA}
semantic target SHA: ${SEMANTIC_SOURCE_SHA}
fixture suffix: 0123456789ab-cdef01234567
EOF
if bash -c '
    source "$1"
    SOURCES_DIR="$2"
    PREPARED_DEPLOYMENT_FILE="$3"
    prepare_or_resume_sources "$4" main "$5" main
' _ "${ROOT}/deploy.sh" "${VALIDATION_SOURCES}" "${PREPARED_DEPLOYMENT_FILE}" \
    "${VALIDATION_DIRECTORY}/runtime.git" "${VALIDATION_DIRECTORY}/semantic.git" >/dev/null 2>&1; then
    printf 'expected prepared recovery to reject a dirty target checkout\n' >&2
    exit 1
fi

printf 'Session Agent source SHA: %s\nSemantic source SHA: %040d\n' "${RUNTIME_SHA}" 0 > "${RECORD_FILE}"
if deployment_record_matches_sources "${RECORD_FILE}" "${RUNTIME_DIRECTORY}" "${SEMANTIC_DIRECTORY}"; then
    printf 'expected mismatching deployment record to fail\n' >&2
    exit 1
fi
assert_equals "ACTIVE_INCONSISTENT" \
    "$(classify_active_deployment_state "${HEALTHY_ROWS}" "${RECORD_FILE}" "${RUNTIME_DIRECTORY}" "${SEMANTIC_DIRECTORY}")" \
    "mismatching deployment record is inconsistent"
assert_fails_without_sync \
    "${HEALTHY_ROWS}" "${RECORD_FILE}" "${RUNTIME_DIRECTORY}" "${SEMANTIC_DIRECTORY}" \
    'docker compose --project-name java-agent-uat ps --all'
