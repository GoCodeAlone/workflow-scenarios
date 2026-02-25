#!/usr/bin/env bash
# Usage: ./scripts/upgrade.sh <component> <version>
# Example: ./scripts/upgrade.sh workflow v0.3.0
#          ./scripts/upgrade.sh workflow-cloud latest
#          ./scripts/upgrade.sh workflow-plugin-admin v1.1.0
#          ./scripts/upgrade.sh workflow-plugin-bento v1.1.0
set -euo pipefail

COMPONENT="${1:-}"
VERSION="${2:-latest}"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

if [ -z "$COMPONENT" ]; then
    echo "Usage: ./scripts/upgrade.sh <component> <version>"
    echo "Supported components: workflow, workflow-cloud, workflow-plugin-admin, workflow-plugin-bento"
    exit 1
fi

cd "$REPO_ROOT"

echo "============================================"
echo "Upgrade: $COMPONENT -> $VERSION"
echo "============================================"

# --- Step 1: Record pre-upgrade state ---
echo ""
echo "[1/6] Recording pre-upgrade test state..."
PRE_STATE=$(python3 -c "
import json
with open('scenarios.json') as f:
    d = json.load(f)
# Capture per-scenario pass/fail counts
result = {}
for name, s in d['scenarios'].items():
    if s.get('deployed'):
        result[name] = {
            'passCount': s.get('passCount', 0),
            'failCount': s.get('failCount', 0),
            'lastResult': s.get('lastResult', 'unknown'),
        }
print(json.dumps(result))
")
echo "Pre-upgrade state captured for deployed scenarios."

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
    echo "No scenarios currently deployed. Nothing to upgrade."
    exit 0
fi

echo "Deployed scenarios:"
for s in $DEPLOYED; do
    echo "  - $s"
done

# --- Step 2: Build new Docker images ---
echo ""
echo "[2/6] Building new Docker images for $COMPONENT..."

case "$COMPONENT" in
    workflow)
        WORKFLOW_REPO="${WORKFLOW_REPO:-/Users/jon/workspace/workflow}"
        echo "Cross-compiling workflow server binary (linux/arm64)..."
        GOOS=linux GOARCH=arm64 CGO_ENABLED=0 go build \
            -ldflags="-s -w" \
            -o /tmp/workflow-server-bin \
            "${WORKFLOW_REPO}/cmd/server"

        echo "Building workflow-server:local image in minikube..."
        # Create a temp build context with the fresh binary
        TMPCTX=$(mktemp -d)
        cp /tmp/workflow-server-bin "$TMPCTX/server"
        cat > "$TMPCTX/Dockerfile" <<'DOCEOF'
FROM alpine:3.21
RUN apk add --no-cache ca-certificates tzdata \
    && adduser -D -u 65532 nonroot
WORKDIR /app
COPY server .
USER nonroot
EXPOSE 8080 8081
ENTRYPOINT ["./server"]
DOCEOF
        minikube image build -t workflow-server:local "$TMPCTX"
        rm -rf "$TMPCTX"
        echo "Image workflow-server:local built."
        ;;

    workflow-cloud)
        CLOUD_REPO="${CLOUD_REPO:-/Users/jon/workspace/workflow-cloud}"
        echo "Cross-compiling workflow-cloud binary (linux/arm64)..."
        GOOS=linux GOARCH=arm64 CGO_ENABLED=0 go build \
            -ldflags="-s -w" \
            -o /tmp/workflow-cloud-bin \
            "${CLOUD_REPO}/cmd/cloudserver"

        echo "Building workflow-cloud:local image in minikube..."
        TMPCTX=$(mktemp -d)
        cp /tmp/workflow-cloud-bin "$TMPCTX/cloudserver"
        cp "${CLOUD_REPO}/cloud.yaml" "$TMPCTX/"
        cp -r "${CLOUD_REPO}/migrations" "$TMPCTX/"
        cat > "$TMPCTX/Dockerfile" <<'DOCEOF'
FROM gcr.io/distroless/static-debian12:nonroot
COPY cloudserver /cloudserver
COPY cloud.yaml /cloud.yaml
COPY migrations /migrations
EXPOSE 8080
ENTRYPOINT ["/cloudserver"]
CMD ["-config", "/cloud.yaml"]
DOCEOF
        minikube image build -t workflow-cloud:local "$TMPCTX"
        rm -rf "$TMPCTX"
        echo "Image workflow-cloud:local built."
        ;;

    workflow-plugin-admin)
        ADMIN_REPO="${ADMIN_REPO:-/Users/jon/workspace/workflow-plugin-admin}"
        WORKFLOW_REPO="${WORKFLOW_REPO:-/Users/jon/workspace/workflow}"
        echo "Cross-compiling workflow-plugin-admin binary (linux/arm64)..."
        GOOS=linux GOARCH=arm64 CGO_ENABLED=0 go build \
            -ldflags="-s -w" \
            -o /tmp/workflow-plugin-admin-bin \
            "${ADMIN_REPO}/cmd/workflow-plugin-admin"

        echo "Cross-compiling workflow server binary (linux/arm64)..."
        GOOS=linux GOARCH=arm64 CGO_ENABLED=0 go build \
            -ldflags="-s -w" \
            -o /tmp/workflow-server-bin \
            "${WORKFLOW_REPO}/cmd/server"

        echo "Building workflow-server-admin:local image in minikube..."
        TMPCTX=$(mktemp -d)
        mkdir -p "$TMPCTX/app/data/plugins/admin"
        cp /tmp/workflow-server-bin "$TMPCTX/server"
        cp /tmp/workflow-plugin-admin-bin "$TMPCTX/app/data/plugins/admin/admin"
        cp "${ADMIN_REPO}/plugin.json" "$TMPCTX/app/data/plugins/admin/"
        cat > "$TMPCTX/Dockerfile" <<'DOCEOF'
