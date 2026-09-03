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
grep -Fq 'exercise_representative_query_flow' "${UAT_SCRIPT}"
for public_route in \
    '/api/v1/repositories' \
    '/api/v1/search-code' \
    '/api/v1/fact-source' \
    '/api/v1/api-routes' \
    '/api/v1/callers'; do
    grep -Fq "${public_route}" "${UAT_SCRIPT}"
done
for removed_surface in \
    '/v1/code-facts' \
    '/v1/api-routes/suggest' \
    '/v1/discovery/source-symbols' \
    '/v1/analyses/call-graphs' \
    'packageName:' \
    'className:' \
    'sourceFile:' \
    'methodName:' \
    'parameterTypes:'; do
    if rg -F -- "${removed_surface}" "${UAT_SCRIPT}"; then
        printf 'Semantic UAT retains removed query surface: %s\n' "${removed_surface}" >&2
        exit 1
    fi
done
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

pointer_counter="${TEMPORARY_DIRECTORY}/pointer-counter"
rebuild_query_marker="${TEMPORARY_DIRECTORY}/rebuild-query-complete"
open_stdin="${TEMPORARY_DIRECTORY}/open-stdin"
printf '0\n' > "${pointer_counter}"
mkfifo "${open_stdin}"
sleep 10 > "${open_stdin}" &
stdin_holder=$!
set +e
timeout 2 bash -c '
    source "$1"
    pointer_counter="$2"
    rebuild_query_marker="$3"
    publication() {
        local call
        call="$(<"${pointer_counter}")"
        if [[ "${call}" == 0 ]]; then
            printf "%s\n" '\''{"revision":"1111111111111111111111111111111111111111","generationId":"generation-1"}'\''
        else
            printf "%s\n" '\''{"revision":"1111111111111111111111111111111111111111","generationId":"generation-2"}'\''
        fi
        printf "%s\n" "$((call + 1))" > "${pointer_counter}"
    }
    pointer() { cat; }
    submit_and_wait() { :; }
    exercise_representative_query_flow() {
        [[ "$1" == 1111111111111111111111111111111111111111 ]]
        touch "${rebuild_query_marker}"
    }
    same_revision_rebuild
' _ "${UAT_SCRIPT}" "${pointer_counter}" "${rebuild_query_marker}" < "${open_stdin}"
rebuild_status=$?
set -e
kill "${stdin_holder}" 2>/dev/null || true
wait "${stdin_holder}" 2>/dev/null || true
[[ "${rebuild_status}" -eq 0 ]] || {
    printf 'same-revision rebuild verification waited for stdin\n' >&2
    exit 1
}
[[ -e "${rebuild_query_marker}" ]] || {
    printf 'same-revision rebuild did not verify the rebuilt generation through Query\n' >&2
    exit 1
}

make_fixture_remote() {
    local repository="$1" remote="${UAT_GIT_ROOT}/${1}.git" checkout="${TEMPORARY_DIRECTORY}/${1}-fixture"
    git init --quiet --bare "${remote}"
    git init --quiet --initial-branch=main "${checkout}"
    git -C "${checkout}" config user.email test@example.invalid
    git -C "${checkout}" config user.name test
    printf 'v1\n' > "${checkout}/fixture.txt"
    git -C "${checkout}" add fixture.txt
    git -C "${checkout}" commit --quiet -m v1
    git -C "${checkout}" tag -a v1 -m v1
    printf 'v2\n' > "${checkout}/fixture.txt"
    git -C "${checkout}" commit --quiet -am v2
    git -C "${checkout}" tag -a v2 -m v2
    git -C "${checkout}" remote add origin "${remote}"
    git -C "${checkout}" push --quiet origin main --tags
}

UAT_GIT_ROOT="${TEMPORARY_DIRECTORY}/fixture-remotes"
mkdir -p "${UAT_GIT_ROOT}"
make_fixture_remote payment-service
payment_v1="$(git --git-dir="${UAT_GIT_ROOT}/payment-service.git" rev-parse v1^{commit})"
assert_fixture_revision payment-service v1 "${payment_v1}"
if (assert_fixture_revision payment-service v1 "0000000000000000000000000000000000000000") 2>"${TEMPORARY_DIRECTORY}/fixture-revision-error"; then
    printf 'Semantic UAT accepted a publication revision that is not the peeled fixture tag\n' >&2
    exit 1
