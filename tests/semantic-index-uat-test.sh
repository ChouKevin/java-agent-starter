#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
UAT_SCRIPT="${ROOT}/semantic-index-uat.sh"

[[ -x "${UAT_SCRIPT}" ]]
grep -Fq 'semantic_index_uat_impl' "${UAT_SCRIPT}"
grep -Fq 'deploy_impl reset' "${UAT_SCRIPT}"
grep -Fq 'model-egress-canary' "${UAT_SCRIPT}"
grep -Fq 'REVISION_OUTDATED' "${UAT_SCRIPT}"
grep -Fq 'semantic-indexer-repository-data' "${UAT_SCRIPT}"
grep -Fq 'semantic-repository-data' "${UAT_SCRIPT}"
grep -Fq 'cf588ff' "${ROOT}/.env.example"
grep -Fq 'semantic-index-uat.sh' "${ROOT}/runtime-uat.sh"
grep -Fq 'SEMANTIC_UAT_PROFILE' "${ROOT}/compose.yaml"
grep -Fq 'SEMANTIC_UAT_PROFILE' "${ROOT}/README.md"

TEMPORARY_DIRECTORY="$(mktemp -d)"
trap 'rm -rf "${TEMPORARY_DIRECTORY}"' EXIT
source "${UAT_SCRIPT}"
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
