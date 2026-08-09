#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"

bash -n "${ROOT}/deploy.sh"
bash -n "${ROOT}/repository.sh"
bash -n "${ROOT}/contract-uat.sh"
bash -n "${ROOT}/knowledge-uat.sh"
bash -c 'source "$1"; declare -F classify_compose_rows preflight_active_deployment >/dev/null' bash "${ROOT}/deploy.sh"
bash -c 'source "$1"; declare -F main request >/dev/null' bash "${ROOT}/repository.sh"
bash -c 'source "$1"; declare -F main deployment_sha repository_revision pin_agent_fixture ensure_discovery_fixture write_summary_junit >/dev/null' bash "${ROOT}/contract-uat.sh"
bash -c 'source "$1"; declare -F main preflight read_live_configuration fixture_revision ensure_knowledge_fixture_and_database run_live_scenario validate_junit write_manifest >/dev/null' bash "${ROOT}/knowledge-uat.sh"
grep -Fq 'if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then' "${ROOT}/deploy.sh"
grep -Fq 'if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then' "${ROOT}/repository.sh"
grep -Fq 'if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then' "${ROOT}/contract-uat.sh"
grep -Fq 'if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then' "${ROOT}/knowledge-uat.sh"
grep -Fq 'reports/knowledge-uat/${RUN_ID}' "${ROOT}/knowledge-uat.sh"
grep -Fq 'gemini-3.1-flash-lite' "${ROOT}/knowledge-uat.sh"
! rg -q 'SLACK_' "${ROOT}/knowledge-uat.sh"
[[ "$(grep -Fc 'run --rm agent-knowledge' "${ROOT}/knowledge-uat.sh")" -eq 1 ]]
grep -Fq 'ps --all --format' "${ROOT}/deploy.sh"
grep -q '^AGENT_GIT_REF=uat$' "${ROOT}/.env.example"
grep -q '^SEMANTIC_GIT_REF=uat$' "${ROOT}/.env.example"
grep -Fxq '    m6-semantic-contract:' "${ROOT}/config/semantic-repositories.yml"
grep -Fxq '      mode: LOCAL_FIXTURE' "${ROOT}/config/semantic-repositories.yml"
grep -Fxq '      display-name: M6 Semantic Contract Fixture' "${ROOT}/config/semantic-repositories.yml"
grep -Fxq '      path: /fixtures/m6-semantic-contract' "${ROOT}/config/semantic-repositories.yml"
grep -Fxq '    m7-knowledge-query:' "${ROOT}/config/semantic-repositories.yml"
grep -Fxq '      mode: LOCAL_FIXTURE' "${ROOT}/config/semantic-repositories.yml"
grep -Fxq '      display-name: M7 Knowledge Query Fixture' "${ROOT}/config/semantic-repositories.yml"
grep -Fxq '      path: /fixtures/m7-knowledge-query' "${ROOT}/config/semantic-repositories.yml"
grep -q '/v1/repositories/.*/ensure' "${ROOT}/repository.sh"
grep -q '/v1/repositories/.*/sync' "${ROOT}/repository.sh"
grep -Fq '/checkout' "${ROOT}/repository.sh"
grep -Fq '^[0-9a-f]{40}$' "${ROOT}/repository.sh"
! grep -qE '^[[:space:]]+ports:' "${ROOT}/compose.yaml" \
    || [[ "$(grep -cE '^[[:space:]]+ports:' "${ROOT}/compose.yaml")" -eq 1 ]]

if rg -q '\$\{STARTER_ROOT\}/logs/(agent|semantic)' "${ROOT}/compose.yaml"; then
    exit 1
fi
if rg -q '/app/(agent-logs|semantic-logs)' "${ROOT}/compose.yaml"; then
    exit 1
fi
if rg -q '\$\{ROOT\}/logs/(agent|semantic)' "${ROOT}/deploy.sh"; then
    exit 1
fi
if rg -q 'tail -f' "${ROOT}/README.md"; then
    exit 1
fi
grep -Fq 'uat logs -f semantic-service' "${ROOT}/README.md"
grep -Fq 'uat logs -f java-system-agent' "${ROOT}/README.md"
grep -Fq 'bounded `json-file` rotation' "${ROOT}/README.md"

