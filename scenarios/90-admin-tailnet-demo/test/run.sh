#!/usr/bin/env bash
set -euo pipefail

BASE="${BASE:-http://127.0.0.1:18080}"
COOKIE_JAR="$(mktemp)"
FRONTEND_COOKIE="$(mktemp)"
MALICIOUS_COOKIE="$(mktemp)"
PROVIDER_COOKIE="$(mktemp)"
PASS_COUNT=0
FAIL_COUNT=0
trap 'rm -f "$COOKIE_JAR" "$FRONTEND_COOKIE" "$MALICIOUS_COOKIE" "$PROVIDER_COOKIE"' EXIT

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

validate_provider_config() {
  local provider="$1"
  local payload="$2"
  local label="$3"
  local response
  response="$(curl -b "$COOKIE_JAR" -fsS -H 'content-type: application/json' -d "$payload" "$BASE/api/admin/auth/providers/config")"
  contains "$response" '"valid": true' "$label"
  if grep -q 'rotation-secret' <<<"$response"; then
    fail "$label should redact submitted provider secrets"
  else
    pass "$label redacts submitted provider secrets"
  fi
}

admin_status="$(curl -s -o /dev/null -w "%{http_code}:%{redirect_url}:%{header_json}" "$BASE/admin")"
if [[ "$admin_status" == 303:*"/login?next=admin"* ]]; then
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

auth_config_status="$(curl -s -o /dev/null -w "%{http_code}" "$BASE/api/admin/auth/config")"
if [[ "$auth_config_status" == "401" ]]; then
  pass "Anonymous auth admin API is unauthorized"
else
  fail "Anonymous auth admin API expected 401, got $auth_config_status"
fi

login_status="$(curl -s -o /dev/null -w "%{http_code}" -c "$COOKIE_JAR" -d 'email=admin@tailnet&password=admin' "$BASE/login")"
if [[ "$login_status" == "303" ]]; then
  pass "Admin login creates a session"
else
  fail "Admin login expected 303, got $login_status"
fi

malicious_login_headers="$(curl -s -D - -o /dev/null -c "$MALICIOUS_COOKIE" --data-urlencode 'email=admin@tailnet' --data-urlencode 'password=admin' --data-urlencode $'next=/admin\r\nx-injected: bad' "$BASE/login" | tr -d '\r')"
if grep -qi '^location: /admin$' <<<"$malicious_login_headers" && ! grep -qi '^x-injected:' <<<"$malicious_login_headers"; then
  pass "Login redirect rejects response-splitting next values"
else
  fail "Login redirect should sanitize malicious next header"
fi

admin="$(curl -b "$COOKIE_JAR" -fsS "$BASE/admin")"
contains "$admin" "Authorization roles" "Admin navigation includes authz UI"
contains "$admin" "/admin/authz" "Admin links authz contribution"
contains "$admin" "Authentication settings" "Admin navigation includes auth UI"
contains "$admin" "/admin/auth" "Admin links auth contribution"

auth_config="$(curl -b "$COOKIE_JAR" -fsS "$BASE/api/admin/auth/config")"
contains "$auth_config" '"groups"' "Auth admin config exposes control groups"
contains "$auth_config" '"config_key": "webauthn_rp_id"' "Auth admin config maps passkey RP ID to real config key"
contains "$auth_config" '"config_key": "password_auth_enabled"' "Auth admin config maps password toggle to real config key"
contains "$auth_config" '"provider_catalog"' "Auth admin config includes provider catalog"
contains "$auth_config" '"workflow-plugin-auth0"' "Auth admin config includes Auth0 provider descriptor"
contains "$auth_config" '"workflow-plugin-entra"' "Auth admin config includes Entra provider descriptor"
contains "$auth_config" '"workflow-plugin-scalekit"' "Auth admin config includes Scalekit provider descriptor"
contains "$auth_config" '"Auth0 client secret"' "Auth admin config exposes descriptor-backed OAuth secret control metadata"
contains "$auth_config" '"secret_fields"' "Auth admin config declares write-only secret fields"
if grep -q 'configured-secret' <<<"$auth_config"; then
  fail "Auth admin config should not echo configured secret values"
else
  pass "Auth admin config redacts configured secret values"
fi

unsafe_auth_status="$(curl -b "$COOKIE_JAR" -s -o /tmp/workflow-auth-admin-unsafe.json -w "%{http_code}" -H 'content-type: application/json' -d '{"require_primary_method":true,"desired_config":{"environment":"production","password_auth_enabled":true}}' "$BASE/api/admin/auth/config/validate")"
if [[ "$unsafe_auth_status" == "400" ]] && grep -q 'password_auth_enabled' /tmp/workflow-auth-admin-unsafe.json; then
  pass "Auth admin rejects production password enablement"
