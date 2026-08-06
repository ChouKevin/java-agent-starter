# Cross-Service Integration Roadmap

This roadmap owns milestones that require coordinated delivery across `java-system-agent`,
`java-code-intelligence`, and the Starter composition. Internal refactors and implementation-only
changes remain in the repository that owns the code.

## Ownership

- `java-system-agent` owns Agent runtime behavior, planning tools, Semantic HTTP consumers, Slack,
  and Agent persistence
- `java-code-intelligence` owns repository lifecycle, Semantic HTTP/MCP contracts, JDT LS, source
  analysis, and call-graph behavior
- `java-agent-starter` owns compatible source revision selection, clone/build/deploy composition,
  executable cross-service UAT, and integration milestone acceptance

The services share versioned network contracts and opaque repository identities. Starter must not
introduce shared Java source, duplicate Semantic schemas, or a second implementation of either
service's domain behavior.

## M4: External Service Cutover

**Status:** Complete

The embedded Semantic Service source was extracted from `java-system-agent` into
`java-code-intelligence`. Starter can clone and build both services, start their shared PostgreSQL
and private Docker network, configure one Semantic API token, and verify authenticated Semantic
HTTP/MCP connectivity.

Acceptance already established:

- both service source revisions are recorded for a deployment
- repository catalog, clone, and revision lookup are independently operable
- Semantic HTTP and MCP requests preserve repository revision pinning
- authentication, unknown repository, malformed request, and revision mismatch failures are typed
- Java System Agent consumes Semantic Service through its external HTTP boundary

## M5: Cross-Service Contract Baseline

**Status:** Complete

Build an executable Starter-owned contract UAT that proves a selected pair of service revisions can
interoperate before capability expansion begins.

Deliverables:

- record the exact Agent and Semantic source revisions under test
- inventory the Agent planning tools and the Semantic HTTP/MCP operations they depend on
- verify request identity, repository revision, source locations, follow-up metadata, and bounded
  result metadata across the network boundary
- verify typed authentication, repository, revision, request-validation, engine, and contract
  failures at the consumer boundary
- run representative HTTP and MCP queries without treating their adapters as one transport
- provide one command that produces a clear pass/fail integration report

Contract authority remains distributed deliberately:

- Semantic OpenAPI and MCP schemas own provider-facing transport contracts
- Agent consumer DTO and adapter tests own the Agent's accepted HTTP subset
- Starter UAT owns compatibility of an exact pair of deployed revisions

Starter must not copy complete JSON schemas into a third contract model.

M5 is accepted when incompatible service revisions fail before an Agent knowledge-query scenario,
while a compatible pair passes the same revision-pinned HTTP/MCP contract suite.

Acceptance established on 2026-08-06 with `./contract-uat.sh`:

- Agent source and fixture: `dc8d25acd32a0e52edcb8f0e5e9a0dbc1244fff7`
- Semantic source: `6af36c585aacd68953c3aa621e66ceb45e743c7c`
- Semantic MCP contract: 5 tests passed
- Agent HTTP consumer contract: 2 tests passed
- JUnit summary: `reports/contract-uat/20260806T020921Z-650974/summary.xml`

## M6: Agent Semantic Capability Expansion

**Status:** Next

Expose the newer Semantic discovery and navigation capabilities as Agent `QUERY` planning tools.
The initial scope includes source-symbol resolution, source-segment retrieval, internal source
references, implementation discovery, and listener discovery where the Semantic contract supports
them.

The Agent uses its HTTP adapter. MCP remains a separate Semantic adapter for direct tool clients;
the two adapters may share Semantic application data but not transport-specific implementation.
Every response must retain enough typed identity, source location, revision, and follow-up metadata
for the model to make the next query without guessing hidden server state.

M6 is accepted when each new Agent capability is a registration extension, preserves the existing
planning-tool runtime contract, and passes the M5 compatibility suite for its selected service
revisions.

## M7: Knowledge Query End to End

**Status:** Planned

Prove the complete user workflow through the deployed services. From a business question, the
Agent must be able to identify relevant API, scheduled-job, and message-consumer packages, classes,
and methods; read the complete method scope; and continue through incoming/outgoing calls,
implementations, and internal references.

The scenario keeps one explicit repository revision throughout a reasoning chain. Truncated,
partial, unresolved, ambiguous, or external results must remain visible and supply a concrete
follow-up operation when another supported query can recover useful evidence.

M7 is accepted through a Starter-owned UAT scenario using the actual containers and a representative
repository. The scenario verifies the final evidence trail rather than only service liveness.

## M8: Operational and Multi-Repository Hardening

**Status:** Planned

Harden the integration after the knowledge-query path is complete:

- measure and reduce JDT LS cold-start and repeated-query latency
- resolve the Semantic OpenAPI endpoint failure or explicitly replace that discovery boundary
- define a tested service-revision compatibility matrix and rollback procedure
- verify cache, monitoring logs, and bounded response behavior under multiple repositories
- verify repository isolation when concurrent requests target different repository identities
- document capacity limits and operational recovery without claiming distributed ownership

M8 is accepted when Starter can deploy, observe, and recover a supported multi-repository
configuration with explicit capacity and compatibility evidence.

## Milestone Rules

- Cross-service behavior is specified and accepted here; repository-internal design remains local
- A milestone records exact source revisions rather than relying on moving branch names
- HTTP and MCP receive transport-specific adapter tests even when they expose equivalent data
- Every Semantic query remains revision-pinned
- No compatibility layer is retained unless a milestone explicitly approves one
- A completed milestone updates its status and records its acceptance command or artifact here
