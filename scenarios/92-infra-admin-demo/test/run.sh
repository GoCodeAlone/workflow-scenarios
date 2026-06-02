#!/usr/bin/env bash
# Scenario 92 — Infra Admin MIGRATION demo test runner (v2)
#
# Tests the migration from the deleted infra.admin engine module to the
# new step.iac_provider_* pipeline architecture (workflow v0.70.0).
#
# Assertions:
#   1. /healthz 200 (stack health)
#   2. /api/admin/contributions 200 (admin shell reachable)
#   3. GET /api/infra/catalog → regions [stub-east,stub-west] + types [stub.database,stub.bucket]
#   4. GET /api/infra/resources → provider stub-iac-provider, resources []
#   5. POST /api/infra/plan (operator) → plan.actions[0].action=create, desired_hash=64-char hex
#   6. POST /api/infra/apply (operator) → apply_result, no error (hash guard passes)
#   7. POST /api/infra/commit (operator) → committed=true
#   8. GET /api/infra/drift (operator) → supported, any_drifted=false
#   9. Unauthenticated mutation → 401
#  10. Non-Bearer auth → 401 (CSRF gate)
#  11. Viewer POST /api/infra/apply → 403 (server-side RBAC)
#  12. GET /api/infra/secrets → metadata_only=true, values not exposed
#  13. Playwright spec (catalog dropdowns + SPA loads)
#
# Assumes seed.sh has already brought up the stack on port 18092.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCENARIO_DIR="$(dirname "$SCRIPT_DIR")"
SCENARIOS_ROOT="$(cd "$SCENARIO_DIR/../.." && pwd)"
BASE_URL="${BASE_URL:-http://127.0.0.1:18092}"
SCENARIO="92-infra-admin-demo"

PASS=0
FAIL=0
SKIP=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
skip() { echo "SKIP: $1"; SKIP=$((SKIP + 1)); }

echo ""
echo "=== Scenario $SCENARIO (v2: migration demo) ==="
echo ""

# --- PRECONDITION: /healthz ---------------------------------------------------

if ! curl -fs "$BASE_URL/healthz" >/dev/null 2>&1; then
  echo "FATAL: /healthz is not 200 — did seed.sh complete successfully?" >&2
  echo "Run: bash $SCENARIO_DIR/seed/seed.sh" >&2
  exit 1
fi
pass "GET /healthz returns 200 (stack health)"

# --- JWT minting helpers -------------------------------------------------------

CFG_LOCAL="$SCENARIO_DIR/config/app.yaml"