fi
grep -Fq 'published revision mismatch for payment-service v1' "${TEMPORARY_DIRECTORY}/fixture-revision-error"
initial_block="$(awk '/^semantic_uat_capture_initial_revisions\(\)/,/^}/' "${UAT_SCRIPT}")"
grep -Fq 'assert_fixture_revision payment-service v1 "${payment_revision}"' <<< "${initial_block}"
grep -Fq 'assert_fixture_revision order-service v1 "${order_revision}"' <<< "${initial_block}"
grep -Fq 'assert_fixture_revision video-service v1 "${video_revision}"' <<< "${initial_block}"
transition_block="$(awk '/^semantic_uat_gated_payment_transition_impl\(\)/,/^}/' "${UAT_SCRIPT}")"
grep -Fq 'assert_fixture_revision payment-service v1 "${r1_revision}"' <<< "${transition_block}"
grep -Fq 'assert_fixture_revision payment-service v2 "${r2_revision}"' <<< "${transition_block}"

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
evidence() { record "$*"; }
revision='1111111111111111111111111111111111111111'
expected_current_revision='2222222222222222222222222222222222222222'
expected_fact_id='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
expected_source_code='public Money calculate() {}'
query() {
    local method="$1" path="$2" body="${3:-}"
    case "${method} ${path}" in
        'GET /api/v1/repositories')
            record repositories
            jq -cn --arg revision "${revision}" '{items:[{repositoryId:"payment-service",revision:$revision}],page:{offset:0,limit:20,returned:1,total:1,hasMore:false}}'
            ;;
        'GET /api/v1/repositories/payment-service')
            record repository
            jq -cn --arg revision "${revision}" '{repositoryId:"payment-service",revision:$revision}'
            ;;
        'POST /api/v1/search-code')
            jq -e --arg revision "${revision}" '.repositoryId == "payment-service" and .revision == $revision and .query == "Payment" and .kinds == ["METHOD"]' <<< "${body}" >/dev/null
            record search-code
            jq -cn --arg revision "${revision}" --arg fact_id "${expected_fact_id}" --arg code "${expected_source_code}" '{repositoryId:"payment-service",revision:$revision,items:[{factId:$fact_id,kind:"METHOD",displayName:"calculate",source:{path:"src/main/java/com/example/payment/PaymentFeeCalculator.java",startLine:1,endLine:1,code:$code}}],page:{offset:0,limit:20,returned:1,total:1,hasMore:false}}'
            ;;
        'POST /api/v1/fact-source')
            jq -e --arg revision "${revision}" --arg fact_id "${expected_fact_id}" '.repositoryId == "payment-service" and .revision == $revision and .factId == $fact_id' <<< "${body}" >/dev/null
            record fact-source
            jq -cn --arg revision "${revision}" --arg fact_id "${expected_fact_id}" --arg code "${expected_source_code}" '{repositoryId:"payment-service",revision:$revision,factId:$fact_id,source:{path:"src/main/java/com/example/payment/PaymentFeeCalculator.java",startLine:1,endLine:1,code:$code},factRange:{startLine:1,endLine:1}}'
            ;;
        'POST /api/v1/api-routes')
            jq -e --arg revision "${revision}" '.repositoryId == "payment-service" and .revision == $revision and .httpMethod == "GET" and .path == "/payments"' <<< "${body}" >/dev/null
            record api-routes
            jq -cn --arg revision "${revision}" '{repositoryId:"payment-service",revision:$revision,items:[],page:{offset:0,limit:20,returned:0,total:0,hasMore:false}}'
            ;;
        'POST /api/v1/callers')
            jq -e --arg revision "${revision}" --arg fact_id "${expected_fact_id}" '.repositoryId == "payment-service" and .revision == $revision and .methodFactId == $fact_id' <<< "${body}" >/dev/null
            record callers
            jq -cn --arg revision "${revision}" '{repositoryId:"payment-service",revision:$revision,items:[],page:{offset:0,limit:20,returned:0,total:0,hasMore:false}}'
            ;;
        *)
            printf 'unexpected query operation: %s %s\n' "${method}" "${path}" >&2
            return 1
            ;;
    esac
}
exercise_representative_query_flow "${revision}"
[[ "$(<"${CALLS}")" == $'repositories\nrepository\nsearch-code\nfact-source\napi-routes\ncallers\nquery=representative-flow repository=payment-service revision=1111111111111111111111111111111111111111 result=accepted' ]]

printf 'SEMANTIC_QUERY_API_TOKEN=read-token\nSEMANTIC_HOST_PORT=18080\n' > "${TEMPORARY_DIRECTORY}/query.env"
ENV_FILE="${TEMPORARY_DIRECTORY}/query.env"
curl() {
    local output_file='' request_body='' target=''
    while [[ "$#" -gt 0 ]]; do
        case "$1" in
            --output) output_file="$2"; shift 2 ;;
            --data) request_body="$2"; shift 2 ;;
            *) target="$1"; shift ;;
        esac
    done
    [[ "${target}" == 'http://127.0.0.1:18080/api/v1/search-code' ]]
    jq -e --arg requested "${revision}" '.repositoryId == "payment-service" and .revision == $requested and .query == "Payment"' \
        <<< "${request_body}" >/dev/null
    jq -cn --arg current "${expected_current_revision}" \
        '{code:"REVISION_OUTDATED",message:"The requested revision is no longer current.",retryable:false,currentRevision:$current}' > "${output_file}"
    printf '409'
}
assert_stale_revision "${revision}" "${expected_current_revision}"
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
