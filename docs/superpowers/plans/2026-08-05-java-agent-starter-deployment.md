# Java Agent Starter Deployment Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `java-agent-starter` the sole UAT stack owner so an operator can clone it and run `./deploy.sh` to clone, build, and start Java System Agent, Java Code Intelligence, and PostgreSQL

**Architecture:** The starter repository owns Compose, environment generation, platform source synchronization, runtime directories, and operator helpers. Application sources are clean `uat` checkouts under `.runtime/sources`; deployment only fast-forwards them. Semantic business repositories remain declarative catalog entries and are prepared explicitly through the existing authenticated repository HTTP API

**Tech Stack:** Bash, Git, Docker Compose, PostgreSQL 17, existing application Dockerfiles, Semantic Service repository HTTP API

---

## File Map

### `java-agent-starter`

- Create: `.gitignore` — excludes secrets and all runtime state
- Create: `.env.example` — documents source, stack, cache, Git, Slack, and model settings
- Create: `AGENTS.md` — concise maintenance and safety rules
- Create: `CLAUDE.md` — direct `AGENTS.md` reference only
- Create: `config/semantic-repositories.yml` — default Java System Agent catalog entry
- Create: `compose.yaml` — owns the three-service UAT stack and one-shot helpers
- Create: `deploy.sh` — generates environment, safely synchronizes sources, deploys, probes, and records SHAs
- Create: `repository.sh` — authenticated list, ensure, and revision helper
- Create: `README.md` — complete operator workflow and repository onboarding
- Create: `tests/deploy-source-sync-test.sh` — protects clone, fast-forward, dirty-tree, and origin boundaries
- Create: `tests/repository-helper-test.sh` — protects helper availability and response behavior

### `java-system-agent`

- Modify: `README.md` — point stack operators to `java-agent-starter`
- Delete: `deploy/uat/.env.example`
- Delete: `deploy/uat/compose.yaml`
- Delete: `deploy/uat/deploy.sh`
- Delete: `deploy/uat/README.md`

No Java source, persistence contract, Semantic API, MCP contract, or application Dockerfile changes are part of this plan

---

### Task 1: Establish the starter repository contract

**Files:**
- Create: `.gitignore`
- Create: `.env.example`
- Create: `AGENTS.md`
- Create: `CLAUDE.md`
- Create: `config/semantic-repositories.yml`

- [ ] **Step 1: Add runtime and secret exclusions**

Create `.gitignore`:

```gitignore
.env
.runtime/
```

- [ ] **Step 2: Add the environment template**

Create `.env.example` with plain unquoted values because both the shell parser and Docker Compose consume it:

```dotenv
# Docker Compose interpolates this file. Write a literal $ as $$ in operator-supplied values.
# Platform source defaults. deploy.sh clones these branches beneath .runtime/sources.
AGENT_GIT_URL=git@github.com:ChouKevin/java-system-agent.git
AGENT_GIT_BRANCH=uat
SEMANTIC_GIT_URL=git@github.com:ChouKevin/java-code-intelligence.git
SEMANTIC_GIT_BRANCH=uat

# Generated automatically on first deploy. Existing values are never overwritten.
SEMANTIC_API_TOKEN=replace-with-generated-token

# Optional Semantic repository credentials for private catalog repositories.
GIT_USERNAME=
GIT_TOKEN=

# Optional UAT overrides.
SEMANTIC_HOST_PORT=8080
JDTLS_MAX_ACTIVE_WORKSPACES=2
# RepositorySyntax weight measures structural metadata, not source bytes.
# These defaults hold about two revisions near the size of java-system-agent.
REPOSITORY_SYNTAX_CACHE_MAXIMUM_WEIGHT=120000
REPOSITORY_SYNTAX_CACHE_MAXIMUM_ENTRY_WEIGHT=60000
POSTGRES_USER=agent
POSTGRES_DB=java_system_agent
POSTGRES_PASSWORD=poc-postgres-password
SPRING_PROFILES_ACTIVE=agent-runtime

# Required only for slack-agent or real model calls.
SLACK_APP_TOKEN=
SLACK_BOT_TOKEN=
SLACK_BOT_USER_ID=
GOOGLE_API_KEY=
GOOGLE_GENAI_MODEL=gemini-3.1-flash-lite
```

- [ ] **Step 3: Add the default repository catalog**

Create `config/semantic-repositories.yml`:

