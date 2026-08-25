#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"

grep -Fq 'schema-rebuild)' "${ROOT}/deploy.sh"
grep -Fq 'record_current_pointers' "${ROOT}/deploy.sh"
grep -Fq 'rollback_rebuilt_repositories' "${ROOT}/deploy.sh"
grep -Fq 'expectedCurrent: $current[0], expectedRollback: $rollback[0]' "${ROOT}/deploy.sh"
grep -Fq 'currentPointer // error' "${ROOT}/deploy.sh"
grep -Fq 'schema-rebuild requires compatible sealed manifests' "${ROOT}/deploy.sh"
if awk '/normal_deploy\(\)/,/^}/' "${ROOT}/deploy.sh" | rg -- '--volumes'; then
    printf 'normal deploy must preserve volumes\n' >&2
    exit 1
fi
if awk '/schema_rebuild\(\)/,/^}/' "${ROOT}/deploy.sh" | rg -- '--volumes'; then
    printf 'schema rebuild must preserve volumes\n' >&2
    exit 1
fi
