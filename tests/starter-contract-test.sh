#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"

bash -n "${ROOT}/deploy.sh"
bash -n "${ROOT}/repository.sh"
grep -q '^AGENT_GIT_REF=uat$' "${ROOT}/.env.example"
grep -q '^SEMANTIC_GIT_REF=uat$' "${ROOT}/.env.example"
grep -q 'java-system-agent:' "${ROOT}/config/semantic-repositories.yml"
grep -q '/v1/repositories/.*/ensure' "${ROOT}/repository.sh"
! grep -qE '^[[:space:]]+ports:' "${ROOT}/compose.yaml" \
    || [[ "$(grep -cE '^[[:space:]]+ports:' "${ROOT}/compose.yaml")" -eq 1 ]]

