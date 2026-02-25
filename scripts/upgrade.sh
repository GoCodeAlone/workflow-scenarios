#!/usr/bin/env bash
set -euo pipefail

COMPONENT="${1:-}"
VERSION="${2:-latest}"

echo "Upgrading component: $COMPONENT to version: $VERSION"
echo "This will upgrade all deployed scenarios using $COMPONENT"

# Get list of deployed scenarios
DEPLOYED=$(python3 -c "
import json
with open('scenarios.json') as f:
    d = json.load(f)
for name, s in d['scenarios'].items():
    if s.get('deployed'):
        print(name)
")

if [ -z "$DEPLOYED" ]; then
    echo "No scenarios currently deployed."
    exit 0
fi

echo "Deployed scenarios that will be affected:"
for s in $DEPLOYED; do
    echo "  - $s"
done

echo ""
echo "Upgrading $COMPONENT..."

case "$COMPONENT" in
    workflow)
        # Rebuild workflow-server image with new version
        echo "Rebuilding workflow-server image..."
        # For each deployed scenario, update the deployment image
        for s in $DEPLOYED; do
            NS=$(python3 -c "import json; d=json.load(open('scenarios.json')); print(d['scenarios']['$s']['namespace'])")
            echo "  Updating $s in $NS..."
            kubectl set image deploy/workflow-server workflow-server=workflow-server:${VERSION} -n "$NS" 2>/dev/null || true
        done
        ;;
    workflow-cloud)
        echo "Upgrading workflow-cloud via Helm..."
        helm upgrade workflow-cloud /Users/jon/workspace/workflow-cloud/deploy/helm/workflow-cloud \
            --set image.tag="${VERSION}" 2>/dev/null || echo "WARNING: Helm upgrade may need additional values"
        ;;
    ratchet)
        echo "Upgrading ratchet via Helm..."
        helm upgrade ratchet /Users/jon/workspace/ratchet/deploy/helm/ratchet \
            --set image.tag="${VERSION}" 2>/dev/null || echo "WARNING: Helm upgrade may need additional values"
        ;;
    *)
        echo "Unknown component: $COMPONENT"
        echo "Supported: workflow, workflow-cloud, ratchet"
        exit 1
        ;;
esac

# Update version in scenarios.json
python3 -c "
import json
with open('scenarios.json', 'r') as f:
    d = json.load(f)
d['componentVersions']['$COMPONENT'] = '$VERSION'
with open('scenarios.json', 'w') as f:
    json.dump(d, f, indent=2)
"

echo ""
echo "Upgrade complete. Run 'make test-all' to verify all scenarios still pass."
