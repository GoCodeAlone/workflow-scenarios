#!/usr/bin/env bash
# Scenario 92 — Infra Admin MIGRATION demo seed (v2)
#
# Builds the workflow-admin:scenario-92 docker image (if not present) and
# brings up the docker-compose stack.
#
# All plugins are EXTERNAL gRPC binaries — no in-process fixtures:
#   stub-iac-provider: built from scenarios/92-infra-admin-demo/fixtures/stub-iac-provider/
#   workflow-plugin-admin: built from local checkout
#
# The stub-iac-provider is registered as an IaCProvider service under the
# plugin name "stub-iac-provider" via the engine's WiringHook mechanism.
# Steps configured with `provider: stub-iac-provider` resolve it at runtime.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCENARIO_DIR="$(dirname "$SCRIPT_DIR")"
SCENARIOS_ROOT="$(cd "$SCENARIO_DIR/../.." && pwd)"
WORKSPACE_ROOT="${WORKSPACE_ROOT:-$(cd "$SCENARIOS_ROOT/.." && pwd)}"

PLUGIN_ADMIN_REPO="${PLUGIN_ADMIN_REPO:-$WORKSPACE_ROOT/workflow-plugin-admin}"
IMAGE_TAG="${IMAGE_TAG:-workflow-admin:scenario-92}"

echo ""
echo "=== Scenario 92 seed (v2: migration demo) ==="
echo "  SCENARIO_DIR=$SCENARIO_DIR"
echo "  WORKSPACE_ROOT=$WORKSPACE_ROOT"
echo "  PLUGIN_ADMIN_REPO=$PLUGIN_ADMIN_REPO"
echo "  IMAGE_TAG=$IMAGE_TAG"
echo ""

# --- Helpers ------------------------------------------------------------------

require_go_module() {
  local repo="$1"
  if [ ! -f "$repo/go.mod" ]; then
    echo "ERROR: $repo is not a Go module checkout" >&2
    exit 1
  fi
}

build_plugin() {
  local repo="$1"
  local plugin_name="$2"
  local cmd_path="$3"
  local dest="$BUILD_DIR/plugins/$plugin_name"
  require_go_module "$repo"
  mkdir -p "$dest"
  echo "Building $plugin_name..."
  (cd "$repo" && GOWORK=off GOOS=linux GOARCH=amd64 \
    go build -o "$dest/$plugin_name" "$cmd_path")
  cp "$repo/plugin.json" "$dest/plugin.json"
}

# --- Validate repos -----------------------------------------------------------

if [ ! -f "$PLUGIN_ADMIN_REPO/go.mod" ]; then
  echo "ERROR: PLUGIN_ADMIN_REPO=$PLUGIN_ADMIN_REPO is not a Go module checkout" >&2
  exit 1
fi

STUB_PROVIDER_DIR="$SCENARIO_DIR/fixtures/stub-iac-provider"
if [ ! -f "$STUB_PROVIDER_DIR/go.mod" ]; then
  # The stub-iac-provider fixture lives under scenarios/92.../fixtures/
  # and shares the scenarios module (no separate go.mod). Build from repo root.
  STUB_PROVIDER_BUILD_ROOT="$SCENARIOS_ROOT"
  STUB_PROVIDER_CMD="./scenarios/92-infra-admin-demo/fixtures/stub-iac-provider/cmd/stub-iac-provider"
else
  STUB_PROVIDER_BUILD_ROOT="$STUB_PROVIDER_DIR"
  STUB_PROVIDER_CMD="./cmd/stub-iac-provider"
fi

# --- Build dirs ---------------------------------------------------------------

BUILD_DIR="$SCENARIO_DIR/.build"
rm -rf "$BUILD_DIR"
mkdir -p \
  "$BUILD_DIR/plugins/stub-iac-provider" \
  "$BUILD_DIR/plugins/workflow-plugin-admin"

# --- Build scenario-92 server binary ------------------------------------------
# Built from the scenarios module (pinned to workflow v0.70.0 via go.mod).
# Uses no in-process fixtures — all providers are external gRPC plugins.

