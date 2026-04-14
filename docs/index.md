# Project Garrison

Project Garrison is a policy-governed runtime for spawning, coordinating, and auditing agents with explicit identity and secret lifecycle controls.

## What Is Running

- Open WebUI receives user prompts and can trigger orchestration.
- tool-server is the runtime policy and orchestration chokepoint.
- beeai-runtime runs as a stub spawn/terminate runtime.
- Vault is used for token lookup, AppRole issuance, and transit crypto.
- Valkey backs memory and registry state.
- MongoDB receives runtime audit and artifact-related writes.
- Nginx is deployed as the tool-server fetch egress proxy.
- Fluent Bit tails Vault and Nginx logs and forwards events to tool-server internal audit ingest endpoints.
- OTel Collector is enabled, and tool-server audit middleware emits OTLP logs to it (collector exports debug in local mode).
- Open WebUI garrison_audit pipeline also emits OTLP logs for inlet/outlet events.

## Quick Start

From repository root:

```bash
bash scripts/bootstrap.sh
```

Run CI-equivalent smoke flow locally:

```bash
bash scripts/ci-smoke.sh
```

## Verification Gates

The smoke path validates:

- Vault bootstrap and readiness.
- Vault class policy matrix.
- Vault dynamic secret issue/renew/revoke lifecycle.
- Nginx proxy readiness and access-log evidence.
- Audit evidence flow: Vault + Nginx logs -> Fluent Bit -> tool-server ingest -> MongoDB.
- Runtime endpoint sanity including spawn, delete, and orchestrate bridge.
- Python test suites for tool-server and pipeline behavior.

## Scope Boundaries

- Open WebUI auth is enabled; full Keycloak OIDC role mapping and policy enforcement are the next increment.
- OTel exports to debug in collector config.
- OTLP logs are emitted by both tool-server and Open WebUI pipeline in local mode.