```yaml
semantic:
  repositories:
    java-system-agent:
      mode: REMOTE
      display-name: Java System Agent
      url: https://github.com/ChouKevin/java-system-agent.git
      default-branch: uat
```

- [ ] **Step 4: Add minimal agent-maintenance instructions**

Create `AGENTS.md`:

```markdown
# Repository Guidelines

This repository owns only the single-host Java Agent UAT deployment. Application behavior belongs
to `java-system-agent` and `java-code-intelligence`; do not duplicate application source here.

- Keep `deploy.sh` non-destructive: never reset, rebase, clean, stash, or overwrite a source checkout.
- Never commit `.env`, credentials, `.runtime`, repository clones, logs, data, or backups.
- Keep `compose.yaml` usable after a clean clone with only Git, Docker, Compose, and platform SSH access.
- Repository catalog membership does not imply automatic clone; use `repository.sh ensure <repoId>`.
- Preserve private PostgreSQL and Agent networking. Plain Semantic HTTP is trusted-network POC only.
- Validate shell with `bash -n`, run focused tests in `tests/`, and verify `docker compose config --quiet`.
- Use Conventional Commits.
```

Create `CLAUDE.md`:

```markdown
@AGENTS.md
```

- [ ] **Step 5: Verify committed files contain no generated secret or runtime state**

Run:

```bash
git status --short
git check-ignore .env .runtime/test
rg -n 'xox[baprs]-|AIza|gh[pousr]_' --glob '!docs/superpowers/**' .
```

Expected: `.env` and `.runtime/test` are ignored; the credential scan has no matches

- [ ] **Step 6: Commit the repository contract**

```bash
git add .gitignore .env.example AGENTS.md CLAUDE.md config/semantic-repositories.yml
git commit -m "chore: establish starter deployment contract"
```

---

### Task 2: Implement safe source synchronization and stack deployment

**Files:**
- Create: `tests/deploy-source-sync-test.sh`
- Create: `compose.yaml`
- Create: `deploy.sh`

- [ ] **Step 1: Write the source synchronization regression test**

Create `tests/deploy-source-sync-test.sh`. The test uses only temporary local Git repositories and sources `deploy.sh` without executing `main`:

```bash
#!/usr/bin/env bash
set -euo pipefail

TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "${TEST_ROOT}"' EXIT

STARTER_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
# shellcheck source=../deploy.sh
source "${STARTER_ROOT}/deploy.sh"

REMOTE="${TEST_ROOT}/remote.git"
SEED="${TEST_ROOT}/seed"
CHECKOUT="${TEST_ROOT}/checkout"

git init --bare "${REMOTE}" >/dev/null
git init "${SEED}" >/dev/null
git -C "${SEED}" config user.name test
git -C "${SEED}" config user.email test@example.invalid
printf 'one\n' > "${SEED}/version.txt"
git -C "${SEED}" add version.txt
git -C "${SEED}" commit -m one >/dev/null
git -C "${SEED}" branch -M uat
git -C "${SEED}" remote add origin "${REMOTE}"
git -C "${SEED}" push -u origin uat >/dev/null

sync_source "test" "${CHECKOUT}" "${REMOTE}" uat
[[ "$(cat "${CHECKOUT}/version.txt")" == "one" ]]

printf 'two\n' > "${SEED}/version.txt"
git -C "${SEED}" commit -am two >/dev/null
git -C "${SEED}" push >/dev/null
sync_source "test" "${CHECKOUT}" "${REMOTE}" uat
[[ "$(cat "${CHECKOUT}/version.txt")" == "two" ]]

printf 'dirty\n' >> "${CHECKOUT}/version.txt"
if (sync_source "test" "${CHECKOUT}" "${REMOTE}" uat) 2>"${TEST_ROOT}/dirty.err"; then
    printf 'expected dirty checkout rejection\n' >&2
    exit 1
fi
grep -q 'working tree is not clean' "${TEST_ROOT}/dirty.err"
git -C "${CHECKOUT}" restore version.txt

git -C "${CHECKOUT}" remote set-url origin "${TEST_ROOT}/other.git"
if (sync_source "test" "${CHECKOUT}" "${REMOTE}" uat) 2>"${TEST_ROOT}/origin.err"; then
    printf 'expected origin mismatch rejection\n' >&2
    exit 1
fi
grep -q 'origin URL does not match' "${TEST_ROOT}/origin.err"

printf 'deploy source synchronization tests passed\n'
```

- [ ] **Step 2: Run the test to verify RED**

```bash
bash tests/deploy-source-sync-test.sh
```

