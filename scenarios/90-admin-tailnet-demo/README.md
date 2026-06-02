# Scenario 90: Workflow-Native Admin Tailnet Demo

This scenario runs the Workflow Go server with external Go plugin binaries. It
does not contain or run an application-specific Python/Node/Ruby web harness.

- Primary app: <http://localhost:18080/>
- App/status API: <http://localhost:18080/api/status>
- Admin shell: <http://localhost:18080/admin/>
- Authz admin contribution: <http://localhost:18080/admin/authz/>
- Admin contribution API: <http://localhost:18080/api/admin/contributions>
- Auth provider catalog API: <http://localhost:18080/api/admin/auth/providers>
- Auth config apply API: <http://localhost:18080/api/admin/auth/config/apply>
- Auth config applied-state API: <http://localhost:18080/api/admin/auth/config/applied>

The scenario creates an admin user during tests:

- Email: `admin@tailnet`
- Password: `admin-password`

The primary app test user is:

- Email: `app-user@tailnet`
- Password: `app-password`

The image is built by `seed/seed.sh` from local checkouts:

- `workflow` server binary
- `workflow-plugin-admin`
- `workflow-plugin-auth`
- `workflow-plugin-authz-ui`
- `workflow-plugin-auth0`
- `workflow-plugin-entra`
- `workflow-plugin-okta`
- `workflow-plugin-sso`
- `workflow-plugin-ory-kratos`
- `workflow-plugin-ory-hydra`
- `workflow-plugin-ory-polis`
- `workflow-plugin-scalekit`

The root app, admin UI, and authz UI are all served by Workflow routes and
`static.fileserver`. Admin navigation is backed by
`step.admin_register_contribution` and `step.admin_list_contributions`; auth
configuration is declared by `step.auth_admin_contribution_describe` and rendered
through the admin shell's generic config-form mode; authz proof endpoints use
`workflow-plugin-authz-ui` steps. The app demonstrates frontend scope checks for
order read/update and admin scope checks for auth/authz management pages.

Auth config apply is host-owned Workflow YAML: the endpoint authenticates with
`auth.jwt`, enforces `admin:auth.config:update`, validates through
`workflow-plugin-auth`, writes the submitted Auth0 provider secret through a
real `secrets.vault` module backed by the scenario Vault sidecar, and persists
only accepted non-secret config plus `secret://` refs in SQLite. The
applied-state endpoint exposes the persisted non-secret config and secret refs
for scenario verification and admin observability, without returning secret
values.

Provider catalog and provider descriptor routes are public-CI safe. Live
remote Auth0/Okta/Entra/Ory/Scalekit provisioning remains provider-plugin-owned
and should run in credentialed/provider-specific scenarios, not through
`workflow-plugin-infra` unless an identity resource is explicitly modeled as
IaC.

## Run

```sh
./seed/seed.sh
```

If `TS_AUTHKEY` is present, the sidecar joins the tailnet as
`workflow-admin-demo` and publishes the app with `tailscale serve`.

Without `TS_AUTHKEY`, the app still runs locally. On a host already connected to
Tailscale:

```sh
tailscale serve --bg --http=18080 http://127.0.0.1:18080
```

## Test

```sh
./test/run.sh
```

## Stop

```sh
docker compose down
tailscale serve reset
```
