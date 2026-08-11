#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
KNOWLEDGE_SCENARIO=payment exec "${ROOT}/knowledge-uat.sh" "$@"
