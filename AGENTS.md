# Starter Repository Guide

## Purpose

This repository builds and runs the single-host UAT environment. It stages exact
source revisions, builds images, controls Docker Compose, creates deterministic Git
fixtures, and runs cross-service acceptance checks.

It does not contain the Java implementation of Session Agent Runtime or Java Code
Intelligence.

## Hard boundaries

- Keep service behavior in its owning repository. Do not add Runtime or Semantic
  Java source, persistence logic, model logic, or query logic here.
- Treat `.runtime/sources/` as disposable deployment output. Never develop in it,
  commit it, or rely on local edits inside it; `deploy.sh` may replace it.
- Keep `.env`, `.runtime/`, `deployment-record.txt`, logs, evidence, generated Git
  remotes, database data, and credentials out of Git.
- Preserve exact source SHA recording. A deployed source must be traceable through
  `deployment-record.txt`.
- Keep ordinary deploys non-destructive. Only the explicit `reset` flow may remove
  volumes, and only for the fixed disposable UAT project after its safety checks.
- One public operation owns `.runtime/deploy.lock` for its full run. Sourced helper
  functions must not acquire a second lock.
- Live model tests are opt-in. Default tests must not require a model key or consume
  model quota.

## Files and responsibilities

- `deploy.sh`: source staging, image build, Compose lifecycle, and deployment record.
- `fixture.sh`: deterministic local Git fixture versions.
- `repository.sh`: repository indexing commands and revision inspection.
- `cross-service-uat.sh`: clean no-model cross-service acceptance.
- `runtime-uat.sh`: opt-in real-model session acceptance.
- `compose.yaml`: UAT services, networks, volumes, health checks, and credentials.
- `config/`: repository catalog and MongoDB initialization.
- `tests/`: fake-backed shell contract and regression tests.
- `docs/roadmap.md`: ownership and current acceptance boundary.

## Working rules

- Quote shell variables and validate paths before destructive operations.
- Keep scripts non-interactive unless a command is explicitly documented as
  interactive.
- Reuse the existing source-staging, lock, evidence, and Compose helpers instead of
  adding a second path for the same operation.
- Do not add compatibility paths for removed pre-release behavior unless a new
  requirement explicitly asks for them.
- When a service contract changes, update Starter only for deployment configuration
  or cross-service acceptance; do not copy the service contract implementation here.

## Verification

For changed shell files, run syntax checks first:

```bash
bash -n <changed-script>
```

Run the fake-backed Starter suite for ordinary changes:

```bash
for test_script in tests/*-test.sh; do
  bash "${test_script}"
done
```

Run the clean deployed proof only when Docker state may be replaced:

```bash
./cross-service-uat.sh
```

Run `SESSION_AGENT_LIVE=true ./runtime-uat.sh` only when real-model verification is
explicitly required and the needed local secrets are available. Never commit its
evidence.
