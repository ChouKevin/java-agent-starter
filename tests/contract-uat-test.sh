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

    [[ "${actual}" == "${expected}" ]] || {
        printf 'expected %s, got %s: %s\n' "${expected}" "${actual}" "${description}" >&2
        exit 1
    }
}

assert_fails() {
    local description="$1"

    shift
    if ("$@" >/dev/null 2>&1); then
        printf 'expected failure: %s\n' "${description}" >&2
        exit 1
    fi
}

source "${ROOT}/contract-uat.sh"

AGENT_TEST_SHA=1111111111111111111111111111111111111111
SEMANTIC_TEST_SHA=2222222222222222222222222222222222222222
RECORD_FILE="${TEMPORARY_DIRECTORY}/deployment-record.txt"
printf 'Agent source SHA: %s\nSemantic source SHA: %s\n' \
    "${AGENT_TEST_SHA}" "${SEMANTIC_TEST_SHA}" > "${RECORD_FILE}"

assert_equals "${AGENT_TEST_SHA}" \
    "$(deployment_sha 'Agent source SHA' "${RECORD_FILE}")" \
    "Agent deployment SHA"
assert_equals "${SEMANTIC_TEST_SHA}" \
    "$(deployment_sha 'Semantic source SHA' "${RECORD_FILE}")" \
    "Semantic deployment SHA"

printf 'Agent source SHA: short\n' > "${RECORD_FILE}"
assert_fails "malformed deployment SHA" deployment_sha 'Agent source SHA' "${RECORD_FILE}"
printf 'Agent source SHA: %s\nAgent source SHA: %s\n' \
    "${AGENT_TEST_SHA}" "${AGENT_TEST_SHA}" > "${RECORD_FILE}"
assert_fails "duplicate deployment SHA" deployment_sha 'Agent source SHA' "${RECORD_FILE}"
assert_fails "missing deployment record" deployment_sha 'Agent source SHA' \
    "${TEMPORARY_DIRECTORY}/missing-record.txt"

assert_equals "${AGENT_TEST_SHA}" \
    "$(repository_revision "{\"repoId\":\"java-system-agent\",\"currentRevision\":\"${AGENT_TEST_SHA}\"}")" \
    "repository current revision"
assert_fails "null repository revision" repository_revision \
    '{"repoId":"java-system-agent","currentRevision":null}'
assert_fails "malformed repository JSON" repository_revision '{'
assert_fails "duplicate repository revision" repository_revision \
    "{\"currentRevision\":\"${AGENT_TEST_SHA}\",\"nested\":{\"currentRevision\":\"${AGENT_TEST_SHA}\"}}"

RUN_ID=m5-test-run
RUN_DIRECTORY="${TEMPORARY_DIRECTORY}/report"
AGENT_SHA="${AGENT_TEST_SHA}"
SEMANTIC_SHA="${SEMANTIC_TEST_SHA}"
FIXTURE_SHA="${AGENT_TEST_SHA}"
mkdir -p "${RUN_DIRECTORY}"

write_manifest
grep -Fq "runId=${RUN_ID}" "${RUN_DIRECTORY}/manifest.txt"
grep -Fq "agentSourceSha=${AGENT_SHA}" "${RUN_DIRECTORY}/manifest.txt"
grep -Fq "semanticSourceSha=${SEMANTIC_SHA}" "${RUN_DIRECTORY}/manifest.txt"
grep -Fq 'repositoryId=java-system-agent' "${RUN_DIRECTORY}/manifest.txt"
grep -Fq "fixtureSha=${FIXTURE_SHA}" "${RUN_DIRECTORY}/manifest.txt"

write_summary_junit PASS PASS
grep -Fq '<testsuite name="contract-uat" tests="3" failures="0" skipped="0">' \
    "${RUN_DIRECTORY}/summary.xml"
[[ "$(grep -c '<testcase ' "${RUN_DIRECTORY}/summary.xml")" -eq 3 ]]
! grep -q '<failure\|<skipped' "${RUN_DIRECTORY}/summary.xml"

write_summary_junit FAIL SKIPPED
grep -Fq '<testsuite name="contract-uat" tests="3" failures="1" skipped="1">' \
    "${RUN_DIRECTORY}/summary.xml"
