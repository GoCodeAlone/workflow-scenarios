# Admin App Access Integration Design

## User Ask

Fix Scenario 90 so it demonstrates a real Workflow-powered application at `/`
plus an admin portal at `/admin/`. The admin portal must load plugin-declared
management UI dynamically, use real auth/authz plugin contracts, avoid
user-facing jargon like "surfaces" and "contributions", show auth management
controls, show role/scope effects in admin and the primary SPA, and pass real
Playwright exploratory QA. The demo must not fake the app harness.

## Global Design Guidance

Source: `/Users/jon/workspace/AGENTS.md`; scenario-local durable guidance is
captured through this design and the runtime checks below.

| guidance | design response |
|---|---|
| Workflow is the app framework | Scenario 90 keeps Workflow Go server, YAML pipelines, Go plugins, and static assets served through Workflow. |
| Plugin-first behavior | Admin shell and plugin UIs get reusable changes; scenario only composes and proves them. |
| Avoid duplicated application plumbing | No Python/Node/Ruby harness; root app and admin APIs are Workflow routes/pipelines. |
| Build usable operational UI | Admin language becomes "Admin tools" / "Management pages"; auth and authz tools expose task-oriented controls. |
| Prove multi-component behavior | Runtime proof must cross primary SPA, admin shell, auth plugin, authz UI, admin contribution registry, and protected APIs. |

## Demonstration Fidelity

The demo must execute the real artifact:

- Workflow server binary from `/Users/jon/workspace/workflow/cmd/server`.
- External Go plugin binaries for admin, auth, authz-ui, and auth providers.
- Workflow YAML routes/pipelines for root app, admin, auth, authz, and access
  projection.
- Static SPA assets served by `static.fileserver`.

Allowed fixture seam: Scenario 90 may use in-memory/static YAML data for orders,
users, role assignments, and provider descriptors. The artifact under
demonstration remains the Workflow runtime and plugin contracts.

Forbidden: any application-specific Python/Node/Ruby server, hard-coded browser
output, or copied auth/authz logic outside plugin/Workflow contracts.

## Design

Use the admin plugin as a generic management shell and keep plugin-owned
management UIs in their owning plugins.

1. `workflow-plugin-admin` updates the shell language and bridge:
   - Rename user-facing "Surfaces" / "Contributions" to "Admin tools" /
     "Management pages".
   - Keep `AdminContribution` as internal/proto contract language.
   - Add a narrow iframe token bridge. Embedded tools can send
     `workflow.admin.auth.request`; the shell replies only to same-origin admin
     paths with `workflow.admin.auth.response` containing a bearer token.
   - Render tool navigation based on the filtered contribution list returned by
     the backend. The shell remains unaware of auth/authz-specific fields.

2. `workflow-plugin-authz-ui` becomes admin-bridge aware:
   - API client requests a token from the shell when embedded, then includes
     `Authorization: Bearer ...`.
   - 401/403 responses render explicit not-authorized states instead of
     console-only errors.
   - RBAC/ABAC/ReBAC tabs remain capability-driven and scope-gated.
   - Scope assignment keeps using declared scope lookup, not free-text entry.

3. `workflow-plugin-auth` contributes an admin-management contract:
   - Add a service method/step output that describes an admin tool for auth
     management.
   - Reuse existing `step.auth_admin_config_describe` and
     `step.auth_admin_config_validate` contracts for passkeys, password login,
     MFA/magic link, OAuth/OIDC providers, secrets redaction, and diagnostics.
   - Do not invent fake toggles. UI changes must validate through plugin
     contract output.

4. Scenario 90 composes the real app and admin:
   - `/` serves a Workflow-powered primary SPA for an orders/support use case.
   - The SPA calls Workflow APIs for session, access projection, order read, and
     update actions.
   - Frontend scopes visibly affect SPA behavior:
     `frontend:orders:read` controls order visibility and
     `frontend:orders:update` controls update controls.
   - Admin scopes visibly affect admin behavior:
     `admin:authz.roles:read` lists Authorization, and
     `admin:authz.roles:update` enables updates. A lower-privilege admin should
     not see or should not load protected tools.
   - `/admin/` provides Auth and Authorization admin tools through dynamic
     plugin contributions, not shell hard-coding.

## Security Review

