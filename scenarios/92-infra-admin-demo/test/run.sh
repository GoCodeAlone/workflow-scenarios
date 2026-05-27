#!/usr/bin/env bash
# Scenario 92 — Infra Admin test runner
#
# Runs:
#   1. curl smoke checks against the live docker-compose stack
#      (config-validation + RPC endpoints)
#   2. wfctl infra admin CLI parity smoke (per plan §CLI end-to-end smoke)
#   3. Playwright regression spec from the central e2e harness
#
# Assumes seed.sh has already brought up the stack.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCENARIO_DIR="$(dirname "$SCRIPT_DIR")"
SCENARIOS_ROOT="$(cd "$SCENARIO_DIR/../.." && pwd)"
WORKFLOW_REPO="${WORKFLOW_REPO:-$(cd "$SCENARIOS_ROOT/.." && pwd)/workflow}"
BASE_URL="${BASE_URL:-http://127.0.0.1:18092}"
SCENARIO="92-infra-admin-demo"
VARIANT="${VARIANT:-}"

PASS=0
FAIL=0
SKIP=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
skip() { echo "SKIP: $1"; SKIP=$((SKIP + 1)); }

echo ""
echo "=== Scenario $SCENARIO (variant=${VARIANT:-stub}) ==="
echo ""

# --- Locate wfctl binary -----------------------------------------------------

WFCTL=""
for candidate in \
    "$(which wfctl 2>/dev/null)" \
    "$WORKFLOW_REPO/wfctl" \
    "$WORKFLOW_REPO/bin/wfctl" \
    "${WFCTL_BIN:-}"; do
    if [ -n "$candidate" ] && [ -x "$candidate" ]; then
        WFCTL="$candidate"
        break
    fi
done

if [ -z "$WFCTL" ]; then
    echo "Building wfctl from $WORKFLOW_REPO..."
    (cd "$WORKFLOW_REPO" && GOWORK=off go build -o wfctl ./cmd/wfctl)
    WFCTL="$WORKFLOW_REPO/wfctl"
fi

CFG_NAME="app.yaml"
[ -n "$VARIANT" ] && CFG_NAME="app-${VARIANT}.yaml"
CFG_LOCAL="$SCENARIO_DIR/config/$CFG_NAME"

# --- Phase 1: config validation ----------------------------------------------

if "$WFCTL" validate "$CFG_LOCAL" >/dev/null 2>&1; then
    pass "wfctl validate accepts $CFG_NAME"
else
    fail "wfctl validate rejected $CFG_NAME"
fi

# --- Phase 2: HTTP smoke against live stack ----------------------------------

if curl -fs "$BASE_URL/healthz" >/dev/null 2>&1; then
    pass "GET /healthz returns 200"
else
    fail "GET /healthz failed (is seed.sh up?)"
fi

# --- Mint HS256 JWT matching the scenario's auth.jwt module ---
# Per PR-1 T15 auth gate (47341ff6f), /api/admin/contributions +
# /api/infra-admin/* + /admin/infra-admin/* require a Bearer token
# signed by the scenario's HS256 secret (config/app.yaml::auth.config.secret).
# We mint a long-lived token inline so the smoke checks don't need
# an external dependency. The token is test-only — the secret is
# the literal "scenario-92-jwt-secret-do-not-use-in-prod".
JWT_SECRET='scenario-92-jwt-secret-do-not-use-in-prod'
NOW=$(date +%s)
EXP=$((NOW + 3600))

b64url() { openssl base64 -e -A | tr '+/' '-_' | tr -d '='; }

HEADER=$(printf '%s' '{"alg":"HS256","typ":"JWT"}' | b64url)
PAYLOAD=$(printf '{"iss":"scenario-92","sub":"scenario-92-run","iat":%d,"exp":%d}' "$NOW" "$EXP" | b64url)
UNSIGNED="${HEADER}.${PAYLOAD}"
SIGNATURE=$(printf '%s' "$UNSIGNED" | openssl dgst -sha256 -hmac "$JWT_SECRET" -binary | b64url)
BEARER="${UNSIGNED}.${SIGNATURE}"
AUTH_HEADER="Authorization: Bearer $BEARER"

