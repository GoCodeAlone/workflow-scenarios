#!/usr/bin/env bash
# Scenario 82 — Data Graph and Catalog
# Config-validation only: validates knowledge graph + data catalog pipeline
# with Neo4j, DataHub, OpenMetadata, and schema migrations.
set -uo pipefail

SCENARIO="82-data-graph-catalog"
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

# Test 1: config file exists
[ -f "$CONFIG" ] && pass "config/app.yaml exists" || { fail "config/app.yaml missing"; echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"; exit 1; }

# Test 2: YAML syntax is valid
python3 -c "import sys, yaml; yaml.safe_load(open('$CONFIG'))" 2>/dev/null \
    && pass "config/app.yaml is valid YAML" \
    || fail "config/app.yaml YAML syntax error"

# Test 3: wfctl validate
OUTPUT=$("$WFCTL" validate --skip-unknown-types "$CONFIG" 2>&1)
EXIT=$?
[ "$EXIT" -eq 0 ] && pass "wfctl validate passes" || fail "wfctl validate failed: $OUTPUT"

# Test 4: graph.neo4j module
grep -q "type: graph.neo4j" "$CONFIG" \
    && pass "graph.neo4j module defined" \
    || fail "graph.neo4j module missing"

grep -q "uri: bolt://neo4j" "$CONFIG" \
    && pass "graph.neo4j has bolt URI config" \
    || fail "graph.neo4j missing bolt URI config"

grep -q "database: knowledge" "$CONFIG" \
    && pass "graph.neo4j has database: knowledge" \
    || fail "graph.neo4j missing database: knowledge"

grep -q "encrypted: true" "$CONFIG" \
    && pass "graph.neo4j has encrypted: true" \
    || fail "graph.neo4j missing encrypted: true"

# Test 5: catalog.datahub module
grep -q "type: catalog.datahub" "$CONFIG" \
    && pass "catalog.datahub module defined" \
    || fail "catalog.datahub module missing"

grep -q "endpoint: http://datahub-gms" "$CONFIG" \
    && pass "catalog.datahub has GMS endpoint" \
    || fail "catalog.datahub missing GMS endpoint"

grep -q "lineageEnabled: true" "$CONFIG" \
    && pass "catalog.datahub has lineageEnabled: true" \
    || fail "catalog.datahub missing lineageEnabled: true"

# Test 6: catalog.openmetadata module
grep -q "type: catalog.openmetadata" "$CONFIG" \
    && pass "catalog.openmetadata module defined" \
    || fail "catalog.openmetadata module missing"

grep -q "endpoint: http://openmetadata" "$CONFIG" \
    && pass "catalog.openmetadata has endpoint config" \
    || fail "catalog.openmetadata missing endpoint config"

grep -q "serviceName:" "$CONFIG" \
    && pass "catalog.openmetadata has serviceName config" \
    || fail "catalog.openmetadata missing serviceName config"

# Test 7: migrate.schema module
grep -q "type: migrate.schema" "$CONFIG" \
    && pass "migrate.schema module defined" \
    || fail "migrate.schema module missing"

grep -q "migrationsDir:" "$CONFIG" \
    && pass "migrate.schema has migrationsDir config" \
    || fail "migrate.schema missing migrationsDir config"

grep -q "strategy: sequential" "$CONFIG" \
    && pass "migrate.schema uses strategy: sequential" \
    || fail "migrate.schema missing strategy: sequential"

grep -q "validateChecksums:" "$CONFIG" \
    && pass "migrate.schema has validateChecksums config" \
    || fail "migrate.schema missing validateChecksums config"

# Test 8: all graph step types present
grep -q "type: step.graph_query" "$CONFIG" \
    && pass "step.graph_query defined" \
    || fail "step.graph_query missing"

grep -q "type: step.graph_write" "$CONFIG" \
    && pass "step.graph_write defined" \
    || fail "step.graph_write missing"

grep -q "type: step.graph_import" "$CONFIG" \
    && pass "step.graph_import defined" \
    || fail "step.graph_import missing"

grep -q "type: step.graph_extract_entities" "$CONFIG" \
    && pass "step.graph_extract_entities defined" \
    || fail "step.graph_extract_entities missing"

grep -q "type: step.graph_link" "$CONFIG" \
    && pass "step.graph_link defined" \
    || fail "step.graph_link missing"

# Test 9: all catalog step types present
grep -q "type: step.catalog_register" "$CONFIG" \
    && pass "step.catalog_register defined" \
    || fail "step.catalog_register missing"

grep -q "type: step.catalog_search" "$CONFIG" \
    && pass "step.catalog_search defined" \
    || fail "step.catalog_search missing"

grep -q "type: step.contract_validate" "$CONFIG" \
    && pass "step.contract_validate defined" \
    || fail "step.contract_validate missing"

# Test 10: all migration step types present
grep -q "type: step.migrate_plan" "$CONFIG" \
    && pass "step.migrate_plan defined" \
    || fail "step.migrate_plan missing"

grep -q "type: step.migrate_apply" "$CONFIG" \
    && pass "step.migrate_apply defined" \
    || fail "step.migrate_apply missing"

grep -q "type: step.migrate_status" "$CONFIG" \
    && pass "step.migrate_status defined" \
    || fail "step.migrate_status missing"

# Test 11: pipeline names
grep -q "build_knowledge_graph:" "$CONFIG" \
    && pass "build_knowledge_graph pipeline defined" \
    || fail "build_knowledge_graph pipeline missing"

grep -q "catalog_register_dataset:" "$CONFIG" \
    && pass "catalog_register_dataset pipeline defined" \
    || fail "catalog_register_dataset pipeline missing"

grep -q "schema_migration:" "$CONFIG" \
    && pass "schema_migration pipeline defined" \
    || fail "schema_migration pipeline missing"

# Test 12: entity extraction has types config
grep -q "confidenceThreshold:" "$CONFIG" \
    && pass "graph_extract_entities has confidenceThreshold config" \
    || fail "graph_extract_entities missing confidenceThreshold config"

grep -q "Person" "$CONFIG" \
    && pass "graph_extract_entities includes Person entity type" \
    || fail "graph_extract_entities missing Person entity type"

# Test 13: step ordering — build_knowledge_graph: extract_entities → write → link
EXTRACT_LINE=$(grep -n "type: step.graph_extract_entities" "$CONFIG" | head -1 | cut -d: -f1)
WRITE_LINE=$(grep -n "type: step.graph_write" "$CONFIG" | head -1 | cut -d: -f1)
LINK_LINE=$(grep -n "type: step.graph_link" "$CONFIG" | head -1 | cut -d: -f1)
if [ -n "$EXTRACT_LINE" ] && [ -n "$WRITE_LINE" ] && [ -n "$LINK_LINE" ]; then
    if [ "$EXTRACT_LINE" -lt "$WRITE_LINE" ] && [ "$WRITE_LINE" -lt "$LINK_LINE" ]; then
        pass "build_knowledge_graph: extract_entities → graph_write → graph_link ordering correct"
    else
        fail "build_knowledge_graph: step ordering must be extract_entities → graph_write → graph_link"
    fi
else
    fail "build_knowledge_graph: cannot verify step ordering"
fi

# Test 14: catalog pipeline — contract_validate before catalog_register
CONTRACT_LINE=$(grep -n "type: step.contract_validate" "$CONFIG" | head -1 | cut -d: -f1)
CATALOG_REG_LINE=$(grep -n "type: step.catalog_register" "$CONFIG" | head -1 | cut -d: -f1)
if [ -n "$CONTRACT_LINE" ] && [ -n "$CATALOG_REG_LINE" ]; then
    [ "$CONTRACT_LINE" -lt "$CATALOG_REG_LINE" ] \
        && pass "catalog pipeline: contract_validate precedes catalog_register" \
        || fail "catalog pipeline: contract_validate must come before catalog_register"
else
    fail "catalog pipeline: cannot verify contract/register ordering"
fi

# Test 15: schema migration — migrate_plan → migrate_apply → migrate_status
PLAN_LINE=$(grep -n "type: step.migrate_plan" "$CONFIG" | head -1 | cut -d: -f1)
APPLY_LINE=$(grep -n "type: step.migrate_apply" "$CONFIG" | head -1 | cut -d: -f1)
STATUS_LINE=$(grep -n "type: step.migrate_status" "$CONFIG" | head -1 | cut -d: -f1)
if [ -n "$PLAN_LINE" ] && [ -n "$APPLY_LINE" ] && [ -n "$STATUS_LINE" ]; then
    if [ "$PLAN_LINE" -lt "$APPLY_LINE" ] && [ "$APPLY_LINE" -lt "$STATUS_LINE" ]; then
        pass "schema_migration: migrate_plan → migrate_apply → migrate_status ordering correct"
    else
        fail "schema_migration: step ordering must be migrate_plan → migrate_apply → migrate_status"
    fi
else
    fail "schema_migration: cannot verify step ordering"
fi

# Test 16: data contract has SLA and quality fields
grep -q "freshnessHours:" "$CONFIG" \
    && pass "data contract has freshnessHours SLA config" \
    || fail "data contract missing freshnessHours SLA config"

grep -q "completenessPercent:" "$CONFIG" \
    && pass "data contract has completenessPercent config" \
    || fail "data contract missing completenessPercent config"

# Test 17: migrate_apply has backup flag
grep -q "backupBeforeMigrate: true" "$CONFIG" \
    && pass "migrate_apply has backupBeforeMigrate: true" \
    || fail "migrate_apply missing backupBeforeMigrate: true"

# Test 18: expr syntax used (not Go templates)
if grep -q '{{' "$CONFIG"; then
    fail "config uses Go template syntax {{ }} — must use expr syntax \${ }"
else
    pass "config uses expr syntax \${ } (no Go templates)"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
