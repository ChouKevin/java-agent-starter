#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
TEMPORARY_DIRECTORY="$(mktemp -d)"
CONTRACT_ENV="${TEMPORARY_DIRECTORY}/compose.env"

cleanup() {
    rm -rf "${TEMPORARY_DIRECTORY}"
}
trap cleanup EXIT

bash -n "${ROOT}/deploy.sh"
bash -n "${ROOT}/repository.sh"
bash -n "${ROOT}/tests/deploy-session-runtime-test.sh"
bash -n "${ROOT}/tests/deploy-state-test.sh"
bash -n "${ROOT}/runtime-uat.sh"
bash -n "${ROOT}/tests/runtime-uat-test.sh"

for removed_file in contract-uat.sh knowledge-uat.sh payment-uat.sh \
    tests/contract-uat-test.sh tests/deploy-agent-only-test.sh tests/knowledge-uat-test.sh; do
    [[ ! -e "${ROOT}/${removed_file}" ]] || {
        printf 'legacy agent workflow remains: %s\n' "${removed_file}" >&2
        exit 1
    }
done

for expected_line in \
    'SESSION_AGENT_GIT_URL=git@github.com:ChouKevin/session-agent-runtime.git' \
    'SESSION_AGENT_GIT_REF=main' \
    'SEMANTIC_API_TOKEN=' \
    'SESSION_AGENT_POSTGRES_PASSWORD=' \
    'GIT_USERNAME=' \
    'GIT_TOKEN=' \
    'GOOGLE_API_KEY=' \
    'GOOGLE_GENAI_MODEL=gemini-3.1-flash-lite' \
    'SLACK_APP_TOKEN=' \
    'SLACK_BOT_TOKEN=' \
    'SLACK_BOT_USER_ID='; do
    grep -Fxq "${expected_line}" "${ROOT}/.env.example"
done

grep -Fq '${STARTER_ROOT}/.runtime/sources/session-agent-runtime' "${ROOT}/compose.yaml"
grep -Fq '${STARTER_ROOT}/.runtime/sources/java-code-intelligence' "${ROOT}/compose.yaml"
grep -Fq 'Session Agent source SHA:' "${ROOT}/deploy.sh"
grep -Fxq '    payment-service:' "${ROOT}/config/semantic-repositories.yml"
grep -Fxq '    order-service:' "${ROOT}/config/semantic-repositories.yml"
[[ ! -d "${ROOT}/session-agent-runtime" ]]

if rg -n 'java-system-agent|(^|[^A-Z0-9_])AGENT_GIT_|(^|[^A-Z0-9_])AGENT_REPOSITORY_ID|agent-only|agent-contract|agent-knowledge' \
    "${ROOT}/.env.example" "${ROOT}/compose.yaml" "${ROOT}/deploy.sh" \
    "${ROOT}/config/semantic-repositories.yml" >/dev/null; then
    printf 'legacy Java System Agent deployment contract remains\n' >&2
    exit 1
fi

if rg -n 'prompt' "${ROOT}/compose.yaml" >/dev/null; then
    printf 'agent-owned prompt mount remains\n' >&2
    exit 1
fi

if rg -n --glob '!starter-contract-test.sh' --glob '!deploy-state-test.sh' \
    'java-system-agent|(^|[^A-Z_])AGENT_GIT_|(^|[^A-Z_])AGENT_REPOSITORY_ID|agent-only|agent-contract|agent-knowledge' \
    "${ROOT}/README.md" "${ROOT}/.env.example" "${ROOT}/compose.yaml" \
    "${ROOT}/deploy.sh" "${ROOT}/runtime-uat.sh" "${ROOT}/tests" >/dev/null; then
    printf 'legacy Java System Agent deployment contract remains\n' >&2
    exit 1
fi

