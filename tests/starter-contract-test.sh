#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"

grep -Fq 'SEMANTIC_DISPOSABLE_UAT=true' "${ROOT}/.env.example"
grep -Fq 'plaintext Mongo only for disposable UAT' "${ROOT}/deploy.sh"
grep -Fq 'SEMANTIC_GIT_REF=main' "${ROOT}/.env.example"
grep -Fq 'semantic_ref="$(env_or_default SEMANTIC_GIT_REF main)"' "${ROOT}/deploy.sh"
TEMPORARY_DIRECTORY="$(mktemp -d)"
trap 'rm -rf "${TEMPORARY_DIRECTORY}"' EXIT

bash -n "${ROOT}/deploy.sh" "${ROOT}/fixture.sh" "${ROOT}/repository.sh" "${ROOT}/runtime-uat.sh" "${ROOT}/semantic-index-uat.sh"
sed 's/=$/=contract-value/' "${ROOT}/.env.example" > "${TEMPORARY_DIRECTORY}/.env"
compose_json="$(STARTER_ROOT="${ROOT}" docker compose --project-name starter-contract --env-file "${TEMPORARY_DIRECTORY}/.env" \
    --profile setup --profile schema-maintenance --profile semantic-index-check --profile semantic-query-check \
    -f "${ROOT}/compose.yaml" config --format json)"
jq -e '
  (.services | has("semantic-mongodb") and has("semantic-mongo-init") and has("semantic-indexer") and has("semantic-query") and has("semantic-query-gateway") and has("session-agent-runtime"))
  and ([.services | keys[] | select(. == "semantic-indexer")] | length) == 1
  and ((.services["semantic-indexer"].deploy.replicas // 1) == 1)
  and (.services["session-agent-runtime"].environment.SPRING_APPLICATION_JSON | fromjson) as $runtime
  | $runtime["session-agent"].mcp.connections.semantic.enabled == true
  and $runtime["session-agent"].mcp.connections.semantic.url == "http://semantic-query:8080/mcp"
  and $runtime["session-agent"].mcp.connections.semantic.headers["X-Api-Token"] == "contract-value"
  and (.services["session-agent-runtime"].environment | has("SEMANTIC_BASE_URL") | not)
  and (.services["session-agent-runtime"].environment | has("SEMANTIC_API_TOKEN") | not)
  and (.services["session-agent-runtime"].depends_on | has("semantic-query") | not)
  and (.services["session-agent-runtime"].depends_on | has("session-agent-postgres"))
  and (.services["semantic-query"].networks | keys) == ["semantic-read"]
  and ((.services["semantic-query"].ports // []) | length) == 0
  and (.services["semantic-query-gateway"].depends_on["semantic-query"].condition == "service_started")
  and (.services["semantic-query-gateway"].networks | keys | sort) == ["semantic-query-ingress", "semantic-read"]
  and .services["semantic-query-gateway"].ports[0].host_ip == "127.0.0.1"
  and .services["semantic-query-gateway"].ports[0].target == 8080
  and ((.services["semantic-indexer"].volumes | map(.target)) | index("/uat-git")) != null
  and ((.services["semantic-indexer"].volumes | map(.target)) | index("/data/repos")) != null
  and ((.services["semantic-indexer"].volumes | map(.target)) | index("/data/jdtls")) != null
  and ((.services["semantic-query"].volumes // []) | length) == 0
  and ([.services["semantic-query"].environment | keys[] | select(test("JDT|MODEL|GOOGLE|GIT"))] | length) == 0
  and (.services["semantic-mongodb"].environment.MONGO_INITDB_DATABASE == "semantic_uat")
  and ([.services["semantic-mongo-init"].environment.SEMANTIC_MONGODB_URI, .services["semantic-indexer"].environment.SEMANTIC_MONGODB_URI, .services["semantic-query"].environment.SEMANTIC_MONGODB_URI] | all(contains("/semantic_uat?authSource=semantic_uat")))
  and (.services["semantic-index-probe"].command[2] | contains("-H \"X-Api-Token: $$SEMANTIC_INDEXER_ADMIN_TOKEN\""))
  and (.services["semantic-query-probe"].command[2] | contains("-H \"X-Api-Token: $$SEMANTIC_QUERY_API_TOKEN\""))
  and (.services["semantic-query-probe"].command[2] | contains("http://semantic-query:8080/api/v1/repositories"))
  and (.volumes | has("semantic-mongodb-data") and has("semantic-indexer-repository-data") and has("semantic-indexer-jdt-data"))
' <<< "${compose_json}" >/dev/null

jq -e '
  .services["semantic-mongo-users"].entrypoint == ["/bin/sh", "-ec"]
  and (.services["semantic-mongo-users"].command | join(" ") | contains("exec mongosh"))
  and (.services["semantic-mongo-users"].command | join(" ") | contains("$SEMANTIC_MONGO_ROOT_USERNAME"))
' <<< "${compose_json}" >/dev/null
rg -Fq 'semantic_uat' "${ROOT}/compose.yaml"
rg -Fq 'semantic_uat' "${ROOT}/config/mongo-init.js"
for repository in payment-service order-service video-service; do
    rg -Fq "url: file:///uat-git/${repository}.git" "${ROOT}/config/semantic-repositories.yml"
done
if rg -n 'semantic-service|legacy-cutover|SEMANTIC_LEGACY|fixture-init|payment-service-fixture|order-service-fixture|video-service-fixture|semantic-repository-data|semantic-jdt-data|LOCAL_FIXTURE|/fixtures/' \
    "${ROOT}/compose.yaml" "${ROOT}/config" "${ROOT}/.env.example" "${ROOT}/semantic-index-uat.sh" \
    || rg -n 'semantic-service|legacy-cutover|SEMANTIC_LEGACY|fixture-init|payment-service-fixture|order-service-fixture|video-service-fixture|semantic-repository-data|semantic-jdt-data' "${ROOT}/deploy.sh"; then
    printf 'obsolete cutover or fixture configuration remains\n' >&2
    exit 1
fi
if rg -n 'replSet|rs\.initiate|transaction|coordination|expected-database|expectedDatabase' \
    "${ROOT}/compose.yaml" "${ROOT}/config" "${ROOT}/deploy.sh" "${ROOT}/semantic-index-uat.sh"; then
    printf 'standalone semantic_uat configuration contains distributed coordination\n' >&2
    exit 1
fi