Expected: FAIL because `deploy.sh` does not exist

- [ ] **Step 3: Create the Compose stack**

Create `compose.yaml` by moving the proven UAT composition from Java System Agent and changing all source and bind paths to starter-owned relative paths:

```yaml
x-runtime-logging: &runtime-logging
  logging:
    driver: json-file
    options:
      max-size: "100m"
      max-file: "5"

services:
  postgres:
    <<: *runtime-logging
    image: postgres:17-alpine
    environment:
      POSTGRES_USER: ${POSTGRES_USER:-agent}
      POSTGRES_DB: ${POSTGRES_DB:-java_system_agent}
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD:-poc-postgres-password}
    volumes:
      - postgres-data:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U \"$$POSTGRES_USER\" -d \"$$POSTGRES_DB\""]
      interval: 10s
      timeout: 5s
      retries: 12
      start_period: 30s
    restart: unless-stopped
    deploy:
      resources:
        limits:
          cpus: "1.0"
          memory: 1G
    networks: [agent-network]

  semantic-service:
    <<: *runtime-logging
    image: java-code-intelligence:uat
    build:
      context: ./.runtime/sources/java-code-intelligence
    ports:
      - "${SEMANTIC_HOST_PORT:-8080}:8080"
    environment:
      SEMANTIC_API_TOKEN: ${SEMANTIC_API_TOKEN}
      GIT_USERNAME: ${GIT_USERNAME:-}
      GIT_TOKEN: ${GIT_TOKEN:-}
      JDTLS_MAX_ACTIVE_WORKSPACES: ${JDTLS_MAX_ACTIVE_WORKSPACES:-2}
      REPOSITORY_SYNTAX_CACHE_MAXIMUM_WEIGHT: ${REPOSITORY_SYNTAX_CACHE_MAXIMUM_WEIGHT:-120000}
      REPOSITORY_SYNTAX_CACHE_MAXIMUM_ENTRY_WEIGHT: ${REPOSITORY_SYNTAX_CACHE_MAXIMUM_ENTRY_WEIGHT:-60000}
      SPRING_CONFIG_ADDITIONAL_LOCATION: file:/config/semantic-repositories.yml
    volumes:
      - ./config/semantic-repositories.yml:/config/semantic-repositories.yml:ro
      - ./.runtime/data/repositories:/data/repos
      - ./.runtime/data/jdtls-workspaces:/data/jdtls
      - ./.runtime/logs/semantic:/app/logs
    restart: unless-stopped
    deploy:
      resources:
        limits:
          cpus: "4.0"
          memory: 6G
    networks: [agent-network]

  java-system-agent:
    <<: *runtime-logging
    image: java-system-agent:uat
    build:
      context: ./.runtime/sources/java-system-agent
    depends_on:
      postgres:
        condition: service_healthy
      semantic-service:
        condition: service_started
    environment:
      SPRING_PROFILES_ACTIVE: ${SPRING_PROFILES_ACTIVE:-agent-runtime}
      SPRING_DATASOURCE_URL: jdbc:postgresql://postgres:5432/${POSTGRES_DB:-java_system_agent}
      SPRING_DATASOURCE_USERNAME: ${POSTGRES_USER:-agent}
      SPRING_DATASOURCE_PASSWORD: ${POSTGRES_PASSWORD:-poc-postgres-password}
      CODEBASE_SERVICE_BASE_URL: http://semantic-service:8080
      CODEBASE_SERVICE_API_TOKEN: ${SEMANTIC_API_TOKEN}
      SLACK_APP_TOKEN: ${SLACK_APP_TOKEN:-}
      SLACK_BOT_TOKEN: ${SLACK_BOT_TOKEN:-}
      SLACK_BOT_USER_ID: ${SLACK_BOT_USER_ID:-}
      GOOGLE_API_KEY: ${GOOGLE_API_KEY:-poc-not-used}
      GOOGLE_GENAI_MODEL: ${GOOGLE_GENAI_MODEL:-gemini-3.1-flash-lite}
    volumes:
      - ./.runtime/logs/agent:/app/logs
    restart: unless-stopped
    stop_grace_period: 45s
    deploy:
      resources:
        limits:
          cpus: "2.0"
          memory: 2G
    networks: [agent-network]

  permissions-init:
    <<: *runtime-logging
    image: java-code-intelligence:uat
    profiles: [setup]
    user: "0:0"
    entrypoint: ["/bin/sh", "-ec"]
    command:
      - >-
        chown -R 10001:10001 /data/repos /data/jdtls /app/agent-logs /app/semantic-logs &&
        find /data/repos /data/jdtls -type d -exec chmod 0750 {} + &&
        find /app/agent-logs /app/semantic-logs -type d -exec chmod 0755 {} + &&
        find /app/agent-logs /app/semantic-logs -type f -exec chmod 0644 {} +
    volumes:
      - ./.runtime/data/repositories:/data/repos
      - ./.runtime/data/jdtls-workspaces:/data/jdtls
      - ./.runtime/logs/agent:/app/agent-logs
      - ./.runtime/logs/semantic:/app/semantic-logs
    restart: "no"
    networks: [agent-network]

  network-probe:
    <<: *runtime-logging
    image: curlimages/curl:8.12.1
    profiles: [tools]
    depends_on:
      semantic-service:
        condition: service_started
    environment:
      SEMANTIC_API_TOKEN: ${SEMANTIC_API_TOKEN}
    entrypoint: ["/bin/sh", "-ec"]
    command:
      - >-
        curl --fail --silent --show-error --retry 30 --retry-delay 2 --retry-max-time 120
        --retry-connrefused --connect-timeout 5 --max-time 10
        -H "X-Api-Token: $$SEMANTIC_API_TOKEN" http://semantic-service:8080/v1/repositories
    restart: "no"
    networks: [agent-network]

volumes:
  postgres-data:

networks:
  agent-network:
    driver: bridge
```