FROM alpine:3.21
RUN apk add --no-cache ca-certificates tzdata \
    && adduser -D -u 65532 nonroot
WORKDIR /app
COPY server /server
COPY app/data /app/data
RUN chown -R nonroot:nonroot /app
USER nonroot
EXPOSE 8080 8081
ENTRYPOINT ["/server"]
DOCEOF
        minikube image build -t workflow-server-admin:local "$TMPCTX"
        rm -rf "$TMPCTX"
        echo "Image workflow-server-admin:local built."
        ;;

    workflow-plugin-bento)
        BENTO_REPO="${BENTO_REPO:-/Users/jon/workspace/workflow-plugin-bento}"
        WORKFLOW_REPO="${WORKFLOW_REPO:-/Users/jon/workspace/workflow}"
        echo "Cross-compiling workflow-plugin-bento binary (linux/arm64)..."
        GOOS=linux GOARCH=arm64 CGO_ENABLED=0 go build \
            -ldflags="-s -w" \
            -o /tmp/workflow-plugin-bento-bin \
            "${BENTO_REPO}/cmd/workflow-plugin-bento"

        echo "Cross-compiling workflow server binary (linux/arm64)..."
        GOOS=linux GOARCH=arm64 CGO_ENABLED=0 go build \
            -ldflags="-s -w" \
            -o /tmp/workflow-server-bin \
            "${WORKFLOW_REPO}/cmd/server"

        echo "Building workflow-server-bento:local image in minikube..."
        TMPCTX=$(mktemp -d)
        mkdir -p "$TMPCTX/data/plugins/bento"
        cp /tmp/workflow-server-bin "$TMPCTX/server"
        cp /tmp/workflow-plugin-bento-bin "$TMPCTX/data/plugins/bento/workflow-plugin-bento"
        cp "${BENTO_REPO}/plugin.json" "$TMPCTX/data/plugins/bento/"
        cat > "$TMPCTX/Dockerfile" <<'DOCEOF'
FROM alpine:3.21
RUN apk add --no-cache ca-certificates tzdata \
    && adduser -D -u 65532 nonroot
WORKDIR /app
COPY server /server
COPY data /data
RUN chown -R nonroot:nonroot /data
USER nonroot
EXPOSE 8080
ENTRYPOINT ["/server"]
DOCEOF
        minikube image build -t workflow-server-bento:local "$TMPCTX"
        rm -rf "$TMPCTX"
        echo "Image workflow-server-bento:local built."
        ;;

    *)
        echo "ERROR: Unknown component: $COMPONENT"
        echo "Supported: workflow, workflow-cloud, workflow-plugin-admin, workflow-plugin-bento"
        exit 1
        ;;
esac

# --- Step 3: Rolling restart affected deployments ---
echo ""
echo "[3/6] Rolling restart of affected deployments..."

