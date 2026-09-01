#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
TEMPORARY_DIRECTORY="$(mktemp -d)"
FAKE_STARTER="${TEMPORARY_DIRECTORY}/starter"
CALL_LOG="${TEMPORARY_DIRECTORY}/calls.log"
OUTPUT_LOG="${TEMPORARY_DIRECTORY}/output.log"
SECRET_TOKEN='semantic-uat-token'
SECRET_KEY='google-uat-key'

cleanup() { rm -rf "${TEMPORARY_DIRECTORY}"; }
trap cleanup EXIT

[[ -x "${ROOT}/runtime-uat.sh" ]] || { printf 'runtime-uat.sh is missing\n' >&2; exit 1; }
mkdir -p "${FAKE_STARTER}/.runtime/sources/session-agent-runtime" "${FAKE_STARTER}/bin"
cp "${ROOT}/runtime-uat.sh" "${FAKE_STARTER}/runtime-uat.sh"
cat > "${FAKE_STARTER}/.env" <<EOF
GOOGLE_API_KEY=${SECRET_KEY}
GOOGLE_GENAI_MODEL=contract-model
SESSION_AGENT_HOST_PORT=18090
SEMANTIC_QUERY_API_TOKEN=${SECRET_TOKEN}
SEMANTIC_HOST_PORT=18080
EOF

cp "${ROOT}/deploy.sh" "${FAKE_STARTER}/deploy.sh"
chmod +x "${FAKE_STARTER}/deploy.sh"

cat > "${FAKE_STARTER}/semantic-index-uat.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
assert_outer_lock() {
    if flock -n '${FAKE_STARTER}/.runtime/deploy.lock' true; then
        printf 'semantic phase ran outside the Runtime outer lock\n' >&2
        exit 1
    fi
}
semantic_uat_deploy_initial_r1_impl() {
    assert_outer_lock
    touch '${FAKE_STARTER}/.runtime/sources/session-agent-runtime/pom.xml'
    printf 'semantic:r1\n' >> '${CALL_LOG}'
}
semantic_uat_cold_r1_and_rebuild_impl() { assert_outer_lock; printf 'semantic:cold-r1\n' >> '${CALL_LOG}'; }
semantic_uat_gated_payment_transition_impl() {
    assert_outer_lock
    [[ "\$1" == session || "\$1" == repeat ]]
    printf 'semantic:r2:%s\n' "\$1" >> '${CALL_LOG}'
}
semantic_uat_reset_payment_to_v1_impl() { assert_outer_lock; printf 'semantic:reset\n' >> '${CALL_LOG}'; }
evidence() { assert_outer_lock; printf 'evidence:%s\n' "\$*" >> '${CALL_LOG}'; }
semantic_index_uat_main() { printf 'nested semantic main\n' >&2; exit 1; }
EOF
chmod +x "${FAKE_STARTER}/semantic-index-uat.sh"

cat > "${FAKE_STARTER}/bin/mvn" <<EOF
#!/usr/bin/env bash
set -euo pipefail
[[ "\$#" -eq 7 && "\$1" == '-q' && "\$2" == '-f' ]]
[[ "\$3" == '${FAKE_STARTER}/.runtime/sources/session-agent-runtime/pom.xml' ]]
[[ "\$4" == '-Plive-it' ]]
[[ "\$5" == '-DfailIfNoTests=true' ]]
[[ "\$7" == test ]]
[[ "\${SESSION_AGENT_LIVE}" == true ]]
[[ "\${SESSION_AGENT_BASE_URL}" == 'http://127.0.0.1:18090' ]]
[[ -n "\${SESSION_AGENT_HISTORY_KEY}" ]]
[[ -z "\${SEMANTIC_BASE_URL:-}" && -z "\${SEMANTIC_API_TOKEN:-}" ]]
[[ "\${GOOGLE_API_KEY}" == '${SECRET_KEY}' && "\${GOOGLE_GENAI_MODEL}" == contract-model ]]
if flock -n '${FAKE_STARTER}/.runtime/deploy.lock' true; then
    printf 'live acceptance released the deployment lock before Maven finished\n' >&2
    exit 1
