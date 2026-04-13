# Security Hardening Implementation - Pass 001

This writeup describes what was changed after Security Assessment Pass 001, why those changes were made, and what tradeoffs were accepted.

## Scope and Intent

This pass focused on reducing practical exploitability first, while keeping local bootstrap and CI flows usable.

Primary goals were:

- Remove root-level steady-state trust where possible.
- Eliminate easy abuse paths (SSRF, corpus enumeration, weak token checks).
- Improve audit reliability and reduce accidental secret leakage.
- Add regression tests for each high-risk application change.

## Most Interesting Changes (Highest Impact)

## 1) F-01: Replaced tool-server root Vault credential with a scoped service token

### Why this mattered

The previous model ran tool-server with a root Vault token in steady state. Any compromise of tool-server process memory, environment, or request path could become full Vault compromise.

### What changed

- Added a dedicated `garrison-tool-server` Vault policy with only required capabilities:
  - AppRole role-id read and secret-id issue.
  - AppRole login.
  - Token accessor revocation.
  - Transit encrypt/decrypt for expected keys.
- Added a new script to mint a runtime-scoped tool-server token:
  - `scripts/issue-tool-server-token.sh`
- Updated bootstrap to:
  - Configure Vault baseline.
  - Mint scoped token.
  - Start tool-server with `TOOL_SERVER_VAULT_TOKEN` set to that scoped token.
- Removed root fallback behavior in runtime paths that attempted to auto-bootstrap Vault mounts/keys.

### Tradeoffs

- Bootstrap ordering became stricter by design. Tool-server now depends on baseline Vault setup before startup.
- Operationally this is a better failure mode: fail closed rather than silently relying on root privilege.

### Validation and regression coverage

- Provisioning tests were updated to verify spawn credential issuance uses scoped endpoints only.
- Existing test suite passes with these changes.

## 2) F-02: Added concrete SSRF guardrails to /tools/fetch

### Why this mattered

`/tools/fetch` plus wildcard proxy forwarding created a broad SSRF surface. Without host/IP controls, internal services and non-public addresses were reachable.

### What changed

- Hardened URL validation to reject:
  - Internal service hostnames used in this deployment.
  - Non-public resolved addresses (private, loopback, link-local, multicast, reserved, unspecified).
- Kept method and proxy requirements already present.

### Tradeoffs

- This is intentionally restrictive. Some destinations previously reachable in local testing are now blocked.
- The restriction is worth it because fetch is policy-sensitive and this path had high abuse potential.

### Validation and regression coverage

- Added tests for:
  - Internal hostname rejection.
  - Private-IP resolution rejection.
  - Public-IP happy path stability.

## 3) F-03 + F-16: Closed search data exposure and whitespace bypasses

### Why this mattered

Search accepted caller-controlled corpus coordinates and allowed whitespace queries that effectively degraded into broad dumping behavior.

### What changed

- Added corpus allowlist setting (`TOOL_SERVER_SEARCH_ALLOWED_CORPORA`) and server-side enforcement.
- Added model-level query validator to reject whitespace-only search strings.

### Tradeoffs

- New corpora now require explicit configuration before use.
- This reduces accidental data overexposure and makes corpus growth intentional.

### Validation and regression coverage

- Added tests for disallowed corpus rejection.
- Added tests for whitespace query validation failure.

## 4) F-07: Fixed Open WebUI audit redaction to redact values (not keys)

### Why this mattered

The prior pipeline redaction mutated key names but left secret values intact, creating false confidence.

### What changed

- Replaced key-name string replacement with value-aware redaction patterns.
- Added bearer token masking in text payloads.

### Tradeoffs

- Regex redaction remains heuristic and may miss edge-shaped payloads.
- Still a major improvement over prior behavior because direct secret-value leakage path was closed.

### Validation and regression coverage

- Added pipeline test confirming secret values are not present in redacted output.

## Other Completed Fixes in this Pass

- F-04: Converted compose credentials to env-driven defaults instead of hardcoded literals.
- F-05: Removed static Keycloak client-secret default; generate runtime secret when not provided.
- F-10: Reduced OTel debug exporter verbosity from `detailed` to `normal`.
- F-11: Hardened temp-file handling in dynamic secret checks (`umask`, `mktemp`, cleanup trap).
- F-12: Added non-root container users for tool-server and beeai-runtime images.
- F-13: Replaced silent audit persistence swallow with structured error logging.
- F-14: Set Fluent Bit `Read_from_Head` to `false` to reduce duplicate replay risk.
- F-15: Switched ingest token comparison to constant-time `compare_digest`.
- F-17: Added retry backoff to spawn path.
- F-18: Added explicit Vault readiness wait loop in bootstrap.
- F-19: Reduced secret exposure risk in scripts by posting JSON from files instead of command-line payloads.
- F-06/F-08: Added explicit trust-boundary and dev-mode guardrail documentation in code.

## Next Steps Requiring Their Own Change Sets

## F-09: Spawn depth should be bound to minted identity, not caller headers

### Why this needs a dedicated step

This is a protocol-level change, not a local patch. Depth/lineage must be carried in trusted identity context (for example minted token metadata or signed server context), then enforced consistently across:

- Credential issuance flow.
- Runtime auth parsing.
- Spawn/orchestrate request propagation.
- Existing tests and bootstrap scripts.

A partial patch risks creating inconsistent enforcement where one path trusts header state and another trusts token state.

### Planned direction

- Stamp lineage metadata at issuance.
- Treat header depth as informational only.
- Enforce depth strictly from trusted identity metadata.

## F-21: Pin base images by digest

### Why this needs a dedicated step

Digest pinning is operationally correct but requires release/process choices:

- Select and validate exact image digests across Docker Hub and Quay sources.
- Update bootstrap/CI expectations for refresh cadence.
- Add a documented rotation flow for periodic digest refresh and vulnerability review.

Without this process, pinning once can quickly drift into stale, unpatched images.

### Planned direction

- Pin all runtime and infra images by digest.
- Add a periodic update policy (for example monthly) with validation gates.

## Verification Summary

Application and pipeline test suites were re-run after these changes and remained green.

## Files Touched in This Pass

- `compose.yaml`
- `config/fluent-bit/fluent-bit.conf`
- `config/otel/collector.yaml`
- `tool-server/app/config.py`
- `tool-server/app/main.py`
- `tool-server/app/models.py`
- `tool-server/app/provisioning.py`
- `tool-server/tests/test_api.py`
- `tool-server/tests/test_provisioning.py`
- `open-webui/pipelines/garrison_audit.py`
- `open-webui/pipelines/test_garrison_audit.py`
- `tool-server/Dockerfile`
- `beeai-runtime/Dockerfile`
- `scripts/bootstrap.sh`
- `scripts/vault-bootstrap.sh`
- `scripts/vault-readiness.sh`
- `scripts/vault-dynamic-secrets-check.sh`
- `scripts/vault-policy-check.sh`
- `scripts/issue-tool-server-token.sh`