cat > "${CONTRACT_ENV}" <<EOF
STARTER_ROOT=${ROOT}
SEMANTIC_API_TOKEN=contract-semantic-token
SESSION_AGENT_POSTGRES_PASSWORD=contract-postgres-password
GOOGLE_API_KEY=contract-google-key
GOOGLE_GENAI_MODEL=contract-google-model
SLACK_APP_TOKEN=contract-slack-app-token
SLACK_BOT_TOKEN=contract-slack-bot-token
SLACK_BOT_USER_ID=contract-slack-user-id
EOF

compose_json="$(docker compose --env-file "${CONTRACT_ENV}" -f "${ROOT}/compose.yaml" config --format json)"
profiled_compose_json="$(docker compose --env-file "${CONTRACT_ENV}" --profile setup --profile semantic-check --profile runtime-check -f "${ROOT}/compose.yaml" config --format json)"

jq -e --arg starter_root "${ROOT}" '
  (.services | keys == ["semantic-service", "session-agent-postgres", "session-agent-runtime"])
  and .services["session-agent-postgres"].image == "postgres:17"
  and .services["semantic-service"].build.context == ($starter_root + "/.runtime/sources/java-code-intelligence")
  and .services["session-agent-runtime"].build.context == ($starter_root + "/.runtime/sources/session-agent-runtime")
  and .services["semantic-service"].environment.SEMANTIC_API_TOKEN == "contract-semantic-token"
  and .services["semantic-service"].environment.GIT_USERNAME == ""
  and .services["semantic-service"].environment.GIT_TOKEN == ""
  and .services["session-agent-runtime"].environment.SESSION_AGENT_DATASOURCE_URL == "jdbc:postgresql://session-agent-postgres:5432/session_agent"
  and .services["session-agent-runtime"].environment.SESSION_AGENT_DATASOURCE_USERNAME == "session_agent"
  and .services["session-agent-runtime"].environment.SESSION_AGENT_DATASOURCE_PASSWORD == "contract-postgres-password"
  and .services["session-agent-runtime"].environment.SEMANTIC_BASE_URL == "http://semantic-service:8080"
  and .services["session-agent-runtime"].environment.SEMANTIC_API_TOKEN == "contract-semantic-token"
  and .services["session-agent-runtime"].environment.GOOGLE_API_KEY == "contract-google-key"
  and .services["session-agent-runtime"].environment.SPRING_AI_GOOGLE_GENAI_API_KEY == "contract-google-key"
  and .services["session-agent-runtime"].environment.GOOGLE_GENAI_MODEL == "contract-google-model"
  and .services["session-agent-runtime"].environment.SLACK_APP_TOKEN == "contract-slack-app-token"
  and .services["session-agent-runtime"].environment.SLACK_BOT_TOKEN == "contract-slack-bot-token"
  and .services["session-agent-runtime"].environment.SLACK_BOT_USER_ID == "contract-slack-user-id"
  and ([.services["session-agent-runtime"].environment | keys[] | select(startswith("GIT_"))] | length == 0)
  and .services["semantic-service"].ports == [
    {"mode":"ingress","host_ip":"127.0.0.1","target":8080,"published":"8080","protocol":"tcp"}
  ]
  and .services["session-agent-runtime"].ports == [
    {"mode":"ingress","host_ip":"127.0.0.1","target":8080,"published":"8090","protocol":"tcp"}
  ]
  and (.volumes | keys == ["order-service-fixture", "payment-service-fixture", "semantic-jdt-data", "semantic-repository-data", "session-agent-postgres-data"])
  and ([.volumes[] | has("name")] | any | not)
  and (.networks | keys == ["session-agent-network"])
' <<< "${compose_json}" >/dev/null

