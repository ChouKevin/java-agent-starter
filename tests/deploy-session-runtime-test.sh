#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
temporary_directory="$(mktemp -d)"
call_log="${temporary_directory}/calls.log"
required_runtime_commit='a78f1df8f2d4a4dc2e0ea7d80a5d4260f93053ee'

cleanup() {
    rm -rf "${temporary_directory}"
}
trap cleanup EXIT

source "${ROOT}/deploy.sh"
eval "$(declare -f validate_deployment_sources | sed '1s/validate_deployment_sources/real_validate_deployment_sources/')"

create_env_if_missing() { :; }
env_value() {
    case "$1" in
        SEMANTIC_API_TOKEN) printf 'semantic-contract-token' ;;
        GOOGLE_API_KEY) printf 'google-contract-token' ;;
        *) printf '' ;;
    esac
}
env_or_default() { printf '%s' "$2"; }
prepare_host_paths() { :; }
prepare_sources() {
    [[ "$5" == "${required_runtime_commit}" ]]
    printf 'sources:%s:%s:%s:%s:%s\n' "$1" "$2" "$3" "$4" "$5" >> "${call_log}"
}
validate_deployment_sources() { printf 'sources-validated\n' >> "${call_log}"; }
clear_deployment_record() { printf 'record-clear\n' >> "${call_log}"; }
write_deployment_record() { printf 'record\n' >> "${call_log}"; }