else
  fail "Auth admin unsafe password expected 400 with diagnostic, got $unsafe_auth_status"
fi

safe_auth="$(curl -b "$COOKIE_JAR" -fsS -H 'content-type: application/json' -d '{"require_primary_method":true,"desired_config":{"environment":"development","webauthn_rp_id":"tailnet-demo.local","webauthn_origin":"http://127.0.0.1:18080","auth0_client_secret":"new-secret"}}' "$BASE/api/admin/auth/config/validate")"
contains "$safe_auth" '"valid": true' "Auth admin accepts safe passkey config patch"
contains "$safe_auth" '"webauthn_rp_id": "tailnet-demo.local"' "Auth admin returns accepted non-secret config"
if grep -q 'new-secret' <<<"$safe_auth"; then
  fail "Auth admin validate should not echo submitted secret values"
else
  pass "Auth admin validate redacts submitted secret values"
fi

auth_page="$(curl -b "$COOKIE_JAR" -fsS "$BASE/admin/auth")"
contains "$auth_page" "Authentication Administration" "Auth admin UI page renders"
contains "$auth_page" 'role="tablist"' "Auth admin UI groups settings in tabs"
contains "$auth_page" 'href="/admin/auth?group=primary_methods"' "Auth admin UI has primary methods tab"
contains "$auth_page" 'href="/admin/auth?group=oauth_providers"' "Auth admin UI has OAuth providers tab"
contains "$auth_page" "Passkey relying party ID" "Auth admin UI labels passkey RP ID clearly"
contains "$auth_page" "Password login" "Auth admin UI labels password setting clearly"
if grep -q 'configured-secret' <<<"$auth_page"; then
  fail "Auth admin UI should not display secret values"
else
  pass "Auth admin UI does not display secret values"
fi
auth_oauth_page="$(curl -b "$COOKIE_JAR" -fsS "$BASE/admin/auth?group=oauth_providers")"
contains "$auth_oauth_page" "Provider catalog" "Auth admin provider tab is descriptor-backed"
contains "$auth_oauth_page" "Active login provider" "Auth admin provider tab uses selectable provider choices"
contains "$auth_oauth_page" "Auth0 client secret" "Auth admin provider tab labels Auth0 secret"
contains "$auth_oauth_page" "Scalekit Client secret" "Auth admin provider tab labels Scalekit secret"
contains "$auth_oauth_page" "Write-only" "Auth admin OAuth tab explains write-only secrets"

provider_catalog="$(curl -b "$COOKIE_JAR" -fsS "$BASE/api/admin/auth/providers")"
contains "$provider_catalog" '"provider_count": 9' "Provider catalog exposes all composed providers"
contains "$provider_catalog" '"id": "generic-oidc"' "Provider catalog includes generic OIDC"
contains "$provider_catalog" '"id": "okta"' "Provider catalog includes Okta"
contains "$provider_catalog" '"id": "auth0"' "Provider catalog includes Auth0"
contains "$provider_catalog" '"id": "entra"' "Provider catalog includes Entra"
contains "$provider_catalog" '"id": "ory-kratos"' "Provider catalog includes Ory Kratos"
contains "$provider_catalog" '"id": "ory-hydra"' "Provider catalog includes Ory Hydra"
contains "$provider_catalog" '"id": "ory-polis"' "Provider catalog includes Ory Polis"
contains "$provider_catalog" '"id": "scalekit"' "Provider catalog includes Scalekit"
contains "$provider_catalog" '"config_fields"' "Provider catalog exposes lookup-backed field descriptors"

provider_save="$(curl -b "$COOKIE_JAR" -fsS -H 'content-type: application/json' -d '{"provider_id":"auth0","desired_config":{"auth0_domain":"demo.auth0.example","auth0_client_id":"updated-client"}}' "$BASE/api/admin/auth/providers/config")"
contains "$provider_save" '"valid": true' "Auth admin can save accepted non-secret provider config"
pass "Provider config save has no submitted secret to echo"

