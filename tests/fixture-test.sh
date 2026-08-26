#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
SEMANTIC_FIXTURES="${SEMANTIC_UAT_FIXTURE_SOURCE:-${ROOT}/.runtime/sources/java-code-intelligence/semantic-indexer/fixtures/uat}"
TEMPORARY_DIRECTORY="$(mktemp -d)"
trap 'rm -rf "${TEMPORARY_DIRECTORY}"' EXIT

[[ -d "${SEMANTIC_FIXTURES}" ]] || { printf 'Semantic UAT fixture source is unavailable\n' >&2; exit 1; }
grep -Fq '${STARTER_ROOT}/.runtime/sources/java-code-intelligence/semantic-indexer/fixtures/uat/payment-service' "${ROOT}/compose.yaml"
semantic_before="$(git -C "$(dirname -- "$(dirname -- "${SEMANTIC_FIXTURES}")")" status --porcelain)"

run_fixture() {
    local runtime_root="$1"
    shift
    STARTER_ROOT="${runtime_root}" SEMANTIC_UAT_FIXTURE_SOURCE="${SEMANTIC_FIXTURES}" "${ROOT}/fixture.sh" "$@"
}

first_root="${TEMPORARY_DIRECTORY}/first"
second_root="${TEMPORARY_DIRECTORY}/second"
signed_default_root="${TEMPORARY_DIRECTORY}/signed-default"
mkdir -p "${first_root}" "${second_root}" "${signed_default_root}"
run_fixture "${first_root}" prepare

tag_sha() { git --git-dir="$1/.runtime/uat-git/$2.git" rev-parse "$3"; }
main_sha() { git --git-dir="$1/.runtime/uat-git/$2.git" rev-parse refs/heads/main; }
v1_payment="$(tag_sha "${first_root}" payment-service v1)"
v2_payment="$(tag_sha "${first_root}" payment-service v2)"
[[ "$(git --git-dir="${first_root}/.runtime/uat-git/payment-service.git" symbolic-ref HEAD)" == refs/heads/main ]]
[[ "$(main_sha "${first_root}" payment-service)" == "$(git --git-dir="${first_root}/.runtime/uat-git/payment-service.git" rev-parse v1^{commit})" ]]
for repository in order-service video-service; do
    [[ "$(main_sha "${first_root}" "${repository}")" == "$(git --git-dir="${first_root}/.runtime/uat-git/${repository}.git" rev-parse v1^{commit})" ]]
    if git --git-dir="${first_root}/.runtime/uat-git/${repository}.git" rev-parse v2 >/dev/null 2>&1; then
        printf '%s unexpectedly has a v2 tag\n' "${repository}" >&2
        exit 1
    fi
done

run_fixture "${first_root}" prepare
[[ "$(tag_sha "${first_root}" payment-service v1)" == "${v1_payment}" ]]
[[ "$(tag_sha "${first_root}" payment-service v2)" == "${v2_payment}" ]]
run_fixture "${second_root}" prepare
[[ "$(tag_sha "${second_root}" payment-service v1)" == "${v1_payment}" ]]
[[ "$(tag_sha "${second_root}" payment-service v2)" == "${v2_payment}" ]]
for repository in order-service video-service; do
    [[ "$(tag_sha "${second_root}" "${repository}" v1)" == "$(tag_sha "${first_root}" "${repository}" v1)" ]]
done
GIT_CONFIG_COUNT=2 GIT_CONFIG_KEY_0=commit.gpgSign GIT_CONFIG_VALUE_0=true \
    GIT_CONFIG_KEY_1=tag.gpgSign GIT_CONFIG_VALUE_1=true run_fixture "${signed_default_root}" prepare
[[ "$(tag_sha "${signed_default_root}" payment-service v1)" == "${v1_payment}" ]]
[[ "$(tag_sha "${signed_default_root}" payment-service v2)" == "${v2_payment}" ]]

order_before="$(main_sha "${first_root}" order-service)"
video_before="$(main_sha "${first_root}" video-service)"
run_fixture "${first_root}" use payment-service v2
[[ "$(main_sha "${first_root}" payment-service)" == "$(git --git-dir="${first_root}/.runtime/uat-git/payment-service.git" rev-parse v2^{commit})" ]]
[[ "$(main_sha "${first_root}" order-service)" == "${order_before}" ]]
[[ "$(main_sha "${first_root}" video-service)" == "${video_before}" ]]
fixture_status="$(run_fixture "${first_root}" status)"
grep -Fq 'payment-service main=' <<< "${fixture_status}"

for invalid in 'use unknown v1' 'use payment-service v3' 'use order-service v2' 'use video-service v2'; do
    if run_fixture "${first_root}" ${invalid}; then
        printf 'fixture accepted invalid command: %s\n' "${invalid}" >&2
        exit 1
    fi
done
if STARTER_ROOT=/ SEMANTIC_UAT_FIXTURE_SOURCE="${SEMANTIC_FIXTURES}" "${ROOT}/fixture.sh" prepare; then
    printf 'fixture accepted an unsafe runtime root\n' >&2
    exit 1
fi
if STARTER_ROOT="${TEMPORARY_DIRECTORY}/missing" SEMANTIC_UAT_FIXTURE_SOURCE="${TEMPORARY_DIRECTORY}/missing-source" "${ROOT}/fixture.sh" prepare; then
    printf 'fixture accepted a missing Semantic fixture source\n' >&2
    exit 1
fi

mkdir -p "${TEMPORARY_DIRECTORY}/locked/.runtime"
(
    exec 9>"${TEMPORARY_DIRECTORY}/locked/.runtime/deploy.lock"
    flock -n 9
    sleep 2
) &
lock_holder=$!
sleep 0.1
if run_fixture "${TEMPORARY_DIRECTORY}/locked" prepare; then
    printf 'fixture preparation bypassed the deployment lock\n' >&2
    exit 1
fi
wait "${lock_holder}"
[[ ! -e "${TEMPORARY_DIRECTORY}/locked/.runtime/uat-git/payment-service.git" ]]

reset_log="${TEMPORARY_DIRECTORY}/reset.log"
(
    STARTER_ROOT="${first_root}"
    SEMANTIC_UAT_FIXTURE_SOURCE="${SEMANTIC_FIXTURES}"
    source "${ROOT}/fixture.sh"
    indexer() {
        printf '%s %s\n' "$1" "$2" >> "${reset_log}"
        printf '{"jobId":"reset-job"}'
    }
    wait_for_job() { printf '%s %s\n' "$1" "$2" >> "${reset_log}"; printf '{"active":false,"phase":"COMPLETE"}'; }
    submit_and_wait() { printf '%s %s\n' "$1" "$2" >> "${reset_log}"; }
    publication() { git --git-dir="${first_root}/.runtime/uat-git/payment-service.git" rev-parse v1^{commit} | jq -R '{currentPointer:{revision:.}}'; }
    fixture_reset_impl payment-service
)
grep -Fq 'POST /index/uat/repositories/payment-service/reset' "${reset_log}"
grep -Fq 'payment-service ensure' "${reset_log}"
[[ "$(main_sha "${first_root}" payment-service)" == "$(git --git-dir="${first_root}/.runtime/uat-git/payment-service.git" rev-parse v1^{commit})" ]]

semantic_after="$(git -C "$(dirname -- "$(dirname -- "${SEMANTIC_FIXTURES}")")" status --porcelain)"
[[ "${semantic_after}" == "${semantic_before}" ]]
