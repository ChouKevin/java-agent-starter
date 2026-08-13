# Java Agent Starter

Single-host UAT/POC deployment for Java System Agent, Java Code Intelligence, and PostgreSQL.
Clone this repository and run one script; the Starter clones both service repositories at their
`uat` branches, builds the images, starts the stack, and verifies the private container connection.

Cross-service delivery order and acceptance ownership are defined in
[`docs/roadmap.md`](docs/roadmap.md).

Only Java Code Intelligence publishes a host port (`8080` by default). PostgreSQL and Java System
Agent remain on the private Docker network. This is plain HTTP for a trusted firewall/VPN only; do
not expose it to an untrusted network without a separate TLS and security design.

## Start

Requirements: Git, Docker Engine with Compose v2, and SSH access to the two GitHub repositories.
No manual environment value is required for the default `agent-runtime` smoke deployment.

```bash
git clone git@github.com:ChouKevin/java-agent-starter.git
cd java-agent-starter
./deploy.sh
```

On first run, `deploy.sh` creates `.env` with a random shared Semantic API token. It clones sources
under `.runtime/sources/`, builds both images, creates runtime directories, starts the services,
runs an authenticated Semantic API probe, and writes exact source SHAs to
`deployment-record.txt`. Later runs accept only clean checkouts on the configured branch and update
them by fast-forward; they never reset, rebase, overwrite, or discard local work.

### Agent-only prompt update

Prompt files under Java System Agent `src/main/resources/prompts/` are packaged in the Agent JAR
and loaded when the Agent starts. After merging a prompt-only Agent change to the configured branch,
run:

```bash
./deploy.sh --agent-only
```

This requires an already healthy, deployment-record-consistent stack. It fast-forwards and rebuilds
only Java System Agent, recreates only its container, and leaves PostgreSQL and Semantic Service
running. Use the default `./deploy.sh` for first deployment, Semantic or stack configuration changes,
or recovery from a degraded or inconsistent stack.

## M6 contract gate

Run `./contract-uat.sh` to deploy the selected service revisions and execute the revision-pinned
Semantic MCP and Agent HTTP contracts. The gate checks the selected Agent repository revision plus
the `m6-semantic-contract` local fixture and writes its manifest and JUnit reports under
`reports/contract-uat/<run-id>/`.

Set `SPRING_PROFILES_ACTIVE=slack-agent` and the Slack/model values in `.env` only when exercising
the complete Slack Agent. Slack Socket Mode is outbound, so Java System Agent still needs no
published inbound port.

## Knowledge acceptance

Run the default M7 scenario with `./knowledge-uat.sh`, or the payment scenario with
`./payment-uat.sh`. Each run reuses only a healthy active deployment and records the exact Starter,
Agent, and Semantic source SHAs from that deployment in `reports/knowledge-uat/<run-id>/`.

Knowledge acceptance resets the dedicated `agent_knowledge_live` database and isolated M7/payment
fixture volumes and JDT workspaces before running its selected test. The report directory receives
the selected JUnit XML and a manifest with the scenario, fixture revision, model, seed, and source
SHAs.

## Add a repository for analysis

1. Add an entry under `semantic.repositories` in
   `config/semantic-repositories.yml`. Keep credentials out of this file.
2. Run `./deploy.sh` so Semantic Service restarts with the updated catalog.
3. Explicitly clone the catalog entry and read its current revision:

```bash
./repository.sh list
./repository.sh ensure my-service
./repository.sh revision my-service
```

`ensure` requires Semantic Service to be running. Catalog membership alone never clones a source
repository. The returned `currentRevision` is the revision every subsequent semantic query must
carry. For private catalog repositories, set `GIT_USERNAME` and `GIT_TOKEN` in `.env`.

Example catalog entry:

```yaml
semantic:
  repositories:
    my-service:
      mode: REMOTE
      display-name: My Service
      url: https://github.com/example/my-service.git
      default-branch: main
```

## Operations

```bash
export STARTER_ROOT="$PWD"
alias uat='docker compose --project-name java-agent-uat --env-file .env -f compose.yaml'

uat ps
uat logs -f semantic-service
uat logs -f java-system-agent
```

Docker Compose logs use bounded `json-file` rotation; service restarts no longer depend on host log
ownership. Runtime clones, data, `.env`, backups, and the deployment record are intentionally
untracked. To test another service source, change its `*_GIT_URL` and `*_GIT_REF` values before the
first deploy or remove only its clean checkout under `.runtime/sources/`.
