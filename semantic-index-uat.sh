#!/usr/bin/env bash
# Disposable live acceptance for the split Indexer/Query Semantic deployment.
set -euo pipefail

if [[ "${SEMANTIC_INDEX_UAT_LOADED:-false}" == true ]]; then
    return 0
fi
SEMANTIC_INDEX_UAT_LOADED=true

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
ENV_FILE="${ROOT}/.env"
EVIDENCE_DIRECTORY="${ROOT}/.runtime/evidence/semantic-git-uat"
STARTUP_WAIT_SECONDS="${SEMANTIC_UAT_WAIT_SECONDS:-240}"
COMPOSE=(docker compose --project-name java-agent-uat --env-file "${ENV_FILE}" -f "${ROOT}/compose.yaml")

source "${ROOT}/deploy.sh"

uat_fail() { printf 'semantic-index-uat: %s\n' "$*" >&2; exit 1; }

env_value() {
    local line
    line="$(grep -m1 -E "^$1=" "${ENV_FILE}" 2>/dev/null || true)"
    printf '%s' "${line#*=}"
}

evidence() { printf '%s\n' "$*" >> "${EVIDENCE_DIRECTORY}/semantic-index-uat.log"; }

prepare_evidence_directory() {
    rm -rf -- "${EVIDENCE_DIRECTORY}"
    mkdir -p "${EVIDENCE_DIRECTORY}"
}

assert_single_indexer() {
    local count
    count="$("${COMPOSE[@]}" ps -q semantic-indexer | awk 'NF { count += 1 } END { print count + 0 }')"
    [[ "${count}" == 1 ]] || uat_fail "expected one running Indexer, found ${count}"
    evidence "service=indexer state=running instances=${count}"
}

query() {
    local method="$1" path="$2" body="${3:-}" token port
    token="$(env_value SEMANTIC_QUERY_API_TOKEN)"
    port="$(env_value SEMANTIC_HOST_PORT)"
    [[ -n "${token}" ]] || uat_fail "SEMANTIC_QUERY_API_TOKEN is blank"
    local -a arguments=(--fail-with-body --silent --show-error --connect-timeout 5 --max-time 30 --request "${method}"
        --header "X-Api-Token: ${token}" --header 'Accept: application/json')
    [[ -n "${body}" ]] && arguments+=(--header 'Content-Type: application/json' --data "${body}")
    curl "${arguments[@]}" "http://127.0.0.1:${port:-8080}${path}"
}

indexer() {
    local method="$1" path="$2" body="${3:-}" token port
    token="$(env_value SEMANTIC_INDEXER_ADMIN_TOKEN)"
    port="$(env_value SEMANTIC_INDEXER_HOST_PORT)"
    [[ -n "${token}" ]] || uat_fail "SEMANTIC_INDEXER_ADMIN_TOKEN is blank"
    local -a arguments=(--fail --silent --show-error --connect-timeout 5 --max-time 30 --request "${method}"
        --header "X-Api-Token: ${token}" --header 'Accept: application/json')
    [[ -n "${body}" ]] && arguments+=(--header 'Content-Type: application/json' --data "${body}")
    curl "${arguments[@]}" "http://127.0.0.1:${port:-8081}${path}"
}

wait_for_job() {
    local repository="$1" job_id="$2" response phase active failure deadline
    deadline=$((SECONDS + STARTUP_WAIT_SECONDS))
    while (( SECONDS < deadline )); do
        response="$(indexer GET "/index/repositories/${repository}/jobs/${job_id}")" \
            || uat_fail "Indexer job status is unavailable: ${job_id}"
        phase="$(jq -r '.phase' <<< "${response}")"
        active="$(jq -r '.active' <<< "${response}")"
        failure="$(jq -r '.failureCategory // empty' <<< "${response}")"
        evidence "job=${job_id} repository=${repository} phase=${phase} active=${active} failure=${failure:-none}"
        [[ -z "${failure}" ]] || uat_fail "Indexer job ${job_id} failed: ${failure}"
        if [[ "${active}" == false ]]; then
            [[ "${phase}" == COMPLETE ]] || uat_fail "Indexer job ${job_id} ended without a sealed publication: ${phase}"
            printf '%s' "${response}"
            return
        fi
        sleep 2
    done
    uat_fail "Indexer job did not finish within ${STARTUP_WAIT_SECONDS}s: ${job_id}"
}

