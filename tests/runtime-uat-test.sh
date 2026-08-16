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
touch "${FAKE_STARTER}/.runtime/sources/session-agent-runtime/pom.xml"
cat > "${FAKE_STARTER}/.env" <<EOF
SEMANTIC_API_TOKEN=${SECRET_TOKEN}
GOOGLE_API_KEY=${SECRET_KEY}
GOOGLE_GENAI_MODEL=contract-model
SESSION_AGENT_HOST_PORT=18090
SEMANTIC_HOST_PORT=18080
EOF

cat > "${FAKE_STARTER}/deploy.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
[[ "\$#" -eq 0 ]]
printf 'deploy\n' >> '${CALL_LOG}'
EOF
chmod +x "${FAKE_STARTER}/deploy.sh"

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

PATH="${FAKE_STARTER}/bin:${PATH}" "${FAKE_STARTER}/runtime-uat.sh" > "${OUTPUT_LOG}" 2>&1

[[ "$(<"${CALL_LOG}")" == $'deploy\nmvn:true:http://127.0.0.1:18090:http://127.0.0.1:18080:contract-model' ]] || {
    printf 'runtime UAT did not deploy before the external live test\n' >&2
    exit 1
}
! grep -Fq "${SECRET_TOKEN}" "${OUTPUT_LOG}"
! grep -Fq "${SECRET_KEY}" "${OUTPUT_LOG}"