jq -e '
  (.services | keys == ["fixture-init", "runtime-probe", "semantic-probe", "semantic-service", "session-agent-postgres", "session-agent-runtime"])
  and .services["fixture-init"].profiles == ["setup"]
  and .services["semantic-probe"].profiles == ["semantic-check"]
  and .services["runtime-probe"].profiles == ["runtime-check"]
  and .services["semantic-probe"].image == "curlimages/curl:8.12.1"
  and .services["runtime-probe"].image == "curlimages/curl:8.12.1"
  and (.services["fixture-init"].command | join(" ") == "cp -a /fixture-source/payment-service/. /fixtures/payment-service/ && cp -a /fixture-source/order-service/. /fixtures/order-service/ && chown -R 10001:10001 /fixtures/payment-service /fixtures/order-service")
  and (.services["fixture-init"].command | join(" ") | contains(".fixture-ready") | not)
  and (.services["fixture-init"].command | join(" ") | contains("find /fixtures") | not)
  and (.services["fixture-init"].command | join(" ") | contains("rm -rf") | not)
  and (.services["fixture-init"].environment | has("FIXTURE_VOLUME_SUFFIX") | not)
  and (.services["semantic-probe"].depends_on | keys == ["semantic-service"])
  and .services["semantic-probe"].environment.SEMANTIC_API_TOKEN == "contract-semantic-token"
  and (.services["semantic-probe"].command | join(" ") | contains("set -x") | not)
  and (.services["semantic-probe"].command | join(" ") | contains("curl --fail --silent --show-error --retry 30 --retry-delay 2 --retry-connrefused --connect-timeout 5 --max-time 10 -H \\\"X-Api-Token: $$SEMANTIC_API_TOKEN\\\" http://semantic-service:8080/v1/repositories >/dev/null"))
  and (.services["semantic-probe"].command | join(" ") | contains("-X POST -H \\\"X-Api-Token: $$SEMANTIC_API_TOKEN\\\" --connect-timeout 5 --max-time 120 http://semantic-service:8080/v1/repositories/payment-service/ensure >/dev/null"))
  and (.services["semantic-probe"].command | join(" ") | contains("-X POST -H \\\"X-Api-Token: $$SEMANTIC_API_TOKEN\\\" --connect-timeout 5 --max-time 120 http://semantic-service:8080/v1/repositories/order-service/ensure >/dev/null"))
  and (.services["semantic-probe"].command | join(" ") | contains("-H \\\"X-Api-Token: $$SEMANTIC_API_TOKEN\\\" --connect-timeout 5 --max-time 30 http://semantic-service:8080/v1/repositories/payment-service/status >/dev/null"))
  and (.services["semantic-probe"].command | join(" ") | contains("-H \\\"X-Api-Token: $$SEMANTIC_API_TOKEN\\\" --connect-timeout 5 --max-time 120 \\\"http://semantic-service:8080/v1/repositories/payment-service/entry-points?expectedRevision=FIXTURE\\\" >/dev/null"))
  and (.services["semantic-probe"].command | join(" ") | split("--retry") | length == 2)
  and (.services["semantic-probe"].command | join(" ") | split(">/dev/null") | length == 6)
  and (.services["semantic-probe"].command | join(" ") | contains("session-agent-runtime") | not)
  and (.services["runtime-probe"].depends_on | keys == ["session-agent-runtime"])
  and (.services["runtime-probe"] | has("environment") | not)
  and (.services["runtime-probe"].command | join(" ") == "curl --fail --silent --show-error --retry 30 --retry-delay 2 --retry-connrefused --connect-timeout 5 --max-time 10 http://session-agent-runtime:8080/actuator/health >/dev/null")
  and (.services["runtime-probe"].command | join(" ") | contains("semantic-service") | not)
  and (.services["runtime-probe"].command | join(" ") | contains("SEMANTIC_API_TOKEN") | not)
' <<< "${profiled_compose_json}" >/dev/null

if rg -n 'FIXTURE_VOLUME_SUFFIX|network-probe|profiles: \[tools\]' "${ROOT}/compose.yaml" >/dev/null; then
    printf 'legacy fixture suffix or combined probe remains\n' >&2
    exit 1
fi
