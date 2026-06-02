# Auth Provider Admin Apply Plan

Date: 2026-06-02

## Scope

Implement the smallest real slice that proves auth admin save/apply without
duplicating Workflow reload, Workflow secrets, provider CRUD, or infra.

PRs:

- `workflow-plugin-admin`: generic config-form apply button.
- `workflow-scenarios`: Scenario 90 apply endpoint, secrets wiring, and tests.

No `workflow-plugin-auth` PR is required unless implementation proves the
current descriptor/validation contract cannot support the scenario.

## Tasks

1. Admin UI: Add optional apply action
   - In `internal/ui_dist/index.html`, render an `Apply changes` button only
     when contribution metadata has `apply_path`.
   - POST `{desired_config: draft}` to `apply_path` with the same auth headers
     used by validation.
   - Render the JSON response in the existing config result area.
   - Verify with `go test ./...`.

2. Scenario 90: Wire auth contribution metadata
   - Configure `step.auth_admin_contribution_describe` with `describe_path`,
     `validate_path`, and `apply_path`.
   - Verify `/api/admin/contributions` exposes `apply_path` only to authorized
     users who can see the auth contribution.

3. Scenario 90: Add secrets module and persisted apply state
   - Add a Vault dev sidecar and `secrets.vault` module suitable for local
     Docker proof.
   - Add/create an auth admin applied-state table.
   - Store accepted non-secret config JSON, secret refs/status, actor, and
     timestamp.

4. Scenario 90: Add protected apply endpoint
   - Authenticate with `auth.jwt`.
   - Enforce `admin:auth.config:update` from `scenario90_role_assignments`.
   - Validate with `step.auth_admin_config_validate`.
   - Route invalid validation to a non-persisting response.
   - Write submitted secret fields through `step.secret_set`.
   - Persist sanitized accepted config and refs only.
   - Return `applied:true` only after secret write and persistence.

5. Scenario 90: Add applied-state read endpoint
   - Authenticate with `auth.jwt`.
   - Enforce `admin:auth.config:read`.
   - Return persisted state without secret values.

6. Scenario 90: Extend verification
   - Shell tests cover contribution metadata, valid apply, invalid apply, secret
     redaction, state persistence, delegated read-only denial, and support-user
     denial.
   - Playwright tests click Authentication, validate, apply, navigate to
     Authorization, and confirm no console errors.
   - Scenario test must run the real Workflow server through Docker.

## Non-Goals

- No new Workflow reload implementation.
- No new secret storage provider.
- No new infra/IaC resource implementation.
- No public-CI live Auth0/Okta/Entra provisioning.
- No auth-specific logic in the generic admin shell.

## Verification

- `workflow-plugin-admin`: `go test ./...`.
- `workflow-scenarios`: `go test ./...`.
- `workflow-scenarios/scenarios/90-admin-tailnet-demo/test/run.sh`.
- `workflow-scenarios/scenarios/90-admin-tailnet-demo/test/run-playwright.sh`.
- Manual/adversarial review of diffs before PR/merge.
