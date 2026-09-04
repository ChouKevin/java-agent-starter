#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
STARTER_SCRIPT_ROOT="${ROOT}"
TEMPORARY_DIRECTORY="$(mktemp -d)"
trap 'rm -rf "${TEMPORARY_DIRECTORY}"' EXIT

grep -Fq 'mktemp -d "${SOURCES_DIR}/.staging.XXXXXX"' "${ROOT}/deploy.sh"
if rg -n 'REQUIRED_RUNTIME_COMMIT|required compatible commit|merge-base --is-ancestor "\$\{required_commit\}"' "${ROOT}/deploy.sh"; then
    printf 'obsolete Runtime compatibility gate remains\n' >&2
    exit 1
fi
grep -Fq 'status --porcelain' "${ROOT}/deploy.sh"
grep -Fq 'RESET WILL DELETE ALL NAMED VOLUMES' "${ROOT}/deploy.sh"
grep -Fq 'with_deploy_lock' "${ROOT}/deploy.sh"
grep -Fq 'deploy_impl' "${ROOT}/deploy.sh"
grep -Fq 'repository_checkout_impl' "${ROOT}/repository.sh"
main_block="$(awk '/deploy_main\(\)/,/^}/' "${ROOT}/deploy.sh")"
grep -Fq 'with_deploy_lock deploy_impl' <<< "${main_block}"
lock_line="$(grep -n 'with_deploy_lock' <<< "${main_block}" | cut -d: -f1)"
[[ -n "${lock_line}" ]]
awk '/stop_existing_indexer\(\)/,/^}/' "${ROOT}/deploy.sh" | grep -Fq -- '--profile uat-evidence down --remove-orphans'
awk '/reset_deploy\(\)/,/^}/' "${ROOT}/deploy.sh" | grep -Fq -- '--profile uat-evidence down --remove-orphans --volumes'
if awk '/normal_deploy\(\)/,/^}/' "${ROOT}/deploy.sh" | rg -- '--volumes'; then
    printf 'normal deployment deletes volumes\n' >&2
    exit 1
fi

source "${STARTER_SCRIPT_ROOT}/deploy.sh"
DEPLOY_LOCK_FILE="${TEMPORARY_DIRECTORY}/public-deploy.lock"
ROOT="${TEMPORARY_DIRECTORY}"
deploy_impl() { touch "${TEMPORARY_DIRECTORY}/deploy-mutated"; }
(
    exec 9>"${DEPLOY_LOCK_FILE}"
    flock -n 9
    touch "${TEMPORARY_DIRECTORY}/deploy-lock-ready"
    sleep 1
) &
lock_holder=$!
while [[ ! -e "${TEMPORARY_DIRECTORY}/deploy-lock-ready" ]]; do sleep 0.01; done
if (deploy_main normal); then
    printf 'deploy bypassed the deployment lock\n' >&2
    exit 1
fi
[[ ! -e "${TEMPORARY_DIRECTORY}/deploy-mutated" ]]
wait "${lock_holder}"

make_remote() {
    local name="$1"
    git init --quiet --bare "${TEMPORARY_DIRECTORY}/${name}.git"
    git clone --quiet "${TEMPORARY_DIRECTORY}/${name}.git" "${TEMPORARY_DIRECTORY}/${name}-seed"
    git -C "${TEMPORARY_DIRECTORY}/${name}-seed" config user.email test@example.invalid
    git -C "${TEMPORARY_DIRECTORY}/${name}-seed" config user.name test
    touch "${TEMPORARY_DIRECTORY}/${name}-seed/${name}"
    if [[ "${name}" == semantic ]]; then
        mkdir -p "${TEMPORARY_DIRECTORY}/${name}-seed/semantic-indexer/fixtures/uat/payment-service" \
            "${TEMPORARY_DIRECTORY}/${name}-seed/semantic-indexer/fixtures/uat/order-service" \
            "${TEMPORARY_DIRECTORY}/${name}-seed/semantic-indexer/fixtures/uat/video-service"
        touch "${TEMPORARY_DIRECTORY}/${name}-seed/semantic-indexer/fixtures/uat/payment-service/pom.xml" \
            "${TEMPORARY_DIRECTORY}/${name}-seed/semantic-indexer/fixtures/uat/order-service/pom.xml" \
            "${TEMPORARY_DIRECTORY}/${name}-seed/semantic-indexer/fixtures/uat/video-service/pom.xml"
    fi
    git -C "${TEMPORARY_DIRECTORY}/${name}-seed" add .
    git -C "${TEMPORARY_DIRECTORY}/${name}-seed" commit --quiet -m initial
    git -C "${TEMPORARY_DIRECTORY}/${name}-seed" branch -M main
    git -C "${TEMPORARY_DIRECTORY}/${name}-seed" push --quiet origin main
    git --git-dir="${TEMPORARY_DIRECTORY}/${name}.git" symbolic-ref HEAD refs/heads/main
}

