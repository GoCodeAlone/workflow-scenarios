# Scenario 92 — Infra Admin (Dynamic, Proto-Driven)

Demonstrates the host-side `infra.admin` workflow module + dynamic
proto-driven admin UI surface introduced in workflow PR #791
(`feat/infra-admin-host-module-2026-05-27T1534`).

## What this exercises

- **infra.admin host module** mounts:
  - `/api/infra-admin/{resources,resources/{name},types,providers,generate-config,audit}` RPC endpoints
  - `/admin/infra-admin/{resources,resource,new,styles}.{html,js,css}` static asset pages
- **admin.dashboard plugin** picks up three iframe contributions via the
  per-pipeline `engine.TriggerWorkflow` registration flow.
- **wfctl infra admin** CLI mirrors the same surface (parity-tested in
  PR-1 at `cmd/wfctl/infra_admin_parity_test.go`).

## Two variants

| Variant | iac.provider modules | Notes |
|---|---|---|
| `config/app.yaml` | stub-provider only | Always-pass; deterministic Playwright behavior |
| `config/app-do-dryrun.yaml` | stub-provider + do-provider (no token) | DO provider fails any live API call; ListProviders + ListTypes still succeed against empty state |

## Running

```bash
# Stub variant
./seed/seed.sh                           # docker compose up + wait for /healthz
./test/run.sh                            # PASS/FAIL prefixed test summary + Playwright

# DO dry-run variant
VARIANT=do-dryrun ./seed/seed.sh
VARIANT=do-dryrun ./test/run.sh
```

## Exploratory QA

`test/EXPLORATORY.md` is the template for the post-PR-2 exploratory pass via
the `playwright-cli` skill. Different from the regression Playwright spec —
that's the `@playwright/test` spec at
`workflow-scenarios/e2e/tests/scenario-92-infra-admin.spec.ts`.

## Source plan

- Design: `/Users/jon/workspace/docs/plans/2026-05-27-infra-admin-dynamic-design.md`
- Plan:   `/Users/jon/workspace/docs/plans/2026-05-27-infra-admin-dynamic.md` §Task 21-25 + §Task 27
- ADR:    `/Users/jon/workspace/decisions/0002-infra-admin-host-module.md`
