# Scenario 90: Admin Tailnet Demo

This scenario runs a small app with an auth-gated administration portal, a declared-scope authz role manager, and a Tailscale sidecar.

- App: <http://localhost:18080/>
- Admin: <http://localhost:18080/admin>
- Authz admin contribution: <http://localhost:18080/admin/authz>
- Status API: <http://localhost:18080/api/status>

Demo users:

- `admin@tailnet` / `admin`: full admin and frontend scopes.
- `readonly-admin@tailnet` / `readonly`: admin read scopes only.
- `app-user@tailnet` / `user`: frontend scopes only.

The authz contribution displays frontend and admin scopes from the declared scope catalog, including owner plugin/module metadata. The demo defaults to `AUTHZ_PROVIDER=keto`, runs a local Ory Keto container, and resolves role assignments into Keto scope relationship checks for the app/admin surfaces.

## Run

```sh
docker compose up -d --build
```

If `TS_AUTHKEY` is present, the sidecar joins the tailnet as `workflow-admin-demo` and publishes the app with `tailscale serve`.

Without `TS_AUTHKEY`, the app still runs locally. On a host already connected to Tailscale:

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
