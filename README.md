# Java Agent Starter

Java Agent Starter runs a single-host UAT stack for three independently owned parts:

- Session Agent Runtime and its PostgreSQL database;
- Semantic Indexer, Semantic Query, and MongoDB;
- Starter scripts that stage source, build images, control Compose, create Git fixtures, and run acceptance.

Starter contains no Session Runtime or Semantic Java source. Cross-service ownership is summarized in [docs/roadmap.md](docs/roadmap.md).

## Requirements and first start

Install Git, Docker Engine with Compose v2, `jq`, `flock`, Maven, and Java 21. The live script currently uses `/usr/lib/jvm/java-21-openjdk-amd64`. Source Git credentials and a Google GenAI key are required when their configured remotes or live tests need them.

```bash
git clone git@github.com:ChouKevin/java-agent-starter.git
cd java-agent-starter
./deploy.sh
# Fill the required blank values in the generated .env, then run again.
./deploy.sh
```

`.env`, `.runtime/**`, generated fixture repositories, Compose data, evidence, and `deployment-record.txt` are local and untracked. Never commit credentials or runtime evidence.

Starter stages the configured Session and Semantic branches under `.runtime/sources/`. It resolves each remote branch first, clones to operation-owned `.staging.*` directories, validates both sources before promotion, and cleans those temporary directories on success or failure. `deployment-record.txt` records the exact source SHAs used for the deployment.

## Deployment modes

```bash
./deploy.sh                 # normal update; keep named database/workspace volumes
./deploy.sh schema-rebuild  # rebuild repository generations before updating Query
./deploy.sh reset           # disposable UAT reset; delete all named volumes
```

Every public mutating command takes `.runtime/deploy.lock` once for its complete operation. Sourced helpers do not take another lock. A second deploy, fixture change, or UAT run fails fast while the lock is held.

Before any deploy starts a new Indexer, Starter stops the existing Compose stack and verifies that no old Indexer remains. The stack has exactly one `semantic-indexer` service. Query is a separate Mongo-only service and Runtime can reach only Query, not the Indexer admin network.

`reset` is destructive and is only for the fixed disposable `java-agent-uat` project. It checks `SEMANTIC_DISPOSABLE_UAT=true`, prints a warning, removes the project's named volumes, recreates the `semantic_uat` database, publishes all configured repositories, proves Query works while Indexer is stopped, then restarts Indexer and Runtime. Never point this Compose file at production data.

## Deterministic Git fixtures

The source fixture files belong to Semantic under `semantic-indexer/fixtures/uat`. Starter copies that source into deterministic local bare repositories under `.runtime/uat-git/`; it does not copy fixture source into Session Runtime.

```bash
./fixture.sh prepare
./fixture.sh status
./fixture.sh use payment-service v2
./fixture.sh use payment-service v1
./fixture.sh reset payment-service
```

`prepare` creates payment, order, and video remotes with stable `v1` tags; payment also has `v2`. `use` changes only the selected remote's `main` ref. `reset` changes that repository back to peeled `v1`, submits a UAT `RESET` job, republishes it, and checks the exact revision. Fixture commands validate their repository/tag arguments and stay inside `.runtime/uat-git`.

## Live acceptance

Run the full functional proof with:

```bash
./runtime-uat.sh
```

One outer lock covers the whole run. The script:

1. exports the `uat` Semantic profile and performs a clean `deploy.sh reset`;
2. publishes payment, order, and video at exact `v1` commits;
3. records a repository catalog in one persisted Session conversation;
4. stops Indexer and exercises every Query tool family from MongoDB;
5. rebuilds payment at the same revision;
6. pauses payment `v2` before publication, proves `v1` stays visible, releases it, and checks exact `v2` plus typed `REVISION_OUTDATED` feedback for `v1`;
7. lets the model retry with `v2` in the same conversation and runs five business scenarios plus two Runtime contract scenarios;
8. resets payment to `v1` without changing order or video, then repeats the full `v1` to `v2` transition.

The five business scenarios cover payment methods, a runtime-only fee value, video formats, behavior absent from code, and an order cancellation flow whose refund behavior is not proven. Two additional Runtime scenarios verify model-selected recovery from an outdated revision and complete same-session history on a follow-up question.

Semantic evidence is under `.runtime/evidence/semantic-git-uat/`. The Session safe live report is under `.runtime/sources/session-agent-runtime/target/live-reports/`. Evidence contains IDs, revisions, generation IDs, state, tool order, outcomes, and available usage only. It must not contain credentials, source payloads, questions, prompts, raw model context, HTTP bodies, or full tool results.

## Add a repository

Add its Git `url` and `defaultBranch` to `config/semantic-repositories.yml`, then deploy and submit an ordinary ensure job:

```bash
./deploy.sh
./repository.sh list
./repository.sh ensure my-service
./repository.sh revision my-service
```

The returned revision is the exact value later Semantic queries must carry. Catalog membership alone does not index a repository. Keep private Git credentials only in `.env`.

## Inspect and clean the UAT stack

```bash
export STARTER_ROOT="$PWD"
alias uat='docker compose --project-name java-agent-uat --env-file .env -f compose.yaml'
uat ps
uat logs -f semantic-indexer semantic-query session-agent-runtime

# Destructive: remove only this disposable project's containers and named volumes.
uat --profile uat-evidence down --remove-orphans --volumes
```

Profile containers such as the model-egress canary are included in Starter teardown, so their containers and networks do not survive a reset.
