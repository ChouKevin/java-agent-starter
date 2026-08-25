#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"

grep -Fq 'SEMANTIC_DISPOSABLE_UAT=true' "${ROOT}/.env.example"
grep -Fq 'plaintext Mongo only for disposable UAT' "${ROOT}/deploy.sh"
grep -Fq 'SEMANTIC_GIT_REF=main' "${ROOT}/.env.example"
grep -Fq 'semantic_ref="$(env_or_default SEMANTIC_GIT_REF main)"' "${ROOT}/deploy.sh"
TEMPORARY_DIRECTORY="$(mktemp -d)"
trap 'rm -rf "${TEMPORARY_DIRECTORY}"' EXIT

bash -n "${ROOT}/deploy.sh" "${ROOT}/repository.sh" "${ROOT}/runtime-uat.sh"
sed 's/=$/=contract-value/' "${ROOT}/.env.example" > "${TEMPORARY_DIRECTORY}/.env"
compose_json="$(STARTER_ROOT="${ROOT}" docker compose --project-name starter-contract --env-file "${TEMPORARY_DIRECTORY}/.env" --profile setup --profile schema-maintenance --profile legacy-cutover -f "${ROOT}/compose.yaml" config --format json)"
jq -e '
  (.services | has("semantic-mongodb") and has("semantic-mongo-init") and has("semantic-indexer") and has("semantic-query") and has("session-agent-runtime"))
  and .services["session-agent-runtime"].environment.SEMANTIC_BASE_URL == "http://semantic-query:8080"
  and (.services["semantic-query"].networks | keys) == ["semantic-read"]
  and (.volumes | has("semantic-mongodb-data") and has("semantic-indexer-repository-data") and has("semantic-repository-data"))
' <<< "${compose_json}" >/dev/null

jq -e '
  .services["semantic-mongo-users"].entrypoint == ["/bin/sh", "-ec"]
  and (.services["semantic-mongo-users"].command | join(" ") | contains("exec mongosh"))
  and (.services["semantic-mongo-users"].command | join(" ") | contains("$SEMANTIC_MONGO_ROOT_USERNAME"))
' <<< "${compose_json}" >/dev/null
if rg -n 'FIXTURE|semantic-probe|semantic-check' "${ROOT}/compose.yaml" "${ROOT}/deploy.sh"; then
    printf 'obsolete single-service probe contract remains\n' >&2
    exit 1
fi
