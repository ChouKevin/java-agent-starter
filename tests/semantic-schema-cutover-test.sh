#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"

grep -Fq 'schema-rebuild)' "${ROOT}/deploy.sh"
grep -Fq 'record_current_pointers' "${ROOT}/deploy.sh"
grep -Fq 'rollback_rebuilt_repositories' "${ROOT}/deploy.sh"
grep -Fq 'expectedCurrent: $current[0], expectedRollback: $rollback[0]' "${ROOT}/deploy.sh"
grep -Fq '/index/repositories/${repository}/publication' "${ROOT}/deploy.sh"
grep -Fq 'expectedCurrent: $previous[0]' "${ROOT}/deploy.sh"
grep -Fq '.rollbackPointer == $previous[0]' "${ROOT}/deploy.sh"
grep -Fq '.currentPointer == $previous[0]' "${ROOT}/deploy.sh"
grep -Fq 'capture_query_image' "${ROOT}/deploy.sh"
grep -Fq 'restore_previous_query' "${ROOT}/deploy.sh"
grep -Fq 'recover_schema_rebuild' "${ROOT}/deploy.sh"
grep -Fq 'schema-rebuild requires compatible sealed manifests' "${ROOT}/deploy.sh"
main_block="$(awk '/main\(\)/,/^}/' "${ROOT}/deploy.sh")"
capture_line="$(grep -n 'capture_query_image' <<< "${main_block}" | tail -n1 | cut -d: -f1)"
build_line="$(grep -n 'build semantic-mongo-init' <<< "${main_block}" | cut -d: -f1)"
[[ -n "${capture_line}" && -n "${build_line}" && "${capture_line}" -lt "${build_line}" ]]
if awk '/normal_deploy\(\)/,/^}/' "${ROOT}/deploy.sh" | rg -- '--volumes'; then
    printf 'normal deploy must preserve volumes\n' >&2
    exit 1
fi
if awk '/schema_rebuild\(\)/,/^}/' "${ROOT}/deploy.sh" | rg -- '--volumes'; then
    printf 'schema rebuild must preserve volumes\n' >&2
    exit 1
fi