- [ ] **Step 4: Implement deployment orchestration**

Create `deploy.sh` with these exact public functions so the regression test can source it:

```bash
#!/usr/bin/env bash
set -euo pipefail

STARTER_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
RUNTIME_ROOT="${STARTER_ROOT}/.runtime"
ENV_FILE="${STARTER_ROOT}/.env"
CATALOG_FILE="${STARTER_ROOT}/config/semantic-repositories.yml"
STARTUP_WAIT_SECONDS=240

fail() {
    printf 'deploy: %s\n' "$*" >&2
    exit 1
}

read_env_value() {
    local key="$1"
    local fallback="$2"
    local line

    line="$(grep -E "^${key}=" "${ENV_FILE}" | tail -n 1 || true)"
    if [[ -z "${line}" || -z "${line#*=}" ]]; then
        printf '%s' "${fallback}"
        return
    fi
    printf '%s' "${line#*=}"
}

ensure_environment() {
    local token

    if [[ ! -e "${ENV_FILE}" ]]; then
        cp "${STARTER_ROOT}/.env.example" "${ENV_FILE}"
        token="$(od -An -N32 -tx1 /dev/urandom | tr -d ' \n')"
        sed -i "s/^SEMANTIC_API_TOKEN=.*/SEMANTIC_API_TOKEN=${token}/" "${ENV_FILE}"
        printf 'deploy: created %s with a generated Semantic API token\n' "${ENV_FILE}"
    fi
    chmod 0600 "${ENV_FILE}"
    token="$(read_env_value SEMANTIC_API_TOKEN '')"
    [[ -n "${token}" ]] || fail "SEMANTIC_API_TOKEN is missing or blank in ${ENV_FILE}"
    [[ "${token}" != replace-with-* ]] || fail "SEMANTIC_API_TOKEN still contains an example placeholder"
}

sync_source() {
    local label="$1"
    local checkout="$2"
    local url="$3"
    local branch="$4"
    local actual_url
    local actual_branch

    [[ -n "${url}" ]] || fail "${label} Git URL is blank"
    [[ -n "${branch}" ]] || fail "${label} Git branch is blank"
    if [[ ! -e "${checkout}" ]]; then
        git clone --branch "${branch}" --single-branch "${url}" "${checkout}"
        return
    fi
    [[ -d "${checkout}/.git" ]] || fail "${label} source path is not a Git checkout: ${checkout}"
    actual_url="$(git -C "${checkout}" remote get-url origin)"
    [[ "${actual_url}" == "${url}" ]] \
        || fail "${label} origin URL does not match: expected ${url}, found ${actual_url}"
    [[ -z "$(git -C "${checkout}" status --porcelain)" ]] \
        || fail "${label} working tree is not clean: ${checkout}"
    actual_branch="$(git -C "${checkout}" symbolic-ref --quiet --short HEAD || true)"
    [[ "${actual_branch}" == "${branch}" ]] \
        || fail "${label} checkout must be on branch ${branch}, found ${actual_branch:-detached HEAD}"
    git -C "${checkout}" fetch --prune origin \
        "refs/heads/${branch}:refs/remotes/origin/${branch}"
    git -C "${checkout}" merge --ff-only "origin/${branch}"
}

prepare_runtime() {
    mkdir -p \
        "${RUNTIME_ROOT}/sources" \
        "${RUNTIME_ROOT}/data/repositories" \
        "${RUNTIME_ROOT}/data/jdtls-workspaces" \
        "${RUNTIME_ROOT}/logs/agent" \
        "${RUNTIME_ROOT}/logs/semantic" \
        "${RUNTIME_ROOT}/backups"
    chmod 0755 "${RUNTIME_ROOT}/logs/agent" "${RUNTIME_ROOT}/logs/semantic"
    chmod 0700 "${RUNTIME_ROOT}/backups"
    [[ -s "${CATALOG_FILE}" ]] || fail "repository catalog is missing or empty: ${CATALOG_FILE}"
}

write_deployment_record() {
    local agent_root="${RUNTIME_ROOT}/sources/java-system-agent"
    local semantic_root="${RUNTIME_ROOT}/sources/java-code-intelligence"

    {
        printf 'deployment timestamp: %s\n' "$(date --iso-8601=seconds)"
        printf 'Agent branch: %s\n' "$(git -C "${agent_root}" branch --show-current)"
        printf 'Agent source SHA: %s\n' "$(git -C "${agent_root}" rev-parse HEAD)"
        printf 'Semantic branch: %s\n' "$(git -C "${semantic_root}" branch --show-current)"
        printf 'Semantic source SHA: %s\n' "$(git -C "${semantic_root}" rev-parse HEAD)"
    } > "${RUNTIME_ROOT}/deployment-record.txt"
}

main() {
    local agent_url
    local agent_branch
    local semantic_url
    local semantic_branch
    local -a compose

    command -v git >/dev/null 2>&1 || fail "git is required"
    command -v docker >/dev/null 2>&1 || fail "docker is required"
    docker compose version >/dev/null 2>&1 || fail "docker compose is required"

    ensure_environment
    prepare_runtime
    agent_url="$(read_env_value AGENT_GIT_URL 'git@github.com:ChouKevin/java-system-agent.git')"
    agent_branch="$(read_env_value AGENT_GIT_BRANCH uat)"
    semantic_url="$(read_env_value SEMANTIC_GIT_URL 'git@github.com:ChouKevin/java-code-intelligence.git')"
    semantic_branch="$(read_env_value SEMANTIC_GIT_BRANCH uat)"

    sync_source "Java System Agent" \
        "${RUNTIME_ROOT}/sources/java-system-agent" "${agent_url}" "${agent_branch}"
    sync_source "Java Code Intelligence" \
        "${RUNTIME_ROOT}/sources/java-code-intelligence" "${semantic_url}" "${semantic_branch}"

    compose=(
        docker compose
        --project-name java-agent-uat
        --env-file "${ENV_FILE}"
        -f "${STARTER_ROOT}/compose.yaml"
    )
    "${compose[@]}" config --quiet
    "${compose[@]}" build java-system-agent semantic-service
    "${compose[@]}" --profile setup run --rm permissions-init
    "${compose[@]}" up -d --wait --wait-timeout "${STARTUP_WAIT_SECONDS}"
    "${compose[@]}" --profile tools run --rm network-probe
    write_deployment_record
    printf 'deploy: stack started; revisions recorded in %s\n' \
        "${RUNTIME_ROOT}/deployment-record.txt"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
```

