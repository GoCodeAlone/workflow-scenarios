#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCENARIO_DIR="$(dirname "$SCRIPT_DIR")"
BASE="${BASE:-http://127.0.0.1:18080}"
PASS_COUNT=0
FAIL_COUNT=0

pass() { echo "PASS: $1"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail() { echo "FAIL: $1"; FAIL_COUNT=$((FAIL_COUNT + 1)); }

contains() {
  local body="$1"
  local pattern="$2"
  local label="$3"
  if grep -q "$pattern" <<<"$body"; then
    pass "$label"
  else
    fail "$label missing pattern: $pattern"
  fi
}

json_len_at_least() {
  local body="$1"
  local filter="$2"
  local min="$3"
  local label="$4"
  local count
  count="$(jq -r "$filter | length" <<<"$body" 2>/dev/null || echo 0)"
  if [ "$count" -ge "$min" ]; then
    pass "$label"
  else
    fail "$label expected at least $min, got $count"
  fi
}

if find "$SCENARIO_DIR" -type f \( -name '*.py' -o -name '*.pyc' \) | grep -q .; then
  fail "Scenario contains a Python app harness artifact"
else
  pass "Scenario has no Python app harness artifacts"
fi
if grep -A28 'name: admin-authz-contribution' "$SCENARIO_DIR/config/app.yaml" | grep -q 'type: step.authz_admin_contribution'; then
  pass "Authz admin contribution comes from authz UI plugin step"
else
  fail "Authz admin contribution must come from authz UI plugin step"
fi

"$SCENARIO_DIR/seed/seed.sh"

entrypoint="$(docker inspect workflow-admin-tailnet-demo --format '{{json .Config.Entrypoint}} {{json .Config.Cmd}}' 2>/dev/null || true)"
contains "$entrypoint" '"/usr/local/bin/server"' "Container entrypoint is Workflow server"
contains "$entrypoint" '"/data/app.yaml"' "Container runs Workflow config"

status="$(curl -fsS "$BASE/api/status")"
contains "$status" '"runtime":"workflow-go-server"' "Status API reports Workflow Go runtime"
contains "$status" '"plugin_runtime":"external-go-binaries"' "Status API reports external Go plugin runtime"
contains "$status" '"primary_app":"/"' "Status API reports root primary app"

root_page="$(curl -fsS "$BASE/")"
contains "$root_page" "Scenario 90 Workflow App" "Root path serves the primary Workflow app"
contains "$root_page" "/admin/" "Primary app links to admin portal"
contains "$root_page" "/app/app.js" "Primary app loads Workflow-served SPA asset"

admin_status="$(curl -s -o /dev/null -w "%{http_code}:%{redirect_url}" "$BASE/admin")"
if [[ "$admin_status" == "308:$BASE/admin/" || "$admin_status" == "308:/admin/" ]]; then
  pass "Admin bare path redirects to static Workflow admin shell"
else
  fail "Admin bare path redirect expected, got $admin_status"
fi

admin="$(curl -fsS "$BASE/admin/")"
contains "$admin" "<title>Workflow Admin</title>" "Admin shell is served by Workflow static.fileserver"
contains "$admin" 'data-login-endpoint="/api/admin/auth/login"' "Admin shell advertises login endpoint"
contains "$admin" 'id="login-form"' "Admin shell renders login form"
if grep -E 'data-panel="(identity|authorization)-panel"|Identity provider|Authorization mode' <<<"$admin" >/dev/null; then
  fail "Admin shell must be contribution-driven, not hardcoded to auth/authz surfaces"
else
  pass "Admin shell is contribution-driven"
fi

authz_page="$(curl -fsS "$BASE/admin/authz/")"
contains "$authz_page" "<title>Authz Policy Manager</title>" "Authz UI plugin assets are served"

unauth_contribs_code="$(curl -s -o /dev/null -w "%{http_code}" "$BASE/api/admin/contributions" || echo "000")"
if [ "$unauth_contribs_code" = "401" ]; then
  pass "Anonymous admin contributions API is unauthorized"
else
  fail "Anonymous admin contributions API expected 401, got $unauth_contribs_code"
fi

unauth_authz_code="$(curl -s -o /dev/null -w "%{http_code}" "$BASE/api/authz/roles" || echo "000")"
if [ "$unauth_authz_code" = "401" ]; then
  pass "Anonymous authz roles API is unauthorized"
else
  fail "Anonymous authz roles API expected 401, got $unauth_authz_code"
fi

unauth_seed_code="$(curl -s -o /dev/null -w "%{http_code}" -X POST "$BASE/api/scenario90/seed/roles" || echo "000")"
if [ "$unauth_seed_code" = "403" ]; then
  pass "Anonymous role seed endpoint is forbidden"
else
  fail "Anonymous role seed endpoint expected 403, got $unauth_seed_code"
fi
committed_seed_code="$(curl -s -o /dev/null -w "%{http_code}" -X POST -H 'X-Scenario90-Seed-Token: scenario90-local-seed' "$BASE/api/scenario90/seed/roles" || echo "000")"
if [ "$committed_seed_code" = "403" ]; then
  pass "Committed sample seed token is not accepted"
else
  fail "Committed sample seed token expected 403, got $committed_seed_code"
fi

register_body="$(curl -sfS -X POST "$BASE/api/admin/auth/register" \
  -H "content-type: application/json" \
  -d '{"email":"admin@tailnet","password":"admin-password","name":"Scenario Admin"}' 2>/dev/null || true)"
token="$(jq -r '.token // .access_token // empty' <<<"$register_body" 2>/dev/null || true)"
if [ -z "$token" ]; then
  login_body="$(curl -sfS -X POST "$BASE/api/admin/auth/login" \
    -H "content-type: application/json" \
    -d '{"email":"admin@tailnet","password":"admin-password"}' 2>/dev/null || true)"
  token="$(jq -r '.token // .access_token // empty' <<<"$login_body" 2>/dev/null || true)"
fi
if [ -n "$token" ]; then
  pass "Admin login returns JWT token"
else
  fail "Admin login did not return a JWT token"
fi
AUTH_HEADER="Authorization: Bearer $token"

profile="$(curl -fsS -H "$AUTH_HEADER" "$BASE/api/admin/auth/profile")"
contains "$profile" '"email":"admin@tailnet"' "Admin token validates through auth.jwt profile route"

contribs="$(curl -fsS -H "$AUTH_HEADER" "$BASE/api/admin/contributions")"
contains "$contribs" '"id":"authz-roles"' "Admin plugin registered authz contribution"
contains "$contribs" '"id":"auth-config"' "Admin plugin registered auth contribution from auth plugin"
contains "$contribs" '"render_mode":"config-form"' "Auth contribution uses generic config form render mode"
contains "$contribs" '"apply_path":"/api/admin/auth/config/apply"' "Auth contribution advertises apply endpoint"
contains "$contribs" '"render_mode":"iframe"' "Admin contribution uses pluggable iframe render mode"
contains "$contribs" '"admin:authz.roles:update"' "Admin contribution grant bridge includes authz update scope"

catalog="$(curl -fsS -H "$AUTH_HEADER" "$BASE/api/admin/auth/providers")"
json_len_at_least "$catalog" '.providers' 9 "Auth provider catalog includes composed providers"
contains "$catalog" '"implementation":"workflow-plugin-auth0"' "Catalog includes Auth0 plugin descriptor"
contains "$catalog" '"implementation":"workflow-plugin-okta"' "Catalog includes Okta plugin descriptor"
contains "$catalog" '"implementation":"workflow-plugin-ory-kratos"' "Catalog includes Ory Kratos plugin descriptor"
contains "$catalog" '"implementation":"workflow-plugin-scalekit"' "Catalog includes Scalekit plugin descriptor"

auth_config="$(curl -fsS -H "$AUTH_HEADER" "$BASE/api/admin/auth/config")"
contains "$auth_config" '"groups"' "Auth plugin exposes admin config groups"
contains "$auth_config" '"Passkey relying party ID"' "Auth config exposes passkey control metadata"
contains "$auth_config" '"M2M client secret"' "Auth config includes descriptor-backed provider secret control"
if grep -q 'client-secret-value' <<<"$auth_config"; then
  fail "Auth config must not echo provider secret values"
else
  pass "Auth config does not echo provider secrets"
fi

delegated_register="$(curl -sfS -X POST "$BASE/api/admin/auth/register" \
  -H "content-type: application/json" \
  -d '{"email":"delegated-admin@tailnet","password":"delegated-password","name":"Delegated Admin"}' 2>/dev/null || true)"
delegated_token="$(jq -r '.token // .access_token // empty' <<<"$delegated_register" 2>/dev/null || true)"
if [ -z "$delegated_token" ]; then
  delegated_login="$(curl -sfS -X POST "$BASE/api/admin/auth/login" \
    -H "content-type: application/json" \
    -d '{"email":"delegated-admin@tailnet","password":"delegated-password"}' 2>/dev/null || true)"
  delegated_token="$(jq -r '.token // .access_token // empty' <<<"$delegated_login" 2>/dev/null || true)"
fi
if [ -n "$delegated_token" ]; then
  pass "Delegated admin login returns JWT token"
else
  fail "Delegated admin login did not return a JWT token"
fi
DELEGATED_AUTH_HEADER="Authorization: Bearer $delegated_token"
delegated_auth_config="$(curl -fsS -H "$DELEGATED_AUTH_HEADER" "$BASE/api/admin/auth/config")"
contains "$delegated_auth_config" '"groups"' "Auth config read is authorized by admin scope, not hardcoded identity"

validate_config="$(curl -fsS -H "$AUTH_HEADER" -H 'content-type: application/json' -d '{"desired_config":{"environment":"production","password_auth_enabled":true}}' "$BASE/api/admin/auth/config/validate")"
contains "$validate_config" '"valid":false' "Auth config validation rejects unsafe production password login"
contains "$validate_config" 'password auth cannot be enabled in production' "Auth config validation returns plugin diagnostic"
anonymous_apply_code="$(curl -s -o /tmp/scenario90-anonymous-apply.json -w "%{http_code}" -H 'content-type: application/json' -d '{"desired_config":{"environment":"development"}}' "$BASE/api/admin/auth/config/apply")"
if [ "$anonymous_apply_code" = "401" ]; then
  pass "Anonymous user cannot apply admin auth config"
else
  fail "Anonymous auth config apply expected 401, got $anonymous_apply_code"
fi
initial_no_secret_payload='{"desired_config":{"environment":"development","auth_routes_enabled":false,"password_auth_enabled":false,"webauthn_rp_id":"127.0.0.1","webauthn_origin":"http://127.0.0.1:18080"}}'
initial_no_secret_apply="$(curl -fsS -H "$AUTH_HEADER" -H 'content-type: application/json' -d "$initial_no_secret_payload" "$BASE/api/admin/auth/config/apply")"
contains "$initial_no_secret_apply" '"applied":true' "Auth config apply accepts first-time no-secret configuration"
contains "$initial_no_secret_apply" '"secret_refs":{}' "First-time no-secret auth apply returns empty secret refs"
initial_no_secret_state="$(curl -fsS -H "$AUTH_HEADER" "$BASE/api/admin/auth/config/applied")"
contains "$initial_no_secret_state" '"secret_refs":{}' "First-time no-secret auth apply persists empty secret refs"
apply_payload='{"desired_config":{"environment":"development","auth_routes_enabled":true,"password_auth_enabled":false,"webauthn_rp_id":"127.0.0.1","webauthn_origin":"http://127.0.0.1:18080","auth0_domain":"demo.us.auth0.com","auth0_client_id":"scenario90-client","auth0_client_secret":"scenario90-client-secret-value"}}'
apply_config="$(curl -fsS -H "$AUTH_HEADER" -H 'content-type: application/json' -d "$apply_payload" "$BASE/api/admin/auth/config/apply")"
contains "$apply_config" '"applied":true' "Auth config apply persists valid configuration"
contains "$apply_config" '"valid":true' "Auth config apply runs plugin validation before persistence"
contains "$apply_config" '"auth0_client_secret":"secret://scenario90/auth0_client_secret"' "Auth config apply returns secret ref instead of secret value"
contains "$apply_config" '"scenario90/auth0_client_secret"' "Auth config apply reports written secret key"
if grep -q 'scenario90-client-secret-value' <<<"$apply_config"; then
  fail "Auth config apply response must not echo provider secret values"
else
  pass "Auth config apply response does not echo provider secrets"
fi
vault_secret="$(docker compose -f "$SCENARIO_DIR/docker-compose.yml" exec -T vault sh -c 'VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN=scenario90-root-token vault kv get -field=value secret/scenario90/auth0_client_secret' 2>/dev/null || true)"
if [ "$vault_secret" = "scenario90-client-secret-value" ]; then
  pass "Auth config apply writes provider secret through Workflow Vault provider"
else
  fail "Auth config apply did not write provider secret to Vault sidecar"
fi
applied_state="$(curl -fsS -H "$AUTH_HEADER" "$BASE/api/admin/auth/config/applied")"
contains "$applied_state" '"applied":true' "Auth applied-state endpoint reports persisted state"
contains "$applied_state" '"auth0_client_secret":"secret://scenario90/auth0_client_secret"' "Auth applied-state endpoint returns persisted secret ref"
contains "$applied_state" '"auth0_client_id":"scenario90-client"' "Auth applied-state endpoint returns non-secret accepted config"
if grep -q 'scenario90-client-secret-value' <<<"$applied_state"; then
  fail "Auth applied-state endpoint must not echo provider secret values"
else
  pass "Auth applied-state endpoint does not echo provider secrets"
fi
apply_without_secret_payload='{"desired_config":{"environment":"development","auth_routes_enabled":true,"password_auth_enabled":false,"webauthn_rp_id":"127.0.0.1","webauthn_origin":"http://127.0.0.1:18080","auth0_domain":"demo.us.auth0.com","auth0_client_id":"scenario90-client-rotated"}}'
apply_without_secret="$(curl -fsS -H "$AUTH_HEADER" -H 'content-type: application/json' -d "$apply_without_secret_payload" "$BASE/api/admin/auth/config/apply")"
contains "$apply_without_secret" '"applied":true' "Auth config apply accepts later non-secret updates"
contains "$apply_without_secret" '"auth0_client_secret":"secret://scenario90/auth0_client_secret"' "Auth config apply preserves existing secret ref when secret is omitted"
if grep -q 'scenario90-client-secret-value' <<<"$apply_without_secret"; then
  fail "Auth config no-secret apply response must not echo provider secret values"
else
  pass "Auth config no-secret apply response does not echo provider secrets"
fi
applied_state_after_no_secret="$(curl -fsS -H "$AUTH_HEADER" "$BASE/api/admin/auth/config/applied")"
contains "$applied_state_after_no_secret" '"auth0_client_id":"scenario90-client-rotated"' "Auth applied-state endpoint reflects later non-secret update"
contains "$applied_state_after_no_secret" '"auth0_client_secret":"secret://scenario90/auth0_client_secret"' "Auth applied-state endpoint keeps secret ref after no-secret update"
state_before_invalid="$(jq -c '.state' <<<"$applied_state_after_no_secret")"
invalid_apply_code="$(curl -s -o /tmp/scenario90-invalid-apply.json -w "%{http_code}" -H "$AUTH_HEADER" -H 'content-type: application/json' -d '{"desired_config":{"environment":"production","password_auth_enabled":true}}' "$BASE/api/admin/auth/config/apply")"
if [ "$invalid_apply_code" = "422" ]; then
  pass "Auth config apply rejects invalid config before persistence"
else
  fail "Auth config invalid apply expected 422, got $invalid_apply_code"
fi
contains "$(cat /tmp/scenario90-invalid-apply.json)" '"applied":false' "Invalid auth apply reports unapplied state"
state_after_invalid="$(curl -fsS -H "$AUTH_HEADER" "$BASE/api/admin/auth/config/applied" | jq -c '.state')"
if [ "$state_after_invalid" = "$state_before_invalid" ]; then
  pass "Invalid auth apply leaves persisted state unchanged"
else
  fail "Invalid auth apply changed persisted state"
fi
delegated_validate_code="$(curl -s -o /tmp/scenario90-delegated-validate.json -w "%{http_code}" -H "$DELEGATED_AUTH_HEADER" -H 'content-type: application/json' -d '{"desired_config":{"environment":"development"}}' "$BASE/api/admin/auth/config/validate")"
if [ "$delegated_validate_code" = "403" ]; then
  pass "Delegated read-only auth admin cannot validate config without update scope"
else
  fail "Delegated auth config validate expected 403, got $delegated_validate_code"
fi
delegated_apply_code="$(curl -s -o /tmp/scenario90-delegated-apply.json -w "%{http_code}" -H "$DELEGATED_AUTH_HEADER" -H 'content-type: application/json' -d '{"desired_config":{"environment":"development"}}' "$BASE/api/admin/auth/config/apply")"
if [ "$delegated_apply_code" = "403" ]; then
  pass "Delegated read-only auth admin cannot apply config without update scope"
else
  fail "Delegated auth config apply expected 403, got $delegated_apply_code"
fi
delegated_scopes_code="$(curl -s -o /tmp/scenario90-delegated-authz-scopes.json -w "%{http_code}" -H "$DELEGATED_AUTH_HEADER" "$BASE/api/authz/scopes")"
if [ "$delegated_scopes_code" = "403" ]; then
  pass "Delegated auth admin cannot read authz metadata without authz read scope"
else
  fail "Delegated authz scopes expected 403, got $delegated_scopes_code"
fi
delegated_caps_code="$(curl -s -o /tmp/scenario90-delegated-authz-caps.json -w "%{http_code}" -H "$DELEGATED_AUTH_HEADER" "$BASE/api/authz/capabilities")"
if [ "$delegated_caps_code" = "403" ]; then
  pass "Delegated auth admin cannot read authz capabilities without authz read scope"
else
  fail "Delegated authz capabilities expected 403, got $delegated_caps_code"
fi

for provider in auth0 entra ory-kratos ory-hydra ory-polis scalekit; do
  body="$(curl -fsS -H "$AUTH_HEADER" "$BASE/api/admin/auth/providers/$provider")"
  contains "$body" '"providers"' "Provider $provider route is backed by provider plugin step"
  contains "$body" "\"id\":\"$provider\"" "Provider $provider descriptor has expected id"
done

scopes="$(curl -fsS -H "$AUTH_HEADER" "$BASE/api/authz/scopes")"
contains "$scopes" '"frontend:orders:read"' "Authz scopes endpoint includes frontend scope"
contains "$scopes" '"admin:authz.roles:update"' "Authz scopes endpoint includes admin scope"

roles="$(curl -fsS -H "$AUTH_HEADER" "$BASE/api/authz/roles")"
contains "$roles" '"admin@tailnet"' "Authz roles endpoint renders role assignments"
contains "$roles" '"frontend:orders:read"' "Authz roles endpoint carries selectable scope values"

add_role="$(curl -fsS -H "$AUTH_HEADER" -H 'content-type: application/json' -d '{"user":"app-user@tailnet","role":"support","context":"frontend","scopes":["frontend:orders:read"]}' "$BASE/api/authz/roles")"
contains "$add_role" '"updated":true' "Authz role update endpoint accepts admin changes"

caps="$(curl -fsS -H "$AUTH_HEADER" "$BASE/api/authz/capabilities")"
contains "$caps" '"mode":"rbac"' "Authz capabilities report RBAC"
contains "$caps" '"mode":"abac"' "Authz capabilities disclose ABAC availability"
contains "$caps" '"configured":false' "Authz capabilities mark unsupported modes unconfigured"
contains "$caps" 'does not expose ABAC policy routes' "Authz capabilities explain unsupported ABAC routes"
contains "$caps" 'does not expose ReBAC relation routes' "Authz capabilities explain unsupported ReBAC routes"

enforce="$(curl -fsS -H "$AUTH_HEADER" -H 'content-type: application/json' -d '{"subject":"admin@tailnet","object":"authz.roles","action":"update"}' "$BASE/api/authz/enforce")"
contains "$enforce" '"allowed":true' "Authz UI plugin enforce step permits expected action"
contains "$enforce" '"reason":"persisted role assignment grants request"' "Authz enforce response comes from persisted role assignment"

support_register="$(curl -sfS -X POST "$BASE/api/app/auth/register" \
  -H "content-type: application/json" \
  -d '{"email":"app-user@tailnet","password":"app-password","name":"Support User"}' 2>/dev/null || true)"
support_token="$(jq -r '.token // .access_token // empty' <<<"$support_register" 2>/dev/null || true)"
if [ -z "$support_token" ]; then
  support_login="$(curl -sfS -X POST "$BASE/api/app/auth/login" \
    -H "content-type: application/json" \
    -d '{"email":"app-user@tailnet","password":"app-password"}' 2>/dev/null || true)"
  support_token="$(jq -r '.token // .access_token // empty' <<<"$support_login" 2>/dev/null || true)"
fi
if [ -n "$support_token" ]; then
  pass "Primary app support login returns JWT token"
else
  fail "Primary app support login did not return a JWT token"
fi
SUPPORT_AUTH_HEADER="Authorization: Bearer $support_token"

viewer_register="$(curl -sfS -X POST "$BASE/api/app/auth/register" \
  -H "content-type: application/json" \
  -d '{"email":"viewer@tailnet","password":"viewer-password","name":"Viewer User"}' 2>/dev/null || true)"
viewer_token="$(jq -r '.token // .access_token // empty' <<<"$viewer_register" 2>/dev/null || true)"
if [ -z "$viewer_token" ]; then
  viewer_login="$(curl -sfS -X POST "$BASE/api/app/auth/login" \
    -H "content-type: application/json" \
    -d '{"email":"viewer@tailnet","password":"viewer-password"}' 2>/dev/null || true)"
  viewer_token="$(jq -r '.token // .access_token // empty' <<<"$viewer_login" 2>/dev/null || true)"
fi
if [ -n "$viewer_token" ]; then
  pass "Primary app viewer login returns JWT token"
else
  fail "Primary app viewer login did not return a JWT token"
fi
VIEWER_AUTH_HEADER="Authorization: Bearer $viewer_token"

support_access="$(curl -fsS -H "$SUPPORT_AUTH_HEADER" "$BASE/api/app/access")"
contains "$support_access" '"role":"support"' "SPA access projection identifies support role"
contains "$support_access" '"frontend:orders:read"' "SPA projection includes frontend read scope"
if grep -q 'frontend:orders:update' <<<"$support_access"; then
  fail "Support projection must not include frontend update scope"
else
  pass "Support projection omits frontend update scope"
fi

support_orders="$(curl -fsS -H "$SUPPORT_AUTH_HEADER" "$BASE/api/app/orders")"
contains "$support_orders" '"allowed":true' "Support can read orders through authz enforcement"
support_update_code="$(curl -s -o /tmp/scenario90-support-update.json -w "%{http_code}" -H "$SUPPORT_AUTH_HEADER" -H 'content-type: application/json' -d '{"order_id":"ORD-1002","status":"priority-review"}' "$BASE/api/app/orders/update")"
if [ "$support_update_code" = "403" ]; then
  pass "Support cannot update orders without frontend update scope"
else
  fail "Support update expected 403, got $support_update_code"
fi
contains "$(cat /tmp/scenario90-support-update.json)" 'missing frontend:orders:update' "Support update denial explains missing scope"

support_auth_config_code="$(curl -s -o /tmp/scenario90-support-auth-config.json -w "%{http_code}" -H "$SUPPORT_AUTH_HEADER" "$BASE/api/admin/auth/config")"
if [ "$support_auth_config_code" = "403" ]; then
  pass "Support cannot read admin auth config without admin auth scope"
else
  fail "Support auth config expected 403, got $support_auth_config_code"
fi
support_auth_catalog_code="$(curl -s -o /tmp/scenario90-support-auth-catalog.json -w "%{http_code}" -H "$SUPPORT_AUTH_HEADER" "$BASE/api/admin/auth/providers")"
if [ "$support_auth_catalog_code" = "403" ]; then
  pass "Support cannot read admin auth provider catalog without admin auth scope"
else
  fail "Support auth provider catalog expected 403, got $support_auth_catalog_code"
fi
support_validate_code="$(curl -s -o /tmp/scenario90-support-auth-validate.json -w "%{http_code}" -H "$SUPPORT_AUTH_HEADER" -H 'content-type: application/json' -d '{"desired_config":{"environment":"development"}}' "$BASE/api/admin/auth/config/validate")"
if [ "$support_validate_code" = "403" ]; then
  pass "Support cannot validate admin auth config without admin auth update scope"
else
  fail "Support auth config validate expected 403, got $support_validate_code"
fi
support_apply_code="$(curl -s -o /tmp/scenario90-support-auth-apply.json -w "%{http_code}" -H "$SUPPORT_AUTH_HEADER" -H 'content-type: application/json' -d '{"desired_config":{"environment":"development"}}' "$BASE/api/admin/auth/config/apply")"
if [ "$support_apply_code" = "403" ]; then
  pass "Support cannot apply admin auth config without admin auth update scope"
else
  fail "Support auth config apply expected 403, got $support_apply_code"
fi
viewer_roles_code="$(curl -s -o /tmp/scenario90-viewer-roles.json -w "%{http_code}" -H "$VIEWER_AUTH_HEADER" "$BASE/api/authz/roles")"
if [ "$viewer_roles_code" = "403" ]; then
  pass "Viewer cannot read authz role assignments without admin authz read scope"
else
  fail "Viewer authz roles expected 403, got $viewer_roles_code"
fi

arbitrary_enforce="$(curl -fsS -H "$VIEWER_AUTH_HEADER" -H 'content-type: application/json' -d '{"subject":"viewer@tailnet","object":"orders","action":"delete"}' "$BASE/api/authz/enforce")"
contains "$arbitrary_enforce" '"subject":"viewer@tailnet"' "Authz enforce echoes requested subject"
contains "$arbitrary_enforce" '"object":"orders"' "Authz enforce echoes requested object"
contains "$arbitrary_enforce" '"action":"delete"' "Authz enforce echoes requested action"
contains "$arbitrary_enforce" '"allowed":false' "Authz enforce denies ungranted arbitrary action"
spoof_enforce_code="$(curl -s -o /tmp/scenario90-spoof-enforce.json -w "%{http_code}" -H "$SUPPORT_AUTH_HEADER" -H 'content-type: application/json' -d '{"subject":"admin@tailnet","object":"authz.roles","action":"update"}' "$BASE/api/authz/enforce")"
if [ "$spoof_enforce_code" = "403" ]; then
  pass "Authz enforce rejects spoofed subject simulation"
else
  fail "Authz enforce spoof expected 403, got $spoof_enforce_code"
fi
contains "$(cat /tmp/scenario90-spoof-enforce.json)" 'subject does not match authenticated user' "Spoofed enforce denial explains subject mismatch"

new_role="$(curl -fsS -H "$AUTH_HEADER" -H 'content-type: application/json' -d '{"user":"new@tailnet","role":"auditor","context":"frontend","scopes":["frontend:orders:read"]}' "$BASE/api/authz/roles")"
contains "$new_role" '"updated":true' "Authz role update accepts new persisted assignment"
roles_after_add="$(curl -fsS -H "$AUTH_HEADER" "$BASE/api/authz/roles")"
contains "$roles_after_add" '"new@tailnet"' "Authz roles endpoint reflects newly added assignment"
new_register="$(curl -sfS -X POST "$BASE/api/app/auth/register" \
  -H "content-type: application/json" \
  -d '{"email":"new@tailnet","password":"new-password","name":"New Auditor"}' 2>/dev/null || true)"
new_token="$(jq -r '.token // .access_token // empty' <<<"$new_register" 2>/dev/null || true)"
if [ -z "$new_token" ]; then
  new_login="$(curl -sfS -X POST "$BASE/api/app/auth/login" \
    -H "content-type: application/json" \
    -d '{"email":"new@tailnet","password":"new-password"}' 2>/dev/null || true)"
  new_token="$(jq -r '.token // .access_token // empty' <<<"$new_login" 2>/dev/null || true)"
fi
if [ -n "$new_token" ]; then
  pass "New persisted-role user login returns JWT token"
else
  fail "New persisted-role user login did not return a JWT token"
fi
NEW_AUTH_HEADER="Authorization: Bearer $new_token"
new_enforce="$(curl -fsS -H "$NEW_AUTH_HEADER" -H 'content-type: application/json' -d '{"subject":"new@tailnet","object":"orders","action":"read"}' "$BASE/api/authz/enforce")"
contains "$new_enforce" '"allowed":true' "Authz enforce honors newly added persisted assignment"
delete_role="$(curl -fsS -X DELETE -H "$AUTH_HEADER" -H 'content-type: application/json' -d '{"user":"new@tailnet","role":"auditor","context":"frontend"}' "$BASE/api/authz/roles")"
contains "$delete_role" '"deleted":true' "Authz role delete accepts persisted assignment"
roles_after_delete="$(curl -fsS -H "$AUTH_HEADER" "$BASE/api/authz/roles")"
if grep -q '"new@tailnet"' <<<"$roles_after_delete"; then
  fail "Authz roles endpoint still includes deleted assignment"
else
  pass "Authz roles endpoint removes deleted assignment"
fi
new_enforce_after_delete="$(curl -fsS -H "$NEW_AUTH_HEADER" -H 'content-type: application/json' -d '{"subject":"new@tailnet","object":"orders","action":"read"}' "$BASE/api/authz/enforce")"
contains "$new_enforce_after_delete" '"allowed":false' "Authz enforce reflects deleted persisted assignment"

admin_app_access="$(curl -fsS -H "$AUTH_HEADER" "$BASE/api/app/access")"
contains "$admin_app_access" '"role":"admin"' "SPA access projection identifies admin role"
contains "$admin_app_access" '"frontend:orders:update"' "Admin projection includes frontend update scope"
admin_update="$(curl -fsS -H "$AUTH_HEADER" -H 'content-type: application/json' -d '{"order_id":"ORD-1002","status":"priority-review"}' "$BASE/api/app/orders/update")"
contains "$admin_update" '"allowed":true' "Admin can update orders through authz enforcement"

if docker compose -f "$SCENARIO_DIR/docker-compose.yml" logs app 2>&1 | grep -qi 'python'; then
  fail "App logs mention Python"
else
  pass "App logs do not mention Python"
fi

echo ""
echo "PASS=$PASS_COUNT FAIL=$FAIL_COUNT"
if [ "$FAIL_COUNT" -ne 0 ]; then
  exit 1
fi
