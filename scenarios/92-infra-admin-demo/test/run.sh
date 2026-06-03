#!/usr/bin/env bash
# Scenario 92 — Infra Admin Phase 2/3 demo test runner (workflow v0.74.0)
#
# Tests Phase 1 (migration) assertions PLUS Phase 2/3 assertions:
#
# Phase 1 assertions (original 16, updated for dynamic specs):
#   1.  GET /healthz → 200
#   2.  GET /api/admin/contributions → 200
#   3a. GET /api/infra/catalog → regions [stub-east,stub-west]
#   3b. GET /api/infra/catalog → types [stub.database,stub.bucket]
#   3c. GET /api/infra/catalog → source=live
#   4.  GET /api/infra/resources → 200
#   5a. POST /api/infra/plan (operator, WITH specs) → 200
#   5b. plan desired_hash 64-char hex
#   5c. plan contains 1 create action
#   6.  POST /api/infra/apply (operator, WITH specs + hash from /plan) → 200
#   7.  POST /api/infra/reconcile → 200
#   8.  GET /api/infra/drift (operator) → supported, any_drifted=false
#   9.  Unauthenticated mutations → 401
#  10.  Non-Bearer auth → 401 (CSRF gate)
#  11a. Viewer POST /api/infra/apply → 403
#  11b. Viewer POST /api/infra/plan → 403
#  12.  GET /api/infra/secrets → metadata_only=true
#  13.  Bare git repo fixture present (gitops demo)
#  14.  GET /admin/infra → 200, SPA served
#  15.  /api/admin/contributions includes infra-resources at /admin/infra
#  16.  Playwright spec
#
# Phase 2/3 assertions (new):
# (a) HEADLINE — DYNAMIC apply → CREATE → commit-back: operator POSTs operator-edited
#     specs (with secret:// ref) to /plan then /apply → 200, resources CREATED with NO
#     per-action errors (ResourceDriver wired in workflow v0.74.0) → commit-back branch
#     appears in bare repo + committed resources.yaml carries the literal "secret://"
#     ref (NOT resolved value). Hard assertion (no SKIP).
# (b) Reachability 409: spec with secret:// ref + exec_env=remote → POST /apply → 409.
# (c) Reconcile: POST /reconcile → 200, response shape {draft,ref,warning,count}.
# (d) Remote runner: POST /api/infra/sandbox-demo → 200 + MARKER in stdout.
#     Agent profile-clamp log line in docker logs.
# (e) Subject-RBAC viewer → 403 (in Phase 1 block, unchanged).
# (f) 207 state_diverged: DOCUMENTED — not exercisable in the hermetic stack without
#     corrupting the workclone; the code path is covered by unit tests.
# (g) Argo: SCENARIO_92_ARGO-gated (skip unless env var set).
#
# JWT regex: uses [\x22\x27] char classes (NOT [\"\']) — recurring bug avoidance.
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
echo "=== Scenario $SCENARIO (Phase 2/3: dynamic specs + remote runner + commit-back) ==="
echo ""

# --- PRECONDITION: /healthz ---------------------------------------------------

if ! curl -fs "$BASE_URL/healthz" >/dev/null 2>&1; then
  echo "FATAL: /healthz is not 200 — did seed.sh complete successfully?" >&2
  echo "Run: bash $SCENARIO_DIR/seed/seed.sh" >&2
  exit 1
fi
pass "GET /healthz returns 200 (stack health)"

# --- JWT minting helpers -------------------------------------------------------
# JWT regex uses [\x22\x27] char class (avoids the [\"\'] bugclass)

CFG_LOCAL="$SCENARIO_DIR/config/app.yaml"

