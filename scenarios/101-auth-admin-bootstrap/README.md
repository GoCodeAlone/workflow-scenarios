# Scenario 101 — Auth Admin Bootstrap (durable first-run)

Demonstrates **workflow-plugin-auth v0.3.0**'s durable first-run admin bootstrap as a
real admin stack: engine + the auth plugin (gRPC subprocess) + Postgres
(`database.workflow`) + `auth.jwt` session module.

## Flow proved

| # | Step | Assertion |
|---|------|-----------|
| 1 | Fresh DB (0 admin credentials) | `GET /admin/bootstrap/status` → `{open:true}` |
| 2 | Wrong bootstrap code | `POST /admin/bootstrap/redeem` → 403 `invalid_code` |
| 3 | Correct code (`AUTH_BOOTSTRAP_CODE`) | 200 + bearer token (`step.auth_jwt_issue`); super-admin row created |
| 4 | Server-side gate (`step.auth_validate`) | authed `passkey/register/begin` 200; unauth 401 |
| 5 | Credential enrolled → bootstrap auto-closes | `status` → `{open:false}`; re-redeem → 403 `bootstrap_closed` (V-B4) |

**Invariant:** bootstrap is OPEN ⟺ zero admin credentials exist. Auto-closes on first
passkey/SSO enrolment; stays closed on redeploy with the same DB; re-opens on an empty
store (break-glass). The plugin steps are stateless — persistence (`users`/`credentials`),
routing, and session minting are owned by this scenario's `config/app.yaml` pipeline.

## Run

```sh
bash seed/seed.sh          # cross-compile + bake image + bring up postgres+app at :18101
bash test/run.sh           # deterministic curl smoke (steps 1-5)
# Full passkey ceremony (CDP virtual authenticator):
( cd ../../e2e && SCENARIO_URL=http://127.0.0.1:18101 npx playwright test scenario-101-auth-admin-bootstrap.spec.ts )
docker compose down -v
```

Env (set in `docker-compose.yml`, test-only literals): `AUTH_BOOTSTRAP_CODE` (≥16),
`AUTH_JWT_SECRET` (≥32), `DATABASE_URL`.

Exploratory QA (playwright-cli) findings: `test/EXPLORATORY.md`.
