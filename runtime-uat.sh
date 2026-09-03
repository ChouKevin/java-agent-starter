#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "$BASH_SOURCE")" && pwd -P)"
ENV_FILE="$ROOT/.env"
LIVE_EVIDENCE_ROOT="$ROOT/.runtime/evidence/session-mcp-live"
LIVE_WAIT_SECONDS="$(printenv SESSION_AGENT_LIVE_WAIT_SECONDS || printf 240)"

source "$ROOT/cross-service-uat.sh"

runtime_uat_fail() {
    printf 'runtime-uat: %s\n' "$*" >&2
    return 1
}

runtime_env_value() {
    local key="$1"
    local line
    line="$(grep -m1 -E "^$key=" "$ENV_FILE" 2>/dev/null || true)"
    printf '%s' "${line#*=}"
}

runtime_env_or_default() {
    local value
    value="$(runtime_env_value "$1")"
    [[ -n "$value" ]] && printf '%s' "$value" || printf '%s' "$2"
}

live_evidence_file() {
    printf '%s/%s' "$LIVE_EVIDENCE_DIRECTORY" "$1"
}

write_live_evidence() {
    local name="$1"
    local value="$2"
    printf '%s\n' "$value" > "$(live_evidence_file "$name")"
    chmod 0600 "$(live_evidence_file "$name")"
}

prepare_live_evidence() {
    local timestamp
    timestamp="$(date -u +%Y%m%dT%H%M%SZ)-$$-$RANDOM"
    umask 077
    mkdir -p "$LIVE_EVIDENCE_ROOT"
    chmod 0700 "$LIVE_EVIDENCE_ROOT"
    LIVE_EVIDENCE_DIRECTORY="$LIVE_EVIDENCE_ROOT/$timestamp"
    mkdir -p "$LIVE_EVIDENCE_DIRECTORY"
    chmod 0700 "$LIVE_EVIDENCE_DIRECTORY"
}

runtime_request() {
    local method="$1"
    local path="$2"
    local body="${3:-}"
    local runtime_port
    local -a arguments

    runtime_port="$(runtime_env_or_default SESSION_AGENT_HOST_PORT 8090)"
    arguments=(--fail --silent --show-error --connect-timeout 5 --max-time 30 --request "$method"
        --header 'Accept: application/json')
    [[ -n "$body" ]] && arguments+=(--header 'Content-Type: application/json' --data "$body")
    curl "${arguments[@]}" "http://127.0.0.1:$runtime_port$path"
}

semantic_payment_revision() {
    local semantic_port
    local semantic_token
    local catalog

    semantic_port="$(runtime_env_or_default SEMANTIC_HOST_PORT 8080)"
    semantic_token="$(runtime_env_value SEMANTIC_QUERY_API_TOKEN)"
    [[ -n "$semantic_token" ]] || runtime_uat_fail 'SEMANTIC_QUERY_API_TOKEN is blank'
    catalog="$(curl --fail --silent --show-error --connect-timeout 5 --max-time 30 --header "X-Api-Token: $semantic_token" --header 'Accept: application/json' "http://127.0.0.1:$semantic_port/api/v1/repositories")" || return 1
    jq -er '.items[] | select(.repositoryId == "payment-service") | .revision
        | select(type == "string" and length > 0)' <<< "$catalog"
}

unique_identifier() {
    printf '%s-%s-%s' "$(date +%s%N)" "$$" "$RANDOM"
}

submit_message() {
    local session_key="$1"
    local source_message_id="$2"
    local message="$3"
    local request

    request="$(jq -cn --arg session_key "$session_key" --arg source_message_id "$source_message_id" --arg message "$message" '{sessionKey:$session_key,participantId:"live-uat",sourceMessageId:$source_message_id,message:$message}')" || return 1
    runtime_request POST /internal/messages "$request"
}

wait_for_done_job() {
    local job_id="$1"
    local deadline
    local response
    local status

    deadline=$((SECONDS + LIVE_WAIT_SECONDS))
    while (( SECONDS < deadline )); do
        response="$(runtime_request GET "/internal/message-jobs/$job_id")" || return 1
        status="$(jq -er '.status | select(type == "string" and length > 0)' <<< "$response")" || return 1
        if [[ "$status" == DONE ]]; then
            printf '%s' "$response"
            return 0
        fi
        case "$status" in
            PENDING|RETRY|WORKING) sleep 1 ;;
            *) runtime_uat_fail "message job did not complete successfully: $job_id status=$status"; return 1 ;;
        esac
    done
    runtime_uat_fail "message job did not complete within ${LIVE_WAIT_SECONDS}s: $job_id"
}

session_history() {
    runtime_request GET "/internal/sessions/$1/messages"
}

