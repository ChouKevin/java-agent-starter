#!/usr/bin/env bash
# Build deterministic, local UAT Git remotes from Semantic-owned fixture sources.
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
FIXTURE_RUNTIME_ROOT="${STARTER_ROOT:-${ROOT}}"
FIXTURE_SOURCE="${SEMANTIC_UAT_FIXTURE_SOURCE:-${ROOT}/.runtime/sources/java-code-intelligence/semantic-indexer/fixtures/uat}"
UAT_GIT_ROOT="${FIXTURE_RUNTIME_ROOT}/.runtime/uat-git"
FIXTURE_TIMESTAMP='2000-01-01T00:00:00+0000'
FIXTURE_AUTHOR_NAME='Semantic UAT Fixture'
FIXTURE_AUTHOR_EMAIL='semantic-uat@example.invalid'
FIXTURE_REPOSITORIES=(payment-service order-service video-service)

source "${ROOT}/deploy.sh"
source "${ROOT}/semantic-index-uat.sh"

fixture_fail() { printf 'fixture: %s\n' "$*" >&2; exit 1; }

fixture_with_deploy_lock() {
    local operation_lock_fd status
    mkdir -p "${FIXTURE_RUNTIME_ROOT}/.runtime"
    exec {operation_lock_fd}>"${FIXTURE_RUNTIME_ROOT}/.runtime/deploy.lock"
    flock -n "${operation_lock_fd}" || fixture_fail "another starter deployment holds ${FIXTURE_RUNTIME_ROOT}/.runtime/deploy.lock"
    if "$@"; then
        status=0
    else
        status=$?
    fi
    exec {operation_lock_fd}>&-
    return "${status}"
}

