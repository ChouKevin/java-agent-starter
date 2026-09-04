#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "$0")/.." && pwd -P)"
TEMPORARY_DIRECTORY="$(mktemp -d)"
FAKE_STARTER="$TEMPORARY_DIRECTORY/starter"
CALL_LOG="$TEMPORARY_DIRECTORY/calls.log"
REQUEST_LOG="$TEMPORARY_DIRECTORY/requests.log"
STATE_FILE="$TEMPORARY_DIRECTORY/state"
OUTPUT_LOG="$TEMPORARY_DIRECTORY/output.log"
SECRET_KEY='google-uat-key'
SECRET_TOKEN='semantic-uat-token'
SESSION_ID='0d7c5b64-0a67-48a4-aaf9-0e7f5b3a1f86'

cleanup() { rm -rf "$TEMPORARY_DIRECTORY"; }
trap cleanup EXIT

[[ -x "$ROOT/runtime-uat.sh" ]] || { printf 'runtime-uat.sh is missing\n' >&2; exit 1; }
mkdir -p "$FAKE_STARTER/bin"
cp "$ROOT/runtime-uat.sh" "$FAKE_STARTER/runtime-uat.sh"
cat > "$FAKE_STARTER/.env" <<EOF
GOOGLE_API_KEY=
GOOGLE_GENAI_MODEL=contract-model
SESSION_AGENT_HOST_PORT=18090
SEMANTIC_QUERY_API_TOKEN=$SECRET_TOKEN
SEMANTIC_HOST_PORT=18080
EOF

cat > "$FAKE_STARTER/deploy.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
with_deploy_lock() (
    local lock_fd
    mkdir -p "__STARTER__/.runtime"
    exec {lock_fd}>"__STARTER__/.runtime/deploy.lock"
    flock -n "$lock_fd"
    "$@"
)
EOF
sed -i "s|__STARTER__|$FAKE_STARTER|g" "$FAKE_STARTER/deploy.sh"

cat > "$FAKE_STARTER/cross-service-uat.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
source "__STARTER__/deploy.sh"
assert_outer_lock() {
    if flock -n "__STARTER__/.runtime/deploy.lock" true; then
        printf 'cross-service workflow ran outside the Runtime outer lock\n' >&2
        exit 1
    fi
}
cross_service_uat_impl() {
    assert_outer_lock
    COMPOSE=(docker compose --project-name java-agent-uat --env-file "__STARTER__/.env" -f "__STARTER__/compose.yaml")
    printf 'cross-service:offline-stage\n' >> "__CALL_LOG__"
    if [[ "$(printenv FAKE_OFFLINE_WORKFLOW_FAIL || true)" == true ]]; then
        false
    fi
    printf 'cross-service:complete\n' >> "__CALL_LOG__"
    cat > "__STARTER__/deployment-record.txt" <<RECORD
deployment timestamp: 2026-09-03T00:00:00+00:00
Session Agent source SHA: runtime-sha
Semantic source SHA: semantic-sha
Starter source SHA: starter-sha
RECORD
}
wait_for_runtime_health() {
    assert_outer_lock
    [[ "$1" == 18090 ]]
    printf 'runtime-health:ready\n' >> "__CALL_LOG__"
}
wait_for_semantic_catalog() {
    assert_outer_lock
    [[ "$1" == 18090 ]]
    printf 'semantic-catalog:available\n' >> "__CALL_LOG__"
}
EOF
sed -i -e "s|__STARTER__|$FAKE_STARTER|g" -e "s|__CALL_LOG__|$CALL_LOG|g" "$FAKE_STARTER/cross-service-uat.sh"

cat > "$FAKE_STARTER/bin/docker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
FAKE_RUNTIME_FAIL_STAGE="$(printenv FAKE_RUNTIME_FAIL_STAGE || true)"
if flock -n "__STARTER__/.runtime/deploy.lock" true; then
    printf 'Runtime restart ran outside the Runtime outer lock\n' >&2
    exit 1
fi
printf 'docker:%s\n' "$*" >> "__CALL_LOG__"
if [[ "$*" == *'up -d --force-recreate --no-deps session-agent-runtime'* ]] && [[ "$FAKE_RUNTIME_FAIL_STAGE" == restart ]]; then
    exit 41
fi
EOF
sed -i -e "s|__STARTER__|$FAKE_STARTER|g" -e "s|__CALL_LOG__|$CALL_LOG|g" "$FAKE_STARTER/bin/docker"
chmod +x "$FAKE_STARTER/bin/docker"

cat > "$FAKE_STARTER/bin/sleep" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'sleep:%s\n' "$*" >> "__CALL_LOG__"
EOF
sed -i "s|__CALL_LOG__|$CALL_LOG|g" "$FAKE_STARTER/bin/sleep"
chmod +x "$FAKE_STARTER/bin/sleep"

