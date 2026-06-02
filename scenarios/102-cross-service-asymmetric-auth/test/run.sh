#!/usr/bin/env bash
# Scenario 102 — Cross-Service Asymmetric Auth curl smoke test.
#
# Proves genuine cross-process ES256 asymmetric verification:
#   App A (auth.m2m) mints ES256 tokens + publishes /oauth/jwks.
#   App B (sso.oidc jwksUri mode) verifies ONLY from App A's PUBLIC JWKS.
#   No shared secret between services.
#
# Assertions:
#   1. App A + App B /healthz → 200
#   2. Obtain ES256 token from App A (client_credentials) → alg=ES256, iss, aud checks
#   3. ACCEPT: POST app-b:18112/verify with App A token → 200 + verified claims
#   4. REJECT wrong-key: token signed by different EC key → 401
#   5. REJECT aud-mismatch: token with aud=wrong → 401
#   6. REJECT wrong-issuer: token with iss=http://evil → 401
#   7. REJECT expired: token with exp in the past → 401
#   8. REJECT garbage token → 401
#
# Negative-case tokens (4-7) are deterministic: produced by ./data/mint-token-native
# (built by seed.sh), which mints ES256 JWTs with configurable flags.
# The wrong-key case uses a fresh throwaway EC key — proving App B holds only
# App A's public key (genuine asymmetric, not same-key).
#
# Prerequisites: seed.sh has been run (stack up at APP_A_URL / APP_B_URL).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCENARIO_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$SCENARIO_DIR/.build"

APP_A_URL="${APP_A_URL:-http://127.0.0.1:18102}"
APP_B_URL="${APP_B_URL:-http://127.0.0.1:18112}"
APP_A_CLIENT_SECRET="${APP_A_CLIENT_SECRET:-scenario-102-app-a-client-secret-do-not-use-in-prod}"

MINT_TOKEN="$BUILD_DIR/mint-token-native"

PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

echo ""; echo "=== Scenario 102 — Cross-Service Asymmetric Auth ==="; echo ""

# Ensure mint-token is available
if [ ! -x "$MINT_TOKEN" ]; then
    echo "  mint-token not found at $MINT_TOKEN — building now..."
    (cd "$SCENARIO_DIR/test/mint-token" && GOWORK=off go build -o "$MINT_TOKEN" .) \
        && echo "  built" || { fail "mint-token build failed"; }
fi

# --- 1. Health checks -------------------------------------------------------
if curl -fs "$APP_A_URL/healthz" >/dev/null 2>&1; then
    pass "GET app-a/healthz 200"
else
    fail "GET app-a/healthz (is seed.sh up?)"
fi

if curl -fs "$APP_B_URL/healthz" >/dev/null 2>&1; then
    pass "GET app-b/healthz 200"
else
    fail "GET app-b/healthz (is seed.sh up?)"
fi

# --- 2. Obtain ES256 token from App A (client_credentials) ------------------
TOKEN_RESP=$(curl -s -w '\n%{http_code}' \
    -X POST "$APP_A_URL/oauth/token" \
    -d "grant_type=client_credentials&client_id=app-b-caller&client_secret=$APP_A_CLIENT_SECRET")
TOKEN_HTTP=$(echo "$TOKEN_RESP" | tail -n1)
TOKEN_BODY=$(echo "$TOKEN_RESP" | sed '$d')

ACCESS_TOKEN=$(echo "$TOKEN_BODY" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('access_token',''))" 2>/dev/null)

if [ "$TOKEN_HTTP" = "200" ] && [ -n "$ACCESS_TOKEN" ]; then
    pass "App A issued access_token (client_credentials)"
else
    fail "App A token endpoint: HTTP $TOKEN_HTTP, body=$TOKEN_BODY"
fi

