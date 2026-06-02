#!/usr/bin/env bash
# Scenario 92 — Infra Admin GitOps Demo seed (v1.1)
#
# Builds all binaries from LOCAL checkouts (scenario-90 pattern):
#   - scenario-92 server (scenarios/92-infra-admin-demo/cmd/server)
#     (includes in-process stub iac.provider + authz.local fixtures)
#   - workflow-plugin-admin   (provides admin.dashboard)
#   - workflow-plugin-auth    (provides auth.jwt backend)
#   - workflow-plugin-authz-ui (provides authz.ui)
#   - workflow-plugin-infra   (provides infra.* abstract module types)
#   - stub-iac-provider       (external gRPC IaC provider fixture, Task 17)
#
# Also:
#   - Copies the infra SPA UI assets into .build/infra-spa/
#   - Copies admin UI assets from workflow-plugin-admin
#   - Initialises a bare-git-repo fixture at .build/gitrepo.git
#     (bind-mounted into the sandbox container by docker-compose)
#
# Usage:
#   ./seed.sh
#   PLUGIN_ADMIN_REPO=... PLUGIN_AUTH_REPO=... ./seed.sh
#
# All local repo paths can be overridden via env vars.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCENARIO_DIR="$(dirname "$SCRIPT_DIR")"
SCENARIOS_ROOT="$(cd "$SCENARIO_DIR/../.." && pwd)"

find_workspace_root() {
  local dir="$SCENARIOS_ROOT"
  while [ "$dir" != "/" ]; do
    if [ -f "$dir/workflow-plugin-admin/go.mod" ] || [ -d "$dir/workflow-plugin-admin" ]; then
      echo "$dir"
      return 0
    fi
    dir="$(dirname "$dir")"
  done
  echo "$(dirname "$SCENARIOS_ROOT")"
}

WORKSPACE_ROOT="${WORKSPACE_ROOT:-$(find_workspace_root)}"

PLUGIN_ADMIN_REPO="${PLUGIN_ADMIN_REPO:-$WORKSPACE_ROOT/workflow-plugin-admin}"
PLUGIN_AUTH_REPO="${PLUGIN_AUTH_REPO:-$WORKSPACE_ROOT/workflow-plugin-auth}"
PLUGIN_AUTHZ_UI_REPO="${PLUGIN_AUTHZ_UI_REPO:-$WORKSPACE_ROOT/workflow-plugin-authz-ui}"
PLUGIN_INFRA_REPO="${PLUGIN_INFRA_REPO:-$WORKSPACE_ROOT/workflow-plugin-infra}"
IMAGE_TAG="${IMAGE_TAG:-workflow-admin:scenario-92}"

echo ""
echo "=== Scenario 92 seed: Infra Admin GitOps Demo ==="
echo "  WORKSPACE_ROOT=$WORKSPACE_ROOT"
echo "  PLUGIN_ADMIN_REPO=$PLUGIN_ADMIN_REPO"
echo "  PLUGIN_AUTH_REPO=$PLUGIN_AUTH_REPO"
echo "  PLUGIN_AUTHZ_UI_REPO=$PLUGIN_AUTHZ_UI_REPO"
echo "  PLUGIN_INFRA_REPO=$PLUGIN_INFRA_REPO"
echo "  IMAGE_TAG=$IMAGE_TAG"
echo ""

require_go_module() {
  local repo="$1"
  if [ ! -f "$repo/go.mod" ]; then
    echo "ERROR: $repo is not a Go module checkout (go.mod missing)" >&2
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
  (cd "$repo" && GOWORK=off GOOS=linux GOARCH=amd64 go build -o "$dest/$plugin_name" "$cmd_path")
  cp "$repo/plugin.json" "$dest/plugin.json"
}

BUILD_DIR="$SCENARIO_DIR/.build"
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR/plugins" "$BUILD_DIR/admin-ui" "$BUILD_DIR/infra-spa" "$BUILD_DIR/data"

# ── Build scenario-owned server ────────────────────────────────────────────────
# The custom server binary is in scenarios/92-infra-admin-demo/cmd/server.
# It includes the in-process stub iac.provider + authz.local fixtures,
# plus loads external gRPC plugins from <data-dir>/plugins/.
echo "Building scenario-92 server binary..."
(cd "$SCENARIOS_ROOT" && GOWORK=off CGO_ENABLED=0 GOOS=linux GOARCH=amd64 \
    go build -o "$BUILD_DIR/server" ./scenarios/92-infra-admin-demo/cmd/server)

# ── Build external gRPC plugins ────────────────────────────────────────────────
build_plugin "$PLUGIN_ADMIN_REPO"    "workflow-plugin-admin"    "./cmd/workflow-plugin-admin"
build_plugin "$PLUGIN_AUTH_REPO"     "workflow-plugin-auth"     "./cmd/workflow-plugin-auth"

# authz-ui and infra are optional; skip gracefully if checkout is missing.
if [ -f "$PLUGIN_AUTHZ_UI_REPO/go.mod" ]; then
  build_plugin "$PLUGIN_AUTHZ_UI_REPO" "workflow-plugin-authz-ui" "./cmd/workflow-plugin-authz-ui"
else
  echo "WARN: workflow-plugin-authz-ui not found at $PLUGIN_AUTHZ_UI_REPO — skipping" >&2
fi

if [ -f "$PLUGIN_INFRA_REPO/go.mod" ]; then
  build_plugin "$PLUGIN_INFRA_REPO"    "workflow-plugin-infra"    "./cmd/workflow-plugin-infra"
else
  echo "WARN: workflow-plugin-infra not found at $PLUGIN_INFRA_REPO — skipping" >&2
fi