cat > "$FAKE_STARTER/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
FAKE_RUNTIME_FAIL_STAGE="$(printenv FAKE_RUNTIME_FAIL_STAGE || true)"
FAKE_RUNTIME_UNCHANGED_FOLLOW_UP_HISTORY="$(printenv FAKE_RUNTIME_UNCHANGED_FOLLOW_UP_HISTORY || true)"
FAKE_RUNTIME_JOB_1_RETRY="$(printenv FAKE_RUNTIME_JOB_1_RETRY || true)"
FAKE_RUNTIME_BLANK_SOURCE_CODE="$(printenv FAKE_RUNTIME_BLANK_SOURCE_CODE || true)"
FAKE_RUNTIME_BLANK_FIRST_ASSISTANT="$(printenv FAKE_RUNTIME_BLANK_FIRST_ASSISTANT || true)"
FAKE_RUNTIME_BLANK_FOLLOW_UP_ASSISTANT="$(printenv FAKE_RUNTIME_BLANK_FOLLOW_UP_ASSISTANT || true)"
FAKE_RUNTIME_REUSED_TOOL_CALL_ID="$(printenv FAKE_RUNTIME_REUSED_TOOL_CALL_ID || true)"
FAKE_RUNTIME_INDEPENDENT_SOURCE_EVIDENCE="$(printenv FAKE_RUNTIME_INDEPENDENT_SOURCE_EVIDENCE || true)"
method=GET
body=
url=
while (( $# > 0 )); do
    case "$1" in
        --request|-X) method="$2"; shift 2 ;;
        --data|--data-raw) body="$2"; shift 2 ;;
        --header|-H|--connect-timeout|--max-time) shift 2 ;;
        --fail|--fail-with-body|--silent|--show-error) shift ;;
        *) url="$1"; shift ;;
    esac
