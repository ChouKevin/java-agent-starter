#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
TEMPORARY_DIRECTORY="$(mktemp -d)"
FAKE_STARTER="${TEMPORARY_DIRECTORY}/starter"
CALL_LOG="${TEMPORARY_DIRECTORY}/calls.log"
OUTPUT_LOG="${TEMPORARY_DIRECTORY}/output.log"
SECRET_TOKEN='semantic-uat-token'
SYSTEM_CP="$(command -v cp)"
export CALL_LOG SECRET_TOKEN SYSTEM_CP

cleanup() { rm -rf -- "${TEMPORARY_DIRECTORY}"; }
trap cleanup EXIT

[[ -x "${ROOT}/cross-service-uat.sh" ]] || {
    printf 'cross-service-uat.sh is missing\n' >&2
    exit 1
}

mkdir -p "${FAKE_STARTER}/.runtime/sources/java-code-intelligence" \
    "${FAKE_STARTER}/.runtime/sources/session-agent-runtime" "${FAKE_STARTER}/bin"
cp "${ROOT}/cross-service-uat.sh" "${FAKE_STARTER}/cross-service-uat.sh"
cat > "${FAKE_STARTER}/.env" <<EOF
SEMANTIC_QUERY_API_TOKEN=${SECRET_TOKEN}
SEMANTIC_HOST_PORT=18080
SESSION_AGENT_HOST_PORT=18090
EOF

cat > "${FAKE_STARTER}/deploy.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
ENV_FILE="${ROOT}/.env"
SOURCES_DIR="${ROOT}/.runtime/sources"
DEPLOYMENT_RECORD_FILE="${ROOT}/deployment-record.txt"
DEPLOY_LOCK_FILE="${ROOT}/.runtime/deploy.lock"
COMPOSE=(docker compose --project-name java-agent-uat --env-file "${ENV_FILE}" -f "${ROOT}/compose.yaml")
fail() { printf 'deploy: %s\n' "$*" >&2; return 1; }
env_value() { local line; line="$(grep -m1 -E "^$1=" "${ENV_FILE}" 2>/dev/null || true)"; printf '%s' "${line#*=}"; }
env_or_default() { local configured; configured="$(env_value "$1")"; [[ -n "${configured}" ]] && printf '%s' "${configured}" || printf '%s' "$2"; }
with_deploy_lock() (
    local operation_lock_fd
    mkdir -p "${ROOT}/.runtime"
    exec {operation_lock_fd}>"${DEPLOY_LOCK_FILE}"
    flock -n "${operation_lock_fd}" || { printf 'deploy: lock held\n' >&2; return 1; }
    "$@"
)
deploy_impl() {
    [[ "$1" == reset ]]
    if flock -n "${DEPLOY_LOCK_FILE}" true; then
        printf 'deploy reset ran outside the outer lock\n' >&2
        return 1
    fi
    mkdir -p "${ROOT}/.runtime/sources/java-code-intelligence" "${ROOT}/.runtime/sources/session-agent-runtime"
    : > "${ROOT}/.runtime/sources/java-code-intelligence/pom.xml"
    : > "${ROOT}/.runtime/sources/session-agent-runtime/pom.xml"
    printf 'deployment-record-safe\n' > "${DEPLOYMENT_RECORD_FILE}"
    printf 'deploy:reset\n' >> "${CALL_LOG}"
}
EOF
chmod +x "${FAKE_STARTER}/deploy.sh"

cat > "${FAKE_STARTER}/semantic-index-uat.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
SEMANTIC_INDEX_UAT_LOADED=true
EVIDENCE_DIRECTORY="${ROOT}/.runtime/evidence/semantic-git-uat"
semantic_uat_deploy_initial_r1_impl() {
    if flock -n "${DEPLOY_LOCK_FILE}" true; then
        printf 'fixture publication ran outside the outer lock\n' >&2
        return 1
    fi
    mkdir -p "${EVIDENCE_DIRECTORY}"
    deploy_impl reset
    printf 'fixture-evidence-safe\n' > "${EVIDENCE_DIRECTORY}/initial-revisions.txt"
    printf 'fixtures:published\n' >> "${CALL_LOG}"
}
EOF
chmod +x "${FAKE_STARTER}/semantic-index-uat.sh"

