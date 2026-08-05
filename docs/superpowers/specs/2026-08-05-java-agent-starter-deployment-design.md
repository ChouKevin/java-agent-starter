# Java Agent Starter Deployment Design

## 1. Goal

`java-agent-starter` owns the single-host UAT deployment of Java System Agent, Java Code Intelligence, and PostgreSQL

An operator clones only this repository and runs `./deploy.sh`. The script prepares configuration, clones both application sources, builds the images, starts the stack, verifies Semantic Service connectivity, and records the deployed revisions

Deployment files are removed from `java-system-agent` after this cutover. Application repositories continue to own their Dockerfiles and application behavior; they do not own stack composition

## 2. Scope

This milestone includes:

- source checkout and safe fast-forward updates for both application repositories
- Docker Compose ownership for PostgreSQL, Java Code Intelligence, and Java System Agent
- automatic first-run environment creation and Semantic API token generation
- persistent runtime directories, logs, backups, and deployment records
- a declarative Semantic repository catalog
- repository lifecycle helper commands for list, ensure, and revision
- operator documentation for first deployment, repository onboarding, diagnostics, and trusted-network constraints
- removal of the superseded `deploy/uat` implementation from Java System Agent

This milestone does not include:

- production TLS or public-internet hardening
- a container registry or prebuilt image release process
- multi-host orchestration
- automatic checkout of every business repository in the Semantic catalog
- destructive source synchronization such as reset, rebase, or forced checkout
- scheduled backup or certified restore automation

## 3. Repository Layout

The committed starter repository has this structure:

```text
java-agent-starter/
|-- deploy.sh
|-- repository.sh
|-- compose.yaml
|-- .env.example
|-- .gitignore
|-- README.md
|-- config/
|   `-- semantic-repositories.yml
`-- docs/
    `-- superpowers/
        `-- specs/
```

Runtime state is created beneath a gitignored `.runtime` directory:

```text
.runtime/
|-- sources/
|   |-- java-system-agent/
|   `-- java-code-intelligence/
|-- data/
|   |-- repositories/
|   `-- jdtls-workspaces/
|-- logs/
|   |-- agent/
|   `-- semantic/
|-- backups/
`-- deployment-record.txt
```

The starter root is the deployment root. No external directory layout or `UAT_DEPLOYMENT_ROOT` setting is required

## 4. Source Ownership and Synchronization

The default platform sources are:

| Component | Git URL | Branch |
| --- | --- | --- |
| Java System Agent | `git@github.com:ChouKevin/java-system-agent.git` | `uat` |
| Java Code Intelligence | `git@github.com:ChouKevin/java-code-intelligence.git` | `uat` |

The URLs and branches may be overridden in `.env`. The first version supports branches only; tag and commit-SHA deployment modes are out of scope

For each source, `deploy.sh` follows one safe synchronization algorithm:

1. Clone the configured branch when the checkout is absent
2. Verify the configured origin URL when the checkout exists
3. Require the working tree and index to be clean
4. Require the checkout to be on the configured branch
5. Fetch the configured branch from origin
6. Fast-forward the local branch with `merge --ff-only`

A URL mismatch, dirty checkout, wrong branch, or non-fast-forward history stops deployment before Docker build. The script never resets, rebases, cleans, stashes, or overwrites application sources

The user's host SSH configuration authenticates platform source clones. Credentials used by Java Code Intelligence to clone catalog repositories remain separate Semantic Service environment values

## 5. Environment Contract

When `.env` does not exist, `deploy.sh` copies `.env.example`, generates a cryptographically random `SEMANTIC_API_TOKEN`, and sets mode `0600`

When `.env` exists, the script preserves it. It validates required values without sourcing the file as shell code

The example exposes optional overrides for:

- platform Git URLs and `uat` branches
- Semantic host port
- JDT LS workspace limit
- repository syntax cache weights
- PostgreSQL database settings
- Agent profile
- Semantic repository Git credentials
- Slack and Google credentials

PostgreSQL POC defaults and `agent-runtime` allow the stack to start without Slack or model credentials. `slack-agent` and actual model calls require their corresponding values

## 6. Deployment Flow

`./deploy.sh` performs these operations in order:

1. Validate Docker and Docker Compose availability
2. Create or validate `.env`
3. Safely synchronize both platform source checkouts
4. Create runtime data, workspace, log, and backup directories
5. Validate the committed repository catalog
6. Build the Agent and Semantic Service images from `.runtime/sources`
7. Run the permission initializer for bind-mounted directories
8. Start PostgreSQL, Semantic Service, and Agent with a bounded wait
9. Run an authenticated private-network Semantic repository probe
10. Write the deployment timestamp, branch, and SHA of both application sources to `.runtime/deployment-record.txt`

Failure preserves source checkouts, logs, containers, database data, Semantic repository clones, and JDT LS workspaces for diagnosis. The script does not automatically tear down or delete state