done
case "$url" in
    http://127.0.0.1:18080/api/v1/repositories)
        printf 'GET catalog\n' >> "__REQUEST_LOG__"
        printf '%s\n' '{"items":[{"repositoryId":"payment-service","revision":"payment-revision-42"},{"repositoryId":"order-service","revision":"order-revision-7"}]}' ;;
    http://127.0.0.1:18090/actuator/health)
        printf 'GET health\n' >> "__REQUEST_LOG__"
        printf '%s\n' '{"status":"UP"}' ;;
    http://127.0.0.1:18090/actuator/mcpConnections)
        printf 'GET mcp\n' >> "__REQUEST_LOG__"
        printf '%s\n' '{"connections":{"semantic":{"state":"AVAILABLE","toolCount":12}}}' ;;
    http://127.0.0.1:18090/internal/messages)
        count="$(cat "__STATE_FILE__" 2>/dev/null || printf 0)"
        count=$((count + 1))
        printf '%s' "$count" > "__STATE_FILE__"
        session_key="$(jq -er '.sessionKey' <<< "$body")"
        source_id="$(jq -er '.sourceMessageId' <<< "$body")"
        question="$(jq -er '.message' <<< "$body")"
        [[ -n "$session_key" && -n "$source_id" ]]
        if (( count == 1 )); then
            [[ "$question" == '我們目前支援哪些付款方式？請根據程式碼回答。' ]]
            printf '%s\n' "$session_key" > "__TEMPORARY_DIRECTORY__/session-key"
            printf '%s\n' "$source_id" > "__TEMPORARY_DIRECTORY__/first-source-id"
            printf 'POST first-message\n' >> "__REQUEST_LOG__"
            printf '%s\n' '{"sessionId":"0d7c5b64-0a67-48a4-aaf9-0e7f5b3a1f86","messageJobId":"job-1"}'
        elif (( count == 2 )); then
            [[ "$session_key" == "$(< "__TEMPORARY_DIRECTORY__/session-key")" ]]
            [[ "$source_id" != "$(< "__TEMPORARY_DIRECTORY__/first-source-id")" ]]
            [[ "$question" == '這些付款方式的手續費能否只看程式碼就確定？若不能，請說明缺少哪類執行期資料。' ]]
            printf 'POST follow-up\n' >> "__REQUEST_LOG__"
            printf '%s\n' '{"sessionId":"0d7c5b64-0a67-48a4-aaf9-0e7f5b3a1f86","messageJobId":"job-2"}'
        elif (( count == 3 )); then
            [[ "$question" == '目前是否支援 Apple Pay？請根據程式碼查詢；若找不到，請明確回答「未找到程式碼證據」。' ]]
            printf 'POST unsupported-business\n' >> "__REQUEST_LOG__"
            printf '%s\n' '{"sessionId":"11111111-1111-4111-8111-111111111111","messageJobId":"job-unsupported-business"}'
        elif (( count == 4 )); then
            [[ "$question" == '目前每種付款方式的實際手續費是多少？請先查程式碼；如果程式碼不足以確定，請明確回答「需要執行期資料」。' ]]
            printf 'POST runtime-data\n' >> "__REQUEST_LOG__"
            printf '%s\n' '{"sessionId":"22222222-2222-4222-8222-222222222222","messageJobId":"job-runtime-data"}'
        elif (( count == 5 )); then
            [[ "$question" == '請根據程式碼列出目前支援的付款方式，最後只回傳 JSON 陣列，例如 ["CREDIT_CARD"]，不要加上 Markdown 或固定欄位。' ]]
            printf 'POST json-reply\n' >> "__REQUEST_LOG__"
            printf '%s\n' '{"sessionId":"33333333-3333-4333-8333-333333333333","messageJobId":"job-json-reply"}'
        else
            exit 44
        fi ;;
    http://127.0.0.1:18090/internal/message-jobs/job-1)
        [[ "$FAKE_RUNTIME_FAIL_STAGE" != job ]] || exit 42
        if [[ "$FAKE_RUNTIME_JOB_1_RETRY" == true ]]; then
            poll_file="__TEMPORARY_DIRECTORY__/job-1-retry-polls"
            polls=0
            [[ -f "$poll_file" ]] && polls="$(< "$poll_file")"
            polls=$((polls + 1))
            printf '%s' "$polls" > "$poll_file"
            case "$polls" in
                1) status=RETRY ;;
                2) status=WORKING ;;
                3) status=DONE ;;
                *) exit 46 ;;
            esac
            printf 'GET job-1:%s\n' "$status" >> "__REQUEST_LOG__"
            jq -cn --arg status "$status" '{messageJobId:"job-1",sessionId:"0d7c5b64-0a67-48a4-aaf9-0e7f5b3a1f86",status:$status}'
        else
            printf 'GET job-1\n' >> "__REQUEST_LOG__"
            printf '%s\n' '{"messageJobId":"job-1","sessionId":"0d7c5b64-0a67-48a4-aaf9-0e7f5b3a1f86","status":"DONE"}'
        fi ;;
    http://127.0.0.1:18090/internal/message-jobs/job-2)
        printf 'GET job-2\n' >> "__REQUEST_LOG__"
        printf '%s\n' '{"messageJobId":"job-2","sessionId":"0d7c5b64-0a67-48a4-aaf9-0e7f5b3a1f86","status":"DONE"}' ;;
    http://127.0.0.1:18090/internal/message-jobs/job-unsupported-business)
        printf 'GET job-unsupported-business\n' >> "__REQUEST_LOG__"
        printf '%s\n' '{"messageJobId":"job-unsupported-business","sessionId":"11111111-1111-4111-8111-111111111111","status":"DONE","retryCount":0,"modelCallCount":3}' ;;
    http://127.0.0.1:18090/internal/message-jobs/job-runtime-data)
        printf 'GET job-runtime-data\n' >> "__REQUEST_LOG__"
        printf '%s\n' '{"messageJobId":"job-runtime-data","sessionId":"22222222-2222-4222-8222-222222222222","status":"DONE","retryCount":0,"modelCallCount":3}' ;;
    http://127.0.0.1:18090/internal/message-jobs/job-json-reply)
        printf 'GET job-json-reply\n' >> "__REQUEST_LOG__"
        printf '%s\n' '{"messageJobId":"job-json-reply","sessionId":"33333333-3333-4333-8333-333333333333","status":"DONE","retryCount":0,"modelCallCount":3}' ;;
    http://127.0.0.1:18090/internal/sessions/0d7c5b64-0a67-48a4-aaf9-0e7f5b3a1f86/messages)
        [[ "$FAKE_RUNTIME_FAIL_STAGE" != history ]] || exit 43
        count="$(cat "__STATE_FILE__" 2>/dev/null || printf 0)"
        printf 'GET history-%s\n' "$count" >> "__REQUEST_LOG__"
        if (( count <= 1 )) || [[ "$FAKE_RUNTIME_UNCHANGED_FOLLOW_UP_HISTORY" == true ]]; then
            cat <<'JSON' | jq --arg blank_source "$FAKE_RUNTIME_BLANK_SOURCE_CODE" \
                --arg blank_first_assistant "$FAKE_RUNTIME_BLANK_FIRST_ASSISTANT" \
                --arg blank_follow_up_assistant "$FAKE_RUNTIME_BLANK_FOLLOW_UP_ASSISTANT" \
                --arg reused_tool_call_id "$FAKE_RUNTIME_REUSED_TOOL_CALL_ID" \
                --arg independent_source_evidence "$FAKE_RUNTIME_INDEPENDENT_SOURCE_EVIDENCE" '
                map(
                    if $independent_source_evidence == "true" and .type == "ASSISTANT_TOOL_CALLS" then
                        .calls += [{toolCallId:"other-source-call",toolName:"semantic_search_code",arguments:{repositoryId:"order-service",revision:"order-revision-7",query:"payment methods"}}]
                    elif $independent_source_evidence == "true" and .type == "TOOL" and .toolCallId == "source-call" then
                        .output = {isError:true,result:{code:"TOOL_CONNECTION_FAILED"}}
                    elif $reused_tool_call_id == "true" and .type == "ASSISTANT_TOOL_CALLS" then
                        .calls |= map(if .toolCallId == "source-call" then .toolCallId = "catalog-call" else . end)
                    elif $reused_tool_call_id == "true" and .type == "TOOL" and .toolCallId == "source-call" then
                        .toolCallId = "catalog-call"
                    elif $blank_source == "true" and .type == "TOOL" and .toolName == "semantic_search_code" then
                        .output.result.items[0].source.code = " \t "
                    elif $blank_first_assistant == "true" and .type == "ASSISTANT" and .messageJobId == "job-1" then
                        .message = " \t "
                    elif $blank_follow_up_assistant == "true" and .type == "ASSISTANT" and .messageJobId == "job-2" then
                        .message = " \t "
                    else .
                    end
                )
                | if $independent_source_evidence == "true" then
                    .[0:4] + [{sequence:99,type:"TOOL",messageJobId:"job-1",toolCallId:"other-source-call",toolName:"semantic_search_code",output:{isError:false,result:{repositoryId:"order-service",revision:"order-revision-7",items:[{source:{code:"public OrderPaymentMethod supported() { return CARD; }"}}]}}}] + .[4:]
                  else .
                  end