cat > "${FAKE_STARTER}/bin/docker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
arguments="$*"
case "${arguments}" in
    *' stop semantic-query-gateway semantic-query')
        printf 'semantic:stopped\n' >> "${CALL_LOG}"
        ;;
    *' up -d --force-recreate --no-deps session-agent-runtime')
        printf 'runtime:recreated-no-deps\n' >> "${CALL_LOG}"
        ;;
    *' up -d --no-recreate semantic-query semantic-query-gateway')
        printf 'semantic:started-no-runtime\n' >> "${CALL_LOG}"
        ;;
    *' ps -q session-agent-runtime')
        if [[ "${CROSS_SERVICE_UAT_FAIL_RUNTIME_CONTAINER_READ:-false}" == true ]]; then
            exit 61
        elif [[ "${CROSS_SERVICE_UAT_RUNTIME_CONTAINER_CHANGES:-false}" == true ]]; then
            count_file="${CROSS_SERVICE_UAT_TEST_TEMPORARY_DIRECTORY}/runtime-container-id-count"
            count=0
            [[ -f "${count_file}" ]] && count="$(<"${count_file}")"
            count=$((count + 1))
            printf '%s' "${count}" > "${count_file}"
            if (( count == 1 )); then
                printf 'runtime-container-id\n'
            else
                printf 'runtime-container-id-changed\n'
            fi
        else
            printf 'runtime-container-id\n'
        fi
        ;;
    *' logs --no-color session-agent-runtime semantic-query')
        printf 'safe component logs\n'
        ;;
    *)
        printf 'unexpected docker invocation: %s\n' "${arguments}" >&2
        exit 1
        ;;
esac
EOF
chmod +x "${FAKE_STARTER}/bin/docker"

export CROSS_SERVICE_UAT_TEST_TEMPORARY_DIRECTORY="${TEMPORARY_DIRECTORY}"
cat > "${FAKE_STARTER}/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
target="${!#}"
case "${target}" in
    'http://127.0.0.1:18090/actuator/health')
        printf 'runtime:health-ready\n' >> "${CALL_LOG}"
        printf '{"status":"UP"}\n'
        ;;
    'http://127.0.0.1:18090/actuator/mcpConnections')
        poll_file="${CROSS_SERVICE_UAT_TEST_TEMPORARY_DIRECTORY}/mcp-polls"
        polls=0
        [[ -f "${poll_file}" ]] && polls="$(<"${poll_file}")"
        polls=$((polls + 1))
        printf '%s' "${polls}" > "${poll_file}"
        if (( polls == 1 )); then
            printf 'runtime:mcp-unavailable\n' >> "${CALL_LOG}"
            printf '{"connections":{"semantic":{"state":"UNAVAILABLE","toolCount":0}}}\n'
        else
            printf 'runtime:mcp-available\n' >> "${CALL_LOG}"
            printf '{"connections":{"semantic":{"state":"AVAILABLE","toolCount":12}}}\n'
        fi
        ;;
    *)
        printf 'unexpected curl target: %s\n' "${target}" >&2
        exit 1
        ;;
esac
EOF
chmod +x "${FAKE_STARTER}/bin/curl"

cat > "${FAKE_STARTER}/bin/cp" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
fake_root="$(cd -- "$(dirname -- "$0")/.." && pwd -P)"
if [[ "${CROSS_SERVICE_UAT_FAIL_FIXTURE_EVIDENCE:-false}" == true \
    && "$1" == -R \
    && "$2" == "${fake_root}/.runtime/evidence/semantic-git-uat" ]]; then
    "${SYSTEM_CP}" "$@"
    exit 53
