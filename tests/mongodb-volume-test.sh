#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"

grep -Fq 'semantic-mongodb-data:' "${ROOT}/compose.yaml"
grep -Fq 'MONGO_INITDB_ROOT_USERNAME' "${ROOT}/compose.yaml"
grep -Fq 'semantic_bootstrap' "${ROOT}/compose.yaml"
grep -Fq 'semantic_query' "${ROOT}/compose.yaml"
grep -Fq 'semantic_indexer' "${ROOT}/compose.yaml"
grep -Fq 'semantic.schema-bootstrap=true' "${ROOT}/compose.yaml"
grep -Fq 'semantic-mongo-users' "${ROOT}/compose.yaml"
mongo_users_block="$(awk '/^  semantic-mongo-users:/{active=1} active && /^  [a-z].*:$/ && !/^  semantic-mongo-users:/{exit} active {print}' "${ROOT}/compose.yaml")"
[[ "${mongo_users_block}" == *'entrypoint: ["/bin/sh", "-ec"]'* ]]
[[ "${mongo_users_block}" == *'exec mongosh'* ]]
[[ "${mongo_users_block}" == *'"$SEMANTIC_MONGO_ROOT_USERNAME"'* ]]
grep -Fq 'run --rm semantic-mongo-users' "${ROOT}/deploy.sh"
grep -Fq 'run --rm semantic-mongo-init' "${ROOT}/deploy.sh"
grep -Fq 'semantic_bootstrap' "${ROOT}/config/mongo-init.js"
if rg -n 'semanticIndexerWrite.*(createCollection|createIndex)' "${ROOT}/config/mongo-init.js"; then
    printf 'Indexer writer unexpectedly has schema-maintenance privileges\n' >&2
    exit 1
fi
if rg -n 'rs\.initiate|replSet|transaction-manager|keyFile' "${ROOT}/compose.yaml" "${ROOT}/deploy.sh"; then
    printf 'standalone Mongo deployment unexpectedly enables replica-set machinery\n' >&2
    exit 1
fi
