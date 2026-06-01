#!/usr/bin/env bash
# Scenario 92 — Infra Admin demo seed
#
# Builds the workflow-admin:scenario-92 docker image (if not present) and
# brings up the docker-compose stack. infra.admin.Start() fires four
# registration pipelines automatically via engine.TriggerWorkflow when
# the host boots — no manual curl needed.
#
# Variants:
#   ./seed.sh                       # config/app.yaml (stub)
#   VARIANT=do-dryrun ./seed.sh     # config/app-do-dryrun.yaml

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCENARIO_DIR="$(dirname "$SCRIPT_DIR")"
SCENARIOS_ROOT="$(cd "$SCENARIO_DIR/../.." && pwd)"
# Default to the infra-admin-authz-inproc worktree which includes:
#   - plugins/stubprovider (iac.provider stub, scenario_stub tag)
#   - plugins/localauthz  (authz.local in-process RBAC, scenario_stub tag)
# PR-1b merged the localauthz plugin into this worktree (workflow#815).
WORKFLOW_REPO="${WORKFLOW_REPO:-$(cd "$SCENARIOS_ROOT/.." && pwd)/.config/autodev/worktrees/workflow/infra-admin-authz-inproc}"
# Fallback: if the authz-inproc worktree doesn't exist, try plain workflow repo.
[ -f "$WORKFLOW_REPO/go.mod" ] || WORKFLOW_REPO="$(cd "$SCENARIOS_ROOT/.." && pwd)/workflow"
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

if [ ! -f "$PLUGIN_ADMIN_REPO/go.mod" ]; then
    echo "ERROR: PLUGIN_ADMIN_REPO=$PLUGIN_ADMIN_REPO is not a Go module checkout" >&2
    exit 1
fi

# Build the SCENARIO-OWNED server (scenarios/92-infra-admin-demo/cmd/server).
# It imports the workflow engine via go.mod (pinned to the merged v1.1 commit)
# and registers the scenario-local fixtures (stub iac.provider + authz.local
# in-process RBAC) via NewEngineBuilder().WithPlugin(...). Test fixtures live in
# the scenario repo, NOT the workflow engine (workflow#818). No build tags.
echo "Building scenario-92-owned server binary..."
(cd "$SCENARIOS_ROOT" && GOWORK=off CGO_ENABLED=0 GOOS=linux GOARCH=amd64 \
    go build -o "$BUILD_DIR/server" ./scenarios/92-infra-admin-demo/cmd/server)

echo "Building workflow-plugin-admin binary..."
mkdir -p "$BUILD_DIR/plugins/workflow-plugin-admin"
(cd "$PLUGIN_ADMIN_REPO" && GOWORK=off GOOS=linux GOARCH=amd64 \
    go build -o "$BUILD_DIR/plugins/workflow-plugin-admin/workflow-plugin-admin" \
    ./cmd/workflow-plugin-admin)
cp "$PLUGIN_ADMIN_REPO/plugin.json" "$BUILD_DIR/plugins/workflow-plugin-admin/plugin.json"

# --- Build the scenario image -------------------------------------------------

cat > "$BUILD_DIR/Dockerfile" <<'EOF'
FROM gcr.io/distroless/static-debian12:nonroot
COPY server /usr/local/bin/server
# /home/nonroot is writable by UID 65532 (nonroot) in distroless.
# Plugins go here so data-dir /home/nonroot resolves plugins/ correctly
# AND the server can create workflow.db in the same dir (no permission error).
COPY plugins/ /home/nonroot/plugins/
USER nonroot
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