grep -Fq 'x-contract-runner: &contract-runner' "${ROOT}/compose.yaml"
grep -Fq 'image: maven:3.9.11-eclipse-temurin-21' "${ROOT}/compose.yaml"
grep -Fq 'profiles: [contract]' "${ROOT}/compose.yaml"
grep -Fq 'M6_SEMANTIC_BASE_URL: http://semantic-service:8080' "${ROOT}/compose.yaml"
grep -Fq 'M6_SEMANTIC_API_TOKEN: ${SEMANTIC_API_TOKEN}' "${ROOT}/compose.yaml"
grep -Fq 'M6_AGENT_REPO_ID: ${M6_AGENT_REPO_ID:-java-system-agent}' "${ROOT}/compose.yaml"
grep -Fq 'M6_AGENT_EXPECTED_REVISION: ${M6_AGENT_EXPECTED_REVISION:-}' "${ROOT}/compose.yaml"
grep -Fq 'M6_DISCOVERY_REPO_ID: ${M6_DISCOVERY_REPO_ID:-m6-semantic-contract}' "${ROOT}/compose.yaml"
grep -Fq 'M6_DISCOVERY_EXPECTED_REVISION: ${M6_DISCOVERY_EXPECTED_REVISION:-FIXTURE}' "${ROOT}/compose.yaml"
[[ "$(grep -cE '^    M6_(SEMANTIC_BASE_URL|SEMANTIC_API_TOKEN|AGENT_REPO_ID|AGENT_EXPECTED_REVISION|DISCOVERY_REPO_ID|DISCOVERY_EXPECTED_REVISION):' "${ROOT}/compose.yaml")" -eq 6 ]]
! rg -q 'M5_' "${ROOT}/compose.yaml" "${ROOT}/contract-uat.sh"
grep -Fq 'semantic-contract:' "${ROOT}/compose.yaml"
grep -Fq 'agent-contract:' "${ROOT}/compose.yaml"
grep -Fq '${STARTER_ROOT}/.runtime/sources/java-code-intelligence/pom.xml:/workspace/pom.xml:ro' "${ROOT}/compose.yaml"
grep -Fq '${STARTER_ROOT}/.runtime/sources/java-code-intelligence/src:/workspace/src:ro' "${ROOT}/compose.yaml"
grep -Fq '${STARTER_ROOT}/.runtime/sources/java-system-agent/pom.xml:/workspace/pom.xml:ro' "${ROOT}/compose.yaml"
grep -Fq '${STARTER_ROOT}/.runtime/sources/java-system-agent/src:/workspace/src:ro' "${ROOT}/compose.yaml"
grep -Fq '${STARTER_ROOT}/.runtime/sources/java-system-agent/src/test/resources/fixtures/m6-semantic-contract:/fixture-source/m6-semantic-contract:ro' \
    "${ROOT}/compose.yaml"
[[ "$(grep -Fc 'semantic-fixture:/fixtures/m6-semantic-contract' "${ROOT}/compose.yaml")" -eq 2 ]]
grep -Fq 'find /fixtures/m6-semantic-contract -mindepth 1 -delete' "${ROOT}/compose.yaml"
grep -Fq 'cp -a /fixture-source/m6-semantic-contract/. /fixtures/m6-semantic-contract/' "${ROOT}/compose.yaml"
grep -Fq 'chown -R 10001:10001 /fixtures/m6-semantic-contract' "${ROOT}/compose.yaml"
grep -Fq 'semantic-contract-workspace:/workspace' "${ROOT}/compose.yaml"
grep -Fq 'agent-contract-workspace:/workspace' "${ROOT}/compose.yaml"
grep -Fxq '  semantic-fixture:' "${ROOT}/compose.yaml"
grep -Fxq '  knowledge-fixture:' "${ROOT}/compose.yaml"
grep -Fxq '  agent-knowledge-workspace:' "${ROOT}/compose.yaml"
! grep -Fq 'contract-target:/workspace/target' "${ROOT}/compose.yaml"
grep -Fq 'mvn --batch-mode --no-transfer-progress clean test -Dtest=McpLiveContractIT' "${ROOT}/compose.yaml"
grep -Fq 'mvn --batch-mode --no-transfer-progress clean test -Dtest=JavaSemanticServiceLiveContractIT' "${ROOT}/compose.yaml"
grep -Fq 'TEST-com.java.semantic.mcp.McpLiveContractIT.xml' "${ROOT}/compose.yaml"
grep -Fq 'TEST-com.java.system.agent.codeintelligence.semantic.JavaSemanticServiceLiveContractIT.xml' \
    "${ROOT}/compose.yaml"
