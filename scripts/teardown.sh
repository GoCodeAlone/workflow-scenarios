#!/usr/bin/env bash
set -euo pipefail

SCENARIO="$1"

NAMESPACE=$(python3 -c "
import json
with open('scenarios.json') as f:
    d = json.load(f)
print(d['scenarios']['$SCENARIO']['namespace'])
")

echo "Tearing down scenario: $SCENARIO (namespace: $NAMESPACE)"
echo "NOTE: PVCs are preserved for data persistence."

# Delete deployments and services but keep PVCs
kubectl delete deploy,svc,configmap --all -n "$NAMESPACE" 2>/dev/null || true

# Update status
./scripts/update-status.sh "$SCENARIO" deployed false

echo "Scenario $SCENARIO torn down. PVCs preserved in $NAMESPACE."
echo "To fully delete (including data): kubectl delete namespace $NAMESPACE"
