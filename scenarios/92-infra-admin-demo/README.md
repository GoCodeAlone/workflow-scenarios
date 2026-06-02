# Scenario 92 — Infra Admin Migration Demo

Demonstrates the migration from the deleted engine module to the new
step-based IaC pipeline architecture (workflow v0.70.0, PR-5 Task 18-19).

## Architecture

The stub IaC provider is an **external gRPC plugin** built from
`fixtures/stub-iac-provider/`. The engine's `WiringHook` registers it as
service `"stub-iac-provider"` so `step.iac_provider_*` steps resolve it.

**No `infra.admin` module type is used** — that was deleted from the engine.
All IaC operations flow through the platform plugin's step types.

## API routes (step-based pipelines)

| Route | Method | Step | Notes |
|---|---|---|---|
| `/api/infra/catalog` | GET | `step.iac_provider_catalog` | Live regions via RegionLister gRPC |
| `/api/infra/resources` | GET | `step.iac_provider_list` | Status from external plugin |
| `/api/infra/plan` | POST | `step.iac_provider_plan` | Returns desired_hash + create action |
| `/api/infra/apply` | POST | `step.iac_provider_apply` | Two-phase hash guard |
| `/api/infra/drift` | GET | `step.iac_provider_drift` | DriftDetector via external gRPC |
| `/api/infra/commit` | POST | `step.json_response` | Gitops commit fixture |
| `/api/infra/secrets` | GET | `step.json_response` | Metadata-only, no values |
| `/api/admin/contributions` | GET | `step.admin_list_contributions` | Admin shell |

## Auth/RBAC

JWT subject-based RBAC via `step.auth_validate` + `step.conditional`:
- `operator` → plan/apply/commit allowed
- `viewer` → catalog/list/drift only; plan/apply/commit → 403
- unauthenticated → 401

```
secret: "scenario-92-jwt-secret-do-not-use-in-prod"
```

## Running

```bash
# Seed (builds external plugins + docker compose up)
./seed/seed.sh

# Tests (curl smoke + Playwright)
./test/run.sh
```

## External plugins loaded

1. **stub-iac-provider** — built from `fixtures/stub-iac-provider/`
   - Serves `IaCProviderRequired` + `IaCProviderRegionLister` + `IaCProviderDriftDetector`
   - WiringHook registers it as service `"stub-iac-provider"`
   - Deterministic data: regions `stub-east`/`stub-west`, types `stub.database`/`stub.bucket`

2. **workflow-plugin-admin** — built from local checkout (`PLUGIN_ADMIN_REPO`)
   - Provides `admin.dashboard` module type
   - Serves admin shell at `/admin/`
