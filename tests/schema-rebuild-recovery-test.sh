#!/usr/bin/env bash
set -euo pipefail

STARTER_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
TEMPORARY_DIRECTORY="$(mktemp -d)"
trap 'rm -rf "${TEMPORARY_DIRECTORY}"' EXIT

source "${STARTER_ROOT}/deploy.sh"
SCHEMA_REBUILD_POINTERS="${TEMPORARY_DIRECTORY}/pointers"
CALL_LOG="${TEMPORARY_DIRECTORY}/calls.log"

previous='{"revision":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","generationId":"g-old","manifestDigest":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","committedJobId":"job-old","publishedAt":"2026-08-22T00:00:00Z"}'
rebuilt='{"revision":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","generationId":"g-new","manifestDigest":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","committedJobId":"job-new","publishedAt":"2026-08-22T00:01:00Z"}'
publication="$(jq -cn --argjson current "${previous}" --argjson rollback "${rebuilt}" '{currentPointer:$current,rollbackPointer:$rollback}')"

configured_repositories() { printf 'orders\n'; }
env_value() { printf 'admin-token'; }
env_or_default() { printf '%s' "$2"; }
poll_index_job() { printf '{"active":false,"phase":"COMPLETE"}'; }

CURL_PUBLICATION="$(jq -cn --argjson current "${previous}" '{currentPointer:$current,rollbackPointer:null}')"
curl() {
    local argument request=''
    printf '%s\n' "$*" >> "${CALL_LOG}"
    while (( "$#" > 0 )); do
        argument="$1"
        shift
        if [[ "${argument}" == --data ]]; then
            request="$1"
            shift
        fi
    done
    if [[ -n "${request}" ]]; then
        printf '%s\n' "${request}" >> "${TEMPORARY_DIRECTORY}/requests.log"
        printf '{"jobId":"job-request"}'
    else
        printf '%s' "${CURL_PUBLICATION}"
    fi
}

record_current_pointers
jq -e --argjson previous "${previous}" '. == $previous' "${SCHEMA_REBUILD_POINTERS}/orders.previous.json" >/dev/null
grep -Fq 'X-Api-Token: admin-token' "${CALL_LOG}"
grep -Fq '127.0.0.1:8081/index/repositories/orders/publication' "${CALL_LOG}"

CURL_PUBLICATION="$(jq -cn --argjson current "${rebuilt}" --argjson rollback "${previous}" '{currentPointer:$current,rollbackPointer:$rollback}')"
rebuild_all_repositories
jq -e --argjson rebuilt "${rebuilt}" '. == $rebuilt' "${SCHEMA_REBUILD_POINTERS}/orders.rebuilt.json" >/dev/null
jq -s -e --argjson previous "${previous}" '.[0].authorizeIncompatibleSchema and .[0].expectedCurrent == $previous' \
    "${TEMPORARY_DIRECTORY}/requests.log" >/dev/null

CURL_PUBLICATION="${publication}"
rollback_rebuilt_repositories
[[ "$(wc -l < "${TEMPORARY_DIRECTORY}/requests.log")" -eq 2 ]]

CURL_PUBLICATION="$(jq -cn --argjson current "${rebuilt}" '{currentPointer:$current,rollbackPointer:null}')"
if rollback_rebuilt_repositories; then
    printf 'rollback accepted a publication that did not restore the recorded pointer\n' >&2
    exit 1
fi
