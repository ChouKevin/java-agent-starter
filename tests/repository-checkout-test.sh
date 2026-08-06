#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
TEMPORARY_DIRECTORY="$(mktemp -d)"

cleanup() {
    rm -rf "${TEMPORARY_DIRECTORY}"
}

trap cleanup EXIT

assert_equals() {
    local expected="$1"
    local actual="$2"
    local description="$3"

    [[ "${actual}" == "${expected}" ]] \
        || {
            printf 'expected %s, got %s: %s\n' "${expected}" "${actual}" "${description}" >&2
            exit 1
        }
}

curl() {
    CURL_ARGUMENTS=("$@")
    touch "${CURL_MARKER}"
}

assert_curl_arguments() {
    local description="$1"
    local index
    local -a expected

    shift
    expected=("$@")
    assert_equals "${#expected[@]}" "${#CURL_ARGUMENTS[@]}" "${description} curl argument count"
    for index in "${!expected[@]}"; do
        assert_equals "${expected[${index}]}" "${CURL_ARGUMENTS[${index}]}" "${description} curl argument ${index}"
    done
}

assert_checkout_fails_without_curl() {
    local description="$1"

    shift
    CURL_MARKER="${TEMPORARY_DIRECTORY}/curl-${description}"
    if (main checkout "$@" >/dev/null 2>&1); then
        printf 'expected checkout to fail: %s\n' "${description}" >&2
        exit 1
    fi
    [[ ! -e "${CURL_MARKER}" ]] || {
        printf 'invalid checkout invoked curl: %s\n' "${description}" >&2
        exit 1
    }
}

source "${ROOT}/repository.sh"

ENV_FILE="${TEMPORARY_DIRECTORY}/.env"
printf 'SEMANTIC_API_TOKEN=test-token\nSEMANTIC_HOST_PORT=18080\n' > "${ENV_FILE}"
REVISION_SHA=0123456789abcdef0123456789abcdef01234567
CURL_MARKER="${TEMPORARY_DIRECTORY}/curl-valid-checkout"

main checkout java-system-agent "${REVISION_SHA}"

assert_curl_arguments "checkout" \
    --fail \
    --silent \
    --show-error \
    --request \
    POST \
    --header \
    'X-Api-Token: test-token' \
    --header \
    'Content-Type: application/json' \
    --data \
    "{\"revision\":\"${REVISION_SHA}\"}" \
    'http://127.0.0.1:18080/v1/repositories/java-system-agent/checkout'

CURL_MARKER="${TEMPORARY_DIRECTORY}/curl-list"
main list
assert_curl_arguments "list" \
    --fail \
    --silent \
    --show-error \
    --request \
    GET \
    --header \
    'X-Api-Token: test-token' \
    'http://127.0.0.1:18080/v1/repositories'

CURL_MARKER="${TEMPORARY_DIRECTORY}/curl-sync"
main sync java-system-agent
assert_curl_arguments "sync" \
    --fail \
    --silent \
    --show-error \
    --request \
    POST \
    --header \
    'X-Api-Token: test-token' \
    --header \
    'Content-Type: application/json' \
    --data \
    '{}' \
    'http://127.0.0.1:18080/v1/repositories/java-system-agent/sync'

assert_checkout_fails_without_curl "invalid-repository" JAVA_SYSTEM_AGENT "${REVISION_SHA}"
assert_checkout_fails_without_curl "uppercase-revision" java-system-agent 0123456789ABCDEF0123456789ABCDEF01234567
assert_checkout_fails_without_curl "short-revision" java-system-agent 0123456789abcdef0123456789abcdef0123456
assert_checkout_fails_without_curl "nonhex-revision" java-system-agent g123456789abcdef0123456789abcdef01234567
assert_checkout_fails_without_curl "missing-revision" java-system-agent
assert_checkout_fails_without_curl "extra-argument" java-system-agent "${REVISION_SHA}" unexpected
