#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"

grep -Fq 'semantic-indexer:' "${ROOT}/compose.yaml"
grep -Fq 'semantic-query:' "${ROOT}/compose.yaml"
grep -Fq 'SEMANTIC_BASE_URL: http://semantic-query:8080' "${ROOT}/compose.yaml"
grep -Fq 'Dockerfile.indexer' "${ROOT}/compose.yaml"
grep -Fq 'Dockerfile.query' "${ROOT}/compose.yaml"
grep -Fq 'schema-bootstrap' "${ROOT}/compose.yaml"
grep -Fq 'ensure_all_repositories' "${ROOT}/deploy.sh"
grep -Fq 'wait_for_compatible_manifests' "${ROOT}/deploy.sh"
