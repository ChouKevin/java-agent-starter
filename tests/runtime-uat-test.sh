#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
TEMPORARY_DIRECTORY="$(mktemp -d)"
FAKE_STARTER="${TEMPORARY_DIRECTORY}/starter"
CALL_LOG="${TEMPORARY_DIRECTORY}/calls.log"
OUTPUT_LOG="${TEMPORARY_DIRECTORY}/output.log"
SECRET_TOKEN='semantic-uat-token'
SECRET_KEY='google-uat-key'

cleanup() {
    rm -rf "${TEMPORARY_DIRECTORY}"
}
trap cleanup EXIT

[[ -x "${ROOT}/runtime-uat.sh" ]] || {
    printf 'runtime-uat.sh is missing\n' >&2
    exit 1
}

mkdir -p "${FAKE_STARTER}/.runtime/sources/session-agent-runtime" "${FAKE_STARTER}/bin"
cp "${ROOT}/runtime-uat.sh" "${FAKE_STARTER}/runtime-uat.sh"
cp "${ROOT}/semantic-index-uat.sh" "${FAKE_STARTER}/semantic-index-uat.sh"
touch "${FAKE_STARTER}/.runtime/sources/session-agent-runtime/pom.xml"
cat > "${FAKE_STARTER}/.env" <<EOF
SEMANTIC_QUERY_API_TOKEN=${SECRET_TOKEN}
GOOGLE_API_KEY=${SECRET_KEY}
GOOGLE_GENAI_MODEL=contract-model
SESSION_AGENT_HOST_PORT=18090
SEMANTIC_HOST_PORT=18080
EOF

cat > "${FAKE_STARTER}/deploy.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
with_deploy_lock() {
    mkdir -p '${FAKE_STARTER}/.runtime'
    exec {DEPLOY_LOCK_FD}>'${FAKE_STARTER}/.runtime/deploy.lock'
    flock -n "\${DEPLOY_LOCK_FD}"
    "\$@"
}
deploy_impl() {
    [[ "\$#" -eq 1 && "\$1" == reset ]]
    printf 'deploy\n' >> '${CALL_LOG}'
}
EOF
chmod +x "${FAKE_STARTER}/deploy.sh"

cat > "${FAKE_STARTER}/semantic-index-uat.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
semantic_index_uat_impl() {
    [[ "\${SEMANTIC_UAT_PROFILE}" == uat ]]
    deploy_impl reset
    printf 'semantic\n' >> '${CALL_LOG}'
}
EOF
chmod +x "${FAKE_STARTER}/semantic-index-uat.sh"

cat > "${FAKE_STARTER}/bin/mvn" <<EOF
#!/usr/bin/env bash
set -euo pipefail
[[ "\$#" -eq 5 ]]
[[ "\$1" == '-q' ]]
[[ "\$2" == '-f' ]]
[[ "\$3" == '${FAKE_STARTER}/.runtime/sources/session-agent-runtime/pom.xml' ]]
[[ "\$4" == '-Dtest=SessionAgentLiveIT' ]]
[[ "\$5" == 'test' ]]
[[ "\${SESSION_AGENT_LIVE}" == true ]]
[[ "\${SESSION_AGENT_BASE_URL}" == 'http://127.0.0.1:18090' ]]
[[ "\${SEMANTIC_BASE_URL}" == 'http://127.0.0.1:18080' ]]
[[ "\${SEMANTIC_API_TOKEN}" == '${SECRET_TOKEN}' ]]
[[ "\${GOOGLE_API_KEY}" == '${SECRET_KEY}' ]]
[[ "\${GOOGLE_GENAI_MODEL}" == 'contract-model' ]]
if flock -n '${FAKE_STARTER}/.runtime/deploy.lock' true; then
    printf 'live acceptance released the deployment lock before Maven finished\n' >&2
    exit 1
fi
printf 'mvn:%s:%s:%s:%s\n' "\${SESSION_AGENT_LIVE}" "\${SESSION_AGENT_BASE_URL}" "\${SEMANTIC_BASE_URL}" "\${GOOGLE_GENAI_MODEL}" >> '${CALL_LOG}'
EOF
chmod +x "${FAKE_STARTER}/bin/mvn"

if PATH="${FAKE_STARTER}/bin:${PATH}" "${FAKE_STARTER}/runtime-uat.sh" unexpected > "${OUTPUT_LOG}" 2>&1; then
    printf 'runtime UAT accepted a positional argument\n' >&2
    exit 1
fi
grep -Fq 'usage: ./runtime-uat.sh' "${OUTPUT_LOG}"
[[ ! -e "${CALL_LOG}" ]] || {
    printf 'runtime UAT deployed before rejecting a positional argument\n' >&2
    exit 1
}

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
[[ ! -e "${CALL_LOG}" ]] || {
    printf 'runtime UAT mutated while the deployment lock was held\n' >&2
    exit 1
}
wait "${LOCK_HOLDER_PID}"

PATH="${FAKE_STARTER}/bin:${PATH}" "${FAKE_STARTER}/runtime-uat.sh" > "${OUTPUT_LOG}" 2>&1

[[ "$(<"${CALL_LOG}")" == $'deploy\nsemantic\nmvn:true:http://127.0.0.1:18090:http://127.0.0.1:18080:contract-model' ]] || {
    printf 'runtime UAT did not run Semantic acceptance once before the external live test\n' >&2
    exit 1
}
! grep -Fq "${SECRET_TOKEN}" "${OUTPUT_LOG}"
! grep -Fq "${SECRET_KEY}" "${OUTPUT_LOG}"