'
[{"sequence":1,"type":"USER","messageJobId":"job-1","participantId":"live-uat","message":"我們目前支援哪些付款方式？請根據程式碼回答。"},{"sequence":2,"type":"ASSISTANT_TOOL_CALLS","messageJobId":"job-1","calls":[{"toolCallId":"catalog-call","toolName":"semantic_list_repositories","arguments":{}},{"toolCallId":"source-call","toolName":"semantic_search_code","arguments":{"repositoryId":"payment-service","revision":"payment-revision-42","query":"payment methods"}}]},{"sequence":3,"type":"TOOL","messageJobId":"job-1","toolCallId":"catalog-call","toolName":"semantic_list_repositories","output":{"isError":false,"result":{"items":[{"repositoryId":"payment-service","revision":"payment-revision-42"},{"repositoryId":"order-service","revision":"order-revision-7"}]}}},{"sequence":4,"type":"TOOL","messageJobId":"job-1","toolCallId":"source-call","toolName":"semantic_search_code","output":{"isError":false,"result":{"repositoryId":"payment-service","revision":"payment-revision-42","items":[{"source":{"code":"public PaymentMethod supported() { return CARD; }"}}]}}},{"sequence":5,"type":"ASSISTANT","messageJobId":"job-1","message":"程式碼顯示可用付款方式。"}]
JSON
        else
            cat <<'JSON' | jq --arg blank_source "$FAKE_RUNTIME_BLANK_SOURCE_CODE" \
                --arg blank_first_assistant "$FAKE_RUNTIME_BLANK_FIRST_ASSISTANT" \
                --arg blank_follow_up_assistant "$FAKE_RUNTIME_BLANK_FOLLOW_UP_ASSISTANT" \
                --arg reused_tool_call_id "$FAKE_RUNTIME_REUSED_TOOL_CALL_ID" \
                --arg independent_source_evidence "$FAKE_RUNTIME_INDEPENDENT_SOURCE_EVIDENCE" '
                map(
                    if $independent_source_evidence == "true" and .type == "ASSISTANT_TOOL_CALLS" then
                        .calls += [{toolCallId:"other-source-call",toolName:"semantic_search_code",arguments:{repositoryId:"order-service",revision:"order-revision-7",query:"payment methods"}}]
                    elif $independent_source_evidence == "true" and .type == "TOOL" and .toolCallId == "source-call" then
                        .output = {isError:true,result:{code:"TOOL_CONNECTION_FAILED"}}
                    elif $reused_tool_call_id == "true" and .type == "ASSISTANT_TOOL_CALLS" then
                        .calls |= map(if .toolCallId == "source-call" then .toolCallId = "catalog-call" else . end)
                    elif $reused_tool_call_id == "true" and .type == "TOOL" and .toolCallId == "source-call" then
                        .toolCallId = "catalog-call"
                    elif $blank_source == "true" and .type == "TOOL" and .toolName == "semantic_search_code" then
                        .output.result.items[0].source.code = " \t "
                    elif $blank_first_assistant == "true" and .type == "ASSISTANT" and .messageJobId == "job-1" then
                        .message = " \t "
                    elif $blank_follow_up_assistant == "true" and .type == "ASSISTANT" and .messageJobId == "job-2" then
                        .message = " \t "
                    else .
                    end
                )
                | if $independent_source_evidence == "true" then
                    .[0:4] + [{sequence:99,type:"TOOL",messageJobId:"job-1",toolCallId:"other-source-call",toolName:"semantic_search_code",output:{isError:false,result:{repositoryId:"order-service",revision:"order-revision-7",items:[{source:{code:"public OrderPaymentMethod supported() { return CARD; }"}}]}}}] + .[4:]
                  else .
                  end
