#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
UAT_SCRIPT="${ROOT}/semantic-index-uat.sh"

[[ -x "${UAT_SCRIPT}" ]]
for phase in \
    semantic_uat_deploy_initial_r1_impl \
    semantic_uat_cold_r1_and_rebuild_impl \
    semantic_uat_gated_payment_transition_impl \
    semantic_uat_reset_payment_to_v1_impl \
    semantic_index_uat_impl; do
    grep -Fq "${phase}" "${UAT_SCRIPT}" || {
        printf 'Semantic UAT is missing composable phase: %s\n' "${phase}" >&2
        exit 1
    }
done
grep -Fq 'fixture_use_impl payment-service v2' "${UAT_SCRIPT}"
grep -Fq 'fixture_reset_impl payment-service' "${UAT_SCRIPT}"
grep -Fq '.runtime/evidence/semantic-git-uat' "${UAT_SCRIPT}"
grep -Fq 'gateCycleId' "${UAT_SCRIPT}"
grep -Fq 'REVISION_OUTDATED' "${UAT_SCRIPT}"
grep -Fq '/index/uat/publication/arm' "${UAT_SCRIPT}"
grep -Fq '/index/uat/publication/await' "${UAT_SCRIPT}"
grep -Fq '/index/uat/publication/release' "${UAT_SCRIPT}"
grep -Fq 'paused_cycle' "${UAT_SCRIPT}"
grep -Fq -- '--fail-with-body' "${UAT_SCRIPT}"
grep -Fq 'src/main/java/com/example/payment/PaymentFeeCalculator.java' "${UAT_SCRIPT}"
grep -Fq 'parameterTypes:["com.example.payment.PaymentMethod","java.math.BigDecimal"]' "${UAT_SCRIPT}"
restart_block="$(awk '/^restart_indexer\(\)/,/^}/' "${UAT_SCRIPT}")"
grep -Fq 'wait_for_indexer_admin' <<< "${restart_block}"
if rg -n 'query-.*\.json|payment-search\.json|uat-logs' "${UAT_SCRIPT}"; then
    printf 'Semantic UAT persists a Query result body outside sanitized evidence\n' >&2
    exit 1
fi
if rg -n 'semantic-repository-data|assert_split_cutover_volumes|mongo ' "${UAT_SCRIPT}"; then
    printf 'Semantic UAT retains a forbidden direct storage dependency\n' >&2
    exit 1
fi

TEMPORARY_DIRECTORY="$(mktemp -d)"
trap 'rm -rf "${TEMPORARY_DIRECTORY}"' EXIT
source "${UAT_SCRIPT}"
EVIDENCE_DIRECTORY="${TEMPORARY_DIRECTORY}/evidence"
mkdir -p "${EVIDENCE_DIRECTORY}"

CALLS="${TEMPORARY_DIRECTORY}/calls"
record() { printf '%s\n' "$*" >> "${CALLS}"; }
deploy_impl() { record deploy-reset; }
fixture_use_impl() { record "fixture-use:$1:$2"; }
fixture_reset_impl() { record "fixture-reset:$1"; }
assert_single_indexer() { record indexer-one; }
semantic_uat_capture_initial_revisions() { record capture-r1; }
semantic_uat_cold_r1_and_rebuild_impl() { record cold-r1-rebuild; }
semantic_uat_gated_payment_transition_impl() { record "transition:$1"; }
semantic_uat_reset_payment_to_v1_impl() { record reset-payment-v1; }
COMPOSE=(true)

semantic_index_uat_impl

[[ "$(<"${CALLS}")" == $'deploy-reset\nfixture-use:payment-service:v1\nfixture-use:order-service:v1\nfixture-use:video-service:v1\nindexer-one\ncapture-r1\ncold-r1-rebuild\ntransition:first\nreset-payment-v1\ntransition:second' ]] || {
    printf 'Semantic UAT phases did not execute the required clean V1-to-V2 twice order\n' >&2
    cat "${CALLS}" >&2
    exit 1
}

: > "${CALLS}"
query() { printf '[]'; }
evidence() { record "$*"; }
query_assert_success repositories GET /v1/repositories
[[ "$(<"${CALLS}")" == 'query=repositories result=accepted' ]]
[[ "$(first_fact_id <<<'{"result":{"facts":[{"fact":{"id":{"value":"fact-1"}}}]}}')" == fact-1 ]]
retain_pointer_evidence first \
    '{"revision":"1111111111111111111111111111111111111111","generationId":"generation-r1"}' \
    '{"revision":"2222222222222222222222222222222222222222","generationId":"generation-r2"}'
jq -e '
    .transition == "first"
    and .paymentR1.revision == "1111111111111111111111111111111111111111"
    and .paymentR2.generationId == "generation-r2"
' "${EVIDENCE_DIRECTORY}/payment-first-pointers.json" >/dev/null

DEPLOY_LOCK_FILE="${TEMPORARY_DIRECTORY}/deploy.lock"
ROOT="${TEMPORARY_DIRECTORY}"
semantic_index_uat_impl() { touch "${TEMPORARY_DIRECTORY}/uat-mutated"; }
(
    exec 9>"${DEPLOY_LOCK_FILE}"
    flock -n 9
    touch "${TEMPORARY_DIRECTORY}/lock-ready"
    sleep 1
) &
lock_holder=$!
while [[ ! -e "${TEMPORARY_DIRECTORY}/lock-ready" ]]; do sleep 0.01; done
if (semantic_index_uat_main); then
    printf 'Semantic UAT bypassed the deployment lock\n' >&2
    exit 1
fi
[[ ! -e "${TEMPORARY_DIRECTORY}/uat-mutated" ]]
wait "${lock_holder}"
