# 003 — Set resource requests/limits on agentstack-ui and the build registry

**Status:** open · **Created:** 2026-07-07 · **Related:** armory's
`doc/handoffs/vm-resource-limits-kernel-tuning-plan.md` (companion doc — this
ticket is garrison's slice of the same gap; read it for the full picture,
including why kernel tuning is a *separate*, armory-only concern).

## Goal

`agentstack-ui` and the agent-build registry currently run `BestEffort` (no
`resources:` anywhere in `agentstack_helm_values`,
`ansible/roles/agentstack/defaults/main.yml`) — nothing caps them, nothing
protects armory's shared control-plane pods from them if either misbehaves.
"Done" = both report `qosClass: Burstable`.

## Scope note — verify before writing values

The chart's Helm value schema for per-component `resources` keys has not been
confirmed against the pinned `agentstack_chart_oci_ref`/`agentstack_chart_version`
in this repo. Before editing defaults, run:

```bash
helm show values {{ agentstack_chart_oci_ref }} --version {{ agentstack_chart_version }}
```

and confirm the exact keys (expected shape: `ui.resources`,
`server.resources`, `localDockerRegistry.resources` — do not assume, check).

## Which registry component gets resources depends on ticket 002

- If ticket `002-agentstack-provider-builds-registry.md` has **not** landed
  yet: the registry pod is still the chart's bundled `localDockerRegistry`
  (`localDockerRegistry.enabled: true` in current defaults) — set
  `localDockerRegistry.resources` there.
- If 002 **has** landed: the registry is armory's zot-based platform registry
  in the `registry` namespace, owned by armory, not garrison — resource limits
  for it belong in armory's plan/role, not here. Confirm which state applies
  before touching `localDockerRegistry`.

## Task — defaults

`ansible/roles/agentstack/defaults/main.yml`, add near the top of
`agentstack_helm_values` construction:

```yaml
agentstack_ui_resources_requests_cpu: 100m
agentstack_ui_resources_requests_memory: 128Mi
agentstack_ui_resources_limits_cpu: 500m
agentstack_ui_resources_limits_memory: 512Mi

agentstack_registry_resources_requests_cpu: 50m
agentstack_registry_resources_requests_memory: 64Mi
agentstack_registry_resources_limits_cpu: 250m
agentstack_registry_resources_limits_memory: 256Mi
```

Then, once the chart's real key names are confirmed (see above), add the
corresponding `resources:` blocks under `ui:` (or whatever the confirmed key
is) and `localDockerRegistry:` in `agentstack_helm_values`, following the
existing `combine(..., recursive=True)` merge pattern already used in
`tasks/helm_release.yml` — do not build a second values dict, extend the one
that exists.

## Validation

```bash
ansible-playbook --syntax-check playbooks/site.yml
ansible-playbook playbooks/site.yml --tags agentstack
k3s kubectl get pod -n agentstack -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.qosClass}{"\n"}{end}'
```

Acceptance: `agentstack-ui` and the registry pod both report
`qosClass: Burstable`; readiness/E2E OIDC login still passes (this touches
Helm values only, nothing behavioral).

## Out of scope

`agentstack-server` (not flagged in the source investigation — add later if
it also turns out BestEffort), the actual registry ownership decision (that's
002's call), armory-side kernel tuning and the other BestEffort pods it owns
(openbao, cert-manager, delve shippers, headlamp, otel-collector,
local-path-provisioner) — those are armory's handoff doc, not this ticket.