validate_provider_config "local-auth" '{"provider_id":"local-auth","desired_config":{"webauthn_rp_id":"tailnet-demo.local","webauthn_origin":"http://127.0.0.1:18080"}}' "Provider rotation validates local auth"
validate_provider_config "generic-oidc" '{"provider_id":"generic-oidc","desired_config":{"generic_oidc_issuer_url":"https://issuer.example.test","generic_oidc_client_id":"generic-client","generic_oidc_client_secret":"rotation-secret","generic_oidc_scopes":"openid profile email"}}' "Provider rotation validates generic OIDC"
validate_provider_config "okta" '{"provider_id":"okta","desired_config":{"okta_org_url":"https://dev-123456.okta.com","okta_client_id":"okta-client","okta_client_secret":"rotation-secret"}}' "Provider rotation validates Okta"
validate_provider_config "auth0" '{"provider_id":"auth0","desired_config":{"auth0_domain":"demo.auth0.example","auth0_client_id":"auth0-client","auth0_client_secret":"rotation-secret","auth0_callback_url":"http://127.0.0.1:18080/auth/auth0/callback"}}' "Provider rotation validates Auth0"
validate_provider_config "entra" '{"provider_id":"entra","desired_config":{"entra_tenant_id":"common","entra_client_id":"entra-client","entra_client_secret":"rotation-secret"}}' "Provider rotation validates Entra"
validate_provider_config "ory-kratos" '{"provider_id":"ory-kratos","desired_config":{"kratos_admin_url":"http://kratos.example.test/admin","kratos_session_cookie_name":"ory_kratos_session"}}' "Provider rotation validates Ory Kratos"
validate_provider_config "ory-hydra" '{"provider_id":"ory-hydra","desired_config":{"hydra_admin_url":"http://hydra.example.test/admin","hydra_public_issuer_url":"https://hydra.example.test/"}}' "Provider rotation validates Ory Hydra"
validate_provider_config "ory-polis" '{"provider_id":"ory-polis","desired_config":{"polis_api_url":"https://polis.example.test","polis_api_token":"rotation-secret"}}' "Provider rotation validates Ory Polis"
validate_provider_config "scalekit" '{"provider_id":"scalekit","desired_config":{"scalekit_environment_url":"https://demo.scalekit.com","scalekit_client_id":"scalekit-client","scalekit_client_secret":"rotation-secret"}}' "Provider rotation validates Scalekit"

invalid_provider_status="$(curl -b "$COOKIE_JAR" -s -o /dev/null -w "%{http_code}" -H 'content-type: application/json' -d '{"provider_id":"unknown","desired_config":{}}' "$BASE/api/admin/auth/providers/config")"
if [[ "$invalid_provider_status" == "400" ]]; then
  pass "Unknown provider config fails closed"
else
  fail "Unknown provider config expected 400, got $invalid_provider_status"
fi

curl -s -o /dev/null -c "$PROVIDER_COOKIE" -d 'email=provider-admin@tailnet&password=provider' "$BASE/login"
provider_page_status="$(curl -b "$PROVIDER_COOKIE" -s -o /dev/null -w "%{http_code}" "$BASE/admin/auth?group=oauth_providers")"
if [[ "$provider_page_status" == "200" ]]; then
  pass "Provider admin can view descriptor-backed provider controls"
else
  fail "Provider admin expected auth provider page 200, got $provider_page_status"
fi
provider_write_status="$(curl -b "$PROVIDER_COOKIE" -s -o /dev/null -w "%{http_code}" -H 'content-type: application/json' -d '{"provider_id":"auth0","desired_config":{"auth0_client_secret":"readonly-secret"}}' "$BASE/api/admin/auth/providers/config")"
if [[ "$provider_write_status" == "403" ]]; then
  pass "Provider admin without write scope cannot save secrets"
else
  fail "Provider admin secret save expected 403, got $provider_write_status"
fi

authz="$(curl -b "$COOKIE_JAR" -fsS "$BASE/admin/authz")"
contains "$authz" "Role and Scope Administration" "Authz UI page renders"
contains "$authz" 'role="tablist"' "Authz UI groups access modes in tabs"
contains "$authz" 'href="/admin/authz?tab=rbac"' "Authz UI has RBAC tab"
contains "$authz" 'href="/admin/authz?tab=abac"' "Authz UI has ABAC tab"
contains "$authz" 'href="/admin/authz?tab=rebac"' "Authz UI has ReBAC tab"
contains "$authz" "frontend:orders:read" "Frontend scope visible"
contains "$authz" "admin:authz.roles:update" "Admin scope visible"
contains "$authz" "app.requests" "Application-declared scope visible"
contains "$authz" "scope-picker" "Authz UI renders scope picker"
contains "$authz" ".scope-option input" "Scope picker checkbox sizing isolated"
contains "$authz" "Subject user" "RBAC form labels subject user clearly"
contains "$authz" "Access context" "RBAC form labels frontend/admin context clearly"
if grep -q 'action="/admin/authz/abac/upsert"' <<<"$authz" || grep -q 'action="/admin/authz/rebac/upsert"' <<<"$authz"; then
  fail "RBAC tab should not render ABAC/ReBAC forms"
