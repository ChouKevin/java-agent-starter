#!/usr/bin/env bash
# Query reads use the read token; all repository mutation jobs use the isolated Indexer-admin token.
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
ENV_FILE="${ROOT}/.env"
DEPLOY_LOCK_FILE="${ROOT}/.runtime/deploy.lock"

fail() { printf 'repository: %s\n' "$*" >&2; exit 1; }
env_value() { local line; line="$(grep -m1 -E "^$1=" "${ENV_FILE}" 2>/dev/null || true)"; printf '%s' "${line#*=}"; }
repo_id() { [[ "${1:-}" =~ ^[a-z0-9][a-z0-9._-]{0,63}$ ]] || fail 'repoId must match ^[a-z0-9][a-z0-9._-]{0,63}$'; printf '%s' "$1"; }
revision_sha() { [[ "${1:-}" =~ ^[0-9a-f]{40}$ ]] || fail 'revisionSha must match ^[0-9a-f]{40}$'; printf '%s' "$1"; }

lock_fd_matches_deployment() {
    local descriptor="${1:-}" expected target
    [[ "${descriptor}" =~ ^[0-9]+$ && -e "/proc/$$/fd/${descriptor}" ]] || return 1
    expected="$(readlink -f "${DEPLOY_LOCK_FILE}")" || return 1
    target="$(readlink -f "/proc/$$/fd/${descriptor}")" || return 1
    [[ "${target}" == "${expected}" ]]
}

acquire_indexer_admin_lock() {
    command -v flock >/dev/null 2>&1 || fail 'flock is required for Indexer administration'
    mkdir -p "$(dirname -- "${DEPLOY_LOCK_FILE}")"
    if lock_fd_matches_deployment "${STARTER_DEPLOY_LOCK_FD:-}"; then
        flock -n "${STARTER_DEPLOY_LOCK_FD}" || fail "inherited deployment lock is not held: ${DEPLOY_LOCK_FILE}"
        return
    fi
    if lock_fd_matches_deployment "${REPOSITORY_ADMIN_LOCK_FD:-}"; then
        return
    fi
    exec {REPOSITORY_ADMIN_LOCK_FD}>"${DEPLOY_LOCK_FILE}"
    flock -n "${REPOSITORY_ADMIN_LOCK_FD}" || fail "another deployment or repository mutation holds ${DEPLOY_LOCK_FILE}"
}

request() {
    local token="$1" port="$2" method="$3" path="$4" body="${5:-}"
    local -a curl_args=(--fail --silent --show-error --request "${method}" --header "X-Api-Token: ${token}")
    [[ -n "${body}" ]] && curl_args+=(--header 'Content-Type: application/json' --data "${body}")
    curl "${curl_args[@]}" "http://127.0.0.1:${port}${path}" || fail 'service is unavailable or rejected the request; run ./deploy.sh and inspect logs'
    printf '\n'
}

query_request() {
    local token port
    token="$(env_value SEMANTIC_QUERY_API_TOKEN)"; port="$(env_value SEMANTIC_HOST_PORT)"
    [[ -n "${token}" ]] || fail 'SEMANTIC_QUERY_API_TOKEN is blank in .env'
    request "${token}" "${port:-8080}" "$@"
}

indexer_request() {
    local token port
    token="$(env_value SEMANTIC_INDEXER_ADMIN_TOKEN)"; port="$(env_value SEMANTIC_INDEXER_HOST_PORT)"
    [[ -n "${token}" ]] || fail 'SEMANTIC_INDEXER_ADMIN_TOKEN is blank in .env'
    request "${token}" "${port:-8081}" "$@"
}

main() {
    local body publication
    [[ -s "${ENV_FILE}" ]] || fail "run ./deploy.sh first; ${ENV_FILE} is missing"
    case "${1:-}" in
        list) [[ "$#" -eq 1 ]] || fail 'usage: ./repository.sh list'; query_request GET /v1/repositories ;;
        revision) [[ "$#" -eq 2 ]] || fail 'usage: ./repository.sh revision <repoId>'; repo_id "$2" >/dev/null; query_request GET "/v1/repositories/$2" ;;
        ensure) [[ "$#" -eq 2 ]] || fail 'usage: ./repository.sh ensure <repoId>'; acquire_indexer_admin_lock; repo_id "$2" >/dev/null; indexer_request POST "/index/repositories/$2/ensure" ;;
        sync) [[ "$#" -eq 2 || "$#" -eq 3 ]] || fail 'usage: ./repository.sh sync <repoId> [branch]'; acquire_indexer_admin_lock; repo_id "$2" >/dev/null; body="$(jq -cn --arg branch "${3:-}" '{branch:$branch}')" || fail 'could not encode branch'; indexer_request POST "/index/repositories/$2/sync" "${body}" ;;
        checkout) [[ "$#" -eq 3 ]] || fail 'usage: ./repository.sh checkout <repoId> <revisionSha>'; acquire_indexer_admin_lock; repo_id "$2" >/dev/null; revision_sha "$3" >/dev/null; body="$(jq -cn --arg revision "$3" '{revision:$revision}')" || fail 'could not encode revision'; indexer_request POST "/index/repositories/$2/checkout" "${body}" ;;
        rebuild) [[ "$#" -eq 2 ]] || fail 'usage: ./repository.sh rebuild <repoId>'; acquire_indexer_admin_lock; repo_id "$2" >/dev/null; publication="$(indexer_request GET "/index/repositories/$2/publication")"; body="$(jq -ce '{authorizeIncompatibleSchema:true, expectedCurrent:(.currentPointer // error("missing current pointer"))}' <<< "${publication}")" || fail 'Indexer returned no current publication pointer'; indexer_request POST "/index/repositories/$2/rebuild" "${body}" ;;
        rollback) [[ "$#" -eq 3 ]] || fail 'usage: ./repository.sh rollback <repoId> <rollback-json>'; acquire_indexer_admin_lock; repo_id "$2" >/dev/null; body="$(jq -ce 'if type == "object" then . else error("rollback JSON must be an object") end' <<< "$3")" || fail 'rollback-json must be a valid JSON object'; indexer_request POST "/index/repositories/$2/rollback" "${body}" ;;
        *) fail 'usage: ./repository.sh {list|revision|ensure|sync|checkout|rebuild|rollback}' ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