semantic_probe_fails=0
mutate_source_during_build=0
docker() {
    local -a arguments=("$@")
    local index

    if [[ "$*" == "compose version" ]]; then
        return
    fi
    for ((index = 0; index < ${#arguments[@]}; index++)); do
        case "${arguments[${index}]}" in
            build|down|up|--profile)
                printf 'compose:%s\n' "${arguments[*]:${index}}" >> "${call_log}"
                if [[ "${mutate_source_during_build}" -eq 1 && "${arguments[*]:${index}}" == 'build semantic-service session-agent-runtime' ]]; then
                    touch "${SOURCES_DIR}/session-agent-runtime/mutated-during-build.txt"
                    mutate_source_during_build=2
                fi
                if [[ "${semantic_probe_fails}" -eq 1 && "${arguments[*]:${index}}" == "--profile semantic-check run --rm semantic-probe" ]]; then
                    return 1
                fi
                return
                ;;
        esac
    done
}

main > "${temporary_directory}/output.log"

expected=$'sources:git@github.com:ChouKevin/session-agent-runtime.git:main:git@github.com:ChouKevin/java-code-intelligence.git:uat:a78f1df8f2d4a4dc2e0ea7d80a5d4260f93053ee\nsources-validated\ncompose:build semantic-service session-agent-runtime\nsources-validated\nrecord-clear\ncompose:down --remove-orphans --volumes\ncompose:up -d --wait --wait-timeout 240 session-agent-postgres\ncompose:--profile setup run --rm fixture-init\ncompose:up -d --wait --wait-timeout 240 semantic-service\ncompose:--profile semantic-check run --rm semantic-probe\ncompose:up -d --wait --wait-timeout 240 session-agent-runtime\ncompose:--profile runtime-check run --rm runtime-probe\nsources-validated\nrecord'
actual="$(<"${call_log}")"
[[ "${actual}" == "${expected}" ]] || {
    printf 'unexpected deployment calls\nexpected:\n%s\nactual:\n%s\n' \
        "${expected}" "${actual}" >&2
    exit 1
}
grep -Fq 'Session Agent UAT stack started' "${temporary_directory}/output.log"

: > "${call_log}"
eval "exec ${DEPLOY_LOCK_FD}>&-"
semantic_probe_fails=1
set +e
(set -e; main) > "${temporary_directory}/semantic-probe-failure.log" 2>&1
failure_status=$?
set -e
[[ "${failure_status}" -ne 0 ]] || {
    printf 'semantic probe failure unexpectedly succeeded\n' >&2
    exit 1
}
actual="$(<"${call_log}")"
expected_failure=$'sources:git@github.com:ChouKevin/session-agent-runtime.git:main:git@github.com:ChouKevin/java-code-intelligence.git:uat:a78f1df8f2d4a4dc2e0ea7d80a5d4260f93053ee\nsources-validated\ncompose:build semantic-service session-agent-runtime\nsources-validated\nrecord-clear\ncompose:down --remove-orphans --volumes\ncompose:up -d --wait --wait-timeout 240 session-agent-postgres\ncompose:--profile setup run --rm fixture-init\ncompose:up -d --wait --wait-timeout 240 semantic-service\ncompose:--profile semantic-check run --rm semantic-probe'
[[ "${actual}" == "${expected_failure}" ]] || {
    printf 'semantic probe failure started Runtime, probed Runtime, or wrote a record\nactual:\n%s\n' "${actual}" >&2
    exit 1
}

: > "${call_log}"
eval "exec ${DEPLOY_LOCK_FD}>&-"
semantic_probe_fails=0
mutate_source_during_build=1
runtime_repository="${temporary_directory}/runtime.git"
semantic_repository="${temporary_directory}/semantic.git"
managed_sources="${temporary_directory}/managed-sources"
for repository in "${runtime_repository}" "${semantic_repository}"; do
    git init --bare --quiet "${repository}"
    seed_directory="${repository%.git}-seed"
    git clone --quiet "${repository}" "${seed_directory}"
    git -C "${seed_directory}" config user.email deploy-session-runtime-test@example.invalid
    git -C "${seed_directory}" config user.name deploy-session-runtime-test
    touch "${seed_directory}/source.txt"
    git -C "${seed_directory}" add source.txt
    git -C "${seed_directory}" commit --quiet -m initial
    git -C "${seed_directory}" branch -M main
    git -C "${seed_directory}" push --quiet origin main
done
semantic_seed_directory="${semantic_repository%.git}-seed"
mkdir -p "${semantic_seed_directory}/fixtures/uat/payment-service/src/main/java" \
    "${semantic_seed_directory}/fixtures/uat/order-service/src/main/java"
touch "${semantic_seed_directory}/fixtures/uat/payment-service/pom.xml"
touch "${semantic_seed_directory}/fixtures/uat/payment-service/src/main/java/PaymentFixture.java" \
    "${semantic_seed_directory}/fixtures/uat/order-service/src/main/java/OrderFixture.java"
git -C "${semantic_seed_directory}" add fixtures
git -C "${semantic_seed_directory}" commit --quiet -m 'add incomplete UAT fixtures'
git -C "${semantic_seed_directory}" push --quiet origin main
mkdir -p "${managed_sources}"
git clone --quiet --branch main "${runtime_repository}" "${managed_sources}/session-agent-runtime"
git clone --quiet --branch main "${semantic_repository}" "${managed_sources}/java-code-intelligence"
SOURCES_DIR="${managed_sources}"
prepare_sources() {
    DEPLOYMENT_RUNTIME_URL="${runtime_repository}"
    DEPLOYMENT_RUNTIME_REF=main
    DEPLOYMENT_RUNTIME_TARGET_SHA="$(git -C "${SOURCES_DIR}/session-agent-runtime" rev-parse HEAD)"
    DEPLOYMENT_SEMANTIC_URL="${semantic_repository}"
    DEPLOYMENT_SEMANTIC_REF=main
    DEPLOYMENT_SEMANTIC_TARGET_SHA="$(git -C "${SOURCES_DIR}/java-code-intelligence" rev-parse HEAD)"
    printf 'sources:%s:%s:%s:%s:%s\n' "$1" "$2" "$3" "$4" "$5" >> "${call_log}"
}
validate_deployment_sources() {
    printf 'sources-validated\n' >> "${call_log}"
    real_validate_deployment_sources
}
: > "${call_log}"
eval "exec ${DEPLOY_LOCK_FD}>&-"
mutate_source_during_build=0
set +e
(set -e; main) > "${temporary_directory}/missing-fixture.log" 2>&1
failure_status=$?
set -e
[[ "${failure_status}" -ne 0 ]] || {
    printf 'deployment accepted a Semantic checkout without the order-service fixture POM\n' >&2
    exit 1
}
missing_fixture_error="$(<"${temporary_directory}/missing-fixture.log")"
[[ "${missing_fixture_error}" == 'deploy: Semantic UAT fixture is missing: order-service' ]] || {
    printf 'missing Semantic fixture failed with the wrong diagnostic: %s\n' "${missing_fixture_error}" >&2
    exit 1
}
actual="$(<"${call_log}")"
expected_missing_fixture=$'sources:git@github.com:ChouKevin/session-agent-runtime.git:main:git@github.com:ChouKevin/java-code-intelligence.git:uat:a78f1df8f2d4a4dc2e0ea7d80a5d4260f93053ee\nsources-validated'
[[ "${actual}" == "${expected_missing_fixture}" ]] || {
    printf 'missing Semantic fixture did not abort immediately after source validation\nactual:\n%s\n' "${actual}" >&2
    exit 1
}
if rg -n '^(compose:build|record-clear|compose:down|compose:.*fixture-init|compose:.*semantic-service|compose:.*session-agent-runtime|record)$' "${call_log}" >/dev/null; then
    printf 'missing Semantic fixture triggered deployment side effects\nactual:\n%s\n' "${actual}" >&2
    exit 1
fi
touch "${SOURCES_DIR}/java-code-intelligence/fixtures/uat/order-service/pom.xml"
git -C "${SOURCES_DIR}/java-code-intelligence" config user.email deploy-session-runtime-test@example.invalid
git -C "${SOURCES_DIR}/java-code-intelligence" config user.name deploy-session-runtime-test
git -C "${SOURCES_DIR}/java-code-intelligence" add fixtures/uat/order-service/pom.xml
git -C "${SOURCES_DIR}/java-code-intelligence" commit --quiet -m 'complete UAT fixtures'
: > "${call_log}"
eval "exec ${DEPLOY_LOCK_FD}>&-"
mutate_source_during_build=1
set +e
(set -e; main) > "${temporary_directory}/source-mutation.log" 2>&1
failure_status=$?
set -e
[[ "${failure_status}" -ne 0 ]] || {
    printf 'deployment accepted a source mutation during image build\n' >&2
    exit 1
}
actual="$(<"${call_log}")"
expected_mutation=$'sources:git@github.com:ChouKevin/session-agent-runtime.git:main:git@github.com:ChouKevin/java-code-intelligence.git:uat:a78f1df8f2d4a4dc2e0ea7d80a5d4260f93053ee\nsources-validated\ncompose:build semantic-service session-agent-runtime\nsources-validated'
[[ "${actual}" == "${expected_mutation}" ]] || {
    printf 'source mutation did not abort before deployment record clear and Compose teardown\nactual:\n%s\n' "${actual}" >&2
    exit 1
}
