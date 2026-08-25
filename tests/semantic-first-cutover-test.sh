#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"

grep -Fq "SEMANTIC_LEGACY_REF=366f870c269df27a22ab26e4becdc08359573ff1" "${ROOT}/.env.example"
grep -Fq 'prepare_legacy_cutover_image' "${ROOT}/deploy.sh"
grep -Fq 'checkout --detach' "${ROOT}/deploy.sh"
grep -Fq 'semantic-repository-data' "${ROOT}/compose.yaml"
grep -Fq 'semantic-indexer-repository-data' "${ROOT}/compose.yaml"
grep -Fq 'restart_legacy_on_query_failure' "${ROOT}/deploy.sh"