make_remote runtime
make_remote semantic
mkdir -p "${TEMPORARY_DIRECTORY}/sources"
source "${STARTER_SCRIPT_ROOT}/deploy.sh"
SOURCES_DIR="${TEMPORARY_DIRECTORY}/sources"
prepare_sources "${TEMPORARY_DIRECTORY}/runtime.git" main "${TEMPORARY_DIRECTORY}/semantic.git" main
runtime_before="$(git -C "${SOURCES_DIR}/session-agent-runtime" rev-parse HEAD)"
if find "${SOURCES_DIR}" -maxdepth 1 -type d -name '.staging.*' -print -quit | grep -q .; then
    printf 'successful source promotion left a staging directory behind\n' >&2
    exit 1
fi

printf 'dirty\n' > "${SOURCES_DIR}/session-agent-runtime/local-change.txt"
if (prepare_sources "${TEMPORARY_DIRECTORY}/runtime.git" main "${TEMPORARY_DIRECTORY}/semantic.git" main); then
    printf 'dirty managed source unexpectedly accepted an update\n' >&2
    exit 1
fi
rm "${SOURCES_DIR}/session-agent-runtime/local-change.txt"

git -C "${SOURCES_DIR}/session-agent-runtime" remote set-url origin "${TEMPORARY_DIRECTORY}/semantic.git"
if (prepare_sources "${TEMPORARY_DIRECTORY}/runtime.git" main "${TEMPORARY_DIRECTORY}/semantic.git" main); then
    printf 'managed source with a changed origin unexpectedly accepted an update\n' >&2
    exit 1
fi
git -C "${SOURCES_DIR}/session-agent-runtime" remote set-url origin "${TEMPORARY_DIRECTORY}/runtime.git"

if (prepare_sources "${TEMPORARY_DIRECTORY}/runtime.git" main "${TEMPORARY_DIRECTORY}/missing-semantic.git" main); then
    printf 'semantic source staging unexpectedly succeeded\n' >&2
    exit 1
fi
[[ "$(git -C "${SOURCES_DIR}/session-agent-runtime" rev-parse HEAD)" == "${runtime_before}" ]]
if find "${SOURCES_DIR}" -maxdepth 1 -type d -name '.staging.*' -print -quit | grep -q .; then
    printf 'failed source staging left a staging directory behind\n' >&2
    exit 1
fi

printf 'promotion blocker\n' > "${SOURCES_DIR}/session-agent-runtime.previous"
if bash -c 'source "$1/deploy.sh"; SOURCES_DIR="$2"; prepare_sources "$3" main "$4" main' \
    bash "${STARTER_SCRIPT_ROOT}" "${SOURCES_DIR}" "${TEMPORARY_DIRECTORY}/runtime.git" "${TEMPORARY_DIRECTORY}/semantic.git"; then
    printf 'source promotion unexpectedly succeeded with an occupied previous path\n' >&2
    exit 1
fi
[[ -d "${SOURCES_DIR}/session-agent-runtime/.git" ]]
[[ "$(git -C "${SOURCES_DIR}/session-agent-runtime" rev-parse HEAD)" == "${runtime_before}" ]]
[[ -f "${SOURCES_DIR}/session-agent-runtime.previous" ]]
if find "${SOURCES_DIR}" -maxdepth 1 -type d -name '.staging.*' -print -quit | grep -q .; then
    printf 'failed source promotion left a staging directory behind\n' >&2
    exit 1
fi
rm -f -- "${SOURCES_DIR}/session-agent-runtime.previous"

STARTER_CHECKOUT="${TEMPORARY_DIRECTORY}/starter"
mkdir -p "${STARTER_CHECKOUT}"
git -C "${STARTER_CHECKOUT}" init --quiet
git -C "${STARTER_CHECKOUT}" config user.email test@example.invalid
git -C "${STARTER_CHECKOUT}" config user.name test
touch "${STARTER_CHECKOUT}/starter"
git -C "${STARTER_CHECKOUT}" add starter
git -C "${STARTER_CHECKOUT}" commit --quiet -m initial
starter_sha="$(git -C "${STARTER_CHECKOUT}" rev-parse HEAD)"
DEPLOYMENT_RECORD_FILE="${TEMPORARY_DIRECTORY}/deployment-record.txt"
ROOT="${STARTER_CHECKOUT}"
write_deployment_record
grep -Fqx "Session Agent source SHA: ${DEPLOYMENT_RUNTIME_TARGET_SHA}" "${DEPLOYMENT_RECORD_FILE}"
grep -Fqx "Semantic source SHA: ${DEPLOYMENT_SEMANTIC_TARGET_SHA}" "${DEPLOYMENT_RECORD_FILE}"
grep -Fqx "Starter source SHA: ${starter_sha}" "${DEPLOYMENT_RECORD_FILE}"

ROOT="${TEMPORARY_DIRECTORY}/starter-without-git"
mkdir -p "${ROOT}"
DEPLOYMENT_RECORD_FILE="${TEMPORARY_DIRECTORY}/deployment-record-without-starter-git.txt"
write_deployment_record
grep -Fqx 'Starter source SHA: unavailable' "${DEPLOYMENT_RECORD_FILE}"
