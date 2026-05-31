# Admin App Access Integration Implementation Plan

> **For the implementing agent:** REQUIRED SUB-SKILL: Use autodev:executing-plans to implement this plan task-by-task.

**Goal:** Make Scenario 90 a faithful Workflow-powered primary app plus admin portal that dynamically loads auth/authz plugin management tools and visibly enforces frontend/admin scopes.

**Architecture:** Ship small plugin-first improvements in admin, authz-ui, and auth, then compose them in Scenario 90. Admin owns generic shell/navigation/token bridge, authz-ui owns authz management UX/API calls, auth owns auth management descriptors/validation, and scenarios only prove the real runtime boundary.

**Tech Stack:** Go Workflow plugins, protobuf contracts, React/Vite authz UI, Workflow YAML pipelines, static fileserver modules, Docker Compose, Playwright CLI.

**Base branch:** `origin/main` for each repository worktree.

---

## Scope Manifest

**PR Count:** 4
**Tasks:** 5
**Estimated Lines of Change:** ~1400

**Out of scope:**
- Durable persistence of edited auth/authz config.
- Replacing authz provider engines.
- Production Tailscale deploy or production secrets.
- Cross-origin iframe token delegation.

**PR Grouping:**

| PR # | Title | Tasks | Branch |
|------|-------|-------|--------|
| 1 | Admin shell tools bridge and UX language | Task 1 | `feat/auth-portal-manager` in `workflow-plugin-admin` |
| 2 | Authz UI admin bridge API client | Task 2 | `feat/authz-ui-admin-bridge` in `workflow-plugin-authz-ui` |
| 3 | Auth plugin admin contribution descriptor | Task 3 | `feat/auth-admin-contribution` in `workflow-plugin-auth` |
| 4 | Scenario 90 primary app and access proof | Task 4, Task 5 | `feat/scenario90-real-app-access` in `workflow-scenarios` |

**Status:** Locked 2026-05-30 after design/plan alignment pass.

### Task 1: Admin Shell Tools Bridge and UX Language

**Files:**
- Modify: `/Users/jon/workspace/workflow-plugin-admin/.worktrees/auth-portal-manager/internal/ui_dist/index.html`
- Modify: `/Users/jon/workspace/workflow-plugin-admin/.worktrees/auth-portal-manager/internal/assets_test.go`

**Step 1: Write failing asset tests**

Add assertions that:
- user-facing shell copy does not contain `Surfaces`, `Contributions`, or `contributed admin surfaces`;
- shell contains `workflow.admin.auth.request`, `workflow.admin.auth.response`, and same-origin/path checks;
- existing `Authorization` header support remains.

**Step 2: Run focused tests to verify RED**

Run: `GOWORK=off go test ./internal -run TestEmbeddedAdminShell -count=1`

Expected: FAIL because current shell still uses old labels and lacks the iframe bridge.

**Step 3: Implement minimal shell change**

Change copy to `Admin tools` and `Management pages`. Add a `message` listener
that responds to same-origin `workflow.admin.auth.request` messages from `/admin`
paths with `{type:"workflow.admin.auth.response", token}`. Keep backend
authorization unchanged.

**Step 4: Verify GREEN**

Run:
- `GOWORK=off go test ./internal -run TestEmbeddedAdminShell -count=1`
- `GOWORK=off go test ./... -count=1`
- `GOWORK=off go vet ./...`

Expected: exit 0.

**Rollback:** Revert Task 1 commit and retag/release prior admin plugin if already released.

### Task 2: Authz UI Admin Bridge API Client

**Files:**
- Modify: `/Users/jon/workspace/workflow-plugin-authz-ui/.worktrees/authz-ui-admin-bridge/ui/src/api.ts`
- Modify: `/Users/jon/workspace/workflow-plugin-authz-ui/.worktrees/authz-ui-admin-bridge/ui/src/App.tsx`
- Modify: `/Users/jon/workspace/workflow-plugin-authz-ui/.worktrees/authz-ui-admin-bridge/ui/src/components/RoleTable.tsx`
- Modify: `/Users/jon/workspace/workflow-plugin-authz-ui/.worktrees/authz-ui-admin-bridge/ui/test/source-contract.test.mjs`

**Step 1: Write failing source contract tests**

Add tests requiring:
- `api.ts` sends `workflow.admin.auth.request` and handles `workflow.admin.auth.response`;
- API requests include `Authorization` when a bridge token exists;
- 401/403 messages include `Not authorized` or equivalent visible copy.

**Step 2: Run tests to verify RED**

Run: `cd ui && npm test -- --runInBand` if available, otherwise `node --test test/source-contract.test.mjs`.