submit_job() {
    local repository="$1" operation="$2" body="${3:-}" response job_id
    response="$(indexer POST "/index/repositories/${repository}/${operation}" "${body}")" \
        || uat_fail "Indexer rejected ${repository}/${operation}"
    job_id="$(jq -er '.jobId' <<< "${response}")" || uat_fail "Indexer returned no job id for ${repository}/${operation}"
    evidence "job=${job_id} repository=${repository} operation=${operation} phase=ACCEPTED"
    printf '%s' "${job_id}"
}

submit_and_wait() {
    local repository="$1" operation="$2" body="${3:-}" job_id
    job_id="$(submit_job "${repository}" "${operation}" "${body}")"
    wait_for_job "${repository}" "${job_id}"
}

wait_until_job_is_running() {
    local repository="$1" job_id="$2" response phase active failure deadline
    deadline=$((SECONDS + STARTUP_WAIT_SECONDS))
    while (( SECONDS < deadline )); do
        response="$(indexer GET "/index/repositories/${repository}/jobs/${job_id}")" \
            || uat_fail "Indexer job status is unavailable: ${job_id}"
        phase="$(jq -r '.phase' <<< "${response}")"
        active="$(jq -r '.active' <<< "${response}")"
        failure="$(jq -r '.failureCategory // empty' <<< "${response}")"
        evidence "job=${job_id} repository=${repository} phase=${phase} active=${active} failure=${failure:-none}"
        [[ -z "${failure}" ]] || uat_fail "Indexer job ${job_id} failed: ${failure}"
        if [[ "${active}" == true && "${phase}" == RUNNING ]]; then
            return
        fi
        sleep 2
    done
    uat_fail "Indexer job did not enter RUNNING within ${STARTUP_WAIT_SECONDS}s: ${job_id}"
}

publication() { indexer GET "/index/repositories/$1/publication"; }

pointer() { jq -ce '.currentPointer // error("missing current pointer")'; }

assert_fixture_revision() {
    local repository="$1" tag="$2" actual="$3" remote expected
    remote="${UAT_GIT_ROOT}/${repository}.git"
    expected="$(git --git-dir="${remote}" rev-parse "${tag}^{commit}")" \
        || uat_fail "fixture ${tag} tag is unavailable for ${repository}"
    [[ "${actual}" == "${expected}" ]] \
        || uat_fail "published revision mismatch for ${repository} ${tag}: expected=${expected} actual=${actual}"
    evidence "fixtureRevision repository=${repository} tag=${tag} revision=${actual}"
}

query_assert_success() {
    local label="$1" method="$2" path="$3" body="${4:-}" response
    response="$(query "${method}" "${path}" "${body}")" || uat_fail "Query ${label} transport failed"
    jq -e '(if type == "object" then .code else null end) != "REVISION_OUTDATED"' <<< "${response}" >/dev/null \
        || uat_fail "Query ${label} unexpectedly returned REVISION_OUTDATED"
    evidence "query=${label} result=accepted"
}

first_fact_id() { jq -er '.result.facts[0].fact.id.value'; }

assert_query_is_cold() {
    local query_container canary_log networks mounts environment
    query_container="$("${COMPOSE[@]}" ps -q semantic-query)"
    [[ -n "${query_container}" ]] || uat_fail "Query container is not running"
    networks="$(docker inspect --format '{{range $name, $_ := .NetworkSettings.Networks}}{{$name}} {{end}}' "${query_container}")"
    [[ "${networks}" == *java-agent-uat_semantic-read* && "${networks}" != *model-egress* ]] \
        || uat_fail "Query is not restricted to the internal read network"
    mounts="$(docker inspect --format '{{range .Mounts}}{{.Destination}} {{end}}' "${query_container}")"
    [[ "${mounts}" != *jdtls* && "${mounts}" != *repos* && "${mounts}" != *workspace* ]] \
        || uat_fail "Query has a JDT or repository workspace mount"
    environment="$(docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "${query_container}")"
    [[ "${environment}" != *JDTLS_* && "${environment}" != *GOOGLE_API_KEY=* && "${environment}" != *MODEL_* ]] \
        || uat_fail "Query has a model or JDT environment"
    if docker exec "${query_container}" sh -ec 'ps -eo args | grep -E "[j]dt\.ls|[o]rg\.eclipse\.jdt"'; then
        uat_fail "Query created a JDT LS process"
    fi
    if docker exec "${query_container}" sh -ec 'wget -q -T 3 -O /dev/null http://model-egress-canary:8080'; then
        uat_fail "Query reached the model-egress canary"
    fi
    canary_log="$("${COMPOSE[@]}" logs --no-color model-egress-canary 2>&1 || true)"
    [[ -z "${canary_log}" || "${canary_log}" != *model-egress-ok* ]] || uat_fail "Query produced model-egress canary requests"
    printf 'cold-query asserted jdt=false model=false workspace=false egress=false\n' \
        >> "${EVIDENCE_DIRECTORY}/cold-query-assertions.txt"
}