assert_complete_tool_pairing() {
    local history="$1"
    jq -e '
        [.[] | select(.type == "ASSISTANT_TOOL_CALLS") | .calls[]?
            | {toolCallId, toolName, arguments}] as $calls
        | [.[] | select(.type == "TOOL") | {toolCallId, toolName, output}] as $tools
        | all($calls[]; (.toolCallId | type == "string" and length > 0)
            and (.toolName | type == "string" and length > 0)
            and (.arguments | type == "object"))
        and all($tools[]; (.toolCallId | type == "string" and length > 0)
            and (.toolName | type == "string" and length > 0))
        and all($calls[]; . as $call
            | ([$calls[] | select(.toolCallId == $call.toolCallId and .toolName == $call.toolName)] | length) == 1
            and ([$tools[] | select(.toolCallId == $call.toolCallId and .toolName == $call.toolName)] | length) == 1)
        and all($tools[]; . as $tool
            | ([$calls[] | select(.toolCallId == $tool.toolCallId and .toolName == $tool.toolName)] | length) == 1
            and ([$tools[] | select(.toolCallId == $tool.toolCallId and .toolName == $tool.toolName)] | length) == 1)
    ' <<< "$history" >/dev/null
}

assert_first_turn_history() {
    local history="$1"
    local semantic_revision="$2"

    assert_complete_tool_pairing "$history" || return 1
    jq -e --arg semantic_revision "$semantic_revision" '
        type == "array"
        and length > 0
        and any(.[] | select(.type == "ASSISTANT_TOOL_CALLS") | .calls[]?;
            (.toolName | type == "string" and startswith("semantic_")))
        and any(.[] | select(.type == "ASSISTANT_TOOL_CALLS") | .calls[]?;
            (.arguments | type == "object")
            and .arguments.repositoryId == "payment-service"
            and .arguments.revision == $semantic_revision)
        and any(.[] | select(.type == "TOOL");
            (.output | type == "object")
            and .output.isError == false
            and ([.output | .. | objects | .code? | strings | select(test("[^[:space:]]"))] | length > 0))
        and (.[-1].type == "ASSISTANT")
        and (.[-1].message | type == "string" and test("[^[:space:]]"))
    ' <<< "$history" >/dev/null
}

assert_history_preserved() {
    local first_history="$1"
    local current_history="$2"
    jq -e --slurpfile first <(printf '%s\n' "$first_history") '
        type == "array"
        and length >= ($first[0] | length)
        and .[0:($first[0] | length)] == $first[0]
    ' <<< "$current_history" >/dev/null
}

assert_follow_up_history() {
    local first_history="$1"
    local final_history="$2"
    local second_job_id="$3"

    assert_complete_tool_pairing "$final_history" || return 1
    assert_history_preserved "$first_history" "$final_history" || return 1
    jq -e --slurpfile first <(printf '%s\n' "$first_history") --arg second_job_id "$second_job_id" '
        ($first[0] | length) as $prefix_length
        | .[$prefix_length:] as $suffix
        | ($suffix | length > 0)
        and any($suffix[];
            .type == "ASSISTANT"
            and .messageJobId == $second_job_id
            and (.message | type == "string" and test("[^[:space:]]")))
    ' <<< "$final_history" >/dev/null
}

run_offline_cross_service_uat() {
    set -E
    trap 'runtime_uat_fail "offline cross-service deployment failed"; exit 1' ERR
    cross_service_uat_impl
    trap - ERR
    set +E
}

record_session_metadata() {
    local session_key="$1"
    local session_id="$2"
    local first_job_id="$3"
    local second_job_id="$4"
    local semantic_revision="$5"
    local started_at="$6"
    local first_completed_at="$7"
    local restarted_at="$8"
    local completed_at="$9"
    local runtime_revision
    local starter_revision

    runtime_revision="$(awk -F ': ' '/^Session Agent source SHA:/ { print $2; exit }' "$ROOT/deployment-record.txt")"
    starter_revision="$(awk -F ': ' '/^Starter source SHA:/ { print $2; exit }' "$ROOT/deployment-record.txt")"
    jq -n --arg session_key "$session_key" --arg session_id "$session_id" --arg first_job_id "$first_job_id" \
        --arg second_job_id "$second_job_id" --arg semantic_revision "$semantic_revision" \
        --arg runtime_revision "$runtime_revision" --arg starter_revision "$starter_revision" \
        --arg started_at "$started_at" --arg first_completed_at "$first_completed_at" \
        --arg restarted_at "$restarted_at" --arg completed_at "$completed_at" '
        {sessionKey:$session_key, sessionId:$session_id, firstJobId:$first_job_id, secondJobId:$second_job_id,
         semanticRevision:$semantic_revision, runtimeRevision:$runtime_revision, starterRevision:$starter_revision,
         startedAt:$started_at, firstCompletedAt:$first_completed_at, restartedAt:$restarted_at, completedAt:$completed_at}'
}