case "$COMPONENT" in
    workflow)
        # Scenarios using workflow-server:local image: 01, 02, 04 (local)
        AFFECTED_SCENARIOS=$(python3 -c "
import json
with open('scenarios.json') as f:
    d = json.load(f)
# workflow engine scenarios (not cloud, not plugin-specific)
exclude = ['03-ai-agent', '05-saas-webapp', '06-multitenant-api',
           '07-no-code-workflow', '08-data-pipeline']
for name, s in d['scenarios'].items():
    if s.get('deployed') and name not in exclude:
        print(name)
")
        for s in $AFFECTED_SCENARIOS; do
            NS=$(python3 -c "import json; d=json.load(open('scenarios.json')); print(d['scenarios']['$s']['namespace'])")
            echo "  Restarting workflow-server in $s (ns: $NS)..."
            kubectl rollout restart deployment/workflow-server -n "$NS" 2>/dev/null || true
        done
        ;;

    workflow-cloud)
        # workflow-cloud runs in the default namespace
        echo "  Restarting workflow-cloud in default namespace..."
        kubectl rollout restart deployment/workflow-cloud -n default 2>/dev/null || true
        ;;

    workflow-plugin-admin)
        NS=$(python3 -c "import json; d=json.load(open('scenarios.json')); print(d['scenarios'].get('07-no-code-workflow',{}).get('namespace','wf-scenario-07'))")
        DEPLOYED_07=$(python3 -c "import json; d=json.load(open('scenarios.json')); print(d['scenarios'].get('07-no-code-workflow',{}).get('deployed',False))")
        if [ "$DEPLOYED_07" = "True" ]; then
            echo "  Restarting workflow-server in 07-no-code-workflow (ns: $NS)..."
            kubectl rollout restart deployment/workflow-server -n "$NS" 2>/dev/null || true
        else
            echo "  07-no-code-workflow is not deployed, skipping restart."
        fi
        ;;

    workflow-plugin-bento)
        NS=$(python3 -c "import json; d=json.load(open('scenarios.json')); print(d['scenarios'].get('08-data-pipeline',{}).get('namespace','wf-scenario-08'))")
        DEPLOYED_08=$(python3 -c "import json; d=json.load(open('scenarios.json')); print(d['scenarios'].get('08-data-pipeline',{}).get('deployed',False))")
        if [ "$DEPLOYED_08" = "True" ]; then
            echo "  Restarting workflow-server in 08-data-pipeline (ns: $NS)..."
            kubectl rollout restart deployment/workflow-server -n "$NS" 2>/dev/null || true
        else
            echo "  08-data-pipeline is not deployed, skipping restart."
        fi
        ;;
esac

# --- Step 4: Wait for pods to be ready ---
echo ""
echo "[4/6] Waiting for pods to be ready..."

for s in $DEPLOYED; do
    NS=$(python3 -c "import json; d=json.load(open('scenarios.json')); print(d['scenarios']['$s']['namespace'])")
    if [ "$NS" = "default" ]; then
        continue  # default namespace has many pods; skip blanket wait
    fi
    echo "  Waiting for pods in $s (ns: $NS)..."
    kubectl wait --for=condition=ready pod --all -n "$NS" --timeout=120s 2>/dev/null \
        || echo "  WARNING: Some pods in $s not ready after 120s"
done

# --- Step 5: Re-run ALL scenario tests ---
echo ""
echo "[5/6] Re-running all scenario tests..."

for s in $DEPLOYED; do
    if [ -f "scenarios/$s/test/run.sh" ]; then
        echo ""
        echo "=== Testing $s ==="
        ./scripts/test.sh "$s" || true
    else
        echo "  (no test script for $s, skipping)"
    fi
done

# --- Step 6: Compare pre vs post results and update scenarios.json ---
echo ""
echo "[6/6] Comparing pre-upgrade vs post-upgrade results..."

# Update the componentVersions in scenarios.json
python3 -c "
import json
with open('scenarios.json', 'r') as f:
    d = json.load(f)
if 'componentVersions' not in d:
    d['componentVersions'] = {}
d['componentVersions']['$COMPONENT'] = '$VERSION'
with open('scenarios.json', 'w') as f:
    json.dump(d, f, indent=2)
"

# Compare and print summary
python3 - <<PYEOF
import json

pre = json.loads("""$PRE_STATE""")

with open('scenarios.json') as f:
    d = json.load(f)

improved = []
regressed = []
unchanged = []

for name, post_s in d['scenarios'].items():
    if not post_s.get('deployed'):
        continue
    pre_s = pre.get(name, {})
    pre_result = pre_s.get('lastResult', 'unknown')
    post_result = post_s.get('lastResult', 'unknown')
    pre_pass = pre_s.get('passCount', 0)
    post_pass = post_s.get('passCount', 0)
    pre_fail = pre_s.get('failCount', 0)
    post_fail = post_s.get('failCount', 0)

    if pre_result == 'pass' and post_result == 'pass':
        unchanged.append(f"  {name}: PASS ({post_pass} tests)")
    elif pre_result != 'pass' and post_result == 'pass':
        improved.append(f"  {name}: {pre_result.upper()} -> PASS (was {pre_fail} failures, now 0)")
    elif pre_result == 'pass' and post_result != 'pass':
        regressed.append(f"  {name}: PASS -> {post_result.upper()} ({post_fail} failures)")
    else:
        delta = post_fail - pre_fail
        sign = '+' if delta >= 0 else ''
        unchanged.append(f"  {name}: {post_result.upper()} ({sign}{delta} failures vs before)")

print()
print("============================================")
print(f"Upgrade Summary: $COMPONENT -> $VERSION")
print("============================================")
if improved:
    print(f"\nIMPROVED ({len(improved)}):")
    for line in improved:
        print(line)
if regressed:
    print(f"\nREGRESSED ({len(regressed)}) <-- ACTION REQUIRED:")
    for line in regressed:
        print(line)
if unchanged:
    print(f"\nUNCHANGED ({len(unchanged)}):")
    for line in unchanged:
        print(line)
print()
if regressed:
    print("WARNING: Regressions detected. Review logs in scenarios/<name>/test/artifacts/")
    exit(1)
else:
    print("All scenarios stable after upgrade.")
PYEOF