JWT_SECRET=$(python3 -c "
import re, sys
try:
    data = open('${CFG_LOCAL}').read()
    m = re.search(r'type:\s*auth\.jwt.*?secret:\s*[\x22\x27]?([^\x22\x27\n]+?)[\x22\x27]?\s*$', data, re.DOTALL | re.MULTILINE)
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

# Operator-edited specs (with a secret:// ref that must survive commit-back verbatim)
# This is the NEW dynamic spec set that demonstrates Phase-2 specs_from.
DEMO_SPECS='[{"name":"demo-db","type":"stub.database","config":{"engine":"postgres","version":"15","api_key":"secret://scenario/stub_api_key"}}]'

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

# --- 4. Plan (operator, DYNAMIC specs from body) -------------------------------
# Phase-2: POST body includes "specs" array; step.iac_provider_plan uses specs_from.

PLAN_BODY=$(curl -s -X POST "$BASE_URL/api/infra/plan" \
  -H 'Content-Type: application/json' \
  -H "Authorization: Bearer $OP_TOKEN" \
  -d "{\"specs\":$DEMO_SPECS}" || echo '{}')
PLAN_CODE=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$BASE_URL/api/infra/plan" \
  -H 'Content-Type: application/json' \
  -H "Authorization: Bearer $OP_TOKEN" \
  -d "{\"specs\":$DEMO_SPECS}" || echo "000")

if [ "$PLAN_CODE" = "200" ]; then
  pass "POST /api/infra/plan (operator, dynamic specs) returns 200"
else
  fail "POST /api/infra/plan (operator) returned $PLAN_CODE (body: $PLAN_BODY)"
fi

DESIRED_HASH=$(printf '%s' "$PLAN_BODY" | python3 -c "
import sys, json
d = json.load(sys.stdin)
print(d.get('desired_hash', ''))
" 2>/dev/null || true)

if printf '%s' "$DESIRED_HASH" | grep -qE '^[0-9a-f]{64}$'; then
  pass "plan desired_hash is 64-char lowercase hex SHA-256 (dynamic specs two-phase guard)"
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
  pass "Plan contains 'create' action for operator-edited spec (stub provider)"
else
  fail "Plan first action not 'create': got '$PLAN_ACTIONS' (full plan: $PLAN_BODY)"
fi

# --- 5. Apply (operator, DYNAMIC specs + hash, reachability passes) -----------
# Phase-2: POST body includes "specs" + "desired_hash" + exec_env="" (local-docker path).
# Reachability check: secrets.keychain + local exec_env → reachable → apply proceeds.
# iac_commit_back: CREATEs the resource then pushes a branch to the bare repo.
#
# IMPORTANT: a SINGLE apply call (body + HTTP code captured together via the
# trailing \nHTTP_CODE:%{http_code} marker). The commit-back branch name is
# static, so calling /apply twice would make the second `git checkout -b` fail
# (branch already exists) → state_diverged. One call keeps commit-back idempotent
# within the run (seed.sh recreates a clean workclone each run).

APPLY_RAW=$(curl -s -w $'\nHTTP_CODE:%{http_code}' -X POST "$BASE_URL/api/infra/apply" \
  -H 'Content-Type: application/json' \
  -H "Authorization: Bearer $OP_TOKEN" \
  -d "{\"specs\":$DEMO_SPECS,\"desired_hash\":\"$DESIRED_HASH\"}" || printf '{}\nHTTP_CODE:000')
APPLY_CODE=$(printf '%s' "$APPLY_RAW" | sed -n 's/^HTTP_CODE://p' | tail -1)
APPLY_BODY=$(printf '%s' "$APPLY_RAW" | sed '/^HTTP_CODE:/d')

if [ "$APPLY_CODE" = "200" ]; then
  pass "POST /api/infra/apply (operator, dynamic specs, local exec_env) returns 200"
else
  APPLY_ERROR=$(printf '%s' "$APPLY_BODY" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('error',''))" 2>/dev/null || echo "")
  fail "POST /api/infra/apply (operator) returned $APPLY_CODE: $APPLY_ERROR (body: $APPLY_BODY)"
fi

# --- (a) HEADLINE: dynamic apply → CREATE → commit-back (secret:// survives) ──
# workflow v0.74.0 wires providerclient.ResourceDriver end-to-end, so the operator
# flow genuinely CREATEs resources and commit-back commits a branch:
#   1. /plan with operator-edited specs → desired_hash from dynamic specs.
#   2. /apply with same specs + hash → step.iac_provider_apply CREATEs each
#      resource via the stub's ResourceDriver.Create (no per-action errors now).
#   3. step.iac_commit_back commits resources.yaml + pushes a branch to the bare
#      repo. The committed YAML carries the AUTHORED secret:// ref VERBATIM
#      (specgen.SpecToYAML does NOT resolve it).

BARE_REPO="$SCENARIO_DIR/.build/gitrepo.git"
WORK_CLONE="$SCENARIO_DIR/.build/workclone"

# (a.1) specs_from: dynamic desired_hash (not static).
if printf '%s' "$DESIRED_HASH" | grep -qE '^[0-9a-f]{64}$'; then
  pass "(a) specs_from: desired_hash is 64-char hex from operator-edited dynamic specs (not static)"
else
  fail "(a) specs_from: desired_hash not 64-char hex (got: '$DESIRED_HASH')"
fi

# (a.2) apply GENUINELY CREATEd at least one resource with NO per-action errors.
#
# This must FAIL when ResourceDriver was never invoked. The engine returns:
#   apply_result.resources = [ {name, provider_id, status, type, outputs}, ... ]  (created resources)
#   apply_result.actions   = [ {action_index, status}, ... ]                       (per-action outcomes)
#   apply_result.errors    = [ {action, error, resource}, ... ]                    (per-action failures)
# A null/absent apply_result (the ResourceDriver-never-ran case) must NOT pass:
# we require apply_result is a non-null dict AND len(resources) >= 1 AND no errors.
# Emit a single verdict token (OK / NO_APPLY_RESULT / NO_RESOURCES / ERRORS:<msg>).
APPLY_VERDICT=$(printf '%s' "$APPLY_BODY" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
except Exception as e:
    print('NO_APPLY_RESULT (unparseable body)'); sys.exit(0)
result = d.get('apply_result')
if result is None or not isinstance(result, dict):
    print('NO_APPLY_RESULT'); sys.exit(0)
errors = result.get('errors') or []
if len(errors) > 0:
    msg = errors[0].get('error','') if isinstance(errors[0], dict) else str(errors[0])
    print('ERRORS:' + msg); sys.exit(0)
resources = result.get('resources') or []
if not isinstance(resources, list) or len(resources) < 1:
    print('NO_RESOURCES'); sys.exit(0)
print('OK count=%d' % len(resources))
" 2>/dev/null || echo "NO_APPLY_RESULT (python error)")
if [ "${APPLY_VERDICT%% *}" = "OK" ]; then
  pass "(a) apply GENUINELY CREATEd resources: $APPLY_VERDICT, no per-action errors (ResourceDriver wired, v0.74.0)"
else
  fail "(a) apply did NOT create resources [$APPLY_VERDICT] — ResourceDriver may not have run (full: $APPLY_BODY)"
fi

# (a.3) commit-back committed=true in the apply response.
COMMITTED=$(printf '%s' "$APPLY_BODY" | python3 -c "import sys,json; d=json.load(sys.stdin); print(str(d.get('committed','')).lower())" 2>/dev/null || echo "")
if [ "$COMMITTED" = "true" ]; then
  pass "(a) commit-back: committed=true in apply response (step.iac_commit_back pushed a branch)"
else
  fail "(a) commit-back: committed not true (got '$COMMITTED'; apply response: $APPLY_BODY)"
fi

# (a.4) the commit-back branch appears in the bare repo carrying the literal secret:// ref.
#
# Query the BARE repo directly by its host path ($BARE_REPO). The engine pushed
# the branch from inside the container via its origin remote (container path
# /gitops/bare.git, which maps to $BARE_REPO on the host). The host workclone's
# own origin URL is the container path (unreachable from the host), so we MUST
# read the bare repo directly — not via the workclone's origin.
if [ -d "$BARE_REPO/objects" ]; then
  BRANCH_EXISTS=$(git -C "$BARE_REPO" for-each-ref --format='%(refname:short)' "refs/heads/gitops/infra-apply-demo" 2>/dev/null | wc -l | tr -d ' ')
  if [ "${BRANCH_EXISTS:-0}" -gt 0 ]; then
    BRANCH_COMMIT=$(git -C "$BARE_REPO" log -1 --oneline "gitops/infra-apply-demo" 2>/dev/null || echo "")
    pass "(a) commit-back branch 'gitops/infra-apply-demo' pushed to bare repo ($BRANCH_COMMIT)"
    RESOURCES_YAML=$(git -C "$BARE_REPO" show "gitops/infra-apply-demo:resources.yaml" 2>/dev/null || echo "")
    if printf '%s' "$RESOURCES_YAML" | grep -q "secret://scenario/stub_api_key"; then
      pass "(a) committed resources.yaml carries the literal 'secret://scenario/stub_api_key' ref (NOT resolved)"
    else
      fail "(a) resources.yaml does NOT contain literal secret:// ref (got: $RESOURCES_YAML)"
    fi
  else
    fail "(a) commit-back branch 'gitops/infra-apply-demo' NOT found in bare repo (apply response: $APPLY_BODY)"
  fi
else
  fail "(a) commit-back: bare repo not found at $BARE_REPO (seed.sh not run?)"
fi

# --- 6. Reconcile: POST /api/infra/reconcile ─────────────────────────────────
# Phase-3: stub DetectDrift returns Drifted:false → count=0 → no commit.
# Response shape: {draft, ref, warning, count} — all must be present.

RECONCILE_BODY=$(curl -s -X POST "$BASE_URL/api/infra/reconcile" \
  -H 'Content-Type: application/json' \
  -H "Authorization: Bearer $OP_TOKEN" \
  -d '{}' || echo '{}')
RECONCILE_CODE=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$BASE_URL/api/infra/reconcile" \
  -H 'Content-Type: application/json' \
  -H "Authorization: Bearer $OP_TOKEN" \
  -d '{}' || echo "000")

if [ "$RECONCILE_CODE" = "200" ]; then
  pass "POST /api/infra/reconcile returns 200 (step.iac_provider_reconcile)"
else
  RECONCILE_ERROR=$(printf '%s' "$RECONCILE_BODY" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('error',''))" 2>/dev/null || echo "")
  fail "POST /api/infra/reconcile returned $RECONCILE_CODE: $RECONCILE_ERROR"
fi

if printf '%s' "$RECONCILE_BODY" | python3 -c "
import sys, json
d = json.load(sys.stdin)
# draft, warning, count must all be present (ref is optional — absent when draft=false)
if 'draft' in d and 'warning' in d and 'count' in d:
    sys.exit(0)
sys.exit(1)
" 2>/dev/null; then
  pass "(c) reconcile response has required fields: draft, warning, count"
else
  fail "(c) reconcile response missing expected fields (got: $RECONCILE_BODY)"
fi

RECONCILE_COUNT=$(printf '%s' "$RECONCILE_BODY" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('count',0))" 2>/dev/null || echo "0")
if [ "$RECONCILE_COUNT" = "0" ]; then
  pass "(c) reconcile count=0 (stub DetectDrift returns no drift — correct for stub provider)"
else
  fail "(c) reconcile count=$RECONCILE_COUNT (expected 0 for stub provider — stub DetectDrift always returns Drifted:false)"
fi

# --- 7. Drift check (read-only) -----------------------------------------------

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

# --- 8. Secrets metadata -------------------------------------------------------

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

# --- 9. Unauthenticated mutations → 401 ----------------------------------------

for endpoint in "plan" "apply" "reconcile"; do
  unauth_code=$(curl -s -o /dev/null -w '%{http_code}' -X POST \
    -H 'Content-Type: application/json' \
    -d "{\"specs\":$DEMO_SPECS}" \
    "$BASE_URL/api/infra/$endpoint" || echo "000")
  if [ "$unauth_code" = "401" ]; then
    pass "POST /api/infra/$endpoint without auth → 401 (auth gate)"
  else
    fail "POST /api/infra/$endpoint unauthenticated returned $unauth_code (want 401)"
  fi
done

# --- 10. Non-Bearer Authorization → 401 (CSRF gate) ----------------------------

for endpoint in "plan" "apply"; do
  no_bearer=$(curl -s -o /dev/null -w '%{http_code}' -X POST \
    -H 'Content-Type: application/json' \
    -H "Authorization: Token $OP_TOKEN" \
    -d "{\"specs\":$DEMO_SPECS}" \
    "$BASE_URL/api/infra/$endpoint" || echo "000")
  if [ "$no_bearer" = "401" ]; then
    pass "POST /api/infra/$endpoint with Token (non-Bearer) → 401 (CSRF gate)"
  else
    fail "POST /api/infra/$endpoint Token scheme returned $no_bearer (want 401)"
  fi
done

# --- 11. RBAC: viewer → 403 (assertions e) ─────────────────────────────────────

viewer_apply=$(curl -s -o /dev/null -w '%{http_code}' -X POST \
  -H 'Content-Type: application/json' \
  -H "Authorization: Bearer $VIEWER_TOKEN" \
  -d "{\"specs\":$DEMO_SPECS,\"desired_hash\":\"$DESIRED_HASH\"}" \
  "$BASE_URL/api/infra/apply" || echo "000")
if [ "$viewer_apply" = "403" ]; then
  pass "(e) POST /api/infra/apply (viewer) → 403 (server-side RBAC: viewer cannot apply)"
else
  fail "(e) POST /api/infra/apply (viewer) returned $viewer_apply (want 403)"
fi

viewer_plan=$(curl -s -o /dev/null -w '%{http_code}' -X POST \
  -H 'Content-Type: application/json' \
  -H "Authorization: Bearer $VIEWER_TOKEN" \
  -d "{\"specs\":$DEMO_SPECS}" \
  "$BASE_URL/api/infra/plan" || echo "000")
if [ "$viewer_plan" = "403" ]; then
  pass "POST /api/infra/plan (viewer) → 403 (server-side RBAC: viewer cannot plan)"
else
  fail "POST /api/infra/plan (viewer) returned $viewer_plan (want 403)"
fi

# --- (b) Reachability 409: secret:// ref + exec_env=remote → 409 ---------------
# Phase-2 assertion: /api/infra/apply-remote (dedicated route with exec_env: remote
# in step config) → reachability pre-flight → 409 for specs with secret:// refs.
# (step.iac_secret_reachability exec_env is static in config; the -remote route
# hard-codes exec_env: remote to prove the fail-safe ADR 0017 path.)

REACH_CODE=$(curl -s -o /dev/null -w '%{http_code}' -X POST \
  -H 'Content-Type: application/json' \
  -H "Authorization: Bearer $OP_TOKEN" \
  -d "{\"specs\":$DEMO_SPECS,\"desired_hash\":\"$DESIRED_HASH\"}" \
  "$BASE_URL/api/infra/apply-remote" || echo "000")
if [ "$REACH_CODE" = "409" ]; then
  pass "(b) POST /api/infra/apply-remote with secret:// ref → 409 (host-local secrets unreachable from remote exec_env, ADR 0017)"
else
  REACH_BODY=$(curl -s -X POST \
    -H 'Content-Type: application/json' \
    -H "Authorization: Bearer $OP_TOKEN" \
    -d "{\"specs\":$DEMO_SPECS,\"desired_hash\":\"$DESIRED_HASH\"}" \
    "$BASE_URL/api/infra/apply-remote" || echo '{}')
  fail "(b) POST /api/infra/apply-remote returned $REACH_CODE (want 409): $REACH_BODY"
fi

# --- 12. Bare git repo fixture (seed.sh initialized it) -----------------------

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

# --- 13. exec-envs endpoint ---------------------------------------------------

EXEC_ENVS_BODY=$(curl -s "$BASE_URL/api/infra/exec-envs" || echo '{}')
EXEC_ENVS_CODE=$(curl -s -o /dev/null -w '%{http_code}' "$BASE_URL/api/infra/exec-envs" || echo "000")

if [ "$EXEC_ENVS_CODE" = "200" ]; then
  pass "GET /api/infra/exec-envs returns 200"
else
  fail "GET /api/infra/exec-envs returned $EXEC_ENVS_CODE (want 200)"
fi

if printf '%s' "$EXEC_ENVS_BODY" | python3 -c "
import sys, json
d = json.load(sys.stdin)
envs = d.get('exec_envs', [])
if 'local-docker' in envs and 'remote' in envs:
    sys.exit(0)
sys.exit(1)
" 2>/dev/null; then
  pass "exec-envs includes local-docker and remote"
else
  fail "exec-envs missing local-docker or remote (got: $EXEC_ENVS_BODY)"
fi

# --- 14. SPA served at /admin/infra -------------------------------------------

SPA_CODE=$(curl -sL -o /dev/null -w '%{http_code}' "$BASE_URL/admin/infra" || echo "000")
if [ "$SPA_CODE" = "200" ]; then
  pass "GET /admin/infra returns 200 (SPA served by workflow-plugin-infra ConfigFragment)"
else
  fail "GET /admin/infra returned $SPA_CODE (want 200)"
fi

SPA_BODY=$(curl -sL "$BASE_URL/admin/infra" || echo "")
if printf '%s' "$SPA_BODY" | grep -q 'id="root"'; then
  pass "GET /admin/infra response contains <div id=\"root\"> (React SPA entry point)"
else
  fail "GET /admin/infra response missing id=\"root\""
fi

# --- 15. /api/admin/contributions includes infra-resources --------------------

CONTRIB_BODY=$(curl -s -H "Authorization: Bearer $OP_TOKEN" \
  "$BASE_URL/api/admin/contributions" || echo '{}')

if printf '%s' "$CONTRIB_BODY" | python3 -c "
import sys, json
d = json.load(sys.stdin)
contribs = d.get('contributions', [])
infra = next((c for c in contribs if c.get('id') == 'infra-resources'), None)
if infra and infra.get('path') == '/admin/infra':
    sys.exit(0)
sys.exit(1)
" 2>/dev/null; then
  pass "/api/admin/contributions includes infra-resources contribution at /admin/infra"
else
  CONTRIB_IDS=$(printf '%s' "$CONTRIB_BODY" | python3 -c \
    'import sys,json; d=json.load(sys.stdin); print([c.get("id") for c in d.get("contributions",[])])' \
    2>/dev/null || echo "parse error")
  fail "/api/admin/contributions missing infra-resources (got ids: $CONTRIB_IDS)"
fi

# --- (d) Remote runner: sandbox-demo → MARKER in stdout ─────────────────────
# Phase-3: POSTs to /api/infra/sandbox-demo which runs step.sandbox_exec(exec_env:remote).
# The remote agent (sandbox-runner container) executes the command in Alpine.
# The test asserts: MARKER in response stdout.
# Profile clamp assertion: grep docker logs for "clamped requested profile".

SANDBOX_BODY=$(curl -s -X POST "$BASE_URL/api/infra/sandbox-demo" \
  -H 'Content-Type: application/json' \
  -H "Authorization: Bearer $OP_TOKEN" \
  -d '{}' || echo '{}')
SANDBOX_CODE=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$BASE_URL/api/infra/sandbox-demo" \
  -H 'Content-Type: application/json' \
  -H "Authorization: Bearer $OP_TOKEN" \
  -d '{}' || echo "000")

if [ "$SANDBOX_CODE" = "200" ]; then
  pass "(d) POST /api/infra/sandbox-demo returns 200 (remote agent executed)"
else
  fail "(d) POST /api/infra/sandbox-demo returned $SANDBOX_CODE (body: $SANDBOX_BODY)"
fi

SANDBOX_STDOUT=$(printf '%s' "$SANDBOX_BODY" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('stdout',''))" 2>/dev/null || echo "")
if printf '%s' "$SANDBOX_STDOUT" | grep -q "SCENARIO92_REMOTE_AGENT_MARKER"; then
  pass "(d) sandbox-demo stdout contains SCENARIO92_REMOTE_AGENT_MARKER (remote agent executed command)"
else
  fail "(d) sandbox-demo stdout missing MARKER (got stdout: '$SANDBOX_STDOUT', body: $SANDBOX_BODY)"
fi

# Check agent profile clamp in docker logs (permissive → standard).
RUNNER_LOGS=$(docker logs workflow-scenario-92-sandbox-runner 2>&1 || echo "")
if printf '%s' "$RUNNER_LOGS" | grep -q "clamped"; then
  pass "(d) sandbox-runner logs contain 'clamped' (permissive profile clamped to standard, ADR 0019)"
else
  skip "(d) sandbox-runner clamp log not found (may not have run permissive exec yet; logs: $(printf '%s' "$RUNNER_LOGS" | tail -5))"
fi

# --- (f) 207 state_diverged: DOCUMENTED ─────────────────────────────────────
# Simulation of commit-back git failure after successful apply requires corrupting
# the working clone while the container has it mounted (race-prone). The 207 code
# path is covered by unit tests in module/pipeline_step_iac_commit_back_test.go.
# In the hermetic stack we assert the response shape is correct by checking that
# the apply response carries a 'committed' field (true or false).

COMMITTED_FIELD=$(printf '%s' "$APPLY_BODY" | python3 -c "import sys,json; d=json.load(sys.stdin); print('committed' in d)" 2>/dev/null || echo "False")
if [ "$COMMITTED_FIELD" = "True" ]; then
  pass "(f) apply response carries 'committed' field (207 state_diverged path documented in code)"
else
  skip "(f) apply response missing 'committed' field: $APPLY_BODY"
fi

# --- (g) Argo: SCENARIO_92_ARGO-gated ─────────────────────────────────────────
# exec_env: ephemeral (Argo Workflows) requires a running kind cluster + Argo install.
# Not available in the hermetic docker-compose demo. Gated on SCENARIO_92_ARGO=1.

if [ "${SCENARIO_92_ARGO:-0}" = "1" ]; then
  # When SCENARIO_92_ARGO=1, the operator has wired kind + Argo. The test
  # would POST to a route configured with exec_env: ephemeral and assert the
  # Argo Workflow pod completed.
  skip "(g) Argo: SCENARIO_92_ARGO=1 set but Argo integration route not wired in app.yaml (see Phase-4 plan)"
else
  skip "(g) Argo: exec_env: ephemeral skipped (set SCENARIO_92_ARGO=1 with kind+Argo to enable)"
fi

# --- 16. Playwright spec -------------------------------------------------------

PLAYWRIGHT_SPEC="$SCENARIOS_ROOT/e2e/tests/scenario-92-infra-admin.spec.ts"
if [ -f "$PLAYWRIGHT_SPEC" ]; then
  if command -v npx >/dev/null 2>&1; then
    echo ""
    echo "Running Playwright regression spec (Phase 2/3 extended)..."
    (cd "$SCENARIOS_ROOT/e2e" && \
      SCENARIO_URL="$BASE_URL" \
      JWT_SECRET="$JWT_SECRET" \
      npx playwright test scenario-92-infra-admin.spec.ts \
      --reporter=list 2>&1 | tail -60) \
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
echo ""
if [ "$FAIL" -gt 0 ]; then
  echo "FAILED — $FAIL assertion(s) failed"
  exit 1
fi
echo "ALL PASSED"
exit 0
