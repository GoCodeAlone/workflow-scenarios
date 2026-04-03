#!/usr/bin/env bash
# Scenario 84 — Enterprise RAG Pipeline
# Config-validation only: validates secure RAG pipeline with SSO authentication,
# Pinecone vector search, and S3 compliance audit logging.
set -uo pipefail

SCENARIO="84-enterprise-rag-pipeline"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCENARIO_DIR="$(dirname "$SCRIPT_DIR")"
WORKFLOW_REPO="${WORKFLOW_REPO:-$(cd "$SCENARIO_DIR/../../.." && pwd)/workflow}"
CONFIG="$SCENARIO_DIR/config/app.yaml"

PASS=0
FAIL=0
SKIP=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
skip() { echo "SKIP: $1"; SKIP=$((SKIP + 1)); }

echo ""
echo "=== Scenario $SCENARIO ==="
echo ""

# Locate wfctl binary
WFCTL=""
for candidate in \
    "${WFCTL_BIN:-}" \
    "$(which wfctl 2>/dev/null)" \
    "$WORKFLOW_REPO/bin/wfctl" \
    "/tmp/wfctl"; do
    if [ -n "$candidate" ] && [ -x "$candidate" ]; then
        WFCTL="$candidate"
        break
    fi
done

if [ -z "$WFCTL" ]; then
    skip "wfctl binary not found — config validation skipped (set WFCTL_BIN to override)"
    echo ""
    echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
    exit 0
fi

echo "Using wfctl: $WFCTL"

