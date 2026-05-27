#!/usr/bin/env bash
set -euo pipefail

BASE="${BASE:-http://127.0.0.1:18080}"
COOKIE_JAR="$(mktemp)"
FRONTEND_COOKIE="$(mktemp)"
PASS_COUNT=0
FAIL_COUNT=0
trap 'rm -f "$COOKIE_JAR" "$FRONTEND_COOKIE"' EXIT

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

admin_status="$(curl -s -o /dev/null -w "%{http_code}:%{redirect_url}:%{header_json}" "$BASE/admin")"
if [[ "$admin_status" == 303:*"/login?next=/admin"* ]]; then
  pass "Anonymous admin redirects to login"
else
  fail "Anonymous admin redirect expected, got $admin_status"
fi

api_status="$(curl -s -o /dev/null -w "%{http_code}" "$BASE/api/authz/roles")"
if [[ "$api_status" == "401" ]]; then
  pass "Anonymous authz API is unauthorized"
else
  fail "Anonymous authz API expected 401, got $api_status"
fi

login_status="$(curl -s -o /dev/null -w "%{http_code}" -c "$COOKIE_JAR" -d 'email=admin@tailnet&password=admin' "$BASE/login")"
if [[ "$login_status" == "303" ]]; then
  pass "Admin login creates a session"
else
  fail "Admin login expected 303, got $login_status"
fi

admin="$(curl -b "$COOKIE_JAR" -fsS "$BASE/admin")"
contains "$admin" "Authorization roles" "Admin navigation includes authz UI"
contains "$admin" "/admin/authz" "Admin links authz contribution"

authz="$(curl -b "$COOKIE_JAR" -fsS "$BASE/admin/authz")"
contains "$authz" "Role and Scope Administration" "Authz UI page renders"
contains "$authz" "frontend:orders:read" "Frontend scope visible"
contains "$authz" "admin:authz.roles:update" "Admin scope visible"
contains "$authz" "app.requests" "Application-declared scope visible"
contains "$authz" "scope-picker" "Authz UI renders scope picker"
contains "$authz" ".scope-option input" "Scope picker checkbox sizing isolated"
if grep -q "Direct scopes, comma separated" <<<"$authz"; then
  fail "Authz UI should not render free-text scope entry"
else
  pass "Authz UI does not render free-text scope entry"
fi

roles="$(curl -b "$COOKIE_JAR" -fsS "$BASE/api/authz/roles")"
contains "$roles" '"context": "frontend"' "Frontend role context returned"
contains "$roles" '"context": "admin"' "Admin role context returned"
contains "$roles" '"scopes"' "Direct scopes returned"

scope_catalog="$(curl -b "$COOKIE_JAR" -fsS "$BASE/api/authz/scopes")"
contains "$scope_catalog" '"owner_plugin": "workflow-scenarios"' "Scopes include owner metadata"
contains "$scope_catalog" '"category": "application"' "Scopes include categories"

status="$(curl -fsS "$BASE/api/status")"
contains "$status" '"provider": "keto"' "Status reports Keto authz provider"
contains "$status" '"capabilities"' "Status reports provider capabilities"

capabilities="$(curl -b "$COOKIE_JAR" -fsS "$BASE/api/authz/capabilities")"
contains "$capabilities" '"mode": "rbac"' "Capabilities advertise RBAC"
contains "$capabilities" '"mode": "abac"' "Capabilities advertise ABAC"
contains "$capabilities" '"mode": "rebac"' "Capabilities advertise ReBAC"
contains "$capabilities" '"manage_policies"' "ABAC capability lists policy management"
contains "$capabilities" '"manage_relations"' "ReBAC capability lists relationship management"

declarations="$(curl -b "$COOKIE_JAR" -fsS "$BASE/api/authz/declarations")"
contains "$declarations" '"attributes"' "Declarations include attributes"
contains "$declarations" '"relations"' "Declarations include relations"
contains "$declarations" '"ui_actions"' "Declarations include UI actions"
contains "$declarations" '"lookup_source_id": "directory.departments"' "Attribute values expose lookup source"

projection="$(curl -b "$COOKIE_JAR" -fsS "$BASE/api/authz/projection-inputs")"
contains "$projection" '"scope_names"' "Projection inputs include scope names"
contains "$projection" '"attribute_names"' "Projection inputs include attribute names"
contains "$projection" '"relation_names"' "Projection inputs include relation names"

