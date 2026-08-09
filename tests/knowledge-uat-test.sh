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

bash -n "${ROOT}/knowledge-uat.sh"
bash -c 'source "$1"; declare -F main preflight read_live_configuration create_run_directory read_deployed_revisions active_deployment_state fixture_revision ensure_knowledge_fixture_and_database run_live_scenario validate_junit write_manifest >/dev/null' \
    bash "${ROOT}/knowledge-uat.sh"
grep -Fq 'if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then' "${ROOT}/knowledge-uat.sh"
grep -Fq 'gemini-3.1-flash-lite' "${ROOT}/knowledge-uat.sh"
grep -Fq 'reports/knowledge-uat/${RUN_ID}' "${ROOT}/knowledge-uat.sh"
grep -Fq '"${ROOT}/deploy.sh"' "${ROOT}/knowledge-uat.sh"
grep -Fq 'repository.sh" ensure m7-knowledge-query' "${ROOT}/knowledge-uat.sh"
! rg -q 'SLACK_' "${ROOT}/knowledge-uat.sh"
! rg -q '^[[:space:]]*(while|for)[[:space:]]' "${ROOT}/knowledge-uat.sh"
[[ "$(grep -Fc 'run --rm --no-deps agent-knowledge' "${ROOT}/knowledge-uat.sh")" -eq 1 ]]

source "${ROOT}/knowledge-uat.sh"

TEST_AGENT_SHA=1111111111111111111111111111111111111111
TEST_SEMANTIC_SHA=2222222222222222222222222222222222222222
TEST_STARTER_SHA=3333333333333333333333333333333333333333
TEST_ROOT="${TEMPORARY_DIRECTORY}/starter"
mkdir -p "${TEST_ROOT}"
printf 'GOOGLE_API_KEY=\n' > "${TEST_ROOT}/.env"

ORIGINAL_ROOT="${ROOT}"
ROOT="${TEST_ROOT}"
ENV_FILE="${TEST_ROOT}/.env"
unset GOOGLE_API_KEY GOOGLE_GENAI_MODEL
preflight
assert_fails "blank API key fails before Docker or deployment" read_live_configuration
printf 'GOOGLE_API_KEY=   \n' > "${TEST_ROOT}/.env"
assert_fails "whitespace-only API key fails before Docker or deployment" read_live_configuration
printf 'GOOGLE_API_KEY=poc-not-used\n' > "${TEST_ROOT}/.env"
assert_fails "placeholder API key fails before Docker or deployment" read_live_configuration
printf 'GOOGLE_API_KEY=example-key\n' > "${TEST_ROOT}/.env"
assert_fails "common placeholder API key fails before Docker or deployment" read_live_configuration
printf 'GOOGLE_API_KEY=  example-key  \n' > "${TEST_ROOT}/.env"
assert_fails "padded placeholder API key fails before Docker or deployment" read_live_configuration
printf 'GOOGLE_API_KEY=live-key\nGOOGLE_GENAI_MODEL=custom-model\n' > "${TEST_ROOT}/.env"
read_live_configuration
assert_equals custom-model "${GOOGLE_MODEL}" "configured live model"
export GOOGLE_API_KEY=process-live-key
export GOOGLE_GENAI_MODEL=process-model
read_live_configuration
assert_equals process-model "${GOOGLE_MODEL}" "process environment overrides .env model"
unset GOOGLE_API_KEY GOOGLE_GENAI_MODEL
printf 'GOOGLE_API_KEY=live-key\n' > "${TEST_ROOT}/.env"
read_live_configuration
assert_equals gemini-3.1-flash-lite "${GOOGLE_MODEL}" "default live model"
CONFIG_DEPLOY_INVOCATIONS="${TEMPORARY_DIRECTORY}/configuration-deploy-invocations"
deploy_stack() {
    printf 'deploy\n' >> "${CONFIG_DEPLOY_INVOCATIONS}"
}
unset GOOGLE_API_KEY GOOGLE_GENAI_MODEL
printf 'GOOGLE_API_KEY=example-key\n' > "${TEST_ROOT}/.env"
assert_fails "placeholder API key stops main before deployment" main
[[ ! -e "${CONFIG_DEPLOY_INVOCATIONS}" ]] || {
    printf 'placeholder API key reached deployment\n' >&2
    exit 1
}
printf 'GOOGLE_API_KEY=live-key\n' > "${TEST_ROOT}/.env"
source "${ORIGINAL_ROOT}/knowledge-uat.sh"
ROOT="${TEST_ROOT}"
ENV_FILE="${TEST_ROOT}/.env"
assert_equals FIXTURE "$(fixture_revision '{"currentRevision":"FIXTURE"}')" "exact fixture revision"
assert_fails "duplicate fixture revisions are rejected" fixture_revision \
    '{"currentRevision":"FIXTURE","nested":{"currentRevision":"FIXTURE"}}'

