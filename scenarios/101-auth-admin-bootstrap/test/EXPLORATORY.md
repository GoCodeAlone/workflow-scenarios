# Scenario 101 — Exploratory QA (playwright-cli)

**When:** 2026-06-02 · **Driver:** `playwright-cli` (headless, isolated session `s101qa`) · **Target:** `http://localhost:18101` (live docker-compose stack: engine + workflow-plugin-auth v0.3.0 gRPC + Postgres + auth.jwt).

Manual browser walkthrough of the operator-facing **first-run admin bootstrap** flow, complementing the deterministic `test/run.sh` (10/10) and the committed Playwright virtual-authenticator spec (`e2e/tests/scenario-101-auth-admin-bootstrap.spec.ts`, 7/7).

## Walkthrough + findings

| # | Step | Observed | Screenshot |
|---|------|----------|------------|
| 1 | Load `/` on a fresh DB (0 admin credentials) | Heading badge **OPEN**; "Bootstrap mode: no admin credentials exist. Redeem the one-time code…"; Bootstrap-code field + Redeem button | `screenshots/01-bootstrap-form.png` |
| 2 | Enter the bootstrap code → Redeem | Panel switches to **"Authenticated as admin@scenario-101.test"** with **Enrol Passkey** + **Logout** — bootstrap login succeeds end-to-end in a real browser (POST /admin/bootstrap/redeem → `step.auth_bootstrap_redeem` → `step.auth_jwt_issue` → session token held by the page) | `screenshots/02-authenticated.png` |
| 3 | Click **Enrol Passkey** | No state change — `navigator.credentials.create()` requires an authenticator. This `playwright-cli` session has **no virtual authenticator**, so the WebAuthn ceremony cannot complete here. The full create+get ceremony is exercised by the committed Playwright spec via a CDP virtual authenticator (`WebAuthn.addVirtualAuthenticator`, ctap2/internal). | `screenshots/03-enrol-attempt.png` |
| 4 | Click **Logout** | Returns to the bootstrap form (session cleared client-side; server-side `step.token_revoke` blacklists the JWT) | `screenshots/04-after-logout.png` |

## Verdict

The operator first-run bootstrap-login flow (fresh → redeem code → authenticated super-admin session → logout) works end-to-end through a real browser against the live stack. The passkey-enrolment ceremony is covered by the committed Playwright spec (virtual authenticator) and by `run.sh` at the API/gate level; it cannot be driven from a bare `playwright-cli` session because no authenticator is attached.

## Minor finding (non-blocking)

- The heading **OPEN/CLOSED** badge reflects the status fetched at initial page load and is not re-fetched after redeem/enrol within the same page view (the content panel updates correctly; the badge is cosmetic). Refreshing the page shows the correct badge. Candidate polish: re-fetch `/admin/bootstrap/status` after state transitions.