# ── Build stub-iac-provider external gRPC binary (Task 17) ────────────────────
# Built from THIS scenarios repo's own fixtures/ directory.
STUB_PROVIDER_SRC="$SCENARIO_DIR/fixtures/stub-iac-provider"
if [ -f "$STUB_PROVIDER_SRC/cmd/stub-iac-provider/main.go" ]; then
  echo "Building stub-iac-provider..."
  mkdir -p "$BUILD_DIR/plugins/stub-iac-provider"
  (cd "$SCENARIOS_ROOT" && GOWORK=off GOOS=linux GOARCH=amd64 \
      go build -o "$BUILD_DIR/plugins/stub-iac-provider/stub-iac-provider" \
      ./scenarios/92-infra-admin-demo/fixtures/stub-iac-provider/cmd/stub-iac-provider)
  cp "$STUB_PROVIDER_SRC/cmd/stub-iac-provider/plugin.json" \
     "$BUILD_DIR/plugins/stub-iac-provider/plugin.json"
else
  echo "WARN: stub-iac-provider source not found at $STUB_PROVIDER_SRC" >&2
fi

# ── Copy admin UI assets ───────────────────────────────────────────────────────
# Locate the contribution-driven admin UI from workflow-plugin-admin.
ADMIN_UI_SRC=""
for candidate in \
    "$PLUGIN_ADMIN_REPO/internal/ui_dist" \
    "$PLUGIN_ADMIN_REPO/.worktrees/auth-portal-manager/internal/ui_dist"; do
  if [ -d "$candidate" ] && [ -f "$candidate/index.html" ]; then
    ADMIN_UI_SRC="$candidate"
    break
  fi
done

if [ -z "$ADMIN_UI_SRC" ]; then
  echo "ERROR: Could not find workflow-plugin-admin UI assets under $PLUGIN_ADMIN_REPO" >&2
  exit 1
fi
cp -R "$ADMIN_UI_SRC/." "$BUILD_DIR/admin-ui/"
echo "Copied admin UI from $ADMIN_UI_SRC"

# ── Copy infra SPA assets ──────────────────────────────────────────────────────
INFRA_SPA_SRC="$SCENARIO_DIR/ui"
if [ -d "$INFRA_SPA_SRC" ] && [ -f "$INFRA_SPA_SRC/index.html" ]; then
  cp -R "$INFRA_SPA_SRC/." "$BUILD_DIR/infra-spa/"
  echo "Copied infra SPA from $INFRA_SPA_SRC"
else
  echo "ERROR: infra SPA not found at $INFRA_SPA_SRC" >&2
  exit 1
fi

# ── Initialise bare git repo fixture ──────────────────────────────────────────
# The commit pipeline (POST /api/infra/commit) clones this bare repo inside
# the sandbox container, writes desired-state.yaml, and pushes back.
# docker-compose bind-mounts .build/gitrepo.git → /data/gitrepo.git inside
# the sandbox, and the app container also sees it at /data/gitrepo.git.
GITREPO_DIR="$BUILD_DIR/gitrepo.git"
if [ -d "$GITREPO_DIR" ]; then
  echo "Bare git repo already exists at $GITREPO_DIR — reinitialising"
  rm -rf "$GITREPO_DIR"
fi
echo "Initialising bare git repo at $GITREPO_DIR ..."
git init --bare "$GITREPO_DIR"
# Add an initial commit so the repo has a HEAD branch and clones work.
INIT_WORK="$(mktemp -d)"
git clone "$GITREPO_DIR" "$INIT_WORK/repo" --quiet
(
  cd "$INIT_WORK/repo"
  git config user.email "scenario-92-seed@infra-admin.local"
  git config user.name "Scenario 92 Seed"
  echo "# Infra desired-state (GitOps demo)" > README.md
  git add README.md
  git commit -m "init: scenario-92 gitops bare repo" --quiet
  git push origin HEAD --quiet
)
rm -rf "$INIT_WORK"
echo "Bare git repo ready at $GITREPO_DIR"

# ── Build container image ──────────────────────────────────────────────────────
cp "$SCENARIO_DIR/config/app.yaml" "$BUILD_DIR/app.yaml"

cat > "$BUILD_DIR/Dockerfile" <<'DOCKERFILE'
FROM gcr.io/distroless/static-debian12:nonroot
COPY --chown=nonroot:nonroot server /usr/local/bin/server
COPY --chown=nonroot:nonroot plugins/ /home/nonroot/plugins/
COPY --chown=nonroot:nonroot app.yaml /home/nonroot/app.yaml
COPY --chown=nonroot:nonroot admin-ui/ /opt/workflow-admin-ui/
COPY --chown=nonroot:nonroot infra-spa/ /opt/infra-spa/
USER nonroot
WORKDIR /home/nonroot
ENV WFCTL_PLUGIN_DIR=/home/nonroot/plugins
ENTRYPOINT ["/usr/local/bin/server"]
DOCKERFILE

echo "Building $IMAGE_TAG..."
docker build -t "$IMAGE_TAG" "$BUILD_DIR"

# ── Bring up the stack ─────────────────────────────────────────────────────────
cd "$SCENARIO_DIR"
docker compose down --remove-orphans 2>/dev/null || true
docker compose up -d

echo "Waiting for /healthz ..."
for i in $(seq 1 90); do
  if curl -fs http://127.0.0.1:18092/healthz >/dev/null 2>&1; then
    echo ""
    echo "Stack ready at http://127.0.0.1:18092 (took ${i}s)"
    echo "Admin UI:  http://127.0.0.1:18092/admin/"
    echo "Infra SPA: http://127.0.0.1:18092/admin/infra/"
    exit 0
  fi
  sleep 1
done

echo "ERROR: /healthz never became ready" >&2
docker compose logs --tail=120 app >&2
exit 1