Expected: FAIL because the API client currently sends no auth header.

**Step 3: Implement token bridge client**

Add a small token provider in `api.ts`: request token from parent when embedded,
cache it briefly, and include `Authorization: Bearer <token>` in requests.
Handle timeout/no-parent by making the request without a token. Convert 401/403
errors into explicit not-authorized messages consumed by UI components.

**Step 4: Verify GREEN**

Run:
- `node --test test/source-contract.test.mjs`
- `npm run build`
- `GOWORK=off go test ./... -count=1`

Expected: exit 0.

**Rollback:** Revert Task 2 commit and rebuild previous UI assets.

### Task 3: Auth Plugin Admin Contribution Descriptor

**Files:**
- Modify: `/Users/jon/workspace/workflow-plugin-auth/.worktrees/auth-admin-contribution/internal/contracts/auth.proto`
- Modify: `/Users/jon/workspace/workflow-plugin-auth/.worktrees/auth-admin-contribution/internal/contracts/auth.pb.go`
- Modify: `/Users/jon/workspace/workflow-plugin-auth/.worktrees/auth-admin-contribution/internal/plugin.go`
- Modify: `/Users/jon/workspace/workflow-plugin-auth/.worktrees/auth-admin-contribution/internal/step_admin_config.go`
- Modify: `/Users/jon/workspace/workflow-plugin-auth/.worktrees/auth-admin-contribution/internal/step_admin_config_test.go`
- Modify: `/Users/jon/workspace/workflow-plugin-auth/.worktrees/auth-admin-contribution/plugin.contracts.json`
- Modify: `/Users/jon/workspace/workflow-plugin-auth/.worktrees/auth-admin-contribution/README.md`

**Step 1: Write failing tests**

Add tests requiring a new contract/service/step that emits an admin contribution
descriptor for auth management with title `Authentication`, path `/admin/auth/`,
render mode `json-schema` or `internal`, and permissions such as
`admin:auth.config:read` and `admin:auth.config:update`.

**Step 2: Run focused tests to verify RED**

Run: `GOWORK=off go test ./internal -run 'TestAuthAdmin.*Contribution|TestRuntimeContracts' -count=1`

Expected: FAIL because no auth admin contribution descriptor exists.

**Step 3: Implement descriptor contract**

Add strict proto messages and plugin metadata for auth admin contribution
description. Reuse existing admin config describe/validate outputs; do not add
fake config persistence.

**Step 4: Verify GREEN**

Run:
- `GOWORK=off go test ./internal -run 'TestAuthAdmin.*Contribution|TestRuntimeContracts|TestAuthAdminConfig' -count=1`
- `GOWORK=off go test ./... -count=1`
- `GOWORK=off go vet ./...`

Expected: exit 0 and secret-redaction tests remain green.

**Rollback:** Revert Task 3 commit and regenerate protobufs from prior proto.

### Task 4: Scenario 90 Primary App and Scope-Enforced APIs

**Files:**
- Modify: `/Users/jon/workspace/workflow-scenarios/.worktrees/scenario90-real-app-access/scenarios/90-admin-tailnet-demo/config/app.yaml`
- Modify: `/Users/jon/workspace/workflow-scenarios/.worktrees/scenario90-real-app-access/scenarios/90-admin-tailnet-demo/seed/seed.sh`
- Modify: `/Users/jon/workspace/workflow-scenarios/.worktrees/scenario90-real-app-access/scenarios/90-admin-tailnet-demo/test/run.sh`
- Create: `/Users/jon/workspace/workflow-scenarios/.worktrees/scenario90-real-app-access/scenarios/90-admin-tailnet-demo/app/index.html`
- Create: `/Users/jon/workspace/workflow-scenarios/.worktrees/scenario90-real-app-access/scenarios/90-admin-tailnet-demo/app/app.js`
- Create: `/Users/jon/workspace/workflow-scenarios/.worktrees/scenario90-real-app-access/scenarios/90-admin-tailnet-demo/app/styles.css`

**Step 1: Write failing scenario checks**

Extend `test/run.sh` to require:
- no Python harness;
- `/` returns root SPA HTML with a Workflow app marker;
- anonymous app/admin protected APIs return 401;
- admin/support/viewer logins produce different access projection;
- update API returns 403 without `frontend:orders:update`;
- admin contribution list omits Authorization when granted permissions lack `admin:authz.roles:read`.

**Step 2: Run scenario test to verify RED**

Run: `./test/run.sh` from `scenarios/90-admin-tailnet-demo`.

Expected: FAIL because `/` is currently 404 and access projection does not exist.

