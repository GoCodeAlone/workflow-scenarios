#!/usr/bin/env bash
set -euo pipefail

SCENARIO="$1"
SCENARIO_DIR="scenarios/${SCENARIO}"

if [ ! -d "$SCENARIO_DIR" ]; then
    echo "ERROR: Scenario directory not found: $SCENARIO_DIR"
    exit 1
fi

if [ ! -f "$SCENARIO_DIR/scenario.yaml" ]; then
    echo "ERROR: scenario.yaml not found in $SCENARIO_DIR"
    exit 1
fi

# Check if scenario is blocked
STATUS=$(python3 -c "
import json
with open('scenarios.json') as f:
    d = json.load(f)
s = d['scenarios'].get('$SCENARIO', {})
print(s.get('status', 'unknown'))
" 2>/dev/null || echo "unknown")

if [ "$STATUS" = "blocked" ]; then
    echo "WARNING: Scenario $SCENARIO is blocked. Deploying anyway..."
fi

# Extract namespace from scenarios.json
NAMESPACE=$(python3 -c "
import json
with open('scenarios.json') as f:
    d = json.load(f)
print(d['scenarios']['$SCENARIO']['namespace'])
")

echo "Deploying scenario: $SCENARIO to namespace: $NAMESPACE"

# Create namespace if it doesn't exist
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

# Apply k8s manifests if they exist
if [ -d "$SCENARIO_DIR/k8s" ]; then
    for f in "$SCENARIO_DIR/k8s/"*.yaml; do
        [ -f "$f" ] || continue
        echo "  Applying: $f"
        kubectl apply -f "$f" -n "$NAMESPACE"
    done
fi

# Apply config as ConfigMap if it exists
if [ -d "$SCENARIO_DIR/config" ]; then
    for f in "$SCENARIO_DIR/config/"*.yaml; do
        [ -f "$f" ] || continue
        name=$(basename "$f" .yaml)
        echo "  Creating ConfigMap: $name"
        kubectl create configmap "$name" --from-file="$f" -n "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
    done
fi

# Wait for pods to be ready
echo "Waiting for pods to be ready..."
kubectl wait --for=condition=ready pod --all -n "$NAMESPACE" --timeout=120s 2>/dev/null || echo "WARNING: Some pods not ready yet"

# Run seed script if it exists
if [ -f "$SCENARIO_DIR/seed/seed.sh" ]; then
    echo "Running seed script..."
    NAMESPACE="$NAMESPACE" bash "$SCENARIO_DIR/seed/seed.sh"
fi

# Update scenarios.json
./scripts/update-status.sh "$SCENARIO" deployed true

echo "Scenario $SCENARIO deployed successfully to $NAMESPACE"
