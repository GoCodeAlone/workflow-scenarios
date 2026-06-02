# Scenario 102 — Cross-Service Asymmetric Auth (ES256)

Two Workflow engine processes proving genuine cross-service asymmetric JWT
verification. App A (issuer) mints ES256 tokens. App B (verifier) validates
them using only App A's public JWKS — no shared secret, no mock IDP.

Closes [workflow-plugin-auth#41](https://github.com/GoCodeAlone/workflow-plugin-auth/issues/41).

## Architecture

```
App A (auth.m2m, port 18102)          App B (sso.oidc, port 18112)
  POST /oauth/token  ←── client_credentials (app-a-local secret)
  GET  /oauth/jwks   ────── public JWKS ──→  sso.oidc jwksUri verify
                                              POST /verify
                                              GET  / (console UI)
```

- **App A** uses `auth.m2m` with `algorithm: ES256` (key auto-generated).
- **App B** uses `sso.oidc` with `jwksUri: http://app-a:8080/oauth/jwks` (PR 1
  feature — no OIDC discovery, no shared secret).
- The `client_credentials` secret (`APP_A_CLIENT_SECRET`) authenticates only
  to App A. App B holds **no secret** — cross-service trust is purely the public key.

## Running

```bash
# Build images and bring up the stack
bash seed/seed.sh

# Curl smoke (12 assertions)
bash test/run.sh

# Playwright e2e
cd ../../e2e && npx playwright test scenario-102
```

## Ports

| Service | Host port | Container port |
|---------|-----------|---------------|
| App A (issuer) | 18102 | 8080 |
| App B (verifier + console) | 18112 | 8080 |

## Key files

| File | Purpose |
|------|---------|
| `config/app-a.yaml` | Engine config: `auth.m2m` ES256 issuer |
| `config/app-b.yaml` | Engine config: `sso.oidc` jwksUri verifier + `/verify` pipeline |
| `docker-compose.yml` | Two-service stack |
| `seed/seed.sh` | Cross-compile + image bake + stack up |
| `test/run.sh` | Curl smoke (12 assertions: 2 healthz + token issue + 3 claim checks + accept + wrong-key/aud/issuer/expired/garbage reject) |
| `test/mint-token/` | Stdlib-only ES256 JWT minter for the negative cases (claims are configurable; ECDSA signatures are randomized per RFC 6979/nonce, but the reject *outcome* is deterministic) |
| `ui/index.html` | Browser verification console served by App B |
| `../../e2e/tests/scenario-102-cross-service-asymmetric.spec.ts` | Playwright spec |
