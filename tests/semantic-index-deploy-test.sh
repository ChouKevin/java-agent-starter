#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"

grep -Fq 'semantic-indexer:' "${ROOT}/compose.yaml"
grep -Fq 'semantic-query:' "${ROOT}/compose.yaml"
TEMPORARY_DIRECTORY="$(mktemp -d)"
trap 'rm -rf "${TEMPORARY_DIRECTORY}"' EXIT
sed 's/=$/=contract-value/' "${ROOT}/.env.example" > "${TEMPORARY_DIRECTORY}/.env"
compose_json="$(STARTER_ROOT="${ROOT}" docker compose --project-name semantic-index-contract --env-file "${TEMPORARY_DIRECTORY}/.env" \
    -f "${ROOT}/compose.yaml" config --format json)"
jq -e '
  (.services["session-agent-runtime"].environment.SPRING_APPLICATION_JSON | fromjson) as $runtime
  | $runtime["session-agent"].mcp.connections.semantic.enabled == true
  and $runtime["session-agent"].mcp.connections.semantic.url == "http://semantic-query:8080/mcp"
  and $runtime["session-agent"].mcp.connections.semantic.headers["X-Api-Token"] == "contract-value"
  and (.services["session-agent-runtime"].environment | has("SEMANTIC_BASE_URL") | not)
  and (.services["session-agent-runtime"].environment | has("SEMANTIC_API_TOKEN") | not)
' <<< "${compose_json}" >/dev/null
grep -Fq 'Dockerfile.indexer' "${ROOT}/compose.yaml"
grep -Fq 'Dockerfile.query' "${ROOT}/compose.yaml"
grep -Fq 'schema-bootstrap' "${ROOT}/compose.yaml"
grep -Fq 'ensure_all_repositories' "${ROOT}/deploy.sh"
grep -Fq 'wait_for_compatible_manifests' "${ROOT}/deploy.sh"
grep -Fq 'fixture_prepare_impl' "${ROOT}/deploy.sh"
grep -Fq 'stop_existing_indexer' "${ROOT}/deploy.sh"
deploy_block="$(awk '/deploy_impl\(\)/,/^}/' "${ROOT}/deploy.sh")"
root_line="$(grep -n 'export STARTER_ROOT=' <<< "${deploy_block}" | cut -d: -f1)"
fixture_source_line="$(grep -n 'source "${ROOT}/fixture.sh"' <<< "${deploy_block}" | cut -d: -f1)"
[[ -n "${root_line}" && -n "${fixture_source_line}" && "${root_line}" -lt "${fixture_source_line}" ]] || {
    printf 'deployment must fix STARTER_ROOT before loading fixture paths\n' >&2
    exit 1
}

CALL_LOG="${TEMPORARY_DIRECTORY}/calls.log"

source "${ROOT}/deploy.sh"

create_env_if_missing() { :; }
assert_required_secrets() { :; }
env_or_default() {
    [[ "$1" == SEMANTIC_DISPOSABLE_UAT ]] && { printf '%s' true; return; }
    printf '%s' "$2"
}
prepare_sources() { printf 'sources\n' >> "${CALL_LOG}"; }
fixture_prepare_impl() { printf 'fixtures\n' >> "${CALL_LOG}"; }
validate_deployment_sources() { :; }
write_deployment_record() { :; }
normal_deploy() {
    [[ "${INDEXER_STOPPED:-false}" == true ]] || { printf 'replacement Indexer started before old Indexer stopped\n' >&2; return 1; }
    printf 'start-indexer\n' >> "${CALL_LOG}"
}
docker() {
    case "$*" in
        'compose version') ;;
        *' down --remove-orphans') printf 'down\n' >> "${CALL_LOG}"; INDEXER_STOPPED=true ;;
        *' ps -q semantic-indexer')
            [[ "${INDEXER_STOPPED:-false}" == true ]] || printf 'old-indexer\n'
            printf 'indexer-status\n' >> "${CALL_LOG}"
            ;;
        *' ps -q semantic-query') ;;
        *' build '*)
            [[ "${INDEXER_STOPPED:-false}" == true ]] || { printf 'build began while old Indexer remained running\n' >&2; return 1; }
            printf 'build\n' >> "${CALL_LOG}"
            ;;
        *) printf 'unexpected docker invocation: %s\n' "$*" >&2; return 1 ;;
    esac
}

deploy_impl normal
[[ "$(<"${CALL_LOG}")" == $'sources\nfixtures\ndown\nindexer-status\nbuild\nstart-indexer' ]] || {
    printf 'deployment did not prepare fixtures, stop/confirm old Indexer, then start one replacement\n' >&2
    exit 1
}
