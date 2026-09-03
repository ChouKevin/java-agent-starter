#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
TEMPORARY_DIRECTORY="$(mktemp -d)"
trap 'rm -rf "${TEMPORARY_DIRECTORY}"' EXIT
printf 'SEMANTIC_QUERY_API_TOKEN=read-token\nSEMANTIC_HOST_PORT=18080\nSEMANTIC_INDEXER_ADMIN_TOKEN=index-token\nSEMANTIC_INDEXER_HOST_PORT=18081\n' > "${TEMPORARY_DIRECTORY}/.env"
source "${ROOT}/repository.sh"
ENV_FILE="${TEMPORARY_DIRECTORY}/.env"
CALL_LOG="${TEMPORARY_DIRECTORY}/calls.log"
DEPLOY_LOCK_FILE="${TEMPORARY_DIRECTORY}/deploy.lock"
pointer='{"revision":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","generationId":"g-current","manifestDigest":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","committedJobId":"job-current","publishedAt":"2026-08-22T00:00:00Z"}'
curl() {
    CURL_ARGUMENTS=("$@")
    printf '%s\n' "$*" >> "${CALL_LOG}"
    if [[ "$*" == *'/publication'* ]]; then
        jq -cn --argjson current "${pointer}" '{currentPointer:$current,rollbackPointer:null}'
    else
        printf '{"jobId":"accepted"}'
    fi
}

repository_main list
[[ "${CURL_ARGUMENTS[*]}" == *'X-Api-Token: read-token'* && "${CURL_ARGUMENTS[*]}" == *'127.0.0.1:18080/api/v1/repositories'* ]]
[[ "${CURL_ARGUMENTS[*]}" == *'--request GET'* ]]

repository_main revision payment-service
[[ "${CURL_ARGUMENTS[*]}" == *'X-Api-Token: read-token'* && "${CURL_ARGUMENTS[*]}" == *'127.0.0.1:18080/api/v1/repositories/payment-service'* ]]
[[ "${CURL_ARGUMENTS[*]}" == *'--request GET'* ]]

mkfifo "${TEMPORARY_DIRECTORY}/lock-release"
(
    exec 9>"${DEPLOY_LOCK_FILE}"
    flock -n 9
    touch "${TEMPORARY_DIRECTORY}/lock-ready"
    read -r _ < "${TEMPORARY_DIRECTORY}/lock-release"
) &
LOCK_HOLDER_PID=$!
while [[ ! -e "${TEMPORARY_DIRECTORY}/lock-ready" ]]; do sleep 0.01; done
if (repository_main checkout payment-service 0123456789abcdef0123456789abcdef01234567); then
    printf 'repository mutation bypassed the deployment lock\n' >&2
    printf '\n' > "${TEMPORARY_DIRECTORY}/lock-release"
    exit 1
fi
printf '\n' > "${TEMPORARY_DIRECTORY}/lock-release"
wait "${LOCK_HOLDER_PID}"

repository_checkout_impl payment-service 0123456789abcdef0123456789abcdef01234567
[[ "${CURL_ARGUMENTS[*]}" == *'X-Api-Token: index-token'* && "${CURL_ARGUMENTS[*]}" == *'127.0.0.1:18081/index/repositories/payment-service/checkout'* ]]
repository_main rebuild payment-service
grep -Fq '127.0.0.1:18081/index/repositories/payment-service/publication' "${CALL_LOG}"
rebuild_call="$(tail -n1 "${CALL_LOG}")"
[[ "${rebuild_call}" == *'authorizeIncompatibleSchema'* && "${rebuild_call}" == *'expectedCurrent'* && "${rebuild_call}" == *'job-current'* ]]

repository_main sync payment-service 'feature/quote"safe'
sync_call="$(tail -n1 "${CALL_LOG}")"
sync_body="$(sed -n 's/.*--data \({.*}\) http:.*/\1/p' <<< "${sync_call}")"
jq -e '.branch == "feature/quote\"safe"' <<< "${sync_body}" >/dev/null

CURL_ARGUMENTS=()
if (repository_main checkout PAYMENT_SERVICE 0123456789abcdef0123456789abcdef01234567); then
    printf 'invalid repository id unexpectedly reached Indexer\n' >&2
    exit 1
fi
[[ "${#CURL_ARGUMENTS[@]}" -eq 0 ]]

call_count="$(wc -l < "${CALL_LOG}")"
if (repository_main rollback payment-service 'not-json'); then
    printf 'invalid rollback JSON unexpectedly reached Indexer\n' >&2
    exit 1
fi
[[ "$(wc -l < "${CALL_LOG}")" -eq "${call_count}" ]]
CURL_ARGUMENTS=()
if (repository_main checkout payment-service 0123456789ABCDEF0123456789ABCDEF01234567); then
    printf 'invalid revision unexpectedly reached Indexer\n' >&2
    exit 1
fi
[[ "${#CURL_ARGUMENTS[@]}" -eq 0 ]]