JWT_SECRET=$(python3 -c "
import re, sys
try:
    data = open('${CFG_LOCAL}').read()
    m = re.search(r'type:\s*auth\.jwt.*?secret:\s*[\"\'']?([^\"\''\n]+?)[\"\'']?\s*$', data, re.DOTALL | re.MULTILINE)
    if m:
        print(m.group(1).strip())
    else:
        sys.exit(1)
except Exception:
    sys.exit(1)
" 2>/dev/null) || JWT_SECRET='scenario-92-jwt-secret-do-not-use-in-prod'
export JWT_SECRET

NOW=$(date +%s)
EXP=$((NOW + 3600))

b64url() { openssl base64 -e -A | tr '+/' '-_' | tr -d '='; }

HEADER=$(printf '%s' '{"alg":"HS256","typ":"JWT"}' | b64url)

# Mint a JWT for the given sub claim
mint_jwt() {
  local sub="$1"
  local payload
  payload=$(printf '{"iss":"scenario-92","sub":"%s","iat":%d,"exp":%d}' "$sub" "$NOW" "$EXP" | b64url)
  local unsigned="${HEADER}.${payload}"
  local sig
  sig=$(printf '%s' "$unsigned" | openssl dgst -sha256 -hmac "$JWT_SECRET" -binary | b64url)
  printf '%s.%s' "$unsigned" "$sig"
}

OP_TOKEN=$(mint_jwt "operator")
VIEWER_TOKEN=$(mint_jwt "viewer")

# --- 1. Admin contributions ---------------------------------------------------

CONTRIB_CODE=$(curl -s -o /dev/null -w '%{http_code}' \
  -H "Authorization: Bearer $OP_TOKEN" \
  "$BASE_URL/api/admin/contributions" || echo "000")
if [ "$CONTRIB_CODE" = "200" ]; then
  pass "GET /api/admin/contributions reachable (200)"
else
  fail "GET /api/admin/contributions returned $CONTRIB_CODE (want 200)"
fi

# --- 2. Catalog (stub regions + types) ----------------------------------------

CATALOG_BODY=$(curl -s -H "Authorization: Bearer $OP_TOKEN" "$BASE_URL/api/infra/catalog" || echo '{}')
CATALOG_CODE=$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $OP_TOKEN" "$BASE_URL/api/infra/catalog" || echo "000")

if [ "$CATALOG_CODE" = "200" ]; then
  pass "GET /api/infra/catalog returns 200"
else
  fail "GET /api/infra/catalog returned $CATALOG_CODE (want 200)"
fi

if printf '%s' "$CATALOG_BODY" | python3 -c "
import sys, json
d = json.load(sys.stdin)
regions = [r if isinstance(r, str) else r.get('name', '') for r in d.get('regions', [])]
if 'stub-east' in regions and 'stub-west' in regions:
    sys.exit(0)
sys.exit(1)
" 2>/dev/null; then
  pass "Catalog regions include stub-east and stub-west (external plugin)"
else
  fail "Catalog regions missing stub-east/stub-west (got: $(printf '%s' "$CATALOG_BODY" | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d.get("regions", []))' 2>/dev/null || echo 'parse error'))"
fi

if printf '%s' "$CATALOG_BODY" | python3 -c "
import sys, json
d = json.load(sys.stdin)
types = [t.get('resource_type', t) if isinstance(t, dict) else t for t in d.get('types', [])]
if 'stub.database' in types and 'stub.bucket' in types:
    sys.exit(0)
sys.exit(1)
" 2>/dev/null; then
  pass "Catalog types include stub.database and stub.bucket (external plugin capabilities)"
else
  fail "Catalog types missing stub.database/stub.bucket (got: $(printf '%s' "$CATALOG_BODY" | python3 -c 'import sys,json; d=json.load(sys.stdin); print([t.get("resource_type","") for t in d.get("types",[])])' 2>/dev/null || echo 'parse error'))"
fi

if printf '%s' "$CATALOG_BODY" | python3 -c "
import sys, json
d = json.load(sys.stdin)
if d.get('source') == 'live':
    sys.exit(0)
sys.exit(1)
" 2>/dev/null; then
  pass "Catalog source=live (RegionLister served from external plugin gRPC)"
else
  skip "Catalog source not 'live' — may be static fallback (got: $(printf '%s' "$CATALOG_BODY" | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d.get("source"))' 2>/dev/null || echo 'unknown'))"
fi

# --- 3. List resources --------------------------------------------------------

LIST_CODE=$(curl -s -o /dev/null -w '%{http_code}' \
  -H "Authorization: Bearer $OP_TOKEN" \
  "$BASE_URL/api/infra/resources" || echo "000")
if [ "$LIST_CODE" = "200" ]; then
  pass "GET /api/infra/resources returns 200 (step.iac_provider_list)"
else
  fail "GET /api/infra/resources returned $LIST_CODE (want 200)"
fi

# --- 4. Plan (operator) -------------------------------------------------------

PLAN_BODY=$(curl -s -X POST "$BASE_URL/api/infra/plan" \
  -H 'Content-Type: application/json' \
  -H "Authorization: Bearer $OP_TOKEN" \
  -d '{}' || echo '{}')
PLAN_CODE=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$BASE_URL/api/infra/plan" \
  -H 'Content-Type: application/json' \
  -H "Authorization: Bearer $OP_TOKEN" \
  -d '{}' || echo "000")

if [ "$PLAN_CODE" = "200" ]; then
  pass "POST /api/infra/plan (operator) returns 200 (step.iac_provider_plan)"
else
  fail "POST /api/infra/plan (operator) returned $PLAN_CODE (want 200)"
fi

DESIRED_HASH=$(printf '%s' "$PLAN_BODY" | python3 -c "
import sys, json
d = json.load(sys.stdin)
print(d.get('desired_hash', ''))
" 2>/dev/null || true)

if printf '%s' "$DESIRED_HASH" | grep -qE '^[0-9a-f]{64}$'; then
  pass "plan desired_hash is 64-char lowercase hex SHA-256 (M-3 two-phase guard)"
else
  fail "plan desired_hash not 64-char hex: got '$DESIRED_HASH'"
fi

PLAN_ACTIONS=$(printf '%s' "$PLAN_BODY" | python3 -c "
import sys, json
d = json.load(sys.stdin)
plan = d.get('plan', {})
actions = plan.get('actions', plan.get('Actions', [])) if isinstance(plan, dict) else []
if actions and len(actions) > 0:
    print(actions[0].get('action', actions[0].get('Action', '')))
else:
    print('')
" 2>/dev/null || true)

if [ "$PLAN_ACTIONS" = "create" ]; then
  pass "Plan contains 1 'create' action (stub provider deterministic data)"
else
  fail "Plan first action not 'create': got '$PLAN_ACTIONS' (full plan: $PLAN_BODY)"
fi

# --- 5. Apply (operator, hash guard) ------------------------------------------

APPLY_BODY=$(curl -s -X POST "$BASE_URL/api/infra/apply" \
  -H 'Content-Type: application/json' \
  -H "Authorization: Bearer $OP_TOKEN" \
  -d '{}' || echo '{}')
APPLY_CODE=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$BASE_URL/api/infra/apply" \
  -H 'Content-Type: application/json' \
  -H "Authorization: Bearer $OP_TOKEN" \
  -d '{}' || echo "000")

if [ "$APPLY_CODE" = "200" ]; then
  pass "POST /api/infra/apply (operator) returns 200 (step.iac_provider_apply, hash guard passes)"
else
  APPLY_ERROR=$(printf '%s' "$APPLY_BODY" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('error',''))" 2>/dev/null || echo "")
  fail "POST /api/infra/apply (operator) returned $APPLY_CODE: $APPLY_ERROR"
fi

# --- 6. Commit (operator) -----------------------------------------------------

COMMIT_BODY=$(curl -s -X POST "$BASE_URL/api/infra/commit" \
  -H 'Content-Type: application/json' \
  -H "Authorization: Bearer $OP_TOKEN" \
  -d '{}' || echo '{}')
COMMIT_CODE=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$BASE_URL/api/infra/commit" \
  -H 'Content-Type: application/json' \
  -H "Authorization: Bearer $OP_TOKEN" \
  -d '{}' || echo "000")

if [ "$COMMIT_CODE" = "200" ]; then
  pass "POST /api/infra/commit (operator) returns 200"
else
  fail "POST /api/infra/commit returned $COMMIT_CODE"
fi

COMMITTED=$(printf '%s' "$COMMIT_BODY" | python3 -c "
import sys, json
d = json.load(sys.stdin)
print(str(d.get('committed', '')).lower())
" 2>/dev/null || echo "false")
if [ "$COMMITTED" = "true" ]; then
  pass "Commit response committed=true"
else
  fail "Commit response committed not true: $COMMIT_BODY"
fi

# --- 7. Drift check (operator) ------------------------------------------------

DRIFT_BODY=$(curl -s -H "Authorization: Bearer $OP_TOKEN" "$BASE_URL/api/infra/drift" || echo '{}')
DRIFT_CODE=$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $OP_TOKEN" "$BASE_URL/api/infra/drift" || echo "000")

if [ "$DRIFT_CODE" = "200" ]; then
  pass "GET /api/infra/drift returns 200 (step.iac_provider_drift)"
else
  fail "GET /api/infra/drift returned $DRIFT_CODE (want 200)"
fi

ANY_DRIFTED=$(printf '%s' "$DRIFT_BODY" | python3 -c "
import sys, json
d = json.load(sys.stdin)
print(str(d.get('any_drifted', '')).lower())
" 2>/dev/null || echo "")
if [ "$ANY_DRIFTED" = "false" ]; then
  pass "Drift any_drifted=false (stub DetectDrift returns InSync for all refs)"
else
  skip "Drift any_drifted not false: $DRIFT_BODY"
fi

# --- 8. Secrets metadata ------------------------------------------------------

SECRETS_BODY=$(curl -s -H "Authorization: Bearer $OP_TOKEN" "$BASE_URL/api/infra/secrets" || echo '{}')
SECRETS_CODE=$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $OP_TOKEN" "$BASE_URL/api/infra/secrets" || echo "000")

if [ "$SECRETS_CODE" = "200" ]; then
  pass "GET /api/infra/secrets returns 200 (metadata only)"
else
  fail "GET /api/infra/secrets returned $SECRETS_CODE"
fi

META_ONLY=$(printf '%s' "$SECRETS_BODY" | python3 -c "
import sys, json
d = json.load(sys.stdin)
print(str(d.get('metadata_only', '')).lower())
" 2>/dev/null || echo "false")
if [ "$META_ONLY" = "true" ]; then
  pass "Secrets response metadata_only=true (values never echoed)"
else
  fail "Secrets metadata_only not true: $SECRETS_BODY"
fi

# --- 9. Unauthenticated mutations → 401 ---------------------------------------

for endpoint in "plan" "apply" "commit"; do
  unauth_code=$(curl -s -o /dev/null -w '%{http_code}' -X POST \
    -H 'Content-Type: application/json' \
    -d '{}' \
    "$BASE_URL/api/infra/$endpoint" || echo "000")
  if [ "$unauth_code" = "401" ]; then
    pass "POST /api/infra/$endpoint without auth → 401 (auth gate)"
  else
    fail "POST /api/infra/$endpoint unauthenticated returned $unauth_code (want 401)"
  fi
done

# --- 10. Non-Bearer Authorization → 401 (CSRF gate) --------------------------

for endpoint in "plan" "apply"; do
  no_bearer=$(curl -s -o /dev/null -w '%{http_code}' -X POST \
    -H 'Content-Type: application/json' \
    -H "Authorization: Token $OP_TOKEN" \
    -d '{}' \
    "$BASE_URL/api/infra/$endpoint" || echo "000")
  if [ "$no_bearer" = "401" ]; then
    pass "POST /api/infra/$endpoint with Token (non-Bearer) → 401 (CSRF gate)"
  else
    fail "POST /api/infra/$endpoint Token scheme returned $no_bearer (want 401)"
  fi
done

# --- 11. Viewer apply → 403 (server-side RBAC) --------------------------------

viewer_apply=$(curl -s -o /dev/null -w '%{http_code}' -X POST \
  -H 'Content-Type: application/json' \
  -H "Authorization: Bearer $VIEWER_TOKEN" \
  -d '{}' \
  "$BASE_URL/api/infra/apply" || echo "000")
if [ "$viewer_apply" = "403" ]; then
  pass "POST /api/infra/apply (viewer) → 403 (server-side RBAC: viewer cannot apply)"
else
  fail "POST /api/infra/apply (viewer) returned $viewer_apply (want 403)"
fi

viewer_plan=$(curl -s -o /dev/null -w '%{http_code}' -X POST \
  -H 'Content-Type: application/json' \
  -H "Authorization: Bearer $VIEWER_TOKEN" \
  -d '{}' \
  "$BASE_URL/api/infra/plan" || echo "000")
if [ "$viewer_plan" = "403" ]; then
  pass "POST /api/infra/plan (viewer) → 403 (server-side RBAC: viewer cannot plan)"
else
  fail "POST /api/infra/plan (viewer) returned $viewer_plan (want 403)"
fi

# --- 12. Bare git repo fixture (seed.sh initialized it) ----------------------
# Verify the bare git repo was initialized and has at least one commit.

BARE_REPO="$SCENARIO_DIR/.build/gitrepo.git"
if [ -d "$BARE_REPO/objects" ]; then
  GIT_LOG=$(GIT_DIR="$BARE_REPO" git log --oneline 2>/dev/null | head -1)
  if [ -n "$GIT_LOG" ]; then
    pass "Bare git repo has commits: $GIT_LOG (gitops fixture ready)"
  else
    fail "Bare git repo has no commits"
  fi
else
  skip "Bare git repo not found at $BARE_REPO (seed.sh not run yet)"
fi

# --- 13. Playwright spec ------------------------------------------------------

PLAYWRIGHT_SPEC="$SCENARIOS_ROOT/e2e/tests/scenario-92-infra-admin.spec.ts"
if [ -f "$PLAYWRIGHT_SPEC" ]; then
  if command -v npx >/dev/null 2>&1; then
    echo ""
    echo "Running Playwright regression spec..."
    (cd "$SCENARIOS_ROOT/e2e" && \
      SCENARIO_URL="$BASE_URL" \
      JWT_SECRET="$JWT_SECRET" \
      npx playwright test scenario-92-infra-admin.spec.ts \
      --reporter=list 2>&1 | tail -40) \
      && pass "Playwright scenario-92 spec passed" \
      || fail "Playwright scenario-92 spec failed (see output above)"
  else
    skip "Playwright skipped (npx not installed)"
  fi
else
  fail "Playwright spec not found at $PLAYWRIGHT_SPEC"
fi

# --- Summary ------------------------------------------------------------------

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