fi
if [[ "\${RUNTIME_UAT_FAIL_FIRST_MAVEN:-false}" == true ]]; then
    printf 'mvn:failed:%s\n' "\$6" >> '${CALL_LOG}'
    exit 23
fi
printf 'mvn:%s:%s\n' "\$6" "\${SESSION_AGENT_HISTORY_KEY}" >> '${CALL_LOG}'
EOF
chmod +x "${FAKE_STARTER}/bin/mvn"

if PATH="${FAKE_STARTER}/bin:${PATH}" "${FAKE_STARTER}/runtime-uat.sh" unexpected > "${OUTPUT_LOG}" 2>&1; then
    printf 'runtime UAT accepted a positional argument\n' >&2
    exit 1
fi
grep -Fq 'usage: ./runtime-uat.sh' "${OUTPUT_LOG}"
[[ ! -e "${CALL_LOG}" ]] || { printf 'runtime UAT ran before rejecting an argument\n' >&2; exit 1; }

(
    exec 9>"${FAKE_STARTER}/.runtime/deploy.lock"
    flock -n 9
    touch "${FAKE_STARTER}/lock-ready"
    sleep 1
) &
LOCK_HOLDER_PID=$!
while [[ ! -e "${FAKE_STARTER}/lock-ready" ]]; do sleep 0.01; done
if PATH="${FAKE_STARTER}/bin:${PATH}" "${FAKE_STARTER}/runtime-uat.sh" > "${OUTPUT_LOG}" 2>&1; then
    printf 'runtime UAT bypassed the deployment lock\n' >&2
    exit 1
fi
[[ ! -e "${CALL_LOG}" ]] || { printf 'runtime UAT mutated while the lock was held\n' >&2; exit 1; }
wait "${LOCK_HOLDER_PID}"

if RUNTIME_UAT_FAIL_FIRST_MAVEN=true PATH="${FAKE_STARTER}/bin:${PATH}" "${FAKE_STARTER}/runtime-uat.sh" > "${OUTPUT_LOG}" 2>&1; then
    printf 'runtime UAT returned success after its first Maven phase failed\n' >&2
    exit 1
fi
[[ "$(<"${CALL_LOG}")" == 'semantic:r1
mvn:failed:-Dtest=SessionAgentLiveIT' ]] || {
    printf 'runtime UAT continued after the first Maven phase failed\n' >&2
    cat "${CALL_LOG}" >&2
    exit 1
}
: > "${CALL_LOG}"

SEMANTIC_BASE_URL='http://stale-semantic.invalid' SEMANTIC_API_TOKEN="${SECRET_TOKEN}" \
    PATH="${FAKE_STARTER}/bin:${PATH}" "${FAKE_STARTER}/runtime-uat.sh" > "${OUTPUT_LOG}" 2>&1

mapfile -t CALLS < "${CALL_LOG}"
[[ "${CALLS[0]}" == semantic:r1 ]]
[[ "${CALLS[1]}" == mvn:-Dtest=SessionAgentLiveIT:* ]]
[[ "${CALLS[2]}" == semantic:cold-r1 ]]
[[ "${CALLS[3]}" == semantic:r2:session ]]
[[ "${CALLS[4]}" == semantic:reset ]]
[[ "${CALLS[5]}" == semantic:r2:repeat ]]
[[ "${CALLS[6]}" == evidence:runtime-uat=complete ]]
[[ "${#CALLS[@]}" -eq 7 ]]
! grep -Fq "${SECRET_TOKEN}" "${OUTPUT_LOG}"
! grep -Fq "${SECRET_KEY}" "${OUTPUT_LOG}"
