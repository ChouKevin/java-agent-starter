# Java Agent Starter

Single-host UAT deployment for the externally published Session Agent Runtime,
Semantic Service, and the Runtime's dedicated PostgreSQL database. The Starter
contains no Runtime source: it owns source checkout, Compose lifecycle, probes,
and the deployment record only.

Cross-service ownership and acceptance milestones are in
[`docs/roadmap.md`](docs/roadmap.md).

## Start

Requirements: Git, Docker Engine with Compose v2, SSH access to the Runtime and
Semantic repositories, and a Google API key. Running `runtime-uat.sh` also
requires Maven and JDK 21 installed at `/usr/lib/jvm/java-21-openjdk-amd64`, the
path used by the script. On an initial deployment, let `deploy.sh` create `.env`
with local Semantic and PostgreSQL secrets. It stops until `GOOGLE_API_KEY` is
set; add that key to `.env` and rerun it.

```bash
git clone git@github.com:ChouKevin/java-agent-starter.git
cd java-agent-starter
./deploy.sh
# Set GOOGLE_API_KEY in the generated .env, then rerun.
./deploy.sh
```

`deploy.sh` clones the configured Runtime and Semantic sources under
`.runtime/sources/`, builds their images, initializes Runtime fixtures, starts
the stack, probes both services, and records exact source SHAs in
`deployment-record.txt`. Later runs accept only clean checkouts on the configured
branch and update them by fast-forward; they never reset, rebase, overwrite, or
discard local work.

The Runtime is published only on loopback port `8090` by default; Semantic is on
loopback port `8080`. This is plain HTTP for a trusted firewall/VPN only; do not
expose it to an untrusted network without a separate TLS and security design.

## Live acceptance

```bash
./runtime-uat.sh
```

`runtime-uat.sh` deploys first, then invokes only `SessionAgentLiveIT` from the
checked-out Runtime `pom.xml`. It derives loopback Runtime and Semantic URLs from
`SESSION_AGENT_HOST_PORT` and `SEMANTIC_HOST_PORT`, forwards the configured model,
and does not print secret values.

The Runtime owns the conversation and tool loop, citations, persistence, live
acceptance, and its dedicated database. It uses Semantic for repository/source
analysis and Google for model access. Slack values in `.env` are reserved
deployment inputs only; no Slack integration is implemented here.

## One-time legacy stack cutover

`deploy.sh` has no legacy compatibility mode. Before replacing an existing legacy
deployment, an operator must validate the current deployment record, healthy
services, and clean managed source checkouts. Then clone, fast-forward, render
Compose, and build replacement Runtime and Semantic images while the validated
stack remains running. Recheck that service rows and the deployment record have
not changed, then run:

```bash
docker compose --project-name java-agent-uat --env-file .env -f compose.yaml down --remove-orphans
./deploy.sh
./runtime-uat.sh
```

Do not pass `--volumes`: shutdown removes old containers and the project network,
but retains the old database volume for deliberate later disposal.

## Add a repository for analysis

1. Add an entry under `semantic.repositories` in
   `config/semantic-repositories.yml`. Keep credentials out of this file.
2. Run `./deploy.sh` so Semantic restarts with the updated catalog.
3. Explicitly clone the catalog entry and read its current revision:

```bash
./repository.sh list
./repository.sh ensure my-service
./repository.sh revision my-service
```

Catalog membership alone never clones a source repository. The returned
`currentRevision` is the revision every later Semantic query must carry. For
private catalog repositories, set `GIT_USERNAME` and `GIT_TOKEN` in `.env`.

## Operations

```bash
export STARTER_ROOT="$PWD"
alias uat='docker compose --project-name java-agent-uat --env-file .env -f compose.yaml'
uat ps
uat logs -f session-agent-runtime
uat logs -f semantic-service
```

Runtime checkouts, Compose data, `.env`, backups, and the deployment record are
intentionally untracked. To test another source revision, change its `*_GIT_URL`
or `*_GIT_REF` values before the first deploy or remove only its clean checkout
under `.runtime/sources/`.