grep -Fq '<failure message="semantic-mcp contract failed"/>' "${RUN_DIRECTORY}/summary.xml"
grep -Fq '<skipped message="not run because semantic-mcp failed"/>' "${RUN_DIRECTORY}/summary.xml"

write_summary_junit PASS FAIL
grep -Fq '<testsuite name="contract-uat" tests="3" failures="1" skipped="0">' \
    "${RUN_DIRECTORY}/summary.xml"
grep -Fq '<failure message="agent-http contract failed"/>' "${RUN_DIRECTORY}/summary.xml"

PIN_FIXTURE_ROOT="${TEMPORARY_DIRECTORY}/pin-fixture"
PIN_FIXTURE_INVOCATIONS="${TEMPORARY_DIRECTORY}/pin-fixture-invocations"
mkdir -p "${PIN_FIXTURE_ROOT}"
printf '%s\n' \
    '#!/usr/bin/env bash' \
    'printf "%s\n" "$*" >> "${PIN_FIXTURE_INVOCATIONS}"' \
    'if [[ "$1" == "revision" ]]; then' \
    '    printf "{\"repoId\":\"java-system-agent\",\"currentRevision\":\"%s\"}\n" "${PIN_FIXTURE_SHA}"' \
    'fi' > "${PIN_FIXTURE_ROOT}/repository.sh"
chmod +x "${PIN_FIXTURE_ROOT}/repository.sh"
export PIN_FIXTURE_INVOCATIONS PIN_FIXTURE_SHA="${AGENT_TEST_SHA}"
ORIGINAL_ROOT="${ROOT}"
ROOT="${PIN_FIXTURE_ROOT}"
AGENT_SHA="${AGENT_TEST_SHA}"
pin_fixture
ROOT="${ORIGINAL_ROOT}"
assert_equals $'ensure java-system-agent\nsync java-system-agent\ncheckout java-system-agent 1111111111111111111111111111111111111111\nrevision java-system-agent' \
    "$(cat "${PIN_FIXTURE_INVOCATIONS}")" \
    "fixture must fetch before exact checkout"
assert_equals "${AGENT_TEST_SHA}" "${FIXTURE_SHA}" "pinned fixture SHA"

INVOCATIONS="${TEMPORARY_DIRECTORY}/invocations"

create_run_directory() {
    RUN_ID=orchestration-test
    RUN_DIRECTORY="${TEMPORARY_DIRECTORY}/orchestration-report"
    mkdir -p "${RUN_DIRECTORY}"
}

read_deployed_revisions() {
    printf 'read-revisions\n' >> "${INVOCATIONS}"
    AGENT_SHA="${AGENT_TEST_SHA}"
    SEMANTIC_SHA="${SEMANTIC_TEST_SHA}"
}

pin_fixture() {
    printf 'pin-fixture\n' >> "${INVOCATIONS}"
    FIXTURE_SHA="${AGENT_SHA}"
}

write_manifest() {
    printf 'write-manifest\n' >> "${INVOCATIONS}"
}

deploy_stack() {
    printf 'deploy-failed\n' >> "${INVOCATIONS}"
    return 1
}

run_contract_phase() {
    printf 'phase-%s\n' "$1" >> "${INVOCATIONS}"
}

assert_fails "deploy failure stops the gate" main
assert_equals 'deploy-failed' "$(cat "${INVOCATIONS}")" \
    "deploy failure must stop before revision, fixture, and runners"

: > "${INVOCATIONS}"
deploy_stack() {
    printf 'deploy\n' >> "${INVOCATIONS}"
}
run_contract_phase() {
    local phase="$1"

    printf 'phase-%s\n' "${phase}" >> "${INVOCATIONS}"
    [[ "${phase}" != "semantic-mcp" ]]
}

assert_fails "Semantic failure stops Agent" main
assert_equals $'deploy\nread-revisions\npin-fixture\nwrite-manifest\nphase-semantic-mcp' \
    "$(cat "${INVOCATIONS}")" \
    "Agent phase must be skipped after Semantic failure"

printf 'contract UAT tests passed\n'
