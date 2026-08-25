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

> **Warning — disposable UAT:** Every `./deploy.sh` invocation (including the
> deployment performed by `./runtime-uat.sh`) removes the fixed
> `java-agent-uat` Compose project's PostgreSQL, payment fixture, order fixture,
> Semantic repository cache, and JDT workspace cache volumes. Never point
> Starter at live or production data.

`./deploy.sh` rebuilds and recreates the disposable UAT project. It stages the
configured Runtime and Semantic sources under `.runtime/sources/`, builds both
images, removes the existing project and its volumes, initializes the Runtime
fixtures, starts PostgreSQL, then verifies Semantic before starting and probing
Runtime. It records the exact Runtime and Semantic source SHAs in
`deployment-record.txt`.

The Runtime and Semantic checkouts are one deployment pair. Later runs accept
only clean checkouts on the configured branches and advance them by
fast-forward; the recorded SHAs identify the exact pair used by that UAT run.
Source staging is validated before either checkout is promoted.

The Runtime target must contain
`a78f1df8f2d4a4dc2e0ea7d80a5d4260f93053ee`, which switches its Semantic
authentication to `X-Api-Token`. The default remote `main` currently does not
contain that commit, so deployment safely stops before changing either managed
checkout or the Compose project until the commit is integrated. For local UAT,
set `SESSION_AGENT_GIT_URL=/home/shuu/session-agent-runtime` in `.env`; that
checkout currently contains the required commit.

If a deployment fails after the existing project has been reset, it may leave a
partial project. The supported recovery is to rerun `./deploy.sh` from the
beginning; no alternate recovery procedure is supported.

The Runtime is published only on loopback port `8090` by default; Semantic is on
loopback port `8080`. This is plain HTTP for a trusted firewall/VPN only; do not
expose it to an untrusted network without a separate TLS and security design.

## Live acceptance

```bash
./runtime-uat.sh
```

`./runtime-uat.sh` performs the same disposable deployment first, then runs the
bounded external `SessionAgentLiveIT` selected from the checked-out Runtime
`pom.xml`. It derives loopback Runtime and Semantic URLs from
`SESSION_AGENT_HOST_PORT` and `SEMANTIC_HOST_PORT`, forwards the Semantic token,
Google key, and configured model through the process environment, and does not
print their values. This documents what the command does; it does not claim that
LiveIT has run or succeeded.

The Runtime's public pre-success probe is health-only; its existing public
Semantic calls occur through the conversation/tool flow and can require model
execution. Starter therefore cannot add a model-independent Runtime-to-Semantic
authenticated success operation without changing Runtime. The existing
authenticated Semantic probe and the required Runtime commit gate are the UAT
checks before LiveIT; the Runtime-to-Semantic operation remains covered by
LiveIT.

Before `SessionAgentLiveIT`, the command runs `semantic-index-uat.sh` exactly
once while retaining the same deployment lock. That acceptance explicitly
resets only disposable UAT data, starts the Indexer UAT profile
(`SEMANTIC_UAT_PROFILE=uat`) for its pre-publication pause control, and leaves
the final cold Query/MongoDB state available to LiveIT. The UAT profile is
empty by default and is not enabled by normal deployments.

The Runtime owns the conversation and tool loop, citations, persistence, live
acceptance, and its dedicated database. It uses Semantic for repository/source
analysis and Google for model access. Slack values in `.env` are reserved
deployment inputs only; no Slack integration is implemented here.

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

Runtime checkouts, Compose data, `.env`, and the deployment record are
intentionally untracked. To test another source revision, change its `*_GIT_URL`
or `*_GIT_REF` values before the first deploy or remove only its clean checkout
under `.runtime/sources/`.
