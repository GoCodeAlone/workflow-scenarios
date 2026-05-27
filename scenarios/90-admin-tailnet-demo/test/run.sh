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

unknown_status="$(curl -b "$COOKIE_JAR" -s -o /dev/null -w "%{http_code}" -d 'user=admin@tailnet&role=bad&context=admin&scopes=admin:unknown:update' "$BASE/api/authz/roles")"
if [[ "$unknown_status" == "400" ]]; then
  pass "Unknown scope assignment rejected"
else
  fail "Unknown scope assignment expected 400, got $unknown_status"
fi

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