# Decode JWT header to assert alg=ES256
if [ -n "$ACCESS_TOKEN" ]; then
    HDR=$(echo "$ACCESS_TOKEN" | cut -d. -f1 | python3 -c "
import sys, base64, json
raw = sys.stdin.read().strip()
pad = raw + '=' * (-len(raw) % 4)
print(json.dumps(json.loads(base64.urlsafe_b64decode(pad))))
" 2>/dev/null)
    echo "$HDR" | grep -q '"alg".*"ES256"' \
        && pass "token header alg=ES256" \
        || fail "token header alg not ES256: $HDR"

    # Decode payload: assert iss + aud
    PAY=$(echo "$ACCESS_TOKEN" | cut -d. -f2 | python3 -c "
import sys, base64, json
raw = sys.stdin.read().strip()
pad = raw + '=' * (-len(raw) % 4)
print(json.dumps(json.loads(base64.urlsafe_b64decode(pad))))
" 2>/dev/null)
    echo "$PAY" | grep -q '"iss".*"http://app-a:8080"' \
        && pass "token iss=http://app-a:8080" \
        || fail "token iss wrong: $PAY"
    echo "$PAY" | grep -q '"aud".*"app-b"' \
        && pass "token aud=app-b" \
        || fail "token aud wrong: $PAY"
fi

# --- 3. ACCEPT: App B verifies App A's token via JWKS (the genuine proof) ---
if [ -n "$ACCESS_TOKEN" ]; then
    ACCEPT_RESP=$(curl -s -w '\n%{http_code}' \
        -X POST "$APP_B_URL/verify" \
        -H "Authorization: Bearer $ACCESS_TOKEN")
    ACCEPT_HTTP=$(echo "$ACCEPT_RESP" | tail -n1)
    ACCEPT_BODY=$(echo "$ACCEPT_RESP" | sed '$d')

    if [ "$ACCEPT_HTTP" = "200" ]; then
        pass "App B ACCEPT: App A token verified via App A public JWKS (asymmetric proof)"
        echo "  claims: $(echo "$ACCEPT_BODY" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('claims','?'))" 2>/dev/null)"
    else
        fail "App B ACCEPT: expected 200, got $ACCEPT_HTTP — $ACCEPT_BODY"
    fi
else
    fail "App B ACCEPT: skipped (no token)"
fi

# --- 4. REJECT wrong-key: token signed by a fresh throwaway EC key ----------
if [ -x "$MINT_TOKEN" ]; then
    WRONG_KEY_TOKEN=$("$MINT_TOKEN" -iss "http://app-a:8080" -aud "app-b" -exp "1h" 2>/dev/null)
    WK_HTTP=$(curl -s -o /dev/null -w '%{http_code}' \
        -X POST "$APP_B_URL/verify" \
        -H "Authorization: Bearer $WRONG_KEY_TOKEN")
    [ "$WK_HTTP" = "401" ] \
        && pass "App B REJECT wrong-key (fresh EC key) → 401 (genuine asymmetric proof)" \
        || fail "App B REJECT wrong-key: expected 401, got $WK_HTTP"
else
    fail "App B REJECT wrong-key: mint-token not available"
fi

# --- 5. REJECT aud-mismatch: token with aud=wrong-audience ------------------
if [ -x "$MINT_TOKEN" ]; then
    AUD_BAD_TOKEN=$("$MINT_TOKEN" -iss "http://app-a:8080" -aud "wrong-audience" -exp "1h" 2>/dev/null)
    AUD_HTTP=$(curl -s -o /dev/null -w '%{http_code}' \
        -X POST "$APP_B_URL/verify" \
        -H "Authorization: Bearer $AUD_BAD_TOKEN")
    [ "$AUD_HTTP" = "401" ] \
        && pass "App B REJECT aud-mismatch (aud=wrong-audience) → 401" \
        || fail "App B REJECT aud-mismatch: expected 401, got $AUD_HTTP"
else
    fail "App B REJECT aud-mismatch: mint-token not available"
fi

# --- 6. REJECT wrong-issuer: token with iss=http://evil ---------------------
if [ -x "$MINT_TOKEN" ]; then
    ISS_BAD_TOKEN=$("$MINT_TOKEN" -iss "http://evil" -aud "app-b" -exp "1h" 2>/dev/null)
    ISS_HTTP=$(curl -s -o /dev/null -w '%{http_code}' \
        -X POST "$APP_B_URL/verify" \
        -H "Authorization: Bearer $ISS_BAD_TOKEN")
    [ "$ISS_HTTP" = "401" ] \
        && pass "App B REJECT wrong-issuer (iss=http://evil) → 401 (N3)" \
        || fail "App B REJECT wrong-issuer: expected 401, got $ISS_HTTP"
else
    fail "App B REJECT wrong-issuer: mint-token not available"
fi

# --- 7. REJECT expired: token with exp in the past --------------------------
if [ -x "$MINT_TOKEN" ]; then
    EXP_TOKEN=$("$MINT_TOKEN" -iss "http://app-a:8080" -aud "app-b" -exp "-1m" 2>/dev/null)
    EXP_HTTP=$(curl -s -o /dev/null -w '%{http_code}' \
        -X POST "$APP_B_URL/verify" \
        -H "Authorization: Bearer $EXP_TOKEN")
    [ "$EXP_HTTP" = "401" ] \
        && pass "App B REJECT expired token → 401" \
        || fail "App B REJECT expired: expected 401, got $EXP_HTTP"
else
    fail "App B REJECT expired: mint-token not available"
fi

# --- 8. REJECT garbage token ------------------------------------------------
GARBAGE_HTTP=$(curl -s -o /dev/null -w '%{http_code}' \
    -X POST "$APP_B_URL/verify" \
    -H "Authorization: Bearer not.a.real.jwt.garbage")
[ "$GARBAGE_HTTP" = "401" ] \
    && pass "App B REJECT garbage token → 401" \
    || fail "App B REJECT garbage: expected 401, got $GARBAGE_HTTP"

# --- Summary ----------------------------------------------------------------
echo ""; echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