exercise_query_tool_families() {
    local payment_revision="$1" video_revision="$2" payment_search fact_id
    query_assert_success repositories GET /v1/repositories
    query_assert_success payment-repository GET /v1/repositories/payment-service
    query_assert_success payment-entry-points GET "/v1/repositories/payment-service/entry-points?revision=${payment_revision}"
    payment_search="$(query POST /v1/code-facts/search "$(jq -cn --arg revision "${payment_revision}" \
        '{repositoryId:"payment-service",revision:$revision,query:"Payment"}')")" || uat_fail "payment code-fact search failed"
    fact_id="$(first_fact_id <<< "${payment_search}")" \
        || uat_fail "payment code-fact search returned no fact"
    query_assert_success payment-code-fact POST /v1/code-facts/get "$(jq -cn --arg revision "${payment_revision}" --arg fact_id "${fact_id}" \
        '{repositoryId:"payment-service",revision:$revision,factId:$fact_id}')"
    query_assert_success video-code-fact POST /v1/code-facts/search "$(jq -cn --arg revision "${video_revision}" \
        '{repositoryId:"video-service",revision:$revision,query:"Video"}')"
    local method_request route_request symbol_request member_request
    method_request="$(jq -cn --arg revision "${payment_revision}" '{repositoryId:"payment-service",revision:$revision,packageName:"com.example.payment",className:"PaymentFeeCalculator",sourceFile:"src/main/java/com/example/payment/PaymentFeeCalculator.java",methodName:"calculate",parameterTypes:["com.example.payment.PaymentMethod","java.math.BigDecimal"]}')"
    route_request="$(jq -cn --arg revision "${payment_revision}" '{repositoryId:"payment-service",revision:$revision,httpMethod:"GET",path:"/payments"}')"
    symbol_request="$(jq -cn --arg revision "${payment_revision}" '{repositoryId:"payment-service",revision:$revision,packageName:"com.example.payment",className:"PaymentFeeCalculator",sourceFile:"src/main/java/com/example/payment/PaymentFeeCalculator.java",symbol:"calculate"}')"
    member_request="$(jq -cn --arg revision "${payment_revision}" '{repositoryId:"payment-service",revision:$revision,packageName:"com.example.payment",className:"PaymentFeeCalculator",sourceFile:"src/main/java/com/example/payment/PaymentFeeCalculator.java",kinds:["METHOD"]}')"
    query_assert_success source-symbols POST /v1/discovery/source-symbols/resolve "${symbol_request}"
    query_assert_success members POST /v1/discovery/type-members "${member_request}"
    query_assert_success routes POST /v1/api-routes/lookup "${route_request}"
    query_assert_success route-suggestions POST /v1/api-routes/suggest "${route_request}"
    query_assert_success references POST /v1/discovery/internal-references "${method_request}"
    query_assert_success implementations POST /v1/discovery/method-implementations "${method_request}"
    query_assert_success outgoing POST /v1/analyses/call-graphs/outgoing "${method_request}"
    query_assert_success incoming POST /v1/analyses/call-graphs/incoming "${method_request}"
}

restart_indexer() {
    "${COMPOSE[@]}" up -d --wait --wait-timeout "${STARTUP_WAIT_SECONDS}" semantic-indexer \
        || uat_fail "Indexer restart failed"
    wait_for_indexer_admin || uat_fail "restarted Indexer admin endpoint is not ready"
    assert_single_indexer
}

stop_indexer() {
    "${COMPOSE[@]}" stop semantic-indexer || uat_fail "could not stop Indexer"
    [[ -z "$("${COMPOSE[@]}" ps -q semantic-indexer)" ]] || uat_fail "Indexer remains running"
}

