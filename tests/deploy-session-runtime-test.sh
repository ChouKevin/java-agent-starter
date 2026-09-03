#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"

if rg -n 'REQUIRED_RUNTIME_COMMIT|required compatible commit' "${ROOT}/deploy.sh"; then
    printf 'obsolete Runtime compatibility gate remains\n' >&2
    exit 1
fi
grep -Fq 'stage_branch_source' "${ROOT}/deploy.sh"
grep -Fq 'poll_index_job' "${ROOT}/deploy.sh"
grep -Fq '/index/repositories/${repository}/jobs/${job_id}' "${ROOT}/deploy.sh"
grep -Fq '"${active}" == false' "${ROOT}/deploy.sh"
grep -Fq '"${phase}" == COMPLETE' "${ROOT}/deploy.sh"
grep -Fq 'normal_deploy()' "${ROOT}/deploy.sh"
grep -Fq 'reset_deploy()' "${ROOT}/deploy.sh"
grep -Fq 'fixture_prepare_impl' "${ROOT}/deploy.sh"
grep -Fq 'stop_existing_indexer' "${ROOT}/deploy.sh"
if awk '/normal_deploy\(\)/,/^}/' "${ROOT}/deploy.sh" | rg -- 'down|--volumes'; then
    printf 'normal deploy must not tear down volumes\n' >&2
    exit 1
fi
