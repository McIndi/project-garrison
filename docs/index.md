# Project Garrison

Project Garrison is a policy-governed runtime for spawning, coordinating, and auditing agents with explicit identity and secret lifecycle controls.

## What Is Running Today

- Open WebUI receives user prompts and can trigger orchestration.
- tool-server is the runtime policy and orchestration chokepoint.
- beeai-runtime currently runs as a stub spawn/terminate runtime.
- Vault is used for token lookup, AppRole issuance, and transit crypto.
- Valkey backs memory and registry state.
- MongoDB receives runtime audit and artifact-related writes.
- OTel Collector is enabled and currently exports to debug in local mode.

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
- Runtime endpoint sanity including spawn, delete, and orchestrate bridge.
- Python test suites for tool-server and pipeline behavior.

## Current Scope Boundaries

- Keycloak is deployed in compose but Open WebUI local auth is disabled.
- OTel currently exports to debug in collector config.
- Nginx and Fluent Bit are in spec direction, not current local compose.
