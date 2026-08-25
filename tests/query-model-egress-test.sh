#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"

query_block="$(awk '/^  semantic-query:/{active=1} active && /^  [a-z].*:$/ && !/^  semantic-query:/{exit} active {print}' "${ROOT}/compose.yaml")"
[[ "${query_block}" == *'networks: [semantic-read]'* ]]
[[ "${query_block}" != *'GOOGLE_API_KEY'* ]]
[[ "${query_block}" != *'GIT_TOKEN'* ]]
[[ "${query_block}" != *'model-egress'* ]]
grep -Fq 'model-egress-canary:' "${ROOT}/compose.yaml"
grep -Fq 'semantic-indexer:' "${ROOT}/compose.yaml"
grep -Fq 'networks: [semantic-read, session-agent-network, model-egress]' "${ROOT}/compose.yaml"