RUN_ID=knowledge-test-run
RUN_DIRECTORY="${TEST_ROOT}/report"
mkdir -p "${RUN_DIRECTORY}"
STARTER_SHA="${TEST_STARTER_SHA}"
AGENT_SHA="${TEST_AGENT_SHA}"
SEMANTIC_SHA="${TEST_SEMANTIC_SHA}"
GOOGLE_MODEL=gemini-3.1-flash-lite
FIXTURE_REVISION=FIXTURE
write_manifest
grep -Fq "runId=${RUN_ID}" "${RUN_DIRECTORY}/manifest.txt"
grep -Fq "starterSourceSha=${STARTER_SHA}" "${RUN_DIRECTORY}/manifest.txt"
grep -Fq "agentSourceSha=${AGENT_SHA}" "${RUN_DIRECTORY}/manifest.txt"
grep -Fq "semanticSourceSha=${SEMANTIC_SHA}" "${RUN_DIRECTORY}/manifest.txt"
grep -Fq 'fixtureId=m7-knowledge-query' "${RUN_DIRECTORY}/manifest.txt"
grep -Fq 'fixtureRevision=FIXTURE' "${RUN_DIRECTORY}/manifest.txt"
grep -Fq "model=${GOOGLE_MODEL}" "${RUN_DIRECTORY}/manifest.txt"
! rg -q 'budgetHandleCount' "${RUN_DIRECTORY}/manifest.txt"
! rg -qi 'key|token|prompt|evidence|reason|environment' "${RUN_DIRECTORY}/manifest.txt"

JUNIT_FILE="${RUN_DIRECTORY}/TEST-com.java.system.agent.M7KnowledgeQueryLiveIT.xml"
printf '<testsuite tests="1" failures="0" errors="0" skipped="0"/>\n' > "${JUNIT_FILE}"
validate_junit
printf '<testsuite tests="1" failures="0" errors="0" skipped="1"/>\n' > "${JUNIT_FILE}"
assert_fails "skipped JUnit test fails the run" validate_junit
printf '<testsuite tests="1" failures="0" errors="0"><properties><property skipped="0"/></properties></testsuite>\n' > "${JUNIT_FILE}"
assert_fails "JUnit decoy attributes outside the testsuite root fail the run" validate_junit

DEPLOY_INVOCATIONS="${TEMPORARY_DIRECTORY}/deploy-invocations"
printf '#!/usr/bin/env bash\nprintf deploy >> "%s"\n' "${DEPLOY_INVOCATIONS}" > "${TEST_ROOT}/deploy.sh"
chmod +x "${TEST_ROOT}/deploy.sh"
active_deployment_state() {
    printf '%s' "${TEST_DEPLOYMENT_STATE}"
}
TEST_DEPLOYMENT_STATE=ACTIVE_HEALTHY
deploy_stack
[[ ! -e "${DEPLOY_INVOCATIONS}" ]] || {
    printf 'healthy deployment must not invoke deploy.sh\n' >&2
    exit 1
}
TEST_DEPLOYMENT_STATE=ABSENT
deploy_stack
assert_equals deploy "$(cat "${DEPLOY_INVOCATIONS}")" "absent deployment invokes deploy.sh"
TEST_DEPLOYMENT_STATE=ACTIVE_DEGRADED
assert_fails "degraded deployment fails closed" deploy_stack
TEST_DEPLOYMENT_STATE=ACTIVE_INCONSISTENT
assert_fails "inconsistent deployment fails closed" deploy_stack

INVOCATIONS="${TEMPORARY_DIRECTORY}/invocations"
preflight() {
    printf 'preflight\n' >> "${INVOCATIONS}"
}
read_live_configuration() {
    :
}
create_run_directory() {
    RUN_ID=orchestration-test
    RUN_DIRECTORY="${TEMPORARY_DIRECTORY}/orchestration-report"
    mkdir -p "${RUN_DIRECTORY}"
    printf 'report-directory\n' >> "${INVOCATIONS}"
}
deploy_stack() {
    printf 'deploy\n' >> "${INVOCATIONS}"
}
read_deployed_revisions() {
    STARTER_SHA="${TEST_STARTER_SHA}"
    AGENT_SHA="${TEST_AGENT_SHA}"
    SEMANTIC_SHA="${TEST_SEMANTIC_SHA}"
    printf 'revisions\n' >> "${INVOCATIONS}"
}
ensure_knowledge_fixture_and_database() {
    FIXTURE_REVISION=FIXTURE
    printf 'fixture-db\n' >> "${INVOCATIONS}"
}
write_manifest() {
    printf 'manifest\n' >> "${INVOCATIONS}"
}
run_live_scenario() {
    printf 'live-run\n' >> "${INVOCATIONS}"
}
validate_junit() {
    printf 'validate-junit\n' >> "${INVOCATIONS}"
}

: > "${INVOCATIONS}"
main
assert_equals $'preflight\nreport-directory\ndeploy\nrevisions\nfixture-db\nmanifest\nlive-run\nvalidate-junit' \
    "$(cat "${INVOCATIONS}")" \
    "preflight precedes every Docker-mutating stage and the live scenario runs once"

ROOT="${ORIGINAL_ROOT}"
ENV_FILE="${ROOT}/.env"
unset GOOGLE_API_KEY GOOGLE_GENAI_MODEL
printf 'knowledge UAT tests passed\n'