fi
exec "${SYSTEM_CP}" "$@"
EOF
chmod +x "${FAKE_STARTER}/bin/cp"

cat > "${FAKE_STARTER}/bin/mvn" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
fake_root="$(cd -- "$(dirname -- "$0")/.." && pwd -P)"
if [[ "$3" == "${fake_root}/.runtime/sources/java-code-intelligence/pom.xml" ]]; then
    [[ "$#" -eq 11 && "$1" == -q && "$2" == -f && "$4" == -pl && "$5" == semantic-query && "$6" == -am ]]
    [[ "$7" == -Pdeployed-it && "$8" == -Dtest=SemanticDeploymentIT && "$9" == -DfailIfNoTests=true \
        && "${10}" == -Dsurefire.failIfNoSpecifiedTests=false && "${11}" == test ]]
    [[ "${SEMANTIC_BASE_URL}" == http://127.0.0.1:18080 && "${SEMANTIC_API_TOKEN}" == "${SECRET_TOKEN}" ]]
    [[ "${SEMANTIC_UAT_REPOSITORY}" == payment-service ]]
    if [[ "${CROSS_SERVICE_UAT_FAIL_SEMANTIC:-false}" == true ]]; then
        printf 'mvn:semantic:failed\n' >> "${CALL_LOG}"
        exit 47
    fi
    printf 'mvn:semantic:deployed-it\n' >> "${CALL_LOG}"
elif [[ "$3" == "${fake_root}/.runtime/sources/session-agent-runtime/pom.xml" ]]; then
    [[ "$#" -eq 6 && "$1" == -q && "$2" == -f ]]
    [[ "$4" == '-Dtest=McpToolCatalogTest,ConversationHistoryProjectorTest,MessageJobServiceTest' ]]
    [[ "$5" == -DfailIfNoTests=true && "$6" == test ]]
    [[ -z "${GOOGLE_API_KEY:-}" && -z "${SEMANTIC_BASE_URL:-}" && -z "${SEMANTIC_API_TOKEN:-}" ]]
    printf 'mvn:runtime:fake-backed\n' >> "${CALL_LOG}"
else
    printf 'unexpected Maven pom: %s\n' "$3" >&2
    exit 1
fi
EOF
chmod +x "${FAKE_STARTER}/bin/mvn"

PATH="${FAKE_STARTER}/bin:${PATH}" bash -c 'source "$1"; declare -F cross_service_uat_main >/dev/null' \
    -- "${FAKE_STARTER}/cross-service-uat.sh"
[[ ! -e "${CALL_LOG}" ]] || { printf 'sourcing cross-service UAT performed deployment work\n' >&2; exit 1; }

if PATH="${FAKE_STARTER}/bin:${PATH}" "${FAKE_STARTER}/cross-service-uat.sh" unexpected > "${OUTPUT_LOG}" 2>&1; then
    printf 'cross-service UAT accepted a positional argument\n' >&2
    exit 1
fi
grep -Fq 'usage: ./cross-service-uat.sh' "${OUTPUT_LOG}"
[[ ! -e "${CALL_LOG}" ]] || { printf 'cross-service UAT ran before rejecting an argument\n' >&2; exit 1; }

(
    exec 9>"${FAKE_STARTER}/.runtime/deploy.lock"
    flock -n 9
    touch "${FAKE_STARTER}/lock-ready"
    sleep 1
) &
LOCK_HOLDER_PID=$!
while [[ ! -e "${FAKE_STARTER}/lock-ready" ]]; do sleep 0.01; done
if PATH="${FAKE_STARTER}/bin:${PATH}" "${FAKE_STARTER}/cross-service-uat.sh" > "${OUTPUT_LOG}" 2>&1; then
    printf 'cross-service UAT bypassed the deployment lock\n' >&2
    exit 1
fi
[[ ! -e "${CALL_LOG}" ]] || { printf 'cross-service UAT mutated while the lock was held\n' >&2; exit 1; }
wait "${LOCK_HOLDER_PID}"

: > "${CALL_LOG}"
rm -f "${TEMPORARY_DIRECTORY}/mcp-polls" "${TEMPORARY_DIRECTORY}/runtime-container-id-count"
if CROSS_SERVICE_UAT_FAIL_FIXTURE_EVIDENCE=true PATH="${FAKE_STARTER}/bin:${PATH}" \
    "${FAKE_STARTER}/cross-service-uat.sh" > "${OUTPUT_LOG}" 2>&1; then
    printf 'cross-service UAT returned success after fixture evidence copy failed\n' >&2
    exit 1
fi
mapfile -t FIXTURE_FAILURE_CALLS < "${CALL_LOG}"
[[ "${FIXTURE_FAILURE_CALLS[*]}" == *'fixtures:published'* \
    && "${FIXTURE_FAILURE_CALLS[*]}" != *'semantic:stopped'* ]] || {
    printf 'cross-service UAT continued after fixture evidence copy failed\n' >&2
    exit 1
}
grep -R -Fxq 'stage=fixture-evidence' "${FAKE_STARTER}/.runtime/evidence/cross-service-mcp"/*/failure.txt || {
    printf 'cross-service UAT did not identify fixture-evidence as the failed stage\n' >&2
    exit 1
}

: > "${CALL_LOG}"
rm -f "${TEMPORARY_DIRECTORY}/mcp-polls" "${TEMPORARY_DIRECTORY}/runtime-container-id-count"
if CROSS_SERVICE_UAT_FAIL_RUNTIME_CONTAINER_READ=true PATH="${FAKE_STARTER}/bin:${PATH}" \
    "${FAKE_STARTER}/cross-service-uat.sh" > "${OUTPUT_LOG}" 2>&1; then
    printf 'cross-service UAT returned success after the pre-recovery Runtime ID read failed\n' >&2
    exit 1
fi
mapfile -t RUNTIME_ID_READ_FAILURE_CALLS < "${CALL_LOG}"
[[ "${RUNTIME_ID_READ_FAILURE_CALLS[*]}" != *'semantic:started-no-runtime'* ]] || {
    printf 'cross-service UAT continued after the pre-recovery Runtime ID read failed\n' >&2
    exit 1
}
grep -R -Fxq 'stage=runtime-container-before' "${FAKE_STARTER}/.runtime/evidence/cross-service-mcp"/*/failure.txt || {
    printf 'cross-service UAT did not identify the pre-recovery Runtime ID stage\n' >&2
    exit 1
}

: > "${CALL_LOG}"
rm -f "${TEMPORARY_DIRECTORY}/mcp-polls" "${TEMPORARY_DIRECTORY}/runtime-container-id-count"
if CROSS_SERVICE_UAT_RUNTIME_CONTAINER_CHANGES=true PATH="${FAKE_STARTER}/bin:${PATH}" \
    "${FAKE_STARTER}/cross-service-uat.sh" > "${OUTPUT_LOG}" 2>&1; then
    printf 'cross-service UAT returned success after Runtime recreation during Semantic recovery\n' >&2
    exit 1
fi
mapfile -t RESTART_FAILURE_CALLS < "${CALL_LOG}"
[[ "${RESTART_FAILURE_CALLS[*]}" != *'mvn:semantic:deployed-it'* && "${RESTART_FAILURE_CALLS[*]}" != *'mvn:runtime:fake-backed'* ]] || {
    printf 'cross-service UAT continued after Runtime container changed\n' >&2
    exit 1
}
grep -R -Fxq 'stage=runtime-container-stable' "${FAKE_STARTER}/.runtime/evidence/cross-service-mcp"/*/failure.txt || {
    printf 'cross-service UAT did not identify the Runtime stability stage\n' >&2
    exit 1
}

: > "${CALL_LOG}"
rm -f "${TEMPORARY_DIRECTORY}/mcp-polls" "${TEMPORARY_DIRECTORY}/runtime-container-id-count"
if CROSS_SERVICE_UAT_FAIL_SEMANTIC=true PATH="${FAKE_STARTER}/bin:${PATH}" "${FAKE_STARTER}/cross-service-uat.sh" > "${OUTPUT_LOG}" 2>&1; then
    printf 'cross-service UAT returned success after Semantic deployed-it failed\n' >&2
    exit 1
fi
mapfile -t FAILURE_CALLS < "${CALL_LOG}"
[[ "${FAILURE_CALLS[*]}" == *'mvn:semantic:failed'* && "${FAILURE_CALLS[*]}" != *'mvn:runtime:fake-backed'* ]] || {
    printf 'cross-service UAT continued after Semantic deployed-it failed\n' >&2
    exit 1
}
FAILURE_EVIDENCE="$(find "${FAKE_STARTER}/.runtime/evidence/cross-service-mcp" -type f -name failure.txt -print -quit)"
[[ -n "${FAILURE_EVIDENCE}" && -f "${FAILURE_EVIDENCE}" ]] || { printf 'cross-service UAT did not retain failure evidence\n' >&2; exit 1; }
FAILURE_DIRECTORY="$(dirname -- "${FAILURE_EVIDENCE}")"
[[ -f "${FAILURE_DIRECTORY}/component-logs.txt" && -f "${FAILURE_DIRECTORY}/runtime-mcp-connections.json" \
    && -f "${FAILURE_DIRECTORY}/deployment-record.txt" && -d "${FAILURE_DIRECTORY}/semantic-fixture-evidence" ]] || {
    printf 'cross-service UAT did not retain safe diagnostics for a failed stage\n' >&2
    exit 1
}
! grep -R -Fq "${SECRET_TOKEN}" "${FAKE_STARTER}/.runtime/evidence/cross-service-mcp" "${OUTPUT_LOG}"

: > "${CALL_LOG}"
rm -f "${TEMPORARY_DIRECTORY}/mcp-polls" "${TEMPORARY_DIRECTORY}/runtime-container-id-count"
PATH="${FAKE_STARTER}/bin:${PATH}" "${FAKE_STARTER}/cross-service-uat.sh" > "${OUTPUT_LOG}" 2>&1
mapfile -t CALLS < "${CALL_LOG}"
EXPECTED_CALLS=(
    deploy:reset
    fixtures:published
    semantic:stopped
    runtime:recreated-no-deps
    runtime:health-ready
    semantic:started-no-runtime
    runtime:mcp-unavailable
    runtime:mcp-available
    mvn:semantic:deployed-it
    mvn:runtime:fake-backed
)
[[ "${#CALLS[@]}" -ge "${#EXPECTED_CALLS[@]}" ]] || { printf 'cross-service UAT omitted a required stage\n' >&2; exit 1; }
for index in "${!EXPECTED_CALLS[@]}"; do
    [[ "${CALLS[${index}]}" == "${EXPECTED_CALLS[${index}]}" ]] || {
        printf 'cross-service UAT order mismatch at %s: expected=%s actual=%s\n' \
            "${index}" "${EXPECTED_CALLS[${index}]}" "${CALLS[${index}]}" >&2
        exit 1
    }
done
COMPLETION_EVIDENCE="$(grep -rl -F 'cross-service-mcp=complete' \
    "${FAKE_STARTER}/.runtime/evidence/cross-service-mcp" | head -n 1)"
[[ -n "${COMPLETION_EVIDENCE}" ]] || {
    printf 'cross-service UAT did not write completion evidence\n' >&2
    exit 1
}
! grep -Fq "${SECRET_TOKEN}" "${OUTPUT_LOG}"
printf 'cross-service-uat-test: PASS\n'
