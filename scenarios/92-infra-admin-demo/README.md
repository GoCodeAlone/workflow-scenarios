# Scenario 92 — Infra Admin GitOps Demo (v1.1)

Demonstrates the **infra-admin GitOps workflow**: plan → commit desired-state
YAML to a bare-git-repo fixture → apply → drift detection, all via a single-page
admin UI registered as an `admin.dashboard` contribution.

## What this exercises

- **`infra.admin` host module** (read RPCs + catalog proxy at `/api/infra-admin/*`)
- **Infra SPA** at `/admin/infra/` (static.fileserver + admin contribution registration)
- **Pipeline-based API routes** at `/api/infra/*`:
  - `GET  /api/infra/providers/stub/catalog` — stub regions + types
  - `GET  /api/infra/resources` — proxy to infra.admin resources RPC
  - `POST /api/infra/plan` — stub plan (1 "create" per spec, desired_hash)
  - `POST /api/infra/apply` — stub apply
  - `POST /api/infra/commit` — `step.sandbox_exec` git clone/commit/push to bare repo
  - `GET  /api/infra/drift` — stub drift detection (no drift, supported:true)
  - `GET  /api/infra/secrets` — secrets metadata (names only, values never returned)
  - `POST /api/infra/secrets` — declare a secret name (write-only demo)
- **AuthZ**: Bearer-required on all mutation routes (401 unauthenticated, CSRF defence)
- **Bare git repo fixture** at `.build/gitrepo.git` (bind-mounted into sandbox)

## Stub provider deterministic data

| Operation | Result |
|---|---|
| Catalog regions | `stub-east`, `stub-west` |
| Catalog types | `stub.database`, `stub.bucket` |
| Plan | 1 "create" action per spec |
| desired_hash | `sha256-stub-deterministic-e3b0c44298fc1c149afb` |
| Status | refs echoed as `running` |
| Destroy | refs echoed as destroyed |
| DetectDrift | Drifted:false for every ref, supported:true |

## Auth

JWT secret (test-only, hardcoded for demo): `scenario-92-jwt-secret-do-not-use-in-prod`

Roles:
- `operator@infra` — read + plan + apply + commit + destroy
- `viewer@infra` — read only

## Running

```bash
./seed/seed.sh     # builds 5 plugins + bare git repo + docker compose up
./test/run.sh      # PASS/FAIL + Playwright ≥18 checks
```

## Source

- Design: `docs/plans/2026-05-31-infra-admin-v1.1-design.md`
- ADR-0007: discrete typed mutation RPCs
- ADR-0008: two-phase plan→confirm→apply