# T15 auth-gate regression check: unauthenticated request must 401.
unauth_code=$(curl -s -o /dev/null -w '%{http_code}' -X POST \
    -H 'Content-Type: application/json' \
    -d '{"evidence":{"authz_checked":true,"authz_allowed":true}}' \
    "$BASE_URL/api/infra-admin/resources" || echo "000")
if [ "$unauth_code" = "401" ]; then
    pass "POST /api/infra-admin/resources without auth returns 401 (T15 auth gate)"
else
    fail "POST /api/infra-admin/resources without auth returned $unauth_code (want 401)"
fi

# Admin contributions endpoint (auto-populated by infra.admin.Start()).
CONTRIB_RESPONSE=$(curl -fs -H "$AUTH_HEADER" "$BASE_URL/api/admin/contributions" 2>&1 || true)
if echo "$CONTRIB_RESPONSE" | grep -q "infra.resources"; then
    pass "GET /api/admin/contributions includes infra.resources"
else
    fail "GET /api/admin/contributions missing infra.resources (got: $(echo "$CONTRIB_RESPONSE" | head -c 200))"
fi
if echo "$CONTRIB_RESPONSE" | grep -q "infra.new"; then
    pass "GET /api/admin/contributions includes infra.new"
else
    fail "GET /api/admin/contributions missing infra.new"
fi

# Read-side typed RPCs: POST returns 200 with the typed payload.
RPC_BODY='{"evidence":{"authz_checked":true,"authz_allowed":true}}'
for rpc in resources types providers; do
    code=$(curl -s -o /tmp/scenario-92-$rpc.json -w '%{http_code}' \
        -X POST -H 'Content-Type: application/json' -H "$AUTH_HEADER" \
        -d "$RPC_BODY" "$BASE_URL/api/infra-admin/$rpc" || echo "000")
    if [ "$code" = "200" ]; then
        pass "POST /api/infra-admin/$rpc returns 200"
    else
        fail "POST /api/infra-admin/$rpc returned $code"
    fi
done

# Asset page reachable (proves embed.FS + middleware wiring).
if curl -fs -H "$AUTH_HEADER" "$BASE_URL/admin/infra-admin/new.html" | grep -q '<title>Draft New Infra Resource</title>'; then
    pass "GET /admin/infra-admin/new.html serves the form-builder page"
else
    fail "new.html not served correctly"
fi

# --- Phase 3: wfctl infra admin CLI smoke (per plan §CLI end-to-end smoke) ---

for cmd in "list-resources" "list-types" "list-providers"; do
    out_file="/tmp/scenario-92-wfctl-$cmd.json"
    if ! "$WFCTL" infra admin $cmd -c "$CFG_LOCAL" --format json > "$out_file" 2>/dev/null; then
        fail "wfctl infra admin $cmd returned non-zero"
        continue
    fi
    if command -v jq >/dev/null 2>&1; then
        if jq -e '.' "$out_file" >/dev/null 2>&1; then
            pass "wfctl infra admin $cmd output is valid JSON"
        else
            fail "wfctl infra admin $cmd output not valid JSON"
        fi
    else
        # Fallback when jq absent: smoke-check braces.
        if grep -q '{' "$out_file"; then
            pass "wfctl infra admin $cmd output looks JSON-shaped (jq absent)"
        else
            fail "wfctl infra admin $cmd output not JSON-shaped"
        fi
    fi
done

# --- Phase 4: Playwright regression spec from central harness ----------------

PLAYWRIGHT_SPEC="$SCENARIOS_ROOT/e2e/tests/scenario-92-infra-admin.spec.ts"
if [ -f "$PLAYWRIGHT_SPEC" ]; then
    if command -v npx >/dev/null 2>&1; then
        echo ""
        echo "Running Playwright regression spec..."
        (cd "$SCENARIOS_ROOT/e2e" && \
            SCENARIO_URL="$BASE_URL" \
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

# --- Summary -----------------------------------------------------------------

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
