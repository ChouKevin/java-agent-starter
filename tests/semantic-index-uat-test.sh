#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
UAT_SCRIPT="${ROOT}/semantic-index-uat.sh"

[[ -x "${UAT_SCRIPT}" ]]
grep -Fq 'STARTER_DEPLOY_LOCK_FD' "${UAT_SCRIPT}"
grep -Fq '"${ROOT}/deploy.sh" reset' "${UAT_SCRIPT}"
grep -Fq 'model-egress-canary' "${UAT_SCRIPT}"
grep -Fq 'REVISION_OUTDATED' "${UAT_SCRIPT}"
grep -Fq 'semantic-indexer-repository-data' "${UAT_SCRIPT}"
grep -Fq 'semantic-repository-data' "${UAT_SCRIPT}"
grep -Fq 'cf588ff' "${ROOT}/.env.example"
grep -Fq 'semantic-index-uat.sh' "${ROOT}/runtime-uat.sh"
grep -Fq 'SEMANTIC_UAT_PROFILE' "${ROOT}/compose.yaml"
grep -Fq 'SEMANTIC_UAT_PROFILE' "${ROOT}/README.md"