# ── Test 1: config file exists ──────────────────────────────
[ -f "$CONFIG" ] && pass "config/app.yaml exists" || { fail "config/app.yaml missing"; echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"; exit 1; }

# ── Test 2: YAML syntax is valid ────────────────────────────
python3 -c "import sys, yaml; yaml.safe_load(open('$CONFIG'))" 2>/dev/null \
    && pass "config/app.yaml is valid YAML" \
    || fail "config/app.yaml YAML syntax error"

# ── Test 3: wfctl validate ──────────────────────────────────
OUTPUT=$("$WFCTL" validate --skip-unknown-types "$CONFIG" 2>&1)
EXIT=$?
[ "$EXIT" -eq 0 ] && pass "wfctl validate passes" || fail "wfctl validate failed: $OUTPUT"

# ── Test 4: sso.oidc module ─────────────────────────────────
grep -q "type: sso.oidc" "$CONFIG" \
    && pass "sso.oidc module defined" \
    || fail "sso.oidc module missing"

grep -q "issuer:" "$CONFIG" \
    && pass "sso.oidc has issuer config" \
    || fail "sso.oidc missing issuer config"

grep -q "clientId:" "$CONFIG" \
    && pass "sso.oidc has clientId config" \
    || fail "sso.oidc missing clientId config"

grep -q "jwksUri:" "$CONFIG" \
    && pass "sso.oidc has jwksUri config" \
    || fail "sso.oidc missing jwksUri config"

# ── Test 5: vectorstore.provider module ──────────────────────
grep -q "type: vectorstore.provider" "$CONFIG" \
    && pass "vectorstore.provider module defined" \
    || fail "vectorstore.provider module missing"

grep -q "provider: pinecone" "$CONFIG" \
    && pass "vectorstore uses pinecone provider" \
    || fail "vectorstore missing pinecone provider"

grep -q "index: knowledge-base" "$CONFIG" \
    && pass "vectorstore has index: knowledge-base" \
    || fail "vectorstore missing index: knowledge-base"

grep -q "dimension: 1536" "$CONFIG" \
    && pass "vectorstore has dimension: 1536 (ada-002)" \
    || fail "vectorstore missing dimension: 1536"

# ── Test 6: audit.collector module ───────────────────────────
grep -q "type: audit.collector" "$CONFIG" \
    && pass "audit.collector module defined" \
    || fail "audit.collector module missing"

grep -q "workflow.started" "$CONFIG" \
    && pass "audit.collector subscribes to workflow.started" \
    || fail "audit.collector missing workflow.started topic"

grep -q "step.completed" "$CONFIG" \
    && pass "audit.collector subscribes to step.completed" \
    || fail "audit.collector missing step.completed topic"

grep -q "workflow.completed" "$CONFIG" \
    && pass "audit.collector subscribes to workflow.completed" \
    || fail "audit.collector missing workflow.completed topic"

# ── Test 7: audit.sink.s3 module ────────────────────────────
grep -q "type: audit.sink.s3" "$CONFIG" \
    && pass "audit.sink.s3 module defined" \
    || fail "audit.sink.s3 module missing"

grep -q "bucket: compliance-audit-logs" "$CONFIG" \
    && pass "audit.sink.s3 has bucket: compliance-audit-logs" \
    || fail "audit.sink.s3 missing bucket config"

grep -q 'prefix: "rag-pipeline/"' "$CONFIG" \
    && pass "audit.sink.s3 has prefix: rag-pipeline/" \
    || fail "audit.sink.s3 missing prefix config"

grep -q "region: us-east-1" "$CONFIG" \
    && pass "audit.sink.s3 has region: us-east-1" \
    || fail "audit.sink.s3 missing region config"

grep -q "immutable: true" "$CONFIG" \
    && pass "audit.sink.s3 has immutable: true" \
    || fail "audit.sink.s3 missing immutable: true"

# ── Test 8: SSO step types present ──────────────────────────
grep -q "type: step.sso_validate_token" "$CONFIG" \
    && pass "step.sso_validate_token defined" \
    || fail "step.sso_validate_token missing"

grep -q "type: step.sso_userinfo" "$CONFIG" \
    && pass "step.sso_userinfo defined" \
    || fail "step.sso_userinfo missing"

# ── Test 9: AI step types present ───────────────────────────
EMBED_COUNT=$(grep -c "type: step.ai_complete" "$CONFIG")
[ "$EMBED_COUNT" -ge 2 ] \
    && pass "step.ai_complete defined ($EMBED_COUNT instances: embedding + chat)" \
    || fail "step.ai_complete expected at least 2 instances, found $EMBED_COUNT"

grep -q "model: text-embedding-ada-002" "$CONFIG" \
    && pass "embedding model text-embedding-ada-002 configured" \
    || fail "embedding model text-embedding-ada-002 missing"

grep -q "model: gpt-4" "$CONFIG" \
    && pass "chat model gpt-4 configured" \
    || fail "chat model gpt-4 missing"

# ── Test 10: vector query step ──────────────────────────────
grep -q "type: step.vector_query" "$CONFIG" \
    && pass "step.vector_query defined" \
    || fail "step.vector_query missing"

grep -q "topK: 5" "$CONFIG" \
    && pass "vector_query has topK: 5" \
    || fail "vector_query missing topK: 5"

grep -q "namespace: support-docs" "$CONFIG" \
    && pass "vector_query has namespace: support-docs" \
    || fail "vector_query missing namespace: support-docs"

# ── Test 11: conditional authorization step ──────────────────
grep -q "type: step.conditional" "$CONFIG" \
    && pass "step.conditional defined (group authorization)" \
    || fail "step.conditional missing"

grep -q "support-agents" "$CONFIG" \
    && pass "conditional checks support-agents group" \
    || fail "conditional missing support-agents group check"

grep -q "status: 403" "$CONFIG" \
    && pass "conditional returns 403 on authorization failure" \
    || fail "conditional missing 403 response"

# ── Test 12: rag_chat pipeline defined ───────────────────────
grep -q "rag_chat:" "$CONFIG" \
    && pass "rag_chat pipeline defined" \
    || fail "rag_chat pipeline missing"

grep -q "path: /api/chat" "$CONFIG" \
    && pass "rag_chat triggered on /api/chat" \
    || fail "rag_chat missing /api/chat trigger"

grep -q "method: POST" "$CONFIG" \
    && pass "rag_chat triggered on POST method" \
    || fail "rag_chat missing POST trigger"

# ── Test 13: healthz pipeline ────────────────────────────────
grep -q "healthz:" "$CONFIG" \
    && pass "healthz pipeline defined" \
    || fail "healthz pipeline missing"

grep -q "scenario: \"84-enterprise-rag-pipeline\"" "$CONFIG" \
    && pass "healthz returns correct scenario id" \
    || fail "healthz missing correct scenario id"

# ── Test 14: pipeline step ordering ─────────────────────────
# validate_token → userinfo → authorize → embed → vector_search → build_context → generate → respond
VALIDATE_LINE=$(grep -n "type: step.sso_validate_token" "$CONFIG" | head -1 | cut -d: -f1)
USERINFO_LINE=$(grep -n "type: step.sso_userinfo" "$CONFIG" | head -1 | cut -d: -f1)
CONDITIONAL_LINE=$(grep -n "type: step.conditional" "$CONFIG" | head -1 | cut -d: -f1)
EMBED_LINE=$(grep -n "model: text-embedding-ada-002" "$CONFIG" | head -1 | cut -d: -f1)
VECTOR_LINE=$(grep -n "type: step.vector_query" "$CONFIG" | head -1 | cut -d: -f1)

if [ -n "$VALIDATE_LINE" ] && [ -n "$USERINFO_LINE" ] && [ -n "$CONDITIONAL_LINE" ]; then
    if [ "$VALIDATE_LINE" -lt "$USERINFO_LINE" ] && [ "$USERINFO_LINE" -lt "$CONDITIONAL_LINE" ]; then
        pass "auth ordering: validate_token → userinfo → conditional"
    else
        fail "auth ordering must be: validate_token → userinfo → conditional"
    fi
else
    fail "cannot verify auth step ordering"
fi

if [ -n "$CONDITIONAL_LINE" ] && [ -n "$EMBED_LINE" ] && [ -n "$VECTOR_LINE" ]; then
    if [ "$CONDITIONAL_LINE" -lt "$EMBED_LINE" ] && [ "$EMBED_LINE" -lt "$VECTOR_LINE" ]; then
        pass "RAG ordering: conditional → embed → vector_search"
    else
        fail "RAG ordering must be: conditional → embed → vector_search"
    fi
else
    fail "cannot verify RAG step ordering"
fi

# ── Test 15: audit batch settings ───────────────────────────
grep -q "flushIntervalSeconds: 30" "$CONFIG" \
    && pass "audit flush interval set to 30s" \
    || fail "audit missing flushIntervalSeconds: 30"

grep -q "batchSize: 100" "$CONFIG" \
    && pass "audit batch size set to 100" \
    || fail "audit missing batchSize: 100"

# ── Test 16: system prompt for RAG ──────────────────────────
grep -q "Answer using only the provided context" "$CONFIG" \
    && pass "RAG system prompt constrains answers to context" \
    || fail "RAG missing context-constrained system prompt"

# ── Test 17: expr syntax (no Go templates) ──────────────────
if grep -q '{{' "$CONFIG"; then
    fail "config uses Go template syntax {{ }} — must use expr syntax \${ }"
else
    pass "config uses expr syntax \${ } (no Go templates)"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