fixture_validate_runtime_root() {
    [[ -n "${FIXTURE_RUNTIME_ROOT}" && "${FIXTURE_RUNTIME_ROOT}" != / && "${FIXTURE_RUNTIME_ROOT}" == /* ]] \
        || fixture_fail 'runtime root is unsafe'
    [[ "$(realpath -m -- "${UAT_GIT_ROOT}")" == "${FIXTURE_RUNTIME_ROOT}/.runtime/uat-git" ]] \
        || fixture_fail 'runtime root is unsafe'
}

fixture_validate_source() {
    local repository
    [[ -d "${FIXTURE_SOURCE}" && -f "${FIXTURE_SOURCE}/versions/payment-service-v2.patch" ]] \
        || fixture_fail "Semantic UAT fixture source is missing: ${FIXTURE_SOURCE}"
    for repository in "${FIXTURE_REPOSITORIES[@]}"; do
        [[ -f "${FIXTURE_SOURCE}/${repository}/pom.xml" ]] \
            || fixture_fail "Semantic UAT fixture is missing: ${repository}"
    done
}

fixture_repository() {
    case "${1:-}" in
        payment-service|order-service|video-service) printf '%s' "$1" ;;
        *) fixture_fail "unknown fixture repository: ${1:-}" ;;
    esac
}

fixture_tag() {
    case "${1:-}" in
        v1) printf '%s' "$1" ;;
        v2) [[ "${2:-}" == payment-service ]] || fixture_fail "v2 is available only for payment-service"; printf '%s' "$1" ;;
        *) fixture_fail "unknown fixture tag: ${1:-}" ;;
    esac
}

fixture_copy_tree() {
    local source_tree="$1" destination_tree="$2"
    mkdir -p "${destination_tree}"
    tar --create --file - --directory "${source_tree}" --exclude=target --exclude=.git . \
        | tar --extract --file - --directory "${destination_tree}"
}

fixture_git() {
    GIT_AUTHOR_NAME="${FIXTURE_AUTHOR_NAME}" GIT_AUTHOR_EMAIL="${FIXTURE_AUTHOR_EMAIL}" \
        GIT_AUTHOR_DATE="${FIXTURE_TIMESTAMP}" GIT_COMMITTER_NAME="${FIXTURE_AUTHOR_NAME}" \
        GIT_COMMITTER_EMAIL="${FIXTURE_AUTHOR_EMAIL}" GIT_COMMITTER_DATE="${FIXTURE_TIMESTAMP}" git "$@"
}

fixture_commit_and_tag() {
    local checkout="$1" message="$2" tag="$3"
    fixture_git -C "${checkout}" add --all
    fixture_git -C "${checkout}" commit --quiet --no-gpg-sign --message "${message}"
    fixture_git -C "${checkout}" tag --annotate --no-sign --message "${tag}" "${tag}"
}

fixture_validate_remote() {
    local remote="$1" repository="$2" v1="$3" v2="${4:-}" expected_main
    expected_main="$(git --git-dir="${remote}" rev-parse v1^{commit})"
    [[ "$(git --git-dir="${remote}" symbolic-ref HEAD)" == refs/heads/main ]] || return 1
    [[ "$(git --git-dir="${remote}" rev-parse refs/heads/main)" == "${expected_main}" ]] || return 1
    [[ "$(git --git-dir="${remote}" rev-parse v1)" == "${v1}" ]] || return 1
    if [[ "${repository}" == payment-service ]]; then
        [[ -n "${v2}" && "$(git --git-dir="${remote}" rev-parse v2)" == "${v2}" ]]
    elif git --git-dir="${remote}" rev-parse v2 >/dev/null 2>&1; then
        return 1
    fi
}

fixture_build_remote() {
    local repository="$1" build_root="$2" checkout="${build_root}/${repository}" remote="${build_root}/${repository}.git" v1 v2=''
    fixture_copy_tree "${FIXTURE_SOURCE}/${repository}" "${checkout}"
    git init --quiet --initial-branch=main "${checkout}"
    fixture_git -C "${checkout}" config user.name "${FIXTURE_AUTHOR_NAME}"
    fixture_git -C "${checkout}" config user.email "${FIXTURE_AUTHOR_EMAIL}"
    fixture_commit_and_tag "${checkout}" 'fixture v1' v1
    v1="$(git -C "${checkout}" rev-parse v1)"
    if [[ "${repository}" == payment-service ]]; then
        git -C "${checkout}" apply "${FIXTURE_SOURCE}/versions/payment-service-v2.patch" \
            || fixture_fail 'payment-service v2 patch could not be applied'
        fixture_commit_and_tag "${checkout}" 'fixture v2' v2
        v2="$(git -C "${checkout}" rev-parse v2)"
    fi
    git clone --quiet --bare "${checkout}" "${remote}"
    git --git-dir="${remote}" symbolic-ref HEAD refs/heads/main
    git --git-dir="${remote}" update-ref refs/heads/main "$(git -C "${checkout}" rev-parse v1^{commit})"
    fixture_validate_remote "${remote}" "${repository}" "${v1}" "${v2}" \
        || fixture_fail "generated ${repository} remote did not validate"
}

fixture_prepare_impl() {
    local build_root repository target temporary_target
    fixture_validate_runtime_root
    fixture_validate_source
    command -v git >/dev/null 2>&1 || fixture_fail 'git is required'
    mkdir -p "${FIXTURE_RUNTIME_ROOT}/.runtime"
    build_root="$(mktemp -d "${FIXTURE_RUNTIME_ROOT}/.runtime/fixture-build.XXXXXX")"
    for repository in "${FIXTURE_REPOSITORIES[@]}"; do
        fixture_build_remote "${repository}" "${build_root}"
    done
    mkdir -p "${UAT_GIT_ROOT}"
    for repository in "${FIXTURE_REPOSITORIES[@]}"; do
        target="${UAT_GIT_ROOT}/${repository}.git"
        temporary_target="${UAT_GIT_ROOT}/.${repository}.git.staging"
        rm -rf -- "${temporary_target}"
        mv "${build_root}/${repository}.git" "${temporary_target}"
        fixture_validate_remote "${temporary_target}" "${repository}" \
            "$(git --git-dir="${temporary_target}" rev-parse v1)" \
            "$(git --git-dir="${temporary_target}" rev-parse v2 2>/dev/null || true)" \
            || fixture_fail "validated ${repository} remote could not be promoted"
        rm -rf -- "${target}"
        mv "${temporary_target}" "${target}"
    done
    rm -rf -- "${build_root}"
}

fixture_status_impl() {
    local repository remote
    fixture_validate_runtime_root
    for repository in "${FIXTURE_REPOSITORIES[@]}"; do
        remote="${UAT_GIT_ROOT}/${repository}.git"
        [[ -d "${remote}" ]] || fixture_fail "fixture remote is missing: ${repository}"
        printf '%s main=%s v1=%s' "${repository}" "$(git --git-dir="${remote}" rev-parse refs/heads/main)" \
            "$(git --git-dir="${remote}" rev-parse v1)"
        if [[ "${repository}" == payment-service ]]; then
            printf ' v2=%s' "$(git --git-dir="${remote}" rev-parse v2)"
        fi
        printf '\n'
    done
}

fixture_use_impl() {
    local repository tag remote revision
    repository="$(fixture_repository "$1")"
    tag="$(fixture_tag "$2" "${repository}")"
    remote="${UAT_GIT_ROOT}/${repository}.git"
    [[ -d "${remote}" ]] || fixture_fail "fixture remote is missing: ${repository}"
    revision="$(git --git-dir="${remote}" rev-parse "${tag}^{commit}")" || fixture_fail "fixture tag is missing: ${tag}"
    git --git-dir="${remote}" update-ref refs/heads/main "${revision}"
}

fixture_reset_impl() {
    local repository remote expected publication_json actual response job_id
    repository="$(fixture_repository "$1")"
    remote="${UAT_GIT_ROOT}/${repository}.git"
    [[ -d "${remote}" ]] || fixture_fail "fixture remote is missing: ${repository}"
    expected="$(git --git-dir="${remote}" rev-parse v1^{commit})" || fixture_fail "fixture v1 tag is missing: ${repository}"
    git --git-dir="${remote}" update-ref refs/heads/main "${expected}"
    response="$(indexer POST "/index/uat/repositories/${repository}/reset")" \
        || fixture_fail "Indexer rejected ${repository}/reset"
    job_id="$(jq -er '.jobId' <<< "${response}")" || fixture_fail "Indexer returned no reset job id for ${repository}"
    wait_for_job "${repository}" "${job_id}" >/dev/null
    submit_and_wait "${repository}" ensure >/dev/null
    publication_json="$(publication "${repository}")"
    actual="$(jq -er '.currentPointer.revision // .revision // error("missing published revision")' <<< "${publication_json}")" \
        || fixture_fail "Indexer returned no published revision for ${repository}"
    [[ "${actual}" == "${expected}" ]] || fixture_fail "published revision is not fixture v1 for ${repository}"
}

fixture_main() {
    case "${1:-}" in
        prepare) [[ "$#" -eq 1 ]] || fixture_fail 'usage: ./fixture.sh prepare'; fixture_validate_runtime_root; fixture_validate_source; fixture_with_deploy_lock fixture_prepare_impl ;;
        status) [[ "$#" -eq 1 ]] || fixture_fail 'usage: ./fixture.sh status'; fixture_status_impl ;;
        use) [[ "$#" -eq 3 ]] || fixture_fail 'usage: ./fixture.sh use <repository> <v1|v2>'; fixture_validate_runtime_root; fixture_repository "$2" >/dev/null; fixture_tag "$3" "$2" >/dev/null; fixture_with_deploy_lock fixture_use_impl "$2" "$3" ;;
        reset) [[ "$#" -eq 2 ]] || fixture_fail 'usage: ./fixture.sh reset <repository>'; fixture_validate_runtime_root; fixture_repository "$2" >/dev/null; fixture_with_deploy_lock fixture_reset_impl "$2" ;;
        *) fixture_fail 'usage: ./fixture.sh {prepare|status|use|reset}' ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then fixture_main "$@"; fi