| topic | design |
|---|---|
| Authn | Admin and protected app APIs require `auth.jwt` token validation. |
| Authz | UI visibility is advisory; server-side Workflow pipelines enforce representative scope checks for app/admin APIs. |
| Least privilege | Contribution list receives granted permissions and filters tools before navigation is built. |
| Iframe token bridge | Same-origin/path checks only; token is returned only after explicit embedded-tool request. |
| Secret handling | Auth config descriptors redact secrets; scenario tests assert secrets are not echoed. |
| Confused deputy | Admin shell does not call authz management APIs on behalf of tools except for contribution listing; embedded tools call their own configured APIs with the authenticated token. |

## Infrastructure Impact

No production infrastructure. Runtime impact is Docker image build, local Docker
Compose launch, and optional Tailscale sidecar/serve state. Rollback is to stop
the compose stack, remove the image if needed, and revert the plugin/scenario
PRs.

## Multi-Component Validation

| proof | expected evidence |
|---|---|
| Admin unit tests | User-facing labels are jargon-free; iframe token bridge is present and constrained. |
| Authz UI tests/build | API client sends bearer tokens after bridge response; unauthorized state renders cleanly. |
| Auth plugin tests | Auth admin contribution descriptor exists and config validation remains real/secret-redacted. |
| Scenario static checks | No Python harness; root app assets are served by Workflow; admin/authz/auth contributions are declared dynamically. |
| Scenario runtime checks | `/` returns 200; anonymous admin APIs return 401; login works; scope-specific app/admin behavior changes. |
| Playwright QA | Browser navigates root SPA and admin tools without console 401/JS errors; screenshots captured from real runtime. |

## Rollback

| change | rollback |
|---|---|
| Admin shell bridge/labels | Revert admin plugin PR; release prior admin version. |
| Authz UI bridge client | Revert authz-ui PR; release prior authz-ui version. |
| Auth admin contribution | Revert auth plugin PR; auth config APIs remain callable directly. |
| Scenario 90 app/admin proof | Revert scenario PR; `docker compose down`; rebuild previous image if needed. |

## Assumptions

| id | assumption | fallback |
|---|---|---|
| A1 | Same-origin iframe bridge is acceptable for local admin tools. | Add per-tool signed bootstrap endpoint later; keep initial bridge same-origin only. |
| A2 | Scenario can model role/scope effects with static Workflow data. | Use plugin-backed in-memory fixtures if YAML static responses cannot express required variants. |
| A3 | Auth plugin admin management can initially be descriptor/validation based without durable persistence. | Scenario labels it effective/validated config; persistence belongs to host application config management. |
| A4 | Admin contribution registry remains runtime/declarative, not persistent admin-owned state. | Owning plugins/apps persist their own domain state later. |

## Self-Challenge

| doubt | response |
|---|---|
| Could a single static page prove this? | No. The user specifically needs plugin-loaded admin functionality and Workflow-authenticated SPA access. Static pages would repeat the fake-demo failure. |
| What fails first? | Embedded tools lose auth context. The iframe token bridge and Playwright console checks directly cover this. |
| Is token bridge risky? | It is limited to same-origin admin paths and only transmits the existing admin bearer token. Backend still enforces authz. |

## Adversarial Design Review

Status: PASS after incorporating demonstration-fidelity and embedded-auth
requirements.

| class | result | note |
|---|---|---|
| Project guidance conflicts | Clean | Workflow remains the app framework; no harness. |
| Assumptions under attack | Clean | Bridge/auth persistence assumptions have fallbacks. |
| Repo precedent conflicts | Clean | Keeps `AdminContribution` proto internals while improving shell copy. |
| YAGNI | Clean | No persistence engine or policy engine rewrite. |
| Missing failure modes | Clean | Covers root 404, iframe 401, unauthorized role, and console errors. |
| Security/privacy | Clean | Server enforcement, secret redaction, and bridge origin checks required. |
| Infrastructure | Clean | Local Docker/Tailscale only. |
| Multi-component validation | Clean | Requires real Workflow runtime, plugins, SPA, admin, and Playwright. |
| Rollback | Clean | Per-repo revert and compose shutdown paths defined. |
| Simpler alternative | Clean | Static links rejected because they do not prove plugin management. |
| User intent drift | Clean | Addresses root app, admin, auth manager, authz manager, scope impact, and SPA enforcement. |
