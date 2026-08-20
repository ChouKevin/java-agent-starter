#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
temporary_directory="$(mktemp -d)"

cleanup() {
    rm -rf "${temporary_directory}"
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

assert_prepare_fails() {
    local sources_directory="$1"
    local runtime_url="$2"
    local runtime_ref="$3"
    local semantic_url="$4"
    local semantic_ref="$5"
    local expected_diagnostic="$6"
    local runtime_required_commit
    local diagnostic_file="${temporary_directory}/prepare-failure-${RANDOM}.log"

    runtime_required_commit="$(git ls-remote --heads "${runtime_url}" "refs/heads/${runtime_ref}" | cut -f1)"
    [[ -n "${runtime_required_commit}" ]] || {
        printf 'test Runtime target is unavailable\n' >&2
        exit 1
    }

    if bash -c '
        source "$1"
        SOURCES_DIR="$2"
        prepare_sources "$3" "$4" "$5" "$6" "$7"
    ' _ "${ROOT}/deploy.sh" "${sources_directory}" "${runtime_url}" "${runtime_ref}" \
        "${semantic_url}" "${semantic_ref}" "${runtime_required_commit}" >"${diagnostic_file}" 2>&1; then
        printf 'paired source preparation unexpectedly succeeded\n' >&2
        exit 1
    fi
    grep -Fq "${expected_diagnostic}" "${diagnostic_file}" || {
        printf 'paired source preparation failed for the wrong reason; expected: %s\n' \
            "${expected_diagnostic}" >&2
        cat "${diagnostic_file}" >&2
        exit 1
    }
}

seed_repository() {
    local name="$1"
    local seed_directory="${temporary_directory}/${name}-seed"
    local bare_repository="${temporary_directory}/${name}.git"

    git init --bare --quiet "${bare_repository}"
    git clone --quiet "${bare_repository}" "${seed_directory}"
    git -C "${seed_directory}" config user.email deploy-state-test@example.invalid
    git -C "${seed_directory}" config user.name deploy-state-test
    printf '%s initial\n' "${name}" > "${seed_directory}/${name}.txt"
    git -C "${seed_directory}" add .
    git -C "${seed_directory}" commit --quiet -m initial
    git -C "${seed_directory}" branch -M main
    git -C "${seed_directory}" push --quiet origin main
}

append_and_push() {
    local name="$1"
    local seed_directory="${temporary_directory}/${name}-seed"

    printf '%s update %s\n' "${name}" "$(git -C "${seed_directory}" rev-list --count HEAD)" >> "${seed_directory}/${name}.txt"
    git -C "${seed_directory}" add .
    git -C "${seed_directory}" commit --quiet -m update
    git -C "${seed_directory}" push --quiet origin main
}

source "${ROOT}/deploy.sh"

seed_repository required-runtime
seed_repository required-semantic
incompatible_sources="${temporary_directory}/incompatible-sources"
incompatible_required_sha="$(git -C "${temporary_directory}/required-semantic-seed" rev-parse HEAD)"
if bash -c '
    source "$1"
    SOURCES_DIR="$2"
    prepare_sources "$3" main "$4" main "$5"
' _ "${ROOT}/deploy.sh" "${incompatible_sources}" "${temporary_directory}/required-runtime.git" \
    "${temporary_directory}/required-semantic.git" "${incompatible_required_sha}" >/dev/null 2>&1; then
    printf 'Runtime target without the required compatible commit was promoted\n' >&2
    exit 1
fi
[[ ! -e "${incompatible_sources}/session-agent-runtime" ]] || {
    printf 'incompatible Runtime target was promoted despite the required commit gate\n' >&2
    exit 1
}

grep -Fq 'if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then' "${ROOT}/deploy.sh" || {
    printf 'deploy.sh must guard main when sourced\n' >&2
    exit 1
}
if rg -n 'PREPARED_DEPLOYMENT_FILE|prepared_|prepare_or_resume|preflight_active_deployment|classify_active_deployment|prepare_target_fixture|backups|FIXTURE_VOLUME_SUFFIX|deployment_record_matches' "${ROOT}/deploy.sh" >/dev/null; then
    printf 'deploy.sh still contains prepared, recovery, or active-state symbols\n' >&2
    exit 1
fi

ROOT="${temporary_directory}/starter"
mkdir -p "${ROOT}/.runtime"
lock_file="${ROOT}/.runtime/deploy.lock"
flock -n "${lock_file}" sleep 1 &
lock_holder_pid=$!
sleep 0.1
if (acquire_deploy_lock) >/dev/null 2>&1; then
    printf 'second deployment invocation acquired the exclusive deployment lock\n' >&2
    exit 1
fi
wait "${lock_holder_pid}"

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
seed_repository runtime
seed_repository semantic
seed_repository semantic-wrong

wrong_origin_sources="${temporary_directory}/wrong-origin-sources"
mkdir -p "${wrong_origin_sources}"
git clone --quiet --branch main "${temporary_directory}/runtime.git" "${wrong_origin_sources}/session-agent-runtime"
git clone --quiet --branch main "${temporary_directory}/semantic-wrong.git" "${wrong_origin_sources}/java-code-intelligence"
runtime_before="$(git -C "${wrong_origin_sources}/session-agent-runtime" rev-parse HEAD)"
semantic_before="$(git -C "${wrong_origin_sources}/java-code-intelligence" rev-parse HEAD)"
append_and_push runtime
append_and_push semantic
assert_prepare_fails "${wrong_origin_sources}" "${temporary_directory}/runtime.git" main \
    "${temporary_directory}/semantic.git" main "Semantic origin mismatch"
assert_equals "${runtime_before}" "$(git -C "${wrong_origin_sources}/session-agent-runtime" rev-parse HEAD)" "wrong second origin leaves Runtime unchanged"
assert_equals "${semantic_before}" "$(git -C "${wrong_origin_sources}/java-code-intelligence" rev-parse HEAD)" "wrong second origin leaves Semantic unchanged"

dirty_sources="${temporary_directory}/dirty-sources"
mkdir -p "${dirty_sources}"
git clone --quiet --branch main "${temporary_directory}/runtime.git" "${dirty_sources}/session-agent-runtime"
git clone --quiet --branch main "${temporary_directory}/semantic.git" "${dirty_sources}/java-code-intelligence"
runtime_before="$(git -C "${dirty_sources}/session-agent-runtime" rev-parse HEAD)"
semantic_before="$(git -C "${dirty_sources}/java-code-intelligence" rev-parse HEAD)"
append_and_push runtime
touch "${dirty_sources}/java-code-intelligence/dirty.txt"
assert_prepare_fails "${dirty_sources}" "${temporary_directory}/runtime.git" main \
    "${temporary_directory}/semantic.git" main "Semantic source has local changes"
assert_equals "${runtime_before}" "$(git -C "${dirty_sources}/session-agent-runtime" rev-parse HEAD)" "dirty second checkout leaves Runtime unchanged"
assert_equals "${semantic_before}" "$(git -C "${dirty_sources}/java-code-intelligence" rev-parse HEAD)" "dirty second checkout leaves Semantic unchanged"

missing_sources="${temporary_directory}/missing-sources"
mkdir -p "${missing_sources}"
git clone --quiet --branch main "${temporary_directory}/runtime.git" "${missing_sources}/session-agent-runtime"
git clone --quiet --branch main "${temporary_directory}/semantic.git" "${missing_sources}/java-code-intelligence"
runtime_before="$(git -C "${missing_sources}/session-agent-runtime" rev-parse HEAD)"
semantic_before="$(git -C "${missing_sources}/java-code-intelligence" rev-parse HEAD)"
append_and_push runtime
git -C "${temporary_directory}/semantic.git" symbolic-ref HEAD refs/heads/absent
git -C "${temporary_directory}/semantic-seed" push --quiet origin :main
assert_prepare_fails "${missing_sources}" "${temporary_directory}/runtime.git" main \
    "${temporary_directory}/semantic.git" main "Semantic remote branch is missing or ambiguous"
assert_equals "${runtime_before}" "$(git -C "${missing_sources}/session-agent-runtime" rev-parse HEAD)" "missing second target leaves Runtime unchanged"
assert_equals "${semantic_before}" "$(git -C "${missing_sources}/java-code-intelligence" rev-parse HEAD)" "missing second target leaves Semantic unchanged"

seed_repository semantic-non-ff
non_ff_sources="${temporary_directory}/non-ff-sources"
mkdir -p "${non_ff_sources}"
git clone --quiet --branch main "${temporary_directory}/runtime.git" "${non_ff_sources}/session-agent-runtime"
git clone --quiet --branch main "${temporary_directory}/semantic-non-ff.git" "${non_ff_sources}/java-code-intelligence"
runtime_before="$(git -C "${non_ff_sources}/session-agent-runtime" rev-parse HEAD)"
semantic_before="$(git -C "${non_ff_sources}/java-code-intelligence" rev-parse HEAD)"
append_and_push runtime
semantic_non_ff_seed="${temporary_directory}/semantic-non-ff-seed"
git -C "${semantic_non_ff_seed}" checkout --quiet --orphan replacement
git -C "${semantic_non_ff_seed}" rm -rf . >/dev/null
printf 'replacement\n' > "${semantic_non_ff_seed}/semantic-non-ff.txt"
git -C "${semantic_non_ff_seed}" add .
git -C "${semantic_non_ff_seed}" commit --quiet -m replacement
git -C "${semantic_non_ff_seed}" branch -M main
git -C "${semantic_non_ff_seed}" push --quiet --force origin main
assert_prepare_fails "${non_ff_sources}" "${temporary_directory}/runtime.git" main \
    "${temporary_directory}/semantic-non-ff.git" main "Semantic update is not fast-forward eligible"
assert_equals "${runtime_before}" "$(git -C "${non_ff_sources}/session-agent-runtime" rev-parse HEAD)" "non-fast-forward second target leaves Runtime unchanged"
assert_equals "${semantic_before}" "$(git -C "${non_ff_sources}/java-code-intelligence" rev-parse HEAD)" "non-fast-forward second target leaves Semantic unchanged"

seed_repository runtime-unchanged
seed_repository semantic-unchanged
unchanged_sources="${temporary_directory}/unchanged-sources"
mkdir -p "${unchanged_sources}"
git clone --quiet --branch main "${temporary_directory}/runtime-unchanged.git" "${unchanged_sources}/session-agent-runtime"
git clone --quiet --branch main "${temporary_directory}/semantic-unchanged.git" "${unchanged_sources}/java-code-intelligence"
runtime_before="$(git -C "${unchanged_sources}/session-agent-runtime" rev-parse HEAD)"
semantic_before="$(git -C "${unchanged_sources}/java-code-intelligence" rev-parse HEAD)"
SOURCES_DIR="${unchanged_sources}"
prepare_sources "${temporary_directory}/runtime-unchanged.git" main "${temporary_directory}/semantic-unchanged.git" main "${runtime_before}"
assert_equals "${runtime_before}" "$(git -C "${unchanged_sources}/session-agent-runtime" rev-parse HEAD)" "unchanged Runtime pair succeeds"
assert_equals "${semantic_before}" "$(git -C "${unchanged_sources}/java-code-intelligence" rev-parse HEAD)" "unchanged Semantic pair succeeds"
assert_equals "${runtime_before}" "${DEPLOYMENT_RUNTIME_TARGET_SHA}" "Runtime target SHA is captured from staging"
assert_equals "${semantic_before}" "${DEPLOYMENT_SEMANTIC_TARGET_SHA}" "Semantic target SHA is captured from staging"
touch "${unchanged_sources}/session-agent-runtime/mutated-during-build.txt"
source_authority_diagnostic="${temporary_directory}/source-authority-failure.log"
if (validate_deployment_sources) >"${source_authority_diagnostic}" 2>&1; then
    printf 'source authority validation accepted a mutated managed source\n' >&2
    exit 1
fi
grep -Fq "Session Agent Runtime source has local changes" "${source_authority_diagnostic}" || {
    printf 'source authority validation failed for the wrong reason\n' >&2
    cat "${source_authority_diagnostic}" >&2
    exit 1
}
rm "${unchanged_sources}/session-agent-runtime/mutated-during-build.txt"
if find "${unchanged_sources}" -maxdepth 1 -type d -name '.staging.*' -print -quit | grep -q .; then
    printf 'source preparation left invocation staging behind\n' >&2
    exit 1
fi

seed_repository runtime-advanced
advanced_sources="${temporary_directory}/advanced-sources"
mkdir -p "${advanced_sources}"
git clone --quiet --branch main "${temporary_directory}/runtime-advanced.git" "${advanced_sources}/session-agent-runtime"
append_and_push runtime-advanced
advanced_target_sha="$(remote_branch_sha "Session Agent Runtime" "${temporary_directory}/runtime-advanced.git" main)"
advanced_staging_root="$(mktemp -d "${advanced_sources}/.staging.XXXXXX")"
advanced_staging_directory="${advanced_staging_root}/session-agent-runtime"
stage_source_at_target "Session Agent Runtime" "${temporary_directory}/runtime-advanced.git" main \
    "${advanced_staging_directory}" "${advanced_target_sha}"
append_and_push runtime-advanced
git -C "${advanced_sources}/session-agent-runtime" fetch --quiet origin main
git -C "${advanced_sources}/session-agent-runtime" merge --ff-only origin/main >/dev/null
advanced_checkout_sha="$(git -C "${advanced_sources}/session-agent-runtime" rev-parse HEAD)"
if (
    INVOCATION_STAGING_ROOT="${advanced_staging_root}"
    promote_staged_source "Session Agent Runtime" "${advanced_sources}/session-agent-runtime" \
        "${advanced_staging_directory}" main "${advanced_target_sha}"
); then
    printf 'promotion accepted an externally advanced source checkout\n' >&2
    exit 1
fi
assert_equals "${advanced_checkout_sha}" "$(git -C "${advanced_sources}/session-agent-runtime" rev-parse HEAD)" \
    "rejected source promotion preserves the externally advanced checkout"
[[ ! -e "${advanced_staging_root}" ]] || {
    printf 'rejected source promotion left invocation staging behind\n' >&2
    exit 1
}

DEPLOYMENT_RECORD_FILE="${temporary_directory}/deployment-record.txt"
write_deployment_record
mapfile -t record_lines < "${DEPLOYMENT_RECORD_FILE}"
[[ "${#record_lines[@]}" -eq 3 ]] \
    && [[ "${record_lines[0]}" =~ ^deployment\ timestamp:\ [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:+-]+$ ]] \
    && [[ "${record_lines[1]}" == "Session Agent source SHA: ${runtime_before}" ]] \
    && [[ "${record_lines[2]}" == "Semantic source SHA: ${semantic_before}" ]] || {
    printf 'deployment record did not contain only the timestamp and exact source SHAs\n' >&2
    exit 1
}
assert_equals 600 "$(stat -c '%a' "${DEPLOYMENT_RECORD_FILE}")" "deployment record is mode 0600"
if find "${temporary_directory}" -maxdepth 1 -type f -name 'deployment-record.txt.tmp.*' -print -quit | grep -q .; then
    printf 'deployment record left an atomic-write temporary file behind\n' >&2
    exit 1
fi
