## Plan: Garrison Remaining Phases (Consolidated)

This plan merges the original demo-first delivery plan with spec-critical gaps discovered during review, especially Vault dynamic/auditable secret integration and strict policy chokepoints.

### Current Status Snapshot
- Phase 0 through Phase 5 are functionally in place for MVP behavior and demo flow.
- Remaining work starts at consolidated Phase 6A below.

### Verification Checkpoint (2026-04-13)
- Runtime verification passed against live stack via scripts:
   - `scripts/vault-bootstrap.sh`
   - `scripts/vault-readiness.sh`
   - `scripts/vault-policy-check.sh`
   - `scripts/vault-dynamic-secrets-check.sh`
   - `scripts/sanity-check.sh`
- `sanity-check` confirmed health, memory/scratch, transit encrypt/decrypt, spawn/delete, and `/orchestrate` delegation flow.
- `TOOL_SERVER_REQUIRE_TOKEN_LOOKUP` is enabled in `compose.yaml` for runtime enforcement.
- Automated tests pass:
   - `tool-server`: 30 passed
   - `open-webui/pipelines`: 3 passed
- New automation was added for Vault token lookup enforcement behavior (`require_token_lookup=true` path), including rejection behavior on lookup failure.

Phase 7 Kickoff Status:
- CI smoke automation added:
   - `scripts/ci-smoke.sh` (single-command bootstrap + Vault checks + sanity + test flow)
   - `.github/workflows/phase7-smoke.yml` (GitHub Actions workflow)
- Local dry run of `scripts/ci-smoke.sh` completed successfully against live stack.
- Terraform/OpenTofu scaffold added in spec module order:
   - `terraform/main.tf`
   - `terraform/variables.tf`
   - `modules/{infra,vault-core,vault-pki,vault-secrets,vault-transit,vault-policy,agent-role,agent-skill}`
- Local `init` and `validate` passed against the scaffolded stack.
- Module contracts upgraded from placeholders to concrete inputs/outputs with cross-module wiring:
   - root contract outputs in `terraform/outputs.tf`
   - policy composition map including analyst base-only path
   - role contract deriving policy assignment from policy module output
   - skill document path contract for rendered artifacts
- Operator runbook published: `OPERATIONS-RUNBOOK.md`.

Grounded Next Step:
- Continue Phase 7 by implementing provider-backed resources in module order (start with `vault-core` and `vault-transit`) while preserving current script checks as parity gates.

### Phase 6A - Vault Dynamic + Auditable Secrets Completion
Goal: complete end-to-end Vault integration so credentials are dynamic, scoped, and auditable across runtime components.

Scope:
1. Enforce Vault token lookup in tool-server for runtime calls.
2. Ensure Vault baseline is configured at boot:
   - file audit device
   - AppRole auth mount
   - transit mount
   - transit keys: agent-payload, shared-memory, artifact-signing
   - core AppRole roles: orchestrator, code, rag, analyst
3. Add machine-checkable Vault readiness verification.
4. Keep agent identity separate from human OIDC identity.
5. Preserve rule: agents never call Vault directly; tool-server is the chokepoint.

Exit Criteria:
- Vault readiness script passes in a fresh bootstrap run.
- Sanity checks pass with token lookup enabled.
- Audit evidence exists for Vault operations invoked by tool-server.

### Phase 6B - Vault Policy/Secrets Depth
Goal: align with spec depth for policy templates and dynamic secret lifecycle.

Scope:
1. Introduce policy templates (base + class-specific additive policy).
2. Wire role policy assignment by class.
3. Add dynamic secret engines and role bindings for MongoDB and Valkey.
4. Verify analyst class works with base-only policy path.

Exit Criteria:
- Class policy matrix test passes.
- Dynamic secret issuance + expiry verified.
- Registry + token revoke lifecycle remains consistent.

### Phase 6C - User Request Orchestration Bridge
Goal: connect human requests to controlled dynamic delegation so BeeAI spawn is used by runtime workflows, not only tests/manual calls.

Scope:
1. Add a minimal orchestrator entrypoint in tool-server (for example `POST /orchestrate`) that accepts:
   - `request_text`
   - `human_session_id`
   - optional `preferred_agent_class`
2. Route orchestration only through tool-server policy checks and existing spawn controls.
3. Keep spawn constraints unchanged:
   - orchestrator-only spawn/delete
   - max spawn depth
   - root-orchestrator tree ownership checks
4. Return a workflow envelope to caller:
   - `workflow_id`
   - `spawned_agent_id` (if delegation chosen)
   - `status` (`accepted|completed|failed`)
5. Wire Open WebUI pipeline path to this orchestrator entrypoint for selected actions.

Exit Criteria:
- A user request can trigger orchestrator delegation without direct `/tools/spawn` calls from the UI.
- Audit records correlate `human_session_id` across Open WebUI pipeline, tool-server orchestration call, spawn, and handoff.
- Negative tests pass for non-orchestrator spawn and over-depth spawn attempts.

### Phase 7 - Terraform/Packaging Alignment
Goal: make runtime reproducible and handoff-ready.

Status update (2026-04-14):
- Provider-backed Terraform module pass has been implemented in branch `feat/ok-lets-add-terraform-proper`.
- `scripts/bootstrap.sh` and `scripts/ci-smoke.sh` now support Terraform-backed provisioning via `GARRISON_TERRAFORM=true`.
- Default bootstrap behavior remains script-managed when the Terraform toggle is not set.

Scope:
1. Add terraform module structure to mirror spec execution order.
2. Add reproducible bootstrap command sequence and CI smoke workflow.
3. Publish operator runbook for demo + enterprise transition path.

Exit Criteria:
- Fresh environment can be stood up via documented bootstrap.
- CI smoke checks pass for health, spawn/delete, and security boundaries.

### Immediate Execution Backlog (Started)
1. Enable Vault token lookup in tool-server runtime.
2. Add scripts:
   - scripts/vault-bootstrap.sh
   - scripts/vault-readiness.sh
3. Integrate these scripts into scripts/bootstrap.sh.
4. Run full bootstrap and capture Vault-readiness output.
5. Specify and implement the minimal orchestration bridge (`/orchestrate`) before expanding BeeAI worker lifecycle depth.

### Guardrails
- All runtime operations remain tool-server mediated.
- No direct agent-to-data-net route.
- human_session_id is required on runtime requests; autonomous mode uses system:<uuidv4>.
- Spawn depth remains capped at 2.

### Source of Truth
- SPEC: SPEC.md
- This execution plan: EXECUTION-PLAN.md
