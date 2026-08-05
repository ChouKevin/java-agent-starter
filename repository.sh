#!/usr/bin/env bash
# Operate the Semantic Service repository catalog after deploy.sh has started it.
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
ENV_FILE="${ROOT}/.env"

fail() {
    printf 'repository: %s\n' "$*" >&2
    exit 1
}

env_value() {
    local key="$1"
    local line

    line="$(grep -m1 -E "^${key}=" "${ENV_FILE}" 2>/dev/null || true)"
    printf '%s' "${line#*=}"
}

request() {
    local method="$1"
    local path="$2"
    local token
    local port

    [[ -s "${ENV_FILE}" ]] || fail "run ./deploy.sh first; ${ENV_FILE} is missing"
    token="$(env_value SEMANTIC_API_TOKEN)"
    port="$(env_value SEMANTIC_HOST_PORT)"
    [[ -n "${token}" ]] || fail "SEMANTIC_API_TOKEN is blank in ${ENV_FILE}"
    [[ -n "${port}" ]] || port=8080
    curl --fail --silent --show-error \
        --request "${method}" \
        --header "X-Api-Token: ${token}" \
        "http://127.0.0.1:${port}${path}" \
        || fail "Semantic Service is unavailable or rejected the request; run ./deploy.sh and inspect logs"
    printf '\n'
}

repo_id() {
    local value="${1:-}"

    [[ "${value}" =~ ^[a-z0-9][a-z0-9._-]{0,63}$ ]] \
        || fail "repoId must match ^[a-z0-9][a-z0-9._-]{0,63}$"
    printf '%s' "${value}"
}

case "${1:-}" in
    list)
        [[ "$#" -eq 1 ]] || fail "usage: ./repository.sh list"
        request GET /v1/repositories
        ;;
    ensure)
        [[ "$#" -eq 2 ]] || fail "usage: ./repository.sh ensure <repoId>"
        request POST "/v1/repositories/$(repo_id "$2")/ensure"
        ;;
    revision)
        [[ "$#" -eq 2 ]] || fail "usage: ./repository.sh revision <repoId>"
        request GET "/v1/repositories/$(repo_id "$2")"
        ;;
    *)
        fail "usage: ./repository.sh {list|ensure|revision} [repoId]"
        ;;
esac

