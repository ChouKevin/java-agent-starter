#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
TEMPORARY_DIRECTORY="$(mktemp -d)"
trap 'rm -rf "${TEMPORARY_DIRECTORY}"' EXIT
printf 'SEMANTIC_QUERY_API_TOKEN=read-token\nSEMANTIC_HOST_PORT=18080\nSEMANTIC_INDEXER_ADMIN_TOKEN=index-token\nSEMANTIC_INDEXER_HOST_PORT=18081\n' > "${TEMPORARY_DIRECTORY}/.env"
source "${ROOT}/repository.sh"
ENV_FILE="${TEMPORARY_DIRECTORY}/.env"
curl() { CURL_ARGUMENTS=("$@"); }

main list
[[ "${CURL_ARGUMENTS[*]}" == *'X-Api-Token: read-token'* && "${CURL_ARGUMENTS[*]}" == *'127.0.0.1:18080/v1/repositories'* ]]
main checkout payment-service 0123456789abcdef0123456789abcdef01234567
[[ "${CURL_ARGUMENTS[*]}" == *'X-Api-Token: index-token'* && "${CURL_ARGUMENTS[*]}" == *'127.0.0.1:18081/index/repositories/payment-service/checkout'* ]]
main rebuild payment-service
[[ "${CURL_ARGUMENTS[*]}" == *'authorizeIncompatibleSchema'* ]]

CURL_ARGUMENTS=()
if (main checkout PAYMENT_SERVICE 0123456789abcdef0123456789abcdef01234567); then
    printf 'invalid repository id unexpectedly reached Indexer\n' >&2
    exit 1
fi
[[ "${#CURL_ARGUMENTS[@]}" -eq 0 ]]
CURL_ARGUMENTS=()
if (main checkout payment-service 0123456789ABCDEF0123456789ABCDEF01234567); then
    printf 'invalid revision unexpectedly reached Indexer\n' >&2
    exit 1
fi
[[ "${#CURL_ARGUMENTS[@]}" -eq 0 ]]
