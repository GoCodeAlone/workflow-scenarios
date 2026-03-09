#!/usr/bin/env bash
set -euo pipefail

BASE_URL="${BASE_URL:-http://localhost:8080}"
PASS=0
FAIL=0

check() {
  local desc="$1" url="$2" method="${3:-GET}" expected="${4:-200}"
  local status
  if [ "$method" = "GET" ]; then
    status=$(curl -s -o /dev/null -w '%{http_code}' "$url")
  else
    status=$(curl -s -o /dev/null -w '%{http_code}' -X "$method" "$url")
  fi
  if [ "$status" = "$expected" ]; then
    echo "PASS: $desc (HTTP $status)"
    PASS=$((PASS + 1))
  else
    echo "FAIL: $desc (expected $expected, got $status)"
    FAIL=$((FAIL + 1))
  fi
}

check_json() {
  local desc="$1" url="$2" method="${3:-GET}" field="$4" expected="$5"
  local body
  if [ "$method" = "GET" ]; then
    body=$(curl -s "$url")
  else
    body=$(curl -s -X "$method" "$url")
  fi
  local value
  value=$(echo "$body" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('$field',''))" 2>/dev/null || echo "PARSE_ERROR")
  if [ "$value" = "$expected" ]; then
    echo "PASS: $desc ($field=$value)"
    PASS=$((PASS + 1))
  else
    echo "FAIL: $desc (expected $field=$expected, got $value)"
    echo "  Body: $(echo "$body" | head -c 200)"
    FAIL=$((FAIL + 1))
  fi
}

echo "=== Scenario 51: BMW IaC (DigitalOcean Mock) ==="
echo ""

# Health check
check "healthz" "$BASE_URL/healthz"

# Phase 1: Plan all resources
echo ""
echo "--- Phase 1: Plan ---"
check "plan database" "$BASE_URL/api/v1/iac/plan/database" "POST"
check "plan networking" "$BASE_URL/api/v1/iac/plan/networking" "POST"
check "plan app" "$BASE_URL/api/v1/iac/plan/app" "POST"
check "plan dns" "$BASE_URL/api/v1/iac/plan/dns" "POST"

# Phase 2: Apply all resources
echo ""
echo "--- Phase 2: Apply ---"
check "apply database" "$BASE_URL/api/v1/iac/apply/database" "POST"
check "apply networking" "$BASE_URL/api/v1/iac/apply/networking" "POST"
check "apply app" "$BASE_URL/api/v1/iac/apply/app" "POST"
check "apply dns" "$BASE_URL/api/v1/iac/apply/dns" "POST"

# Phase 3: Status
echo ""
echo "--- Phase 3: Status ---"
check "status all" "$BASE_URL/api/v1/iac/status"

# Phase 4: Drift detection (version changed from 16 → 17)
echo ""
echo "--- Phase 4: Drift Detection ---"
check "drift database" "$BASE_URL/api/v1/iac/drift/database" "POST"

# Phase 5: Idempotency — applying again after already applied
echo ""
echo "--- Phase 5: Idempotency ---"
check "apply database again (idempotent)" "$BASE_URL/api/v1/iac/apply/idempotent" "POST"

# Phase 6: Destroy
echo ""
echo "--- Phase 6: Destroy ---"
check "destroy all" "$BASE_URL/api/v1/iac" "DELETE"

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
exit $FAIL