'
[{"sequence":1,"type":"USER","messageJobId":"job-1","participantId":"live-uat","message":"我們目前支援哪些付款方式？請根據程式碼回答。"},{"sequence":2,"type":"ASSISTANT_TOOL_CALLS","messageJobId":"job-1","calls":[{"toolCallId":"catalog-call","toolName":"semantic_list_repositories","arguments":{}},{"toolCallId":"source-call","toolName":"semantic_search_code","arguments":{"repositoryId":"payment-service","revision":"payment-revision-42","query":"payment methods"}}]},{"sequence":3,"type":"TOOL","messageJobId":"job-1","toolCallId":"catalog-call","toolName":"semantic_list_repositories","output":{"isError":false,"result":{"items":[{"repositoryId":"payment-service","revision":"payment-revision-42"},{"repositoryId":"order-service","revision":"order-revision-7"}]}}},{"sequence":4,"type":"TOOL","messageJobId":"job-1","toolCallId":"source-call","toolName":"semantic_search_code","output":{"isError":false,"result":{"repositoryId":"payment-service","revision":"payment-revision-42","items":[{"source":{"code":"public PaymentMethod supported() { return CARD; }"}}]}}},{"sequence":5,"type":"ASSISTANT","messageJobId":"job-1","message":"程式碼顯示可用付款方式。"},{"sequence":6,"type":"USER","messageJobId":"job-2","participantId":"live-uat","message":"這些付款方式的手續費能否只看程式碼就確定？若不能，請說明缺少哪類執行期資料。"},{"sequence":7,"type":"ASSISTANT","messageJobId":"job-2","message":"無法僅由程式碼確定；還需要目前的費率設定。"}]
JSON
        fi ;;
    http://127.0.0.1:18090/internal/sessions/11111111-1111-4111-8111-111111111111/messages)
        printf 'GET history-unsupported-business\n' >> "__REQUEST_LOG__"
        cat <<'JSON'
[{"sequence":1,"type":"USER","messageJobId":"job-unsupported-business","participantId":"live-uat","message":"目前是否支援 Apple Pay？請根據程式碼查詢；若找不到，請明確回答「未找到程式碼證據」。"},{"sequence":2,"type":"ASSISTANT_TOOL_CALLS","messageJobId":"job-unsupported-business","calls":[{"toolCallId":"unsupported-catalog-call","toolName":"semantic_list_repositories","arguments":{}},{"toolCallId":"unsupported-search-call","toolName":"semantic_search_code","arguments":{"repositoryId":"payment-service","revision":"payment-revision-42","query":"Apple Pay"}}]},{"sequence":3,"type":"TOOL","messageJobId":"job-unsupported-business","toolCallId":"unsupported-catalog-call","toolName":"semantic_list_repositories","output":{"isError":false,"result":{"items":[{"repositoryId":"payment-service","revision":"payment-revision-42"}]} }},{"sequence":4,"type":"TOOL","messageJobId":"job-unsupported-business","toolCallId":"unsupported-search-call","toolName":"semantic_search_code","output":{"isError":false,"result":{"repositoryId":"payment-service","revision":"payment-revision-42","items":[],"page":{"hasMore":false}}}},{"sequence":5,"type":"ASSISTANT","messageJobId":"job-unsupported-business","message":"未找到程式碼證據，無法確認目前支援 Apple Pay。"}]
JSON
        ;;
    http://127.0.0.1:18090/internal/sessions/22222222-2222-4222-8222-222222222222/messages)
        printf 'GET history-runtime-data\n' >> "__REQUEST_LOG__"
        cat <<'JSON'
[{"sequence":1,"type":"USER","messageJobId":"job-runtime-data","participantId":"live-uat","message":"目前每種付款方式的實際手續費是多少？請先查程式碼；如果程式碼不足以確定，請明確回答「需要執行期資料」。"},{"sequence":2,"type":"ASSISTANT_TOOL_CALLS","messageJobId":"job-runtime-data","calls":[{"toolCallId":"runtime-data-search-call","toolName":"semantic_search_code","arguments":{"repositoryId":"payment-service","revision":"payment-revision-42","query":"payment fee formula"}}]},{"sequence":3,"type":"TOOL","messageJobId":"job-runtime-data","toolCallId":"runtime-data-search-call","toolName":"semantic_search_code","output":{"isError":false,"result":{"repositoryId":"payment-service","revision":"payment-revision-42","items":[{"source":{"code":"String formulaJson = settings.loadRuntimeFeeFormulaJson(paymentMethod);"}}]}}},{"sequence":4,"type":"ASSISTANT","messageJobId":"job-runtime-data","message":"無法只看程式碼得知實際手續費，需要執行期資料。"}]
JSON
        ;;
    http://127.0.0.1:18090/internal/sessions/33333333-3333-4333-8333-333333333333/messages)
        printf 'GET history-json-reply\n' >> "__REQUEST_LOG__"
        cat <<'JSON'
