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
contains "$contribs" '"render_mode":"iframe"' "Admin contribution uses pluggable iframe render mode"

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

validate_config="$(curl -fsS -H "$AUTH_HEADER" -H 'content-type: application/json' -d '{"desired_config":{"environment":"production","password_auth_enabled":true}}' "$BASE/api/admin/auth/config/validate")"
contains "$validate_config" '"valid":false' "Auth config validation rejects unsafe production password login"
contains "$validate_config" 'password auth cannot be enabled in production' "Auth config validation returns plugin diagnostic"

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
contains "$caps" '"mode":"abac"' "Authz capabilities report ABAC"
contains "$caps" '"mode":"rebac"' "Authz capabilities report ReBAC"

enforce="$(curl -fsS -H "$AUTH_HEADER" -H 'content-type: application/json' -d '{"subject":"admin@tailnet","object":"authz.roles","action":"update"}' "$BASE/api/authz/enforce")"
contains "$enforce" '"allowed":true' "Authz UI plugin enforce step permits expected action"
contains "$enforce" '"reason":"scenario fixture grants admin role"' "Authz enforce response comes from plugin step config"

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
