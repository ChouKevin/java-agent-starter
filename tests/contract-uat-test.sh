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

RUN_ID=m6-test-run
RUN_DIRECTORY="${TEMPORARY_DIRECTORY}/report"
AGENT_SHA="${AGENT_TEST_SHA}"
SEMANTIC_SHA="${SEMANTIC_TEST_SHA}"
AGENT_FIXTURE_SHA="${AGENT_TEST_SHA}"
DISCOVERY_FIXTURE_REVISION=FIXTURE
mkdir -p "${RUN_DIRECTORY}"

unset KNOWLEDGE_REPORT_DIRECTORY
prepare_contract_environment
assert_equals "${RUN_DIRECTORY}" "${KNOWLEDGE_REPORT_DIRECTORY}" \
    "contract compose interpolation must always receive a report directory"

write_manifest
grep -Fq "runId=${RUN_ID}" "${RUN_DIRECTORY}/manifest.txt"
grep -Fq "agentSourceSha=${AGENT_SHA}" "${RUN_DIRECTORY}/manifest.txt"
grep -Fq "semanticSourceSha=${SEMANTIC_SHA}" "${RUN_DIRECTORY}/manifest.txt"
grep -Fq "agentFixtureSha=${AGENT_FIXTURE_SHA}" "${RUN_DIRECTORY}/manifest.txt"
grep -Fq 'discoveryFixtureId=m6-semantic-contract' "${RUN_DIRECTORY}/manifest.txt"
grep -Fq 'discoveryFixtureRevision=FIXTURE' "${RUN_DIRECTORY}/manifest.txt"

write_summary_junit PASS PASS
grep -Fq '<testsuite name="contract-uat" tests="3" failures="0" skipped="0">' \
    "${RUN_DIRECTORY}/summary.xml"
[[ "$(grep -c '<testcase ' "${RUN_DIRECTORY}/summary.xml")" -eq 3 ]]
! grep -q '<failure\|<skipped' "${RUN_DIRECTORY}/summary.xml"
grep -Fq "<property name=\"agentFixtureSha\" value=\"${AGENT_FIXTURE_SHA}\"/>" \
    "${RUN_DIRECTORY}/summary.xml"
grep -Fq '<property name="discoveryFixtureId" value="m6-semantic-contract"/>' \
    "${RUN_DIRECTORY}/summary.xml"
grep -Fq '<property name="discoveryFixtureRevision" value="FIXTURE"/>' \
    "${RUN_DIRECTORY}/summary.xml"

write_summary_junit FAIL SKIPPED
grep -Fq '<testsuite name="contract-uat" tests="3" failures="1" skipped="1">' \
    "${RUN_DIRECTORY}/summary.xml"
grep -Fq '<failure message="semantic-mcp contract failed"/>' "${RUN_DIRECTORY}/summary.xml"
grep -Fq '<skipped message="not run because semantic-mcp failed"/>' "${RUN_DIRECTORY}/summary.xml"

write_summary_junit PASS FAIL
grep -Fq '<testsuite name="contract-uat" tests="3" failures="1" skipped="0">' \
    "${RUN_DIRECTORY}/summary.xml"
grep -Fq '<failure message="agent-http contract failed"/>' "${RUN_DIRECTORY}/summary.xml"

FIXTURE_ROOT="${TEMPORARY_DIRECTORY}/fixtures"
AGENT_FIXTURE_INVOCATIONS="${TEMPORARY_DIRECTORY}/agent-fixture-invocations"
DISCOVERY_FIXTURE_INVOCATIONS="${TEMPORARY_DIRECTORY}/discovery-fixture-invocations"
mkdir -p "${FIXTURE_ROOT}"
printf '%s\n' \
    '#!/usr/bin/env bash' \
    'case "$2" in' \
    '    java-system-agent) printf "%s\n" "$*" >> "${AGENT_FIXTURE_INVOCATIONS}" ;;' \
    '    m6-semantic-contract) printf "%s\n" "$*" >> "${DISCOVERY_FIXTURE_INVOCATIONS}" ;;' \
    'esac' \
    'if [[ "$1" == "revision" ]]; then' \
    '    if [[ "$2" == "java-system-agent" ]]; then' \
    '        printf "{\"repoId\":\"java-system-agent\",\"currentRevision\":\"%s\"}\n" "${AGENT_FIXTURE_TEST_SHA}"' \
    '    else' \
    '        printf "{\"repoId\":\"m6-semantic-contract\",\"currentRevision\":\"FIXTURE\"}\n"' \
    '    fi' \
    'fi' > "${FIXTURE_ROOT}/repository.sh"
chmod +x "${FIXTURE_ROOT}/repository.sh"
export AGENT_FIXTURE_INVOCATIONS DISCOVERY_FIXTURE_INVOCATIONS
export AGENT_FIXTURE_TEST_SHA="${AGENT_TEST_SHA}"
ORIGINAL_ROOT="${ROOT}"
ROOT="${FIXTURE_ROOT}"
AGENT_SHA="${AGENT_TEST_SHA}"
AGENT_FIXTURE_SHA=""
DISCOVERY_FIXTURE_REVISION=""
pin_agent_fixture
ensure_discovery_fixture
ROOT="${ORIGINAL_ROOT}"
assert_equals $'ensure java-system-agent\nsync java-system-agent\ncheckout java-system-agent 1111111111111111111111111111111111111111\nrevision java-system-agent' \
    "$(cat "${AGENT_FIXTURE_INVOCATIONS}")" \
    "agent fixture must fetch before exact checkout"
assert_equals $'ensure m6-semantic-contract\nrevision m6-semantic-contract' \
    "$(cat "${DISCOVERY_FIXTURE_INVOCATIONS}")" \
    "discovery fixture must not sync or checkout"
assert_equals "${AGENT_TEST_SHA}" "${AGENT_FIXTURE_SHA}" "pinned Agent fixture SHA"
assert_equals FIXTURE "${DISCOVERY_FIXTURE_REVISION}" "discovery fixture revision"

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

pin_agent_fixture() {
    printf 'pin-agent-fixture\n' >> "${INVOCATIONS}"
    AGENT_FIXTURE_SHA="${AGENT_SHA}"
}

ensure_discovery_fixture() {
    printf 'ensure-discovery-fixture\n' >> "${INVOCATIONS}"
    DISCOVERY_FIXTURE_REVISION=FIXTURE
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
    "deploy failure must stop before revision, both fixtures, and runners"

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
assert_equals $'deploy\nread-revisions\npin-agent-fixture\nensure-discovery-fixture\nwrite-manifest\nphase-semantic-mcp' \
    "$(cat "${INVOCATIONS}")" \
    "Agent phase must be skipped after Semantic failure"

: > "${INVOCATIONS}"
run_contract_phase() {
    printf 'phase-%s\n' "$1" >> "${INVOCATIONS}"
}

SUCCESS_OUTPUT="$(main)"
assert_equals \
    "contract-uat: PASS agent=${AGENT_TEST_SHA} semantic=${SEMANTIC_TEST_SHA} fixture=${AGENT_TEST_SHA} discoveryFixture=FIXTURE report=${TEMPORARY_DIRECTORY}/orchestration-report" \
    "${SUCCESS_OUTPUT}" \
    "terminal acceptance line must retain the pinned fixture SHA"
assert_equals $'deploy\nread-revisions\npin-agent-fixture\nensure-discovery-fixture\nwrite-manifest\nphase-semantic-mcp\nphase-agent-http' \
    "$(cat "${INVOCATIONS}")" \
    "contract gate must use the M6 fixture and phase order"

printf 'contract UAT tests passed\n'