- [ ] **Step 5: Run focused tests and static validation**

```bash
chmod +x deploy.sh tests/deploy-source-sync-test.sh
bash -n deploy.sh tests/deploy-source-sync-test.sh
bash tests/deploy-source-sync-test.sh
cp .env.example .env
token="$(od -An -N32 -tx1 /dev/urandom | tr -d ' \n')"
sed -i "s/^SEMANTIC_API_TOKEN=.*/SEMANTIC_API_TOKEN=${token}/" .env
docker compose --project-name java-agent-uat --env-file .env -f compose.yaml config --quiet
rm .env
```

Expected: syntax, source synchronization, and Compose validation pass

- [ ] **Step 6: Commit deployment behavior**

```bash
git add compose.yaml deploy.sh tests/deploy-source-sync-test.sh
git commit -m "feat: deploy the Java Agent stack"
```

---

### Task 3: Add explicit Semantic repository operations

**Files:**
- Create: `tests/repository-helper-test.sh`
- Create: `repository.sh`

- [ ] **Step 1: Write the unavailable-service regression test**

Create `tests/repository-helper-test.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "${TEST_ROOT}"' EXIT
STARTER_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"

cp "${STARTER_ROOT}/repository.sh" "${TEST_ROOT}/repository.sh"
cat > "${TEST_ROOT}/.env" <<'EOF'
SEMANTIC_API_TOKEN=test-token
SEMANTIC_HOST_PORT=18080
EOF
chmod +x "${TEST_ROOT}/repository.sh"

if "${TEST_ROOT}/repository.sh" list >"${TEST_ROOT}/out" 2>"${TEST_ROOT}/err"; then
    printf 'expected unavailable service failure\n' >&2
    exit 1
fi
grep -q 'Semantic Service is unavailable' "${TEST_ROOT}/err"
grep -q 'run ./deploy.sh before repository operations' "${TEST_ROOT}/err"
printf 'repository helper unavailable-service test passed\n'
```

