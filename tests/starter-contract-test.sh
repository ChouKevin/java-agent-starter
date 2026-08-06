#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"

bash -n "${ROOT}/deploy.sh"
bash -n "${ROOT}/repository.sh"
bash -c 'source "$1"; declare -F classify_compose_rows preflight_active_deployment >/dev/null' bash "${ROOT}/deploy.sh"
bash -c 'source "$1"; declare -F main request >/dev/null' bash "${ROOT}/repository.sh"
grep -Fq 'if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then' "${ROOT}/deploy.sh"
grep -Fq 'if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then' "${ROOT}/repository.sh"
grep -Fq 'ps --all --format' "${ROOT}/deploy.sh"
grep -q '^AGENT_GIT_REF=uat$' "${ROOT}/.env.example"
grep -q '^SEMANTIC_GIT_REF=uat$' "${ROOT}/.env.example"
grep -q 'java-system-agent:' "${ROOT}/config/semantic-repositories.yml"
grep -q '/v1/repositories/.*/ensure' "${ROOT}/repository.sh"
grep -Fq '/checkout' "${ROOT}/repository.sh"
grep -Fq '^[0-9a-f]{40}$' "${ROOT}/repository.sh"
! grep -qE '^[[:space:]]+ports:' "${ROOT}/compose.yaml" \
    || [[ "$(grep -cE '^[[:space:]]+ports:' "${ROOT}/compose.yaml")" -eq 1 ]]

grep -Fq 'x-contract-runner: &contract-runner' "${ROOT}/compose.yaml"
grep -Fq 'image: maven:3.9.11-eclipse-temurin-21' "${ROOT}/compose.yaml"
grep -Fq 'profiles: [contract]' "${ROOT}/compose.yaml"
grep -Fq 'M5_SEMANTIC_BASE_URL: http://semantic-service:8080' "${ROOT}/compose.yaml"
grep -Fq 'M5_SEMANTIC_API_TOKEN: ${SEMANTIC_API_TOKEN}' "${ROOT}/compose.yaml"
grep -Fq 'M5_REPO_ID: ${M5_REPO_ID:-java-system-agent}' "${ROOT}/compose.yaml"
grep -Fq 'M5_EXPECTED_REVISION: ${M5_EXPECTED_REVISION:-}' "${ROOT}/compose.yaml"
grep -Fq 'semantic-contract:' "${ROOT}/compose.yaml"
grep -Fq 'agent-contract:' "${ROOT}/compose.yaml"
grep -Fq '${STARTER_ROOT}/.runtime/sources/java-code-intelligence/pom.xml:/workspace/pom.xml:ro' "${ROOT}/compose.yaml"
grep -Fq '${STARTER_ROOT}/.runtime/sources/java-code-intelligence/src:/workspace/src:ro' "${ROOT}/compose.yaml"
grep -Fq '${STARTER_ROOT}/.runtime/sources/java-system-agent/pom.xml:/workspace/pom.xml:ro' "${ROOT}/compose.yaml"
grep -Fq '${STARTER_ROOT}/.runtime/sources/java-system-agent/src:/workspace/src:ro' "${ROOT}/compose.yaml"
grep -Fq 'mvn --batch-mode --no-transfer-progress clean test -Dtest=McpLiveContractIT' "${ROOT}/compose.yaml"
grep -Fq 'mvn --batch-mode --no-transfer-progress clean test -Dtest=JavaSemanticServiceLiveContractIT' "${ROOT}/compose.yaml"

awk '
  /^  semantic-service:$/ { semantic_service = 1; next }
  /^  [^[:space:]]/ { semantic_service = 0 }
  semantic_service && /^[[:space:]]+ports:/ { published_semantic_port = 1 }
  END { exit !published_semantic_port }
' "${ROOT}/compose.yaml"