same_revision_rebuild() {
    local before after rebuild response payment_revision
    before="$(publication payment-service | pointer)"
    payment_revision="$(jq -er '.revision' <<< "${before}")"
    rebuild="$(jq -cn --argjson current "${before}" '{authorizeIncompatibleSchema:true,expectedCurrent:$current}')"
    submit_and_wait payment-service rebuild "${rebuild}" >/dev/null
    after="$(publication payment-service | pointer)"
    jq -ne --argjson before "${before}" --argjson after "${after}" \
        '$before.revision == $after.revision and $before.generationId != $after.generationId' >/dev/null \
        || uat_fail "same-revision rebuild did not change only the generation"
    query_assert_success rebuild-cold GET "/v1/repositories/payment-service/entry-points?revision=${payment_revision}"
}

retain_pointer_evidence() {
    local label="$1" r1="$2" r2="$3"
    jq -n --arg transition_label "${label}" --argjson r1 "${r1}" --argjson r2 "${r2}" \
        '{transition:$transition_label,paymentR1:($r1 | {revision,generationId}),paymentR2:($r2 | {revision,generationId})}' \
        > "${EVIDENCE_DIRECTORY}/payment-${label}-pointers.json"
}

assert_stale_revision() {
    local requested="$1" current="$2" response status_file
    status_file="$(mktemp)"
    response="$(curl --silent --show-error --output "${status_file}" --write-out '%{http_code}' \
        --header "X-Api-Token: $(env_value SEMANTIC_QUERY_API_TOKEN)" \
        "http://127.0.0.1:$(env_value SEMANTIC_HOST_PORT)/v1/repositories/payment-service/entry-points?revision=${requested}")"
    [[ "${response}" == 409 ]] || uat_fail "R1 did not return HTTP 409 after R2 publication"
    jq -e --arg requested "${requested}" --arg current "${current}" \
        '.code == "REVISION_OUTDATED" and .requestedRevision == $requested and .currentRevision == $current' "${status_file}" >/dev/null \
        || uat_fail "R1 stale response did not identify requested R1 and current R2"
    rm -f -- "${status_file}"
    evidence "stale=requested:${requested} current:${current} code=REVISION_OUTDATED"
}

semantic_uat_capture_initial_revisions() {
    local payment_revision order_revision video_revision
    payment_revision="$(query GET /v1/repositories/payment-service | jq -er '.currentRevision // .revision.value')"
    order_revision="$(query GET /v1/repositories/order-service | jq -er '.currentRevision // .revision.value')"
    video_revision="$(query GET /v1/repositories/video-service | jq -er '.currentRevision // .revision.value')"
    assert_fixture_revision payment-service v1 "${payment_revision}"
    assert_fixture_revision order-service v1 "${order_revision}"
    assert_fixture_revision video-service v1 "${video_revision}"
    printf '%s\n%s\n%s\n' "${payment_revision}" "${order_revision}" "${video_revision}" > "${EVIDENCE_DIRECTORY}/initial-revisions.txt"
    evidence "initial paymentRevision=${payment_revision} orderRevision=${order_revision} videoRevision=${video_revision}"
}

semantic_uat_deploy_initial_r1_impl() {
    prepare_evidence_directory
    # deploy_impl prepares deterministic remotes from Semantic-owned fixtures before resetting UAT state.
    # The explicit v1 updates below make the initial branch selection observable and lock-free.
    deploy_impl reset
    fixture_use_impl payment-service v1
    fixture_use_impl order-service v1
    fixture_use_impl video-service v1
    evidence 'fixture=all remotes=v1 prepared=true'
    assert_single_indexer
    "${COMPOSE[@]}" --profile uat-evidence up -d model-egress-canary || uat_fail "model-egress canary did not start"
    semantic_uat_capture_initial_revisions
}

semantic_uat_cold_r1_and_rebuild_impl() {
    local payment_revision video_revision
    payment_revision="$(sed -n '1p' "${EVIDENCE_DIRECTORY}/initial-revisions.txt")"
    video_revision="$(sed -n '3p' "${EVIDENCE_DIRECTORY}/initial-revisions.txt")"
    stop_indexer
    exercise_query_tool_families "${payment_revision}" "${video_revision}"
    assert_query_is_cold
    restart_indexer
    same_revision_rebuild
    stop_indexer
    query_assert_success rebuild-still-cold GET "/v1/repositories/payment-service/entry-points?revision=${payment_revision}"
    assert_query_is_cold
    restart_indexer
}

