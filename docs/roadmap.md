# Cross-Service Integration Roadmap

## Ownership

- **Session Agent Runtime:** conversation history, model/tool loop, feedback, PostgreSQL persistence, HTTP API, and live model scenarios.
- **Semantic:** repository catalog, exact Git indexing, JDT LS analysis, Mongo generations, and read-only source/query APIs.
- **Starter:** exact source staging, deterministic Git remotes, Compose lifecycle, deployment record, and cross-service UAT orchestration.

Starter must not add Runtime Java source, duplicate Semantic schemas, or implement conversation, model/tool-loop, index, or persistence behavior.

## Current UAT boundary

Starter deploys independent Runtime and Semantic source SHAs from `.runtime/sources/` and records the pair in `deployment-record.txt`. Runtime listens on loopback port `8090`; the Semantic Query gateway listens on loopback port `8080`; Indexer admin uses loopback port `8081`. Internal networks keep Runtime away from the Indexer admin path.

`cross-service-uat.sh` is the default no-model proof. It verifies one Indexer, Mongo-only Query, exact Git fixture revisions, authenticated `/api/v1` and `/mcp` access, Runtime startup while Semantic is unavailable, and later MCP discovery without recreating Runtime. `SESSION_AGENT_LIVE=true ./runtime-uat.sh` adds explicitly authorized model flows: indexed payment source, native paired tool history, Runtime recreation, preserved same-session history, runtime-only fee data, unsupported-business honesty, and an unrestricted JSON-array final reply. Local evidence is kept below `.runtime/evidence/` and is not committed.

## Acceptance rules

- Each deployment records immutable Runtime and Semantic source SHAs.
- Only one outer Starter operation owns the deployment lock.
- Semantic fixture source stays in Semantic; Starter creates only disposable Git remotes.
- Session has its own PostgreSQL data and never owns Semantic Git, JDT, Mongo, or fixture state.
- Normal deployment keeps named volumes; only explicit `reset` deletes the disposable UAT volumes.
- There is no legacy deployment or compatibility mode.

## Deferred

- Production TLS, secret-store, backup, and monitoring design beyond this single-host UAT.
- More than one Indexer process or distributed dispatcher ownership.
- Slack transport; current Slack environment values are reserved inputs only.