[[ "$(grep -Fc 'report_status=$$?' "${ROOT}/compose.yaml")" -eq 2 ]]
[[ "$(grep -Fc 'if [ "$$status" -ne 0 ]; then exit "$$status"; fi' "${ROOT}/compose.yaml")" -eq 2 ]]
grep -Fq 'run --rm "${service}"' "${ROOT}/contract-uat.sh"
grep -Fq 'reports/contract-uat/${RUN_ID}' "${ROOT}/contract-uat.sh"
grep -Fq '${M6_RUN_ID}' "${ROOT}/compose.yaml"
grep -Fxq 'reports/' "${ROOT}/.gitignore"

grep -Fq 'knowledge-fixture-init:' "${ROOT}/compose.yaml"
grep -Fq 'knowledge-db-init:' "${ROOT}/compose.yaml"
grep -Fq 'agent-knowledge:' "${ROOT}/compose.yaml"
[[ "$(grep -Fc 'profiles: [knowledge]' "${ROOT}/compose.yaml")" -eq 3 ]]
grep -Fq 'knowledge-fixture:/fixtures/m7-knowledge-query:ro' "${ROOT}/compose.yaml"
grep -Fq 'fixtures/m7-knowledge-query:/fixture-source/m7-knowledge-query:ro' "${ROOT}/compose.yaml"
grep -Fq 'cp -a /fixture-source/m7-knowledge-query/. /fixtures/m7-knowledge-query/' "${ROOT}/compose.yaml"
grep -Fq 'chown -R 10001:10001 /fixtures/m7-knowledge-query' "${ROOT}/compose.yaml"
! rg -q 'find /fixtures/m7-knowledge-query|rm -rf /fixtures/m7-knowledge-query|DROP DATABASE|TRUNCATE' "${ROOT}/compose.yaml"
grep -Fq 'CREATE DATABASE agent_m7_knowledge' "${ROOT}/compose.yaml"
grep -Fq 'jdbc:postgresql://postgres:5432/agent_m7_knowledge' "${ROOT}/compose.yaml"
grep -Fq 'M7_KNOWLEDGE_LIVE: "true"' "${ROOT}/compose.yaml"
grep -Fq 'M7_REPORT_DIRECTORY: /reports' "${ROOT}/compose.yaml"
grep -Fq 'CODEBASE_SERVICE_BASE_URL: http://semantic-service:8080' "${ROOT}/compose.yaml"
grep -Fq 'TEST-com.java.system.agent.M7KnowledgeQueryLiveIT.xml' "${ROOT}/compose.yaml"
grep -Fq 'mvn --batch-mode --no-transfer-progress clean test -Dtest=M7KnowledgeQueryLiveIT' "${ROOT}/compose.yaml"
[[ "$(grep -Fc 'mvn --batch-mode --no-transfer-progress clean test -Dtest=M7KnowledgeQueryLiveIT' "${ROOT}/compose.yaml")" -eq 1 ]]
grep -Fq '${STARTER_ROOT}/reports/knowledge-uat/${M7_RUN_ID}:/reports' "${ROOT}/compose.yaml"
! rg -q 'SLACK_' <(awk '/^  agent-knowledge:/{inside=1; next} /^  [^[:space:]]/{inside=0} inside' "${ROOT}/compose.yaml")

awk '
  /^  semantic-service:$/ { semantic_service = 1; next }
  /^  [^[:space:]]/ { semantic_service = 0 }
  semantic_service && /^[[:space:]]+ports:/ { published_semantic_port = 1 }
  END { exit !published_semantic_port }
' "${ROOT}/compose.yaml"