Re-running `deploy.sh` is the supported update operation. It safely fast-forwards clean source checkouts, rebuilds changed images using Docker cache, and reconciles the Compose stack

## 7. Compose Boundary

The Compose stack contains:

- PostgreSQL with a named data volume and readiness healthcheck
- Java Code Intelligence built from its source checkout
- Java System Agent built from its source checkout
- a one-shot permission initializer
- a one-shot authenticated Semantic network probe

Only Semantic Service port `8080` is published by default. PostgreSQL and Java System Agent remain private to the Compose network. Java System Agent reaches Semantic Service through `http://semantic-service:8080`

Plain HTTP is restricted to a trusted firewall or VPN. Public untrusted exposure requires a separate TLS and security design

## 8. Semantic Repository Catalog

The starter commits `config/semantic-repositories.yml`. Its default entry permits Java Code Intelligence to manage Java System Agent from the `uat` branch:

```yaml
semantic:
  repositories:
    java-system-agent:
      mode: REMOTE
      display-name: Java System Agent
      url: https://github.com/ChouKevin/java-system-agent.git
      default-branch: uat
```

Operators add business repositories declaratively:

```yaml
semantic:
  repositories:
    order-service:
      mode: REMOTE
      display-name: Order Service
      url: https://github.com/example/order-service.git
      default-branch: uat
```

Catalog membership authorizes repository management but does not clone every repository during deployment. This keeps deployment time, disk usage, and JDT LS resource demand independent of catalog size

After editing the catalog, the operator reruns `./deploy.sh` so Semantic Service starts with the new configuration, then explicitly ensures the required repository

## 9. Repository Helper

`repository.sh` is an authenticated operator adapter for Semantic Service repository lifecycle APIs. It does not start or deploy services

Supported commands are:

```bash
./repository.sh list
./repository.sh ensure <repoId>
./repository.sh revision <repoId>
```

The helper reads the Semantic host port and token from `.env` without executing the file. Before every operation it checks service availability. When Semantic Service is unavailable it exits nonzero with:

```text
repository: Semantic Service is unavailable
run ./deploy.sh before repository operations
```

`ensure` invokes the Semantic checkout API and reports repository ID, branch, revision, and current clone state. The existing `cloned` field does not claim that cloning occurred during this specific request. `revision` reports the current revision needed by revision-pinned Semantic HTTP and MCP queries

## 10. Documentation

`README.md` documents:

- prerequisites: Git, Docker, Docker Compose, and host SSH access to both platform repositories
- one-command first deployment
- generated `.env` behavior and optional credentials
- source update safety and failure messages
- catalog entry examples
- the requirement to deploy before using `repository.sh`
- repository list, ensure, and revision examples
- Compose status, application logs, network probe, and manual backup commands
- trusted-network HTTP limitations
- runtime directory ownership and cleanup implications

Java System Agent removes `deploy/uat`. A short handoff in its maintained documentation points operators to `git@github.com:ChouKevin/java-agent-starter.git` and states that stack composition is no longer owned by the Agent repository

## 11. Error Contract

Errors use a stable `<component>: <message>` prefix and exit nonzero

Deployment stops before source mutation or build when:

- Docker or Docker Compose is missing
- `.env` is malformed or a required value is blank
- a checkout has a mismatched origin URL
- a checkout is dirty or on the wrong branch
- a fast-forward update is impossible
- the repository catalog is missing or empty

Build, startup, health, and network-probe failures preserve diagnostic state and print the exact follow-up log command. Repository helper failures distinguish service unavailability, unknown catalog repository, checkout failure, and revision resolution failure without exposing credentials

## 12. Verification

The implementation uses the smallest tests that protect deployment boundaries:

- `bash -n` for both scripts
- focused shell scenarios for first clone, clean fast-forward, dirty-checkout rejection, origin mismatch, and missing Semantic Service
- `docker compose config --quiet` with generated POC settings
- a Docker POC that starts all three services and passes the authenticated Semantic probe
- `repository.sh list`, `ensure java-system-agent`, and `revision java-system-agent`

The implementation does not add exhaustive shell branch tests. Application behavior remains covered by each application repository

## 13. Acceptance Criteria

The milestone is complete when:

1. A clean machine with Git, Docker, Compose, and GitHub SSH access can clone `java-agent-starter` and run `./deploy.sh` without manually cloning application repositories
2. First deployment creates `.env`, generates a non-placeholder token, clones both `uat` branches, and starts the stack
3. Re-running deployment fast-forwards clean checkouts and rejects local modifications without changing them
4. PostgreSQL and Agent remain private while Semantic Service is reachable on the configured host port
5. The authenticated network probe succeeds
6. Adding a catalog entry, rerunning deployment, and invoking `repository.sh ensure <repoId>` prepares that repository for Semantic queries
7. `repository.sh revision <repoId>` returns the revision required for follow-up queries
8. The deployment record contains both application branches and exact SHAs
9. Java System Agent no longer owns duplicate Compose, environment, or deployment scripts