semantic_uat_gated_payment_transition_impl() {
    local label="$1" r1 r2 r1_revision r2_revision arm_response cycle_id job_id await_response paused_cycle
    # The remote and its two commits are created only from Semantic-owned fixture content.
    # Repository configuration is switched by the UAT profile before this phase; no Runtime fixture is copied or edited.
    r1="$(publication payment-service | pointer)"
    r1_revision="$(jq -er '.revision' <<< "${r1}")"
    assert_fixture_revision payment-service v1 "${r1_revision}"
    fixture_use_impl payment-service v2
    arm_response="$(indexer POST /index/uat/publication/arm)" \
        || uat_fail "UAT pre-publication pause is unavailable; production profiles must not expose it"
    cycle_id="$(jq -er '.cycleId // .id // error("missing cycle id")' <<< "${arm_response}")" \
        || uat_fail "UAT publication pause returned no cycle id"
    evidence "transition=${label} gateCycleId=${cycle_id} state=armed"
    job_id="$(submit_job payment-service sync '{"branch":"main"}')"
    wait_until_job_is_running payment-service "${job_id}"
    await_response="$(indexer GET /index/uat/publication/await)" \
        || uat_fail "Indexer never reached the UAT pre-publication pause"
    paused_cycle="$(jq -er '.cycleId // error("missing paused cycle id")' <<< "${await_response}")" \
        || uat_fail "UAT publication pause await returned no cycle id"
    [[ "${paused_cycle}" == "${cycle_id}" ]] || uat_fail "UAT publication pause awaited a different cycle"
    [[ "$(publication payment-service | pointer)" == "${r1}" ]] || uat_fail "R1 was not visible during the R2 publication pause"
    evidence "transition=${label} gateCycleId=${cycle_id} state=paused pointerRevision=${r1_revision}"
    indexer POST /index/uat/publication/release >/dev/null
    wait_for_job payment-service "${job_id}" >/dev/null
    r2="$(publication payment-service | pointer)"
    r2_revision="$(jq -er '.revision' <<< "${r2}")"
    assert_fixture_revision payment-service v2 "${r2_revision}"
    [[ "${r1_revision}" != "${r2_revision}" ]] || uat_fail "R2 did not change the published revision"
    retain_pointer_evidence "${label}" "${r1}" "${r2}"
    assert_stale_revision "${r1_revision}" "${r2_revision}"
    query_assert_success r2-current GET "/v1/repositories/payment-service/entry-points?revision=${r2_revision}"
    stop_indexer
    assert_stale_revision "${r1_revision}" "${r2_revision}"
    exercise_query_tool_families "${r2_revision}" "$(sed -n '3p' "${EVIDENCE_DIRECTORY}/initial-revisions.txt")"
    assert_query_is_cold
    restart_indexer
    submit_and_wait payment-service ensure >/dev/null
    evidence "transition=${label} gateCycleId=${cycle_id} state=published r1=${r1_revision} r2=${r2_revision}"
}

semantic_uat_reset_payment_to_v1_impl() {
    local order_main video_main order_after video_after
    order_main="$(git --git-dir="${UAT_GIT_ROOT}/order-service.git" rev-parse refs/heads/main)"
    video_main="$(git --git-dir="${UAT_GIT_ROOT}/video-service.git" rev-parse refs/heads/main)"
    fixture_reset_impl payment-service
    order_after="$(git --git-dir="${UAT_GIT_ROOT}/order-service.git" rev-parse refs/heads/main)"
    video_after="$(git --git-dir="${UAT_GIT_ROOT}/video-service.git" rev-parse refs/heads/main)"
    [[ "${order_main}" == "${order_after}" && "${video_main}" == "${video_after}" ]] \
        || uat_fail 'payment reset changed order-service or video-service fixture state'
    evidence "reset=payment-service revision=v1 orderGuard=${order_after} videoGuard=${video_after}"
}

semantic_index_uat_impl() {
    semantic_uat_deploy_initial_r1_impl
    semantic_uat_cold_r1_and_rebuild_impl
    semantic_uat_gated_payment_transition_impl first
    semantic_uat_reset_payment_to_v1_impl
    semantic_uat_gated_payment_transition_impl second
    evidence 'semantic-git-uat=complete'
}

semantic_index_uat_main() {
    [[ "$#" -eq 0 ]] || uat_fail "usage: ./semantic-index-uat.sh"
    command -v jq >/dev/null 2>&1 || uat_fail "jq is required"
    with_deploy_lock semantic_index_uat_impl
}

source "${ROOT}/fixture.sh"

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    semantic_index_uat_main "$@"
fi
