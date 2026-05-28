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

if find "$SCENARIO_DIR" -type f -name '*.py' | grep -q .; then
  fail "Scenario contains a Python app harness"
else
  pass "Scenario has no Python app harness"
fi

"$SCENARIO_DIR/seed/seed.sh"

entrypoint="$(docker inspect workflow-admin-tailnet-demo --format '{{json .Config.Entrypoint}} {{json .Config.Cmd}}' 2>/dev/null || true)"
contains "$entrypoint" '"/usr/local/bin/server"' "Container entrypoint is Workflow server"
contains "$entrypoint" '"/data/app.yaml"' "Container runs Workflow config"

status="$(curl -fsS "$BASE/api/status")"
contains "$status" '"runtime":"workflow-go-server"' "Status API reports Workflow Go runtime"
contains "$status" '"plugin_runtime":"external-go-binaries"' "Status API reports external Go plugin runtime"

admin_status="$(curl -s -o /dev/null -w "%{http_code}:%{redirect_url}" "$BASE/admin")"
if [[ "$admin_status" == "308:$BASE/admin/" || "$admin_status" == "308:/admin/" ]]; then
  pass "Admin bare path redirects to static Workflow admin shell"
else
  fail "Admin bare path redirect expected, got $admin_status"
fi

admin="$(curl -fsS "$BASE/admin/")"
contains "$admin" "<title>Workflow Admin</title>" "Admin shell is served by Workflow static.fileserver"

authz_page="$(curl -fsS "$BASE/admin/authz/")"
contains "$authz_page" "<title>Authz Policy Manager</title>" "Authz UI plugin assets are served"

contribs="$(curl -fsS "$BASE/api/admin/contributions")"
contains "$contribs" '"id":"authz-roles"' "Admin plugin registered authz contribution"
contains "$contribs" '"render_mode":"iframe"' "Admin contribution uses pluggable iframe render mode"

catalog="$(curl -fsS "$BASE/api/admin/auth/providers")"
json_len_at_least "$catalog" '.providers' 9 "Auth provider catalog includes composed providers"
contains "$catalog" '"implementation":"workflow-plugin-auth0"' "Catalog includes Auth0 plugin descriptor"
contains "$catalog" '"implementation":"workflow-plugin-okta"' "Catalog includes Okta plugin descriptor"
contains "$catalog" '"implementation":"workflow-plugin-ory-kratos"' "Catalog includes Ory Kratos plugin descriptor"
contains "$catalog" '"implementation":"workflow-plugin-scalekit"' "Catalog includes Scalekit plugin descriptor"

auth_config="$(curl -fsS "$BASE/api/admin/auth/config")"
contains "$auth_config" '"groups"' "Auth plugin exposes admin config groups"
contains "$auth_config" '"Passkey relying party ID"' "Auth config exposes passkey control metadata"
contains "$auth_config" '"M2M client secret"' "Auth config includes descriptor-backed provider secret control"
if grep -q 'client-secret-value' <<<"$auth_config"; then
  fail "Auth config must not echo provider secret values"
else
  pass "Auth config does not echo provider secrets"
fi

for provider in auth0 entra ory-kratos ory-hydra ory-polis scalekit; do
  body="$(curl -fsS "$BASE/api/admin/auth/providers/$provider")"
  contains "$body" '"providers"' "Provider $provider route is backed by provider plugin step"
  contains "$body" "\"id\":\"$provider\"" "Provider $provider descriptor has expected id"
done

scopes="$(curl -fsS "$BASE/api/authz/scopes")"
contains "$scopes" '"frontend:orders:read"' "Authz scopes endpoint includes frontend scope"
contains "$scopes" '"admin:authz.roles:update"' "Authz scopes endpoint includes admin scope"

roles="$(curl -fsS "$BASE/api/authz/roles")"
contains "$roles" '"admin@tailnet"' "Authz roles endpoint renders role assignments"
contains "$roles" '"frontend:orders:read"' "Authz roles endpoint carries selectable scope values"

caps="$(curl -fsS "$BASE/api/authz/capabilities")"
contains "$caps" '"mode":"rbac"' "Authz capabilities report RBAC"
contains "$caps" '"mode":"abac"' "Authz capabilities report ABAC"
contains "$caps" '"mode":"rebac"' "Authz capabilities report ReBAC"

enforce="$(curl -fsS -H 'content-type: application/json' -d '{"subject":"admin@tailnet","object":"authz.roles","action":"update"}' "$BASE/api/authz/enforce")"
contains "$enforce" '"allowed":true' "Authz UI plugin enforce step permits expected action"
contains "$enforce" '"reason":"scenario fixture grants admin role"' "Authz enforce response comes from plugin step config"

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
