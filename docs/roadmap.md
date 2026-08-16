# Cross-Service Integration Roadmap

This roadmap records ownership and acceptance boundaries for the Session Agent
Runtime, Semantic Service, and Starter composition. Repository-internal design
and implementation remain in the repository that owns the behavior.

## Ownership

- Session Agent Runtime: conversation, tool loop, citations, persistence, live acceptance
- Semantic: repository catalog and source analysis APIs
- Starter: source checkout, Compose lifecycle, health/smoke orchestration, deployment record

The Runtime owns its dedicated PostgreSQL database and consumes Semantic through
its network API. The Starter must not add Runtime Java source, duplicate Semantic
schemas, or implement conversation, tool, citation, or persistence behavior.

## Runtime cutover

**Status:** In progress

Starter deploys independent Runtime and Semantic checkouts from
`.runtime/sources/`, records their exact SHAs, and keeps both host ports on
loopback by default: Runtime `8090`, Semantic `8080`. Compose fixture setup and
network probes are Starter operational concerns, not Runtime product source.

Live acceptance belongs to the Runtime repository. Starter invokes the external
`SessionAgentLiveIT` only after deployment, passing the configured loopback URLs,
Semantic token, Google key, and model through its process environment without
logging credentials.

Slack settings are reserved deployment inputs. They do not represent an
implemented Starter or Runtime integration milestone.

## Acceptance rules

- A deployment records immutable Runtime and Semantic source SHAs.
- Runtime live acceptance runs against the deployed loopback services.
- Semantic repository/source APIs remain the only repository analysis boundary.
- The Runtime database is independent from Semantic repository and JDT state.
- A one-time legacy shutdown is an operator procedure after replacement images
  have been built and the current deployment has been validated; it is not a
  `deploy.sh` mode or compatibility path.
- No compatibility layer is retained unless a later milestone explicitly
  approves one.