- [ ] **Step 2: Run the test to verify RED**

```bash
bash tests/repository-helper-test.sh
```

Expected: FAIL because `repository.sh` does not exist

- [ ] **Step 3: Implement the HTTP helper**

Create `repository.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

STARTER_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
ENV_FILE="${STARTER_ROOT}/.env"

fail() {
    printf 'repository: %s\n' "$*" >&2
    exit 1
}

read_env_value() {
    local key="$1"
    local fallback="$2"
    local line

    line="$(grep -E "^${key}=" "${ENV_FILE}" | tail -n 1 || true)"
    if [[ -z "${line}" || -z "${line#*=}" ]]; then
        printf '%s' "${fallback}"
        return
    fi
    printf '%s' "${line#*=}"
}

request() {
    local method="$1"
    local path="$2"

    curl --fail-with-body --silent --show-error \
        --request "${method}" \
        --header "@${HEADER_FILE}" \
        "${BASE_URL}${path}"
}

print_json() {
    if command -v jq >/dev/null 2>&1; then
        jq .
    else
        cat
        printf '\n'
    fi
}

[[ -s "${ENV_FILE}" ]] || fail ".env is missing; run ./deploy.sh first"
command -v curl >/dev/null 2>&1 || fail "curl is required"

TOKEN="$(read_env_value SEMANTIC_API_TOKEN '')"
PORT="$(read_env_value SEMANTIC_HOST_PORT 8080)"
[[ -n "${TOKEN}" ]] || fail "SEMANTIC_API_TOKEN is missing or blank"
BASE_URL="http://127.0.0.1:${PORT}"
HEADER_FILE="$(mktemp)"
trap 'rm -f "${HEADER_FILE}"' EXIT
chmod 0600 "${HEADER_FILE}"
printf 'X-Api-Token: %s\n' "${TOKEN}" > "${HEADER_FILE}"

if ! request GET /v1/repositories >/dev/null 2>&1; then
    printf 'repository: Semantic Service is unavailable\n' >&2
    printf 'run ./deploy.sh before repository operations\n' >&2
    exit 1
fi

COMMAND="${1:-}"
case "${COMMAND}" in
    list)
        request GET /v1/repositories | print_json
        ;;
    ensure|revision)
        REPO_ID="${2:-}"
        [[ "${REPO_ID}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] \
            || fail "a valid repoId is required"
        if [[ "${COMMAND}" == ensure ]]; then
            request POST "/v1/repositories/${REPO_ID}/ensure" | print_json
        else
            RESPONSE="$(request GET "/v1/repositories/${REPO_ID}")"
            REVISION="$(printf '%s' "${RESPONSE}" \
                | sed -nE 's/.*"currentRevision"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p')"
            [[ -n "${REVISION}" ]] \
                || fail "repository ${REPO_ID} has no current revision; run ./repository.sh ensure ${REPO_ID}"
            printf '%s\n' "${REVISION}"
        fi
        ;;
    *)
        fail "usage: ./repository.sh {list|ensure <repoId>|revision <repoId>}"
        ;;
esac
```

The temporary header file keeps the token out of command-line arguments. `jq` is optional and affects display only

- [ ] **Step 4: Run focused helper validation**

```bash
chmod +x repository.sh tests/repository-helper-test.sh
bash -n repository.sh tests/repository-helper-test.sh
bash tests/repository-helper-test.sh
```

Expected: PASS with the unavailable-service contract

- [ ] **Step 5: Commit the repository helper**