[{"sequence":1,"type":"USER","messageJobId":"job-json-reply","participantId":"live-uat","message":"請根據程式碼列出目前支援的付款方式，最後只回傳 JSON 陣列，例如 [\"CREDIT_CARD\"]，不要加上 Markdown 或固定欄位。"},{"sequence":2,"type":"ASSISTANT_TOOL_CALLS","messageJobId":"job-json-reply","calls":[{"toolCallId":"json-search-call","toolName":"semantic_search_code","arguments":{"repositoryId":"payment-service","revision":"payment-revision-42","query":"PaymentMethod"}}]},{"sequence":3,"type":"TOOL","messageJobId":"job-json-reply","toolCallId":"json-search-call","toolName":"semantic_search_code","output":{"isError":false,"result":{"repositoryId":"payment-service","revision":"payment-revision-42","items":[{"source":{"code":"public enum PaymentMethod { CREDIT_CARD, BANK_TRANSFER, WALLET }"}}]}}},{"sequence":4,"type":"ASSISTANT","messageJobId":"job-json-reply","message":"[\"CREDIT_CARD\",\"BANK_TRANSFER\",\"WALLET\"]"}]
JSON
        ;;
    *) printf 'unexpected curl request: %s %s\n' "$method" "$url" >&2; exit 45 ;;
esac
EOF
sed -i -e "s|__REQUEST_LOG__|$REQUEST_LOG|g" -e "s|__STATE_FILE__|$STATE_FILE|g" \
    -e "s|__TEMPORARY_DIRECTORY__|$TEMPORARY_DIRECTORY|g" "$FAKE_STARTER/bin/curl"
chmod +x "$FAKE_STARTER/bin/curl"

run_runtime() { PATH="$FAKE_STARTER/bin:$PATH" "$@" "$FAKE_STARTER/runtime-uat.sh"; }

if SESSION_AGENT_LIVE=true run_runtime env > "$OUTPUT_LOG" 2>&1; then
    printf 'runtime UAT accepted a blank configured model credential\n' >&2
    exit 1
fi
[[ ! -e "$CALL_LOG" ]] || { printf 'runtime UAT deployed with a blank model credential\n' >&2; exit 1; }

sed -i "s/^GOOGLE_API_KEY=$/GOOGLE_API_KEY=$SECRET_KEY/" "$FAKE_STARTER/.env"
sed -i "s/^GOOGLE_API_KEY=$SECRET_KEY$/GOOGLE_API_KEY=   /" "$FAKE_STARTER/.env"
if SESSION_AGENT_LIVE=true run_runtime env > "$OUTPUT_LOG" 2>&1; then
    printf 'runtime UAT accepted a whitespace-only configured model credential\n' >&2
    exit 1
fi
[[ ! -e "$CALL_LOG" ]] || { printf 'runtime UAT deployed with a whitespace-only model credential\n' >&2; exit 1; }
sed -i 's/^GOOGLE_API_KEY=   $/GOOGLE_API_KEY=google-uat-key/' "$FAKE_STARTER/.env"
if run_runtime env -u SESSION_AGENT_LIVE > "$OUTPUT_LOG" 2>&1; then
    printf 'runtime UAT silently opted in without exported SESSION_AGENT_LIVE=true\n' >&2
    exit 1
fi
if SESSION_AGENT_LIVE=false run_runtime env > "$OUTPUT_LOG" 2>&1; then
    printf 'runtime UAT accepted SESSION_AGENT_LIVE=false\n' >&2
    exit 1
fi
if SESSION_AGENT_LIVE=true PATH="$FAKE_STARTER/bin:$PATH" "$FAKE_STARTER/runtime-uat.sh" unexpected > "$OUTPUT_LOG" 2>&1; then
    printf 'runtime UAT accepted a positional argument\n' >&2
    exit 1
fi
[[ ! -e "$CALL_LOG" ]] || { printf 'runtime UAT mutated before its opt-in checks\n' >&2; exit 1; }

rm -f "$STATE_FILE" "$CALL_LOG" "$REQUEST_LOG"
if SESSION_AGENT_LIVE=true FAKE_OFFLINE_WORKFLOW_FAIL=true run_runtime env > "$OUTPUT_LOG" 2>&1; then
    printf 'runtime UAT accepted a failed offline workflow\n' >&2
    exit 1
fi
grep -Fq 'runtime-uat: offline cross-service deployment failed' "$OUTPUT_LOG"
grep -Fxq 'cross-service:offline-stage' "$CALL_LOG"
! grep -Fq 'cross-service:complete' "$CALL_LOG"
[[ ! -e "$REQUEST_LOG" ]]
! grep -Fq 'docker:' "$CALL_LOG"

rm -rf "$FAKE_STARTER/.runtime/evidence/session-mcp-live"
rm -f "$STATE_FILE" "$CALL_LOG" "$REQUEST_LOG"
SESSION_AGENT_LIVE=true run_runtime env > "$OUTPUT_LOG" 2>&1

