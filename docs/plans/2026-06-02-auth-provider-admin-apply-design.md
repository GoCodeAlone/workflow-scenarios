# Auth Provider Admin Apply Design

Date: 2026-06-02

## Goal

Close the gap between the existing admin/auth/authz proof and a usable auth
administration path:

- A protected admin operator can validate and apply auth configuration changes.
- Secret values submitted through admin are written through a configured
  Workflow secrets module, not persisted or echoed by the auth plugin.
- Applied non-secret config state is persisted by the host application.
- Scenario 90 proves the contract with the real Workflow server, real admin
  shell, real auth/authz gates, and real Workflow pipeline steps.

## Current State

Workflow already provides the reload/config mechanisms this work must not
duplicate:

- `POST /api/workflow/reload` reloads the current config.
- The server supports file watch reload through `config.NewConfigWatcher`.
- The server has database config polling when a DB config store is configured.

Workflow also already provides secret storage primitives:

- `secrets.Provider` supports `Get`, `Set`, `Delete`, and `List`.
- `step.secret_set` writes submitted values through a named secrets module.
- Secret modules expose providers through the service registry.

Auth/provider plugins already expose management descriptors or concrete remote
CRUD steps:

- `workflow-plugin-auth` exposes auth admin contribution, config describe,
  config validate, and provider catalog steps.
- Provider plugins own provider-specific management operations:
  Auth0 clients/users/roles, Okta apps/users/groups/policies, Entra users/groups
  and applications, Ory Kratos identities, Ory Hydra OAuth clients/JWKs/trusted
  issuers, Ory Polis SSO/directory resources, and Scalekit SSO/directory
  resources.

`workflow-plugin-infra` and Workflow IaC own infrastructure resource planning
and lifecycle. Auth provider tenant/client/user provisioning is not infra unless
it is explicitly modeled as an IaC resource later.

Scenario 90 already proves:

- Primary app and admin app are served by Workflow.
- Admin is protected by authentication and authorization.
- Admin nav is contribution-driven.
- Auth config describe/validate and provider catalog are live.
- Authz UI is functional through the admin nav.

## Design

### Ownership Boundary

Auth plugin:

- Defines descriptor and validation contracts.
- Redacts secret-bearing fields from describe/validate output.
- Does not persist host config.
- Does not own Workflow reload.
- Does not own secret storage.
- Does not own generic remote provisioning orchestration.

Admin plugin:

- Renders generic contribution UI.
- Adds an optional apply action when contribution metadata includes
  `apply_path`.
- Sends the same `desired_config` draft used for validation.
- Does not assume auth-specific fields or semantics.

Workflow host/scenario:

- Owns authenticated and authorized apply endpoints.
- Runs validation before persistence.
- Writes submitted secret values through `step.secret_set`.
- Persists accepted non-secret config state plus secret refs/status.
- Can trigger Workflow reload or rely on existing hot reload/config-store
  behavior in production deployments.

Provider plugins:

- Own provider-specific remote CRUD/provisioning calls.
- Surface actions through provider-specific Workflow steps.
- Are invoked by host endpoints with explicit scopes, audit, idempotency, and
  rollback behavior.

Infra plugin:

- Owns infrastructure resources, DNS/compute/storage/network provider bindings,
  and wfctl/IaC flows.
- Does not become the default place for Auth0/Okta/Entra/Hydra client CRUD.

### Scenario 90 Extension

Scenario 90 will add:

- `apply_path: /api/admin/auth/config/apply` to the auth contribution metadata.
- A Vault dev sidecar and `secrets.vault` module used only for scenario proof.
- A persisted auth admin state table.
- `POST /api/admin/auth/config/apply`:
  - authenticates the bearer token with `auth.jwt`;
  - enforces `admin:auth.config:update` from persisted admin role grants;
  - validates `desired_config` with `step.auth_admin_config_validate`;
  - rejects invalid config without persistence;
  - writes `auth0_client_secret`, when provided, through `step.secret_set`;
  - persists only sanitized accepted config JSON, secret refs, actor, and time;
  - returns `applied`, `valid`, `accepted_config`, `secret_fields`,
    `secret_refs`, `warnings`, and no submitted secret values.
- `GET /api/admin/auth/config/applied`:
  - authenticates and enforces `admin:auth.config:read`;
  - returns the last applied state for verification and UI observability.

The scenario intentionally does not provision a real Auth0/Okta/Entra tenant in
public CI. Live remote provisioning requires provider credentials, external API
side effects, quotas, and cleanup; that belongs in provider-specific tests or a
credentialed/private scenario. Scenario 90 proves the cross-component admin
apply path and secret-provider wiring. Provider plugins continue to prove their
SDK-backed CRUD steps directly.

### Adversarial Review Adjustment

The initial sketch proposed a file-backed secrets module. That was wrong for
runtime Workflow: `secrets.file` exists in wfctl secret-store resolution, but
the Workflow server module registry currently exposes `secrets.vault`,
`secrets.aws`, and `secrets.keychain`. Scenario 90 therefore uses a Vault dev
container and configures a real `secrets.vault` runtime module. This keeps the
proof honest: `step.secret_set` crosses the real module/provider boundary.

### Use Cases

Solo developer:

- Boots Scenario 101/bootstrap auth or local auth.
- Uses admin to configure passkey/local auth settings.
- Stores local provider secrets through file/keychain/env-backed Workflow
  secrets modules.
- Relies on Workflow hot reload or an explicit reload endpoint after config
  persistence.

Development team:

- Configures staging identity providers from the admin UI.
- Validates config before applying.
- Stores client secrets through the environment's configured secrets provider.
- Uses provider-plugin CRUD routes for staging OIDC clients or SSO connections,
  guarded by `admin:auth.providers.write`.

SRE/platform team:

- Manages approved identity-provider clients/connections with audit and
  explicit scopes.
- Uses Workflow/wfctl infra for infrastructure and auth provider plugins for
  identity-provider resources.
- Requires idempotent provider operations, rollback/delete paths, and no secret
  material in logs or persisted config state.

## Security Requirements

- Apply endpoints must be server-side authenticated and authorized.
- Client-supplied role/scope claims are not trusted.
- Invalid config must not be persisted.
- Submitted secret values must not appear in API responses, stored config JSON,
  logs, or test artifacts.
- Secret writes must target a configured Workflow secrets module.
- Direct iframe/plugin UI access remains protected by server-side endpoints; UI
  hiding is not an authorization control.

## Rollback

- Admin UI apply button is feature-detected by `apply_path`; removing
  `apply_path` hides it without breaking validate-only contributions.
- Scenario state is local file/SQLite data and can be reset with Docker compose
  teardown.
- Production hosts should retain prior accepted config, apply new config only
  after validation, and use Workflow's existing reload/config-store rollback
  path rather than auth-plugin-owned reload code.
