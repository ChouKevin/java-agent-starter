#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"

bash -n "${ROOT}/deploy.sh"
bash -n "${ROOT}/repository.sh"
bash -c 'source "$1"; declare -F classify_compose_rows preflight_active_deployment >/dev/null' bash "${ROOT}/deploy.sh"
grep -Fq 'if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then' "${ROOT}/deploy.sh"
grep -Fq 'ps --all --format' "${ROOT}/deploy.sh"
grep -q '^AGENT_GIT_REF=uat$' "${ROOT}/.env.example"
grep -q '^SEMANTIC_GIT_REF=uat$' "${ROOT}/.env.example"
grep -q 'java-system-agent:' "${ROOT}/config/semantic-repositories.yml"
grep -q '/v1/repositories/.*/ensure' "${ROOT}/repository.sh"
! grep -qE '^[[:space:]]+ports:' "${ROOT}/compose.yaml" \
    || [[ "$(grep -cE '^[[:space:]]+ports:' "${ROOT}/compose.yaml")" -eq 1 ]]
