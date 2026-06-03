# Scenario 92 — Infra Admin Phase 2/3 Demo

Demonstrates the Phase-2/3 infra-admin features against the REAL released stack:
**workflow v0.74.0** (ResourceDriver wired end-to-end, PR13) **+ workflow-plugin-infra v1.2.0
+ workflow-sandbox-runner agent**.

Phase 1 (shipped v0.70.0 / v1.1.0) migrated the deleted engine `infra.admin`
module to the step-based `step.iac_provider_*` pipeline architecture. Phase 2/3
(this scenario) adds dynamic specs, the secret-reachability pre-flight gate,
real git commit-back, reconcile, and the remote sandbox-runner agent.

## Architecture

The stub IaC provider is an **external gRPC plugin** built from
`fixtures/stub-iac-provider/`. The engine's `WiringHook` registers it as
service `"stub-iac-provider"` so `step.iac_provider_*` steps resolve it. The stub
advertises `ResourceDriver` (via its gRPC service registration → ContractRegistry),
so on workflow v0.74.0 `step.iac_provider_apply` genuinely CREATEs resources and
`step.iac_commit_back` commits a branch.

**No engine-built-in `infra.admin` module is used** — that was deleted from the
engine in v0.70.0. The `type: infra.admin` in `config/app.yaml` resolves to the
**external `workflow-plugin-infra` plugin's** module type (the migrated admin SPA),
discovered at runtime. All IaC operations flow through the platform plugin's
`step.iac_provider_*` / `step.iac_commit_back` / `step.iac_provider_reconcile` /
`step.iac_secret_reachability` / `step.sandbox_exec` step types.

## API routes (step-based pipelines)

| Route | Method | Step(s) | Notes |
|---|---|---|---|
| `/api/infra/catalog` | GET | `step.iac_provider_catalog` | Live regions via RegionLister gRPC |
| `/api/infra/resources` | GET | `step.iac_provider_list` | Status from external plugin |
| `/api/infra/plan` | POST | `step.iac_provider_plan` | DYNAMIC `specs_from` body → desired_hash |
| `/api/infra/apply` | POST | `step.iac_secret_reachability` → `step.iac_provider_apply` → `step.iac_commit_back` | Reachability pre-flight → CREATE → branch-push commit-back |
| `/api/infra/apply-remote` | POST | `step.iac_secret_reachability` (exec_env: remote) | 409 when host-local secrets unreachable from remote (ADR 0017) |
| `/api/infra/reconcile` | POST | `step.iac_provider_reconcile` | Drift → import → approximate YAML → draft branch |
| `/api/infra/exec-envs` | GET | `step.json_response` | Static `{exec_envs: ["local-docker","remote"]}` |
| `/api/infra/sandbox-demo` | POST | `step.sandbox_exec` (exec_env: remote) | Runs on the sandbox-runner agent; MARKER asserted |
| `/api/infra/drift` | GET | `step.iac_provider_drift` | DriftDetector via external gRPC |
| `/api/infra/secrets` | GET | `step.json_response` | Metadata-only, no values |
| `/api/admin/contributions` | GET | `step.admin_list_contributions` | Admin shell |

> The Phase-1 `/api/infra/commit` route is removed — commit-back is now integrated
> into the `/apply` pipeline via `step.iac_commit_back`.

## Auth/RBAC

JWT subject-based RBAC via `step.auth_validate` + `step.conditional`:
- `operator` → plan/apply/reconcile/sandbox-demo allowed
- `viewer` → catalog/list/drift only; mutations → 403
- unauthenticated → 401

```
secret: "scenario-92-jwt-secret-do-not-use-in-prod"
```

## Dynamic apply → commit-back (the headline flow)

1. Operator POSTs operator-edited specs (with a `secret://scenario/...` ref) to
   `/api/infra/plan` → `desired_hash` computed from the dynamic specs.
2. Operator POSTs the same specs + hash to `/api/infra/apply`:
   - `step.iac_secret_reachability` pre-flight (local exec_env → reachable).
   - `step.iac_provider_apply` recomputes the hash (two-phase guard) and CREATEs
     each resource via the stub's `ResourceDriver.Create` (v0.74.0 wires it).
   - `step.iac_commit_back` serialises the specs to `resources.yaml` and pushes a
     branch (`gitops/infra-apply-demo`) to the bare repo. `secret://` refs are
     written VERBATIM (`specgen.SpecToYAML` does not resolve them).

## Running

```bash
# Seed (builds engine + sandbox-runner from the scenarios module's v0.74.0 pin,
# builds external plugins, sets up the bare repo + working clone, docker compose up)
./seed/seed.sh

# Tests (curl smoke + Playwright)
./test/run.sh
```

## External plugins / agents

1. **stub-iac-provider** — built from `fixtures/stub-iac-provider/`
   - Serves `IaCProviderRequired` + `IaCProviderRegionLister` + `IaCProviderDriftDetector` + `ResourceDriver`
   - WiringHook registers it as service `"stub-iac-provider"`
   - Deterministic data: regions `stub-east`/`stub-west`, types `stub.database`/`stub.bucket`
   - `ResourceDriver.Create` returns a stub ResourceOutput so apply CREATEs succeed

2. **workflow-plugin-admin** — built from local checkout (`PLUGIN_ADMIN_REPO`)
   - Provides `admin.dashboard` module type; serves admin shell at `/admin/`

3. **workflow-plugin-infra** (v1.2.0) — built from local checkout (`PLUGIN_INFRA_REPO`)
   - Provides `infra.admin` module type; serves the React SPA at `/admin/infra`

4. **workflow-sandbox-runner** — agent built from the scenarios module's v0.74.0 pin
   - gRPC agent for `step.sandbox_exec` `exec_env: remote`; clamps `permissive` → `standard`