```bash
git add repository.sh tests/repository-helper-test.sh
git commit -m "feat: add Semantic repository operations"
```

---

### Task 4: Document first deployment and repository onboarding

**Files:**
- Create: `README.md`

- [ ] **Step 1: Write the operator guide**

Create `README.md` with these sections and exact operator commands:

```markdown
# Java Agent Starter

Single-host trusted-network UAT deployment for Java System Agent, Java Code Intelligence, and PostgreSQL.

## Prerequisites

- Git with SSH access to both ChouKevin application repositories
- Docker Engine
- Docker Compose v2
- `curl` for `repository.sh`

## First deployment

```bash
git clone git@github.com:ChouKevin/java-agent-starter.git
cd java-agent-starter
./deploy.sh
```

The first run creates `.env`, generates a Semantic API token, clones both `uat` branches beneath
`.runtime/sources`, builds both images, starts the stack, runs an authenticated probe, and records
the exact branches and SHAs in `.runtime/deployment-record.txt`.

Docker Compose interpolates `.env`; write a literal `$` in an operator-supplied value as `$$`.

Re-running `./deploy.sh` fast-forwards clean source checkouts. It stops without changing a checkout
when the origin differs, the branch differs, local changes exist, or a fast-forward is impossible.

## Optional integrations

Edit `.env` before enabling Slack or real model calls. `agent-runtime` starts without Slack and uses
the placeholder Google value only until a model call is attempted. Use `slack-agent` only after
setting `SLACK_APP_TOKEN`, `SLACK_BOT_TOKEN`, and the applicable model credentials.

Private repositories managed by Java Code Intelligence use `GIT_USERNAME` and `GIT_TOKEN`. These
credentials belong only in `.env`, never in the repository catalog.

## Add a business repository

Add an entry to `config/semantic-repositories.yml`:

```yaml
semantic:
  repositories:
    order-service:
      mode: REMOTE
      display-name: Order Service
      url: https://github.com/example/order-service.git
      default-branch: uat
```

Reload the catalog and prepare only the repository you need:

```bash
./deploy.sh
./repository.sh ensure order-service
./repository.sh revision order-service
```

`deploy.sh` must run before `repository.sh`. Catalog membership permits management but does not clone
every repository, keeping deployment time and disk usage independent of catalog size.

## Repository commands

```bash
./repository.sh list
./repository.sh ensure java-system-agent
./repository.sh revision java-system-agent
```

`ensure` returns `repoId`, branch, revision, and clone state. Every Semantic query must keep the
returned revision fixed through its follow-up sequence.

## Operations

```bash
docker compose --project-name java-agent-uat --env-file .env -f compose.yaml ps
docker compose --project-name java-agent-uat --env-file .env -f compose.yaml logs -f semantic-service
tail -f .runtime/logs/agent/application.log
tail -f .runtime/logs/semantic/application.log
docker compose --project-name java-agent-uat --env-file .env -f compose.yaml \
  --profile tools run --rm network-probe
```

Before a risky database or persistence change:

```bash
docker compose --project-name java-agent-uat --env-file .env -f compose.yaml \
  exec -T postgres sh -c 'pg_dump -U "$POSTGRES_USER" "$POSTGRES_DB"' \
  > ".runtime/backups/$(date +%F-%H%M%S).sql"
```

There is no scheduled backup or certified restore process in this POC.

## Network boundary

Only Java Code Intelligence publishes `${SEMANTIC_HOST_PORT:-8080}`. PostgreSQL and Java System
Agent remain private to the Compose network. Plain HTTP is acceptable only behind a trusted firewall
or VPN; public untrusted exposure requires a separate TLS and security design.

## Runtime ownership

`.runtime` contains application source checkouts, Semantic repository clones, JDT LS workspaces,
logs, backups, and the deployment record. `.env` and `.runtime` are gitignored. Removing either is
an explicit destructive operator action; deployment never deletes them automatically.
```

- [ ] **Step 2: Verify every supported command appears in documentation**

```bash
rg -n './deploy.sh|repository.sh list|repository.sh ensure|repository.sh revision|semantic-repositories.yml|trusted firewall' README.md
```

Expected: every expression has at least one match

- [ ] **Step 3: Commit operator documentation**

```bash
git add README.md
git commit -m "docs: explain starter deployment workflow"
```

---

### Task 5: Run the end-to-end Docker POC

**Files:**
- Runtime only: `.env`, `.runtime/**`