else
  pass "RBAC tab renders only RBAC management"
fi
authz_abac="$(curl -b "$COOKIE_JAR" -fsS "$BASE/admin/authz?tab=abac")"
contains "$authz_abac" 'aria-selected="true">ABAC' "ABAC tab can be selected"
if grep -q 'action="/api/authz/roles"' <<<"$authz_abac" || grep -q 'action="/admin/authz/rebac/upsert"' <<<"$authz_abac"; then
  fail "ABAC tab should not render RBAC/ReBAC forms"
else
  pass "ABAC tab renders only ABAC management"
fi
authz_rebac="$(curl -b "$COOKIE_JAR" -fsS "$BASE/admin/authz?tab=rebac")"
contains "$authz_rebac" 'aria-selected="true">ReBAC' "ReBAC tab can be selected"
if grep -q 'action="/api/authz/roles"' <<<"$authz_rebac" || grep -q 'action="/admin/authz/abac/upsert"' <<<"$authz_rebac"; then
  fail "ReBAC tab should not render RBAC/ABAC forms"
else
  pass "ReBAC tab renders only ReBAC management"
fi
contains "$authz_abac" 'action="/admin/authz/abac/upsert"' "Authz UI provides ABAC policy create form"
contains "$authz_abac" 'name="department"' "ABAC form uses declared department lookup"
contains "$authz_abac" 'name="visibility"' "ABAC form uses declared visibility lookup"
contains "$authz_abac" "Subject department" "ABAC form labels subject attributes"
contains "$authz_abac" "Resource visibility" "ABAC form labels resource attributes"
contains "$authz_rebac" 'action="/admin/authz/rebac/upsert"' "Authz UI provides ReBAC tuple create form"
contains "$authz_rebac" 'name="relation"' "ReBAC form uses declared relation lookup"
contains "$authz_rebac" "Subject" "ReBAC form labels subject"
contains "$authz_rebac" "Object" "ReBAC form labels object"
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
contains "$status" '"provider": "keto+demo-attribute-policy"' "Status reports composite Keto authz provider"
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

curl -b "$COOKIE_JAR" -fsS -d 'id=finance-public-read&context=frontend&resource=requests&action=read&effect=allow&department=finance&visibility=public' "$BASE/admin/authz/abac/upsert" >/dev/null
created_abac="$(curl -b "$COOKIE_JAR" -fsS "$BASE/api/authz/abac/policies")"
contains "$created_abac" '"finance-public-read"' "ABAC form creates policy"
curl -b "$COOKIE_JAR" -fsS -d 'id=finance-public-read' "$BASE/admin/authz/abac/delete" >/dev/null
deleted_abac="$(curl -b "$COOKIE_JAR" -fsS "$BASE/api/authz/abac/policies")"
if grep -q '"finance-public-read"' <<<"$deleted_abac"; then
  fail "ABAC form delete should remove policy"
else
  pass "ABAC form deletes policy"
fi

curl -b "$COOKIE_JAR" -fsS -d 'subject=readonly-admin@tailnet&relation=delegated-admin&object=admin-section:authz&context=admin' "$BASE/admin/authz/rebac/upsert" >/dev/null
created_rebac="$(curl -b "$COOKIE_JAR" -fsS "$BASE/api/authz/rebac/tuples")"
contains "$created_rebac" '"delegated-admin"' "ReBAC form creates tuple"
curl -b "$COOKIE_JAR" -fsS -d 'subject=readonly-admin@tailnet&relation=delegated-admin&object=admin-section:authz&context=admin' "$BASE/admin/authz/rebac/delete" >/dev/null
deleted_rebac="$(curl -b "$COOKIE_JAR" -fsS "$BASE/api/authz/rebac/tuples")"
if grep -q '"delegated-admin"' <<<"$deleted_rebac"; then
  fail "ReBAC form delete should remove tuple"
else
  pass "ReBAC form deletes tuple"
fi

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

frontend_auth_config_status="$(curl -b "$FRONTEND_COOKIE" -s -o /dev/null -w "%{http_code}" "$BASE/api/admin/auth/config")"
if [[ "$frontend_auth_config_status" == "403" ]]; then
  pass "Frontend-only user cannot access auth admin API"
else
  fail "Frontend-only auth admin API expected 403, got $frontend_auth_config_status"
fi

echo ""
echo "RESULTS: $PASS_COUNT passed, $FAIL_COUNT failed"
if [ "$FAIL_COUNT" -gt 0 ]; then
  exit 1
fi