echo "Building scenario-92-owned server binary..."
(cd "$SCENARIOS_ROOT" && GOWORK=off CGO_ENABLED=0 GOOS=linux GOARCH=amd64 \
  go build -o "$BUILD_DIR/server" ./scenarios/92-infra-admin-demo/cmd/server)

# --- Build stub-iac-provider (external gRPC plugin) ---------------------------
# This is the REAL external plugin: serves IaCProviderRequired +
# IaCProviderRegionLister + IaCProviderDriftDetector via gRPC. The engine's
# WiringHook registers it as service "stub-iac-provider" (plugin.json name).

echo "Building stub-iac-provider external plugin..."
(cd "$STUB_PROVIDER_BUILD_ROOT" && GOWORK=off CGO_ENABLED=0 GOOS=linux GOARCH=amd64 \
  go build -o "$BUILD_DIR/plugins/stub-iac-provider/stub-iac-provider" \
  "$STUB_PROVIDER_CMD")
cp "$SCENARIO_DIR/fixtures/stub-iac-provider/cmd/stub-iac-provider/plugin.json" \
   "$BUILD_DIR/plugins/stub-iac-provider/plugin.json"

# --- Build workflow-plugin-admin (external gRPC plugin) -----------------------

echo "Building workflow-plugin-admin..."
(cd "$PLUGIN_ADMIN_REPO" && GOWORK=off GOOS=linux GOARCH=amd64 \
  go build -o "$BUILD_DIR/plugins/workflow-plugin-admin/workflow-plugin-admin" \
  ./cmd/workflow-plugin-admin)
cp "$PLUGIN_ADMIN_REPO/plugin.json" "$BUILD_DIR/plugins/workflow-plugin-admin/plugin.json"

# --- Initialize bare git repo fixture -----------------------------------------
# Used by run.sh to verify gitops commit assertions shell-side.

BARE_REPO="$BUILD_DIR/gitrepo.git"
if [ ! -d "$BARE_REPO/objects" ]; then
  echo "Initializing bare git repo fixture at $BARE_REPO..."
  git init --bare "$BARE_REPO"
  # Seed with an initial commit so the repo has a HEAD
  WORK_TMP="$(mktemp -d)"
  (
    cd "$WORK_TMP"
    git init
    git config user.email "scenario92@demo.local"
    git config user.name "Scenario 92 Demo"
    echo "# Infra State\n\nInitial infra state — scenario 92 gitops demo." > infra.md
    git add infra.md
    git commit -m "chore: initial infra state (scenario 92 demo)"
    git remote add origin "$BARE_REPO"
    git push origin master 2>/dev/null || git push origin main 2>/dev/null || true
  )
  rm -rf "$WORK_TMP"
fi

# --- Build the scenario image -------------------------------------------------

cat > "$BUILD_DIR/Dockerfile" <<'EOF'
FROM gcr.io/distroless/static-debian12:nonroot
COPY server /usr/local/bin/server
# /home/nonroot is writable by UID 65532 (nonroot) in distroless.
# Plugins go here so data-dir /home/nonroot resolves plugins/ correctly
# AND the server can create workflow.db in the same dir.
COPY plugins/ /home/nonroot/plugins/
USER nonroot
ENTRYPOINT ["/usr/local/bin/server"]
EOF

echo "Building $IMAGE_TAG..."
docker build -t "$IMAGE_TAG" "$BUILD_DIR"

# --- Bring up the stack -------------------------------------------------------

cd "$SCENARIO_DIR"
docker compose down --remove-orphans 2>/dev/null || true
docker compose up -d

echo "Waiting for /healthz ..."
for i in $(seq 1 60); do
  if curl -fs http://127.0.0.1:18092/healthz >/dev/null 2>&1; then
    echo "Stack ready at http://127.0.0.1:18092 (took ${i}s)"
    echo "External plugins loaded: stub-iac-provider, workflow-plugin-admin"
    echo "Provider service: stub-iac-provider (WiringHook registered)"
    exit 0
  fi
  sleep 1
done

echo "ERROR: /healthz never became ready" >&2
docker compose logs --tail=80 app >&2
exit 1