grep -Fxq 'cross-service:complete' "$CALL_LOG"
grep -Fxq 'runtime-health:ready' "$CALL_LOG"
grep -Fxq 'semantic-catalog:available' "$CALL_LOG"
grep -Fq 'up -d --force-recreate --no-deps session-agent-runtime' "$CALL_LOG"
[[ "$(grep -Fc 'POST ' "$REQUEST_LOG")" == 5 ]] || {
    printf 'runtime UAT did not run every configured live case\n' >&2
    exit 1
}
grep -Fxq 'POST first-message' "$REQUEST_LOG"
grep -Fxq 'POST follow-up' "$REQUEST_LOG"
grep -Fxq 'POST unsupported-business' "$REQUEST_LOG"
grep -Fxq 'POST runtime-data' "$REQUEST_LOG"
grep -Fxq 'POST json-reply' "$REQUEST_LOG"
grep -Fxq 'GET job-1' "$REQUEST_LOG"
grep -Fxq 'GET job-2' "$REQUEST_LOG"
grep -Fxq 'GET job-unsupported-business' "$REQUEST_LOG"
grep -Fxq 'GET job-runtime-data' "$REQUEST_LOG"
grep -Fxq 'GET job-json-reply' "$REQUEST_LOG"
[[ "$(grep -Fc 'GET history-' "$REQUEST_LOG")" -ge 3 ]]

EVIDENCE_DIRECTORY="$(find "$FAKE_STARTER/.runtime/evidence/session-mcp-live" -mindepth 1 -maxdepth 1 -type d)"
[[ -n "$EVIDENCE_DIRECTORY" ]]
for evidence_file in deployment-record.txt session.json first-job.json second-job.json first-history.json final-history.json structural-report.txt; do
    [[ -f "$EVIDENCE_DIRECTORY/$evidence_file" ]] || { printf 'missing evidence file: %s\n' "$evidence_file" >&2; exit 1; }
    [[ "$(stat -c '%a' "$EVIDENCE_DIRECTORY/$evidence_file")" == 600 ]]
done
for evidence_file in unsupported-business-job.json unsupported-business-history.json; do
    [[ -f "$EVIDENCE_DIRECTORY/$evidence_file" ]] || { printf 'missing evidence file: %s\n' "$evidence_file" >&2; exit 1; }
    [[ "$(stat -c '%a' "$EVIDENCE_DIRECTORY/$evidence_file")" == 600 ]]
done
for evidence_file in runtime-data-job.json runtime-data-history.json; do
    [[ -f "$EVIDENCE_DIRECTORY/$evidence_file" ]] || { printf 'missing evidence file: %s\n' "$evidence_file" >&2; exit 1; }
    [[ "$(stat -c '%a' "$EVIDENCE_DIRECTORY/$evidence_file")" == 600 ]]
done
for evidence_file in json-reply-job.json json-reply-history.json; do
    [[ -f "$EVIDENCE_DIRECTORY/$evidence_file" ]] || { printf 'missing evidence file: %s\n' "$evidence_file" >&2; exit 1; }
    [[ "$(stat -c '%a' "$EVIDENCE_DIRECTORY/$evidence_file")" == 600 ]]
done
jq -e --arg session_id "$SESSION_ID" '.sessionId == $session_id and .sessionKey != "" and .firstJobId == "job-1" and .secondJobId == "job-2"' "$EVIDENCE_DIRECTORY/session.json" >/dev/null
jq -e 'length == 5 and .[1].type == "ASSISTANT_TOOL_CALLS" and .[3].output.isError == false and .[4].type == "ASSISTANT"' "$EVIDENCE_DIRECTORY/first-history.json" >/dev/null
jq -e --slurpfile first "$EVIDENCE_DIRECTORY/first-history.json" 'length == 7 and .[5].type == "USER" and .[6].type == "ASSISTANT" and (.[:5] == $first[0])' "$EVIDENCE_DIRECTORY/final-history.json" >/dev/null
jq -e '.[-1].type == "ASSISTANT" and (.[-1].message | contains("未找到程式碼證據"))' "$EVIDENCE_DIRECTORY/unsupported-business-history.json" >/dev/null
jq -e '.[-1].type == "ASSISTANT" and (.[-1].message | contains("需要執行期資料"))' "$EVIDENCE_DIRECTORY/runtime-data-history.json" >/dev/null
jq -e '(.[-1].message | fromjson | sort) == ["BANK_TRANSFER", "CREDIT_CARD", "WALLET"]' "$EVIDENCE_DIRECTORY/json-reply-history.json" >/dev/null
grep -Fq 'result=pass' "$EVIDENCE_DIRECTORY/structural-report.txt"
! grep -R -Fq "$SECRET_KEY" "$EVIDENCE_DIRECTORY"
! grep -R -Fq "$SECRET_TOKEN" "$EVIDENCE_DIRECTORY"
! grep -Fq "$SECRET_KEY" "$OUTPUT_LOG"
! grep -Fq "$SECRET_TOKEN" "$OUTPUT_LOG"

