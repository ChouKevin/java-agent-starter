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

cat > "$FAKE_STARTER/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
FAKE_RUNTIME_FAIL_STAGE="$(printenv FAKE_RUNTIME_FAIL_STAGE || true)"
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
        else
            exit 44
        fi ;;
    http://127.0.0.1:18090/internal/message-jobs/job-1)
        [[ "$FAKE_RUNTIME_FAIL_STAGE" != job ]] || exit 42
        printf 'GET job-1\n' >> "__REQUEST_LOG__"
        printf '%s\n' '{"messageJobId":"job-1","sessionId":"0d7c5b64-0a67-48a4-aaf9-0e7f5b3a1f86","status":"DONE"}' ;;
    http://127.0.0.1:18090/internal/message-jobs/job-2)
        printf 'GET job-2\n' >> "__REQUEST_LOG__"
        printf '%s\n' '{"messageJobId":"job-2","sessionId":"0d7c5b64-0a67-48a4-aaf9-0e7f5b3a1f86","status":"DONE"}' ;;
    http://127.0.0.1:18090/internal/sessions/0d7c5b64-0a67-48a4-aaf9-0e7f5b3a1f86/messages)
        [[ "$FAKE_RUNTIME_FAIL_STAGE" != history ]] || exit 43
        count="$(cat "__STATE_FILE__" 2>/dev/null || printf 0)"
        printf 'GET history-%s\n' "$count" >> "__REQUEST_LOG__"
        if (( count <= 1 )); then
            cat <<'JSON'
[{"sequence":1,"type":"USER","messageJobId":"job-1","participantId":"live-uat","message":"我們目前支援哪些付款方式？請根據程式碼回答。"},{"sequence":2,"type":"ASSISTANT_TOOL_CALLS","messageJobId":"job-1","calls":[{"toolCallId":"catalog-call","toolName":"semantic_list_repositories","arguments":{}},{"toolCallId":"source-call","toolName":"semantic_search_code","arguments":{"repositoryId":"payment-service","revision":"payment-revision-42","query":"payment methods"}}]},{"sequence":3,"type":"TOOL","messageJobId":"job-1","toolCallId":"catalog-call","toolName":"semantic_list_repositories","output":{"isError":false,"result":{"items":[{"repositoryId":"payment-service","revision":"payment-revision-42"},{"repositoryId":"order-service","revision":"order-revision-7"}]}}},{"sequence":4,"type":"TOOL","messageJobId":"job-1","toolCallId":"source-call","toolName":"semantic_search_code","output":{"isError":false,"result":{"repositoryId":"payment-service","revision":"payment-revision-42","items":[{"source":{"code":"public PaymentMethod supported() { return CARD; }"}}]}}},{"sequence":5,"type":"ASSISTANT","messageJobId":"job-1","message":"程式碼顯示可用付款方式。"}]
JSON
        else
            cat <<'JSON'
[{"sequence":1,"type":"USER","messageJobId":"job-1","participantId":"live-uat","message":"我們目前支援哪些付款方式？請根據程式碼回答。"},{"sequence":2,"type":"ASSISTANT_TOOL_CALLS","messageJobId":"job-1","calls":[{"toolCallId":"catalog-call","toolName":"semantic_list_repositories","arguments":{}},{"toolCallId":"source-call","toolName":"semantic_search_code","arguments":{"repositoryId":"payment-service","revision":"payment-revision-42","query":"payment methods"}}]},{"sequence":3,"type":"TOOL","messageJobId":"job-1","toolCallId":"catalog-call","toolName":"semantic_list_repositories","output":{"isError":false,"result":{"items":[{"repositoryId":"payment-service","revision":"payment-revision-42"},{"repositoryId":"order-service","revision":"order-revision-7"}]}}},{"sequence":4,"type":"TOOL","messageJobId":"job-1","toolCallId":"source-call","toolName":"semantic_search_code","output":{"isError":false,"result":{"repositoryId":"payment-service","revision":"payment-revision-42","items":[{"source":{"code":"public PaymentMethod supported() { return CARD; }"}}]}}},{"sequence":5,"type":"ASSISTANT","messageJobId":"job-1","message":"程式碼顯示可用付款方式。"},{"sequence":6,"type":"USER","messageJobId":"job-2","participantId":"live-uat","message":"這些付款方式的手續費能否只看程式碼就確定？若不能，請說明缺少哪類執行期資料。"},{"sequence":7,"type":"ASSISTANT","messageJobId":"job-2","message":"無法僅由程式碼確定；還需要目前的費率設定。"}]
JSON
        fi ;;
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

SESSION_AGENT_LIVE=true run_runtime env > "$OUTPUT_LOG" 2>&1

grep -Fxq 'cross-service:complete' "$CALL_LOG"
grep -Fxq 'runtime-health:ready' "$CALL_LOG"
grep -Fxq 'semantic-catalog:available' "$CALL_LOG"
grep -Fq 'up -d --force-recreate --no-deps session-agent-runtime' "$CALL_LOG"
[[ "$(grep -Fc 'POST ' "$REQUEST_LOG")" == 2 ]]
grep -Fxq 'POST first-message' "$REQUEST_LOG"
grep -Fxq 'POST follow-up' "$REQUEST_LOG"
grep -Fxq 'GET job-1' "$REQUEST_LOG"
grep -Fxq 'GET job-2' "$REQUEST_LOG"
[[ "$(grep -Fc 'GET history-' "$REQUEST_LOG")" -ge 3 ]]

EVIDENCE_DIRECTORY="$(find "$FAKE_STARTER/.runtime/evidence/session-mcp-live" -mindepth 1 -maxdepth 1 -type d)"
[[ -n "$EVIDENCE_DIRECTORY" ]]
for evidence_file in deployment-record.txt session.json first-job.json second-job.json first-history.json final-history.json structural-report.txt; do
    [[ -f "$EVIDENCE_DIRECTORY/$evidence_file" ]] || { printf 'missing evidence file: %s\n' "$evidence_file" >&2; exit 1; }
    [[ "$(stat -c '%a' "$EVIDENCE_DIRECTORY/$evidence_file")" == 600 ]]
done
jq -e --arg session_id "$SESSION_ID" '.sessionId == $session_id and .sessionKey != "" and .firstJobId == "job-1" and .secondJobId == "job-2"' "$EVIDENCE_DIRECTORY/session.json" >/dev/null
jq -e 'length == 5 and .[1].type == "ASSISTANT_TOOL_CALLS" and .[3].output.isError == false and .[4].type == "ASSISTANT"' "$EVIDENCE_DIRECTORY/first-history.json" >/dev/null
jq -e --slurpfile first "$EVIDENCE_DIRECTORY/first-history.json" 'length == 7 and .[5].type == "USER" and .[6].type == "ASSISTANT" and (.[:5] == $first[0])' "$EVIDENCE_DIRECTORY/final-history.json" >/dev/null
grep -Fq 'result=pass' "$EVIDENCE_DIRECTORY/structural-report.txt"
! grep -R -Fq "$SECRET_KEY" "$EVIDENCE_DIRECTORY"
! grep -R -Fq "$SECRET_TOKEN" "$EVIDENCE_DIRECTORY"
! grep -Fq "$SECRET_KEY" "$OUTPUT_LOG"
! grep -Fq "$SECRET_TOKEN" "$OUTPUT_LOG"

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