**Step 3: Implement Workflow root app composition**

Add root `static.fileserver` module and copy app assets in `seed.sh`. Add
Workflow pipelines for app session, access projection, orders read, and orders
update. Use auth.jwt validation and static role/scope fixtures to demonstrate
scope effects.

**Step 4: Verify GREEN**

Run:
- `bash -n scenarios/90-admin-tailnet-demo/seed/seed.sh`
- `bash -n scenarios/90-admin-tailnet-demo/test/run.sh`
- `ruby -e 'require "yaml"; YAML.load_file(ARGV.fetch(0)); puts "yaml-ok"' scenarios/90-admin-tailnet-demo/config/app.yaml`
- `./test/run.sh` from scenario directory

Expected: scenario exits 0 and reports zero failures.

**Rollback:** `docker compose down`; revert Task 4 commit; rebuild previous image.

### Task 5: Scenario 90 Admin/Auth/Authz Browser QA

**Files:**
- Modify: `/Users/jon/workspace/workflow-scenarios/.worktrees/scenario90-real-app-access/scenarios/90-admin-tailnet-demo/test/run.sh`
- Create: `/Users/jon/workspace/workflow-scenarios/.worktrees/scenario90-real-app-access/scenarios/90-admin-tailnet-demo/test/qa-admin-app.mjs`
- Modify: `/Users/jon/workspace/workflow-scenarios/.worktrees/scenario90-real-app-access/scenarios/90-admin-tailnet-demo/README.md`

**Step 1: Write failing Playwright QA**

Create a Playwright script that:
- visits `/` and verifies the regular app renders;
- logs in as support and verifies update controls are hidden/disabled;
- logs in as admin and verifies update controls are enabled;
- visits `/admin/`, logs in, opens Authentication and Authorization admin tools;
- asserts no console errors and no failed `/api/` responses after login.

**Step 2: Run QA to verify RED**

Run: `node test/qa-admin-app.mjs`

Expected: FAIL until Task 1/2/4 behavior is present in the rebuilt image.

**Step 3: Integrate QA into scenario test**

Call the Playwright script from `test/run.sh` when Playwright is available.
Record screenshots under `/tmp/scenario90-*` for exploratory review.

**Step 4: Verify GREEN**

Run:
- `./test/run.sh`
- `node test/qa-admin-app.mjs`
- `curl -fsS http://127.0.0.1:18080/api/status`
- `curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:18080/api/admin/contributions`

Expected: scenario and QA exit 0; `/api/status` reports Workflow Go runtime;
anonymous admin contribution API returns 401.

**Rollback:** `docker compose down`; remove QA integration commit; restore prior scenario test.

## Adversarial Plan Review

Status: PASS with required execution constraints.

| class | result | note |
|---|---|---|
| Project guidance conflicts | Clean | Workflow remains the harness; plugin-first changes are split by repo. |
| Assumptions under attack | Clean | Iframe auth bridge and fixture data assumptions have testable fallbacks. |
| Repo-precedent conflicts | Clean | Uses existing admin contribution and auth admin config contracts. |
| YAGNI | Clean | No persistence or provider engine rewrite. |
| Missing failure modes | Clean | Covers root 404, iframe 401, unauthorized admin tool visibility, update 403, and console errors. |
| Security/privacy | Clean | Auth headers, same-origin bridge, redacted secrets, and backend scope checks are required. |
| Infrastructure impact | Clean | Local Docker/Tailscale only; no production change. |
| Multi-component validation | Clean | Scenario/Playwright crosses real Workflow/plugin/admin/SPA boundaries. |
| Rollback wiring | Clean | Every runtime-affecting task includes rollback. |
| Demonstration fidelity | Clean | Demo executes real Workflow server and Go plugins; fixtures are data seams only. |
| Hidden dependencies | Clean | PR order is explicit: admin/authz/auth before scenario proof. |
| Verification-class mismatch | Clean | UI, Go, API, Docker runtime, and browser checks are matched to change class. |

## Alignment Check

Status: PASS.

| design requirement | plan coverage |
|---|---|
| Root Workflow app at `/` | Task 4, Task 5 |
| Dynamic admin plugin tools | Task 1, Task 3, Task 4 |
| Authz iframe no 401 after login | Task 1, Task 2, Task 5 |
| Auth manager UI from plugin contracts | Task 3, Task 4, Task 5 |
| User-friendly admin language | Task 1 |
| Scope impact in admin and SPA | Task 4, Task 5 |
| No fake harness | Task 4 static and runtime checks |
| Playwright exploratory QA | Task 5 |