unknown_status="$(curl -b "$COOKIE_JAR" -s -o /dev/null -w "%{http_code}" -d 'user=admin@tailnet&role=bad&context=admin&scopes=admin:unknown:update' "$BASE/api/authz/roles")"
if [[ "$unknown_status" == "400" ]]; then
  pass "Unknown scope assignment rejected"
else
  fail "Unknown scope assignment expected 400, got $unknown_status"
fi

abac_policies="$(curl -b "$COOKIE_JAR" -fsS "$BASE/api/authz/abac/policies")"
contains "$abac_policies" '"support-can-read-support-requests"' "ABAC policies list seeded policy"
abac_allowed="$(curl -b "$COOKIE_JAR" -fsS -H 'content-type: application/json' -d '{"subject":"app-user@tailnet","object":"requests","action":"read"}' "$BASE/api/authz/enforce")"
contains "$abac_allowed" '"allowed": true' "ABAC allows support user on support request"
invalid_abac_status="$(curl -b "$COOKIE_JAR" -s -o /dev/null -w "%{http_code}" -H 'content-type: application/json' -d '{"id":"bad-policy","context":"frontend","resource":"requests","action":"read","effect":"allow","conditions":[{"target":"subject","attribute":"department","operator":"equals","values":["unknown"]}]}' "$BASE/api/authz/abac/policies")"
if [[ "$invalid_abac_status" == "400" ]]; then
  pass "ABAC rejects undeclared attribute values"
else
  fail "ABAC invalid value expected 400, got $invalid_abac_status"
fi

rebac_tuples="$(curl -b "$COOKIE_JAR" -fsS "$BASE/api/authz/rebac/tuples")"
contains "$rebac_tuples" '"relation": "viewer"' "ReBAC tuples list seeded relation"
rebac_allowed="$(curl -b "$COOKIE_JAR" -fsS -H 'content-type: application/json' -d '{"subject":"app-user@tailnet","relation":"viewer","object":"request:2","context":"frontend"}' "$BASE/api/authz/rebac/check")"
contains "$rebac_allowed" '"allowed": true' "ReBAC allows seeded viewer relation"
rebac_denied="$(curl -b "$COOKIE_JAR" -fsS -H 'content-type: application/json' -d '{"subject":"app-user@tailnet","relation":"owner","object":"request:1","context":"frontend"}' "$BASE/api/authz/rebac/check")"
contains "$rebac_denied" '"allowed": false' "ReBAC denies missing owner relation"

curl -b "$COOKIE_JAR" -fsS -H 'content-type: application/json' -d '{"user":"temp@tailnet","role":"requester","context":"frontend","scopes":["frontend:requests:create"]}' "$BASE/api/authz/roles" >/dev/null
rbac_granted="$(curl -b "$COOKIE_JAR" -fsS -H 'content-type: application/json' -d '{"subject":"temp@tailnet","object":"frontend:requests:create","action":"granted"}' "$BASE/api/authz/enforce")"
contains "$rbac_granted" '"allowed": true' "RBAC grants newly assigned scope"
curl -X DELETE -b "$COOKIE_JAR" -fsS -H 'content-type: application/json' -d '{"user":"temp@tailnet","role":"requester","scopes":["frontend:requests:create"]}' "$BASE/api/authz/roles" >/dev/null
rbac_removed="$(curl -b "$COOKIE_JAR" -fsS -H 'content-type: application/json' -d '{"subject":"temp@tailnet","object":"frontend:requests:create","action":"granted"}' "$BASE/api/authz/enforce")"
contains "$rbac_removed" '"allowed": false' "RBAC removal revokes assigned scope"

curl -s -o /dev/null -c "$FRONTEND_COOKIE" -d 'email=app-user@tailnet&password=user' "$BASE/login"
frontend_admin_status="$(curl -b "$FRONTEND_COOKIE" -s -o /dev/null -w "%{http_code}" "$BASE/admin")"
if [[ "$frontend_admin_status" == "403" ]]; then
  pass "Frontend-only user cannot access admin"
else
  fail "Frontend-only admin access expected 403, got $frontend_admin_status"
fi

echo ""
echo "RESULTS: $PASS_COUNT passed, $FAIL_COUNT failed"
if [ "$FAIL_COUNT" -gt 0 ]; then
  exit 1
fi