runtime_uat_impl() {
    local runtime_port session_key first_source_message_id second_source_message_id
    local first_receipt second_receipt session_id first_job_id second_job_id first_job second_job
    local semantic_revision first_history preserved_history final_history
    local started_at first_completed_at restarted_at completed_at

    prepare_live_evidence
    started_at="$(date --iso-8601=seconds)"
    run_offline_cross_service_uat
    [[ -f "$ROOT/deployment-record.txt" ]] || runtime_uat_fail 'deployment record is unavailable'
    cp "$ROOT/deployment-record.txt" "$(live_evidence_file deployment-record.txt)"
    chmod 0600 "$(live_evidence_file deployment-record.txt)"

    runtime_port="$(runtime_env_or_default SESSION_AGENT_HOST_PORT 8090)"
    semantic_revision="$(semantic_payment_revision)" || runtime_uat_fail 'payment-service Semantic revision is unavailable'
    session_key="session-mcp-live-$(unique_identifier)"
    first_source_message_id="session-mcp-live-first-$(unique_identifier)"
    second_source_message_id="session-mcp-live-follow-up-$(unique_identifier)"

    first_receipt="$(submit_message "$session_key" "$first_source_message_id" '我們目前支援哪些付款方式？請根據程式碼回答。')" \
        || runtime_uat_fail 'first message submission failed'
    session_id="$(jq -er '.sessionId | select(type == "string" and length > 0)' <<< "$first_receipt")" \
        || runtime_uat_fail 'first message receipt has no session id'
    first_job_id="$(jq -er '.messageJobId | select(type == "string" and length > 0)' <<< "$first_receipt")" \
        || runtime_uat_fail 'first message receipt has no job id'
    first_job="$(wait_for_done_job "$first_job_id")" || runtime_uat_fail 'first message job failed'
    write_live_evidence first-job.json "$first_job"
    first_history="$(session_history "$session_id")" || runtime_uat_fail 'first session history is unavailable'
    assert_first_turn_history "$first_history" "$semantic_revision" || runtime_uat_fail 'first session history failed structural validation'
    write_live_evidence first-history.json "$first_history"
    first_completed_at="$(date --iso-8601=seconds)"

    "${COMPOSE[@]}" up -d --force-recreate --no-deps session-agent-runtime \
        || runtime_uat_fail 'Runtime recreation failed'
    wait_for_runtime_health "$runtime_port" || runtime_uat_fail 'Runtime health did not recover after recreation'
    wait_for_semantic_catalog "$runtime_port" || runtime_uat_fail 'Runtime Semantic catalog did not recover after recreation'
    preserved_history="$(session_history "$session_id")" || runtime_uat_fail 'session history is unavailable after Runtime recreation'
    assert_history_preserved "$first_history" "$preserved_history" \
        || runtime_uat_fail 'session history was not preserved after Runtime recreation'
    restarted_at="$(date --iso-8601=seconds)"

    second_receipt="$(submit_message "$session_key" "$second_source_message_id" '這些付款方式的手續費能否只看程式碼就確定？若不能，請說明缺少哪類執行期資料。')" \
        || runtime_uat_fail 'follow-up message submission failed'
    [[ "$(jq -er '.sessionId' <<< "$second_receipt")" == "$session_id" ]] \
        || runtime_uat_fail 'follow-up did not use the original session'
    second_job_id="$(jq -er '.messageJobId | select(type == "string" and length > 0)' <<< "$second_receipt")" \
        || runtime_uat_fail 'follow-up receipt has no job id'
    second_job="$(wait_for_done_job "$second_job_id")" || runtime_uat_fail 'follow-up job failed'
    write_live_evidence second-job.json "$second_job"
    final_history="$(session_history "$session_id")" || runtime_uat_fail 'final session history is unavailable'
    assert_follow_up_history "$first_history" "$final_history" "$second_job_id" \
        || runtime_uat_fail 'follow-up session history failed structural validation'
    write_live_evidence final-history.json "$final_history"
    completed_at="$(date --iso-8601=seconds)"

    write_live_evidence session.json "$(record_session_metadata "$session_key" "$session_id" "$first_job_id" "$second_job_id" \
        "$semantic_revision" "$started_at" "$first_completed_at" "$restarted_at" "$completed_at")"
    write_live_evidence structural-report.txt "result=pass
semanticRevision=$semantic_revision
toolHistory=paired
restart=preserved
finalAssistant=nonblank"
}

runtime_uat_main() {
    local live_opt_in model_key

    [[ "$#" -eq 0 ]] || { runtime_uat_fail 'usage: ./runtime-uat.sh'; return 1; }
    live_opt_in="$(printenv SESSION_AGENT_LIVE || true)"
    [[ "$live_opt_in" == true ]] || { runtime_uat_fail 'SESSION_AGENT_LIVE=true must be exported'; return 1; }
    model_key="$(runtime_env_value GOOGLE_API_KEY)"
    [[ -n "$model_key" ]] || { runtime_uat_fail 'GOOGLE_API_KEY is blank'; return 1; }
    command -v jq >/dev/null 2>&1 || { runtime_uat_fail 'jq is required'; return 1; }
    with_deploy_lock runtime_uat_impl
}

if [[ "$BASH_SOURCE" == "$0" ]]; then
    runtime_uat_main "$@"
fi
