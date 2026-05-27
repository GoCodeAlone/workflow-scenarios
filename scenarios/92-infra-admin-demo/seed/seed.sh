#!/usr/bin/env bash
# Scenario 92 — Infra Admin demo seed
#
# Builds the workflow-admin:scenario-92 docker image (if not present) and
# brings up the docker-compose stack. infra.admin.Start() fires three
# registration pipelines automatically via engine.TriggerWorkflow when
# the host boots — no third curl needed.
#
# Variants:
#   ./seed.sh                       # config/app.yaml (stub)
#   VARIANT=do-dryrun ./seed.sh     # config/app-do-dryrun.yaml

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCENARIO_DIR="$(dirname "$SCRIPT_DIR")"
SCENARIOS_ROOT="$(cd "$SCENARIO_DIR/../.." && pwd)"
WORKFLOW_REPO="${WORKFLOW_REPO:-$(cd "$SCENARIOS_ROOT/.." && pwd)/workflow}"
PLUGIN_ADMIN_REPO="${PLUGIN_ADMIN_REPO:-$(cd "$SCENARIOS_ROOT/.." && pwd)/workflow-plugin-admin}"
IMAGE_TAG="${IMAGE_TAG:-workflow-admin:scenario-92}"
VARIANT="${VARIANT:-}"   # "" → app.yaml; "do-dryrun" → app-do-dryrun.yaml

echo ""
echo "=== Scenario 92 seed ==="
echo "  WORKFLOW_REPO=$WORKFLOW_REPO"
echo "  PLUGIN_ADMIN_REPO=$PLUGIN_ADMIN_REPO"
echo "  IMAGE_TAG=$IMAGE_TAG"
echo "  VARIANT=${VARIANT:-stub}"
echo ""

# --- Build workflow server + admin plugin binaries ----------------------------
# We build native (host-OS) binaries and inject them via a thin Dockerfile.
# This avoids re-baking the whole Go toolchain into the scenario image and
# matches the convention used by Dockerfile.admin at the repo root.

BUILD_DIR="$SCENARIO_DIR/.build"
mkdir -p "$BUILD_DIR/plugins/workflow-plugin-admin"

if [ ! -f "$WORKFLOW_REPO/go.mod" ]; then
    echo "ERROR: WORKFLOW_REPO=$WORKFLOW_REPO is not a Go module checkout" >&2
    exit 1
fi
if [ ! -f "$PLUGIN_ADMIN_REPO/go.mod" ]; then
    echo "ERROR: PLUGIN_ADMIN_REPO=$PLUGIN_ADMIN_REPO is not a Go module checkout" >&2
    exit 1
fi

echo "Building workflow server binary..."
(cd "$WORKFLOW_REPO" && GOWORK=off GOOS=linux GOARCH=amd64 \
    go build -o "$BUILD_DIR/server" ./cmd/server)

echo "Building workflow-plugin-admin binary..."
(cd "$PLUGIN_ADMIN_REPO" && GOWORK=off GOOS=linux GOARCH=amd64 \
    go build -o "$BUILD_DIR/plugins/workflow-plugin-admin/workflow-plugin-admin" \
    ./cmd/workflow-plugin-admin)
cp "$PLUGIN_ADMIN_REPO/plugin.json" "$BUILD_DIR/plugins/workflow-plugin-admin/plugin.json"

# --- Build the scenario image -------------------------------------------------

cat > "$BUILD_DIR/Dockerfile" <<'EOF'
FROM gcr.io/distroless/static-debian12:nonroot
COPY server /usr/local/bin/server
COPY plugins/ /data/plugins/
USER nonroot
ENV WFCTL_PLUGIN_DIR=/data/plugins
ENTRYPOINT ["/usr/local/bin/server"]
EOF

echo "Building $IMAGE_TAG..."
docker build -t "$IMAGE_TAG" "$BUILD_DIR"

# --- Bring up the stack -------------------------------------------------------

cd "$SCENARIO_DIR"
export VARIANT
docker compose down --remove-orphans 2>/dev/null || true
docker compose up -d

echo "Waiting for /healthz ..."
for i in $(seq 1 60); do
    if curl -fs http://127.0.0.1:18092/healthz >/dev/null 2>&1; then
        echo "Stack ready at http://127.0.0.1:18092 (took ${i}s)"
        echo "infra.admin contributions auto-registered by infra.admin.Start()."
        exit 0
    fi
    sleep 1
done

echo "ERROR: /healthz never became ready" >&2
docker compose logs --tail=80 app >&2
exit 1