- [ ] **Step 1: Run all non-container validation**

```bash
bash -n deploy.sh repository.sh tests/*.sh
bash tests/deploy-source-sync-test.sh
bash tests/repository-helper-test.sh
```

Expected: PASS

- [ ] **Step 2: Deploy from the starter repository**

```bash
./deploy.sh
```

Expected:

- `.env` exists with mode `0600` and a non-placeholder token
- both `.runtime/sources/*` checkouts are clean `uat` branches
- PostgreSQL starts healthy
- Semantic Service and Java System Agent remain running
- the authenticated network probe succeeds
- `.runtime/deployment-record.txt` contains both exact SHAs

- [ ] **Step 3: Verify explicit repository lifecycle operations**

```bash
./repository.sh list
./repository.sh ensure java-system-agent
revision="$(./repository.sh revision java-system-agent)"
[[ "${revision}" =~ ^[0-9a-f]{40}$ ]]
```

Expected: catalog listing and ensure succeed; revision is a 40-character Git SHA

- [ ] **Step 4: Verify service status and startup logs**

```bash
docker compose --project-name java-agent-uat --env-file .env -f compose.yaml ps
logs="$(docker compose --project-name java-agent-uat --env-file .env -f compose.yaml \
  logs --tail=150 java-system-agent semantic-service)"
printf '%s\n' "${logs}" | rg 'java-system-agent.*Started Application'
printf '%s\n' "${logs}" | rg 'semantic-service.*Started Application'
if printf '%s\n' "${logs}" | rg -q 'APPLICATION FAILED|currently in creation'; then
  printf 'startup failure found in application logs\n' >&2
  exit 1
fi
```

Expected: both applications report successful startup, with no application failure or circular creation error

- [ ] **Step 5: Confirm generated state remains untracked**

```bash
git status --short
```

Expected: no `.env` or `.runtime` entries

Do not commit runtime state

---

### Task 6: Cut deployment ownership over from Java System Agent

**Files:**
- Modify: `/home/shuu/java-system-agent/README.md`
- Delete: `/home/shuu/java-system-agent/deploy/uat/.env.example`
- Delete: `/home/shuu/java-system-agent/deploy/uat/compose.yaml`
- Delete: `/home/shuu/java-system-agent/deploy/uat/deploy.sh`
- Delete: `/home/shuu/java-system-agent/deploy/uat/README.md`

- [ ] **Step 1: Add the maintained deployment pointer**

Add this section after the Java System Agent README introduction:

```markdown
## UAT Deployment

Single-host stack composition is owned by
[`java-agent-starter`](https://github.com/ChouKevin/java-agent-starter). Clone that repository and
run `./deploy.sh`; this application repository owns only its image build and runtime behavior.
```

- [ ] **Step 2: Remove the superseded deployment implementation**

```bash
rm -rf deploy/uat
```

- [ ] **Step 3: Verify no duplicate deployment owner remains**

```bash
test ! -e deploy/uat
rg -n 'java-agent-starter' README.md
rg -n 'UAT_DEPLOYMENT_ROOT|java-agent-uat|permissions-init|network-probe' \
  --glob '!docs/superpowers/**' . || true
```

Expected: `deploy/uat` is absent, README points to the starter, and no active duplicate stack composition remains

- [ ] **Step 4: Run documentation-only repository checks**

No Java behavior changed. Do not run the Maven suite solely for deleting deployment files and adding a README pointer

- [ ] **Step 5: Commit the Agent ownership cutover**

```bash
git add README.md deploy/uat
git commit -m "chore: move UAT deployment to starter repository"
```

---

### Task 7: Final acceptance and publication handoff

**Files:**
- No source changes expected

- [ ] **Step 1: Confirm both repositories are clean**

```bash
git -C /home/shuu/java-agent-starter status --short
git -C /home/shuu/java-system-agent status --short
```

Expected: no uncommitted task changes; unrelated pre-existing changes must be reported and left untouched

- [ ] **Step 2: Summarize deployed revisions and verification**

Report:

- starter commits created
- Agent ownership-cutover commit
- source synchronization test result
- repository helper test result
- Compose validation result
- Docker POC service status
- `repository.sh ensure/revision` result, treating `cloned` as current state rather than proof that this request performed a clone
- any retained trusted-network or backup limitations

- [ ] **Step 3: Ask before pushing**

Do not push either repository until the user explicitly approves publication. When approved, push the starter branch first so the Agent README never points to an unavailable deployment repository, then push the Agent branch
