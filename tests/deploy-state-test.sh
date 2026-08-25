#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
TEMPORARY_DIRECTORY="$(mktemp -d)"
trap 'rm -rf "${TEMPORARY_DIRECTORY}"' EXIT

grep -Fq 'mktemp -d "${SOURCES_DIR}/.staging.XXXXXX"' "${ROOT}/deploy.sh"
grep -Fq 'merge-base --is-ancestor "${required_commit}" "${target}"' "${ROOT}/deploy.sh"
grep -Fq 'status --porcelain' "${ROOT}/deploy.sh"
grep -Fq 'RESET WILL DELETE ALL NAMED VOLUMES' "${ROOT}/deploy.sh"
awk '/reset_deploy\(\)/,/^}/' "${ROOT}/deploy.sh" | grep -Fq 'down --remove-orphans --volumes'
if awk '/normal_deploy\(\)/,/^}/' "${ROOT}/deploy.sh" | rg -- '--volumes'; then
    printf 'normal deployment deletes volumes\n' >&2
    exit 1
fi

make_remote() {
    local name="$1"
    git init --quiet --bare "${TEMPORARY_DIRECTORY}/${name}.git"
    git clone --quiet "${TEMPORARY_DIRECTORY}/${name}.git" "${TEMPORARY_DIRECTORY}/${name}-seed"
    git -C "${TEMPORARY_DIRECTORY}/${name}-seed" config user.email test@example.invalid
    git -C "${TEMPORARY_DIRECTORY}/${name}-seed" config user.name test
    touch "${TEMPORARY_DIRECTORY}/${name}-seed/${name}"
    if [[ "${name}" == semantic ]]; then
        mkdir -p "${TEMPORARY_DIRECTORY}/${name}-seed/fixtures/uat/payment-service" \
            "${TEMPORARY_DIRECTORY}/${name}-seed/fixtures/uat/order-service" \
            "${TEMPORARY_DIRECTORY}/${name}-seed/fixtures/uat/video-service"
        touch "${TEMPORARY_DIRECTORY}/${name}-seed/fixtures/uat/payment-service/pom.xml" \
            "${TEMPORARY_DIRECTORY}/${name}-seed/fixtures/uat/order-service/pom.xml" \
            "${TEMPORARY_DIRECTORY}/${name}-seed/fixtures/uat/video-service/pom.xml"
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
source "${ROOT}/deploy.sh"
SOURCES_DIR="${TEMPORARY_DIRECTORY}/sources"
REQUIRED_RUNTIME_COMMIT=""
prepare_sources "${TEMPORARY_DIRECTORY}/runtime.git" main "${TEMPORARY_DIRECTORY}/semantic.git" main
runtime_before="$(git -C "${SOURCES_DIR}/session-agent-runtime" rev-parse HEAD)"

if (prepare_sources "${TEMPORARY_DIRECTORY}/runtime.git" main "${TEMPORARY_DIRECTORY}/missing-semantic.git" main); then
    printf 'semantic source staging unexpectedly succeeded\n' >&2
    exit 1
fi
[[ "$(git -C "${SOURCES_DIR}/session-agent-runtime" rev-parse HEAD)" == "${runtime_before}" ]]