rm -f "$STATE_FILE" "$CALL_LOG" "$REQUEST_LOG"
if SESSION_AGENT_LIVE=true FAKE_RUNTIME_REUSED_TOOL_CALL_ID=true run_runtime env > "$OUTPUT_LOG" 2>&1; then
    printf 'runtime UAT accepted tool call ID reuse across tool names\n' >&2
    exit 1
fi

rm -f "$STATE_FILE" "$CALL_LOG" "$REQUEST_LOG"
if SESSION_AGENT_LIVE=true FAKE_RUNTIME_INDEPENDENT_SOURCE_EVIDENCE=true run_runtime env > "$OUTPUT_LOG" 2>&1; then
    printf 'runtime UAT accepted unpaired payment source evidence\n' >&2
    exit 1
fi

for blank_case in source first-assistant follow-up-assistant; do
    rm -f "$STATE_FILE" "$CALL_LOG" "$REQUEST_LOG"
    case "$blank_case" in
        source) blank_environment=FAKE_RUNTIME_BLANK_SOURCE_CODE ;;
        first-assistant) blank_environment=FAKE_RUNTIME_BLANK_FIRST_ASSISTANT ;;
        follow-up-assistant) blank_environment=FAKE_RUNTIME_BLANK_FOLLOW_UP_ASSISTANT ;;
    esac
    if (
        export SESSION_AGENT_LIVE=true
        export "$blank_environment=true"
        run_runtime env > "$OUTPUT_LOG" 2>&1
    ); then
        printf 'runtime UAT accepted whitespace-only %s content\n' "$blank_case" >&2
        exit 1
    fi
done

rm -f "$STATE_FILE" "$CALL_LOG" "$REQUEST_LOG" "$TEMPORARY_DIRECTORY/job-1-retry-polls"
if ! SESSION_AGENT_LIVE=true FAKE_RUNTIME_JOB_1_RETRY=true run_runtime env > "$OUTPUT_LOG" 2>&1; then
    printf 'runtime UAT did not poll RETRY message jobs to completion\n' >&2
    exit 1
fi
grep -Fxq 'GET job-1:RETRY' "$REQUEST_LOG"
grep -Fxq 'GET job-1:WORKING' "$REQUEST_LOG"
grep -Fxq 'GET job-1:DONE' "$REQUEST_LOG"
[[ "$(< "$TEMPORARY_DIRECTORY/job-1-retry-polls")" == 3 ]]
[[ "$(grep -Fc 'sleep:1' "$CALL_LOG")" == 2 ]]

rm -f "$STATE_FILE" "$CALL_LOG" "$REQUEST_LOG"
if SESSION_AGENT_LIVE=true FAKE_RUNTIME_UNCHANGED_FOLLOW_UP_HISTORY=true run_runtime env > "$OUTPUT_LOG" 2>&1; then
    printf 'runtime UAT accepted unchanged history after the follow-up job completed\n' >&2
    exit 1
fi
[[ "$(grep -Fc 'POST ' "$REQUEST_LOG")" == 2 ]]
grep -Fxq 'POST follow-up' "$REQUEST_LOG"

rm -f "$STATE_FILE" "$CALL_LOG" "$REQUEST_LOG"
if SESSION_AGENT_LIVE=true FAKE_RUNTIME_FAIL_STAGE=job run_runtime env > "$OUTPUT_LOG" 2>&1; then
    printf 'runtime UAT continued after a failed first job request\n' >&2
    exit 1
fi
[[ "$(grep -Fc 'POST ' "$REQUEST_LOG")" == 1 ]]
! grep -Fq 'docker:' "$CALL_LOG"

rm -f "$STATE_FILE" "$CALL_LOG" "$REQUEST_LOG"
if SESSION_AGENT_LIVE=true FAKE_RUNTIME_FAIL_STAGE=history run_runtime env > "$OUTPUT_LOG" 2>&1; then
    printf 'runtime UAT continued after a failed first history request\n' >&2
    exit 1
fi
[[ "$(grep -Fc 'POST ' "$REQUEST_LOG")" == 1 ]]
! grep -Fq 'docker:' "$CALL_LOG"

rm -f "$STATE_FILE" "$CALL_LOG" "$REQUEST_LOG"
if SESSION_AGENT_LIVE=true FAKE_RUNTIME_FAIL_STAGE=restart run_runtime env > "$OUTPUT_LOG" 2>&1; then
    printf 'runtime UAT continued after Runtime recreation failed\n' >&2
    exit 1
fi
[[ "$(grep -Fc 'POST ' "$REQUEST_LOG")" == 1 ]]
grep -Fq 'docker:' "$CALL_LOG"

printf 'runtime-uat-test: PASS\n'
