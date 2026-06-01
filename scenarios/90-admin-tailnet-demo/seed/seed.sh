#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCENARIO_DIR="$(dirname "$SCRIPT_DIR")"
SCENARIOS_ROOT="$(cd "$SCENARIO_DIR/../.." && pwd)"

find_workspace_root() {
  local dir="$SCENARIOS_ROOT"
  while [ "$dir" != "/" ]; do
    if [ -f "$dir/workflow/go.mod" ]; then
      echo "$dir"
      return 0
    fi
    dir="$(dirname "$dir")"
  done
  return 1
}

WORKSPACE_ROOT="${WORKSPACE_ROOT:-$(find_workspace_root)}"

admin_ui_dir_has_hardcoded_surfaces() {
  local ui_dir="$1"
  grep -R -E 'data-panel="(identity|authorization)-panel"|Identity provider|Authorization mode' "$ui_dir" >/dev/null 2>&1
}

admin_ui_dir_has_auth_gate() {
  local ui_dir="$1"
  grep -R 'data-login-endpoint' "$ui_dir" >/dev/null 2>&1 &&
    grep -R 'data-token-storage-key' "$ui_dir" >/dev/null 2>&1 &&
    grep -R 'Authorization' "$ui_dir" >/dev/null 2>&1
}

admin_ui_dir_has_contribution_renderers() {
  local ui_dir="$1"
  grep -R 'renderConfigForm' "$ui_dir" >/dev/null 2>&1 &&
    grep -R 'workflow.admin.auth.request' "$ui_dir" >/dev/null 2>&1 &&
    grep -R 'workflow.admin.auth.response' "$ui_dir" >/dev/null 2>&1
}

admin_repo_is_usable() {
  local repo="$1"
  [ -f "$repo/go.mod" ] &&
    [ -d "$repo/internal/ui_dist" ] &&
    ! admin_ui_dir_has_hardcoded_surfaces "$repo/internal/ui_dist" &&
    admin_ui_dir_has_auth_gate "$repo/internal/ui_dist" &&
    admin_ui_dir_has_contribution_renderers "$repo/internal/ui_dist"
}

find_admin_repo() {
  if [ -n "${PLUGIN_ADMIN_REPO:-}" ]; then
    echo "$PLUGIN_ADMIN_REPO"
    return 0
  fi

  local root="$WORKSPACE_ROOT/workflow-plugin-admin"
  if [ -d "$root/.worktrees/auth-portal-manager" ] && admin_repo_is_usable "$root/.worktrees/auth-portal-manager"; then
    echo "$root/.worktrees/auth-portal-manager"
    return 0
  fi
  local candidate
  for candidate in "$root"/.worktrees/* "$root"; do
    [ -d "$candidate" ] || continue
    if admin_repo_is_usable "$candidate"; then
      echo "$candidate"
      return 0
    fi
  done

  if [ -d "$root/.worktrees" ]; then
    while IFS= read -r candidate; do
      if admin_repo_is_usable "$candidate"; then
        echo "$candidate"
        return 0
      fi
    done < <(find "$root/.worktrees" -mindepth 1 -maxdepth 1 -type d | sort)
  fi

  echo "ERROR: no contribution-driven workflow-plugin-admin checkout found under $root" >&2
  echo "       Update workflow-plugin-admin to v1.1.7 or newer, or set PLUGIN_ADMIN_REPO explicitly." >&2
  return 1
}

WORKFLOW_REPO="${WORKFLOW_REPO:-$WORKSPACE_ROOT/workflow}"
PLUGIN_ADMIN_REPO="$(find_admin_repo)"
PLUGIN_AUTH_REPO="${PLUGIN_AUTH_REPO:-$WORKSPACE_ROOT/workflow-plugin-auth/.worktrees/auth-admin-contribution}"
PLUGIN_AUTHZ_UI_REPO="${PLUGIN_AUTHZ_UI_REPO:-$WORKSPACE_ROOT/workflow-plugin-authz-ui/.worktrees/authz-ui-admin-bridge}"
IMAGE_TAG="${IMAGE_TAG:-workflow-admin:scenario-90}"

provider_repos=(
  "workflow-plugin-auth0"
  "workflow-plugin-entra"
  "workflow-plugin-okta"
  "workflow-plugin-sso"
  "workflow-plugin-ory-kratos"
  "workflow-plugin-ory-hydra"
  "workflow-plugin-ory-polis"
  "workflow-plugin-scalekit"
)

echo ""
echo "=== Scenario 90 seed: Workflow-native admin tailnet demo ==="
echo "  WORKFLOW_REPO=$WORKFLOW_REPO"
echo "  PLUGIN_ADMIN_REPO=$PLUGIN_ADMIN_REPO"
echo "  PLUGIN_AUTH_REPO=$PLUGIN_AUTH_REPO"
echo "  PLUGIN_AUTHZ_UI_REPO=$PLUGIN_AUTHZ_UI_REPO"
echo "  IMAGE_TAG=$IMAGE_TAG"
echo ""

if find "$SCENARIO_DIR" -type f -name '*.py' | grep -q .; then
  echo "ERROR: scenario 90 must not contain a Python app harness" >&2
  find "$SCENARIO_DIR" -type f -name '*.py' >&2
  exit 1
fi

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
  (cd "$repo" && GOWORK=off GOOS=linux GOARCH=amd64 go build -o "$dest/$plugin_name" "$cmd_path")
  cp "$repo/plugin.json" "$dest/plugin.json"
}

BUILD_DIR="$SCENARIO_DIR/.build"
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR/plugins" "$BUILD_DIR/admin-ui" "$BUILD_DIR/authz-ui" "$BUILD_DIR/app-ui" "$BUILD_DIR/data"
if [ -z "${SCENARIO90_SEED_TOKEN:-}" ]; then
  if command -v openssl >/dev/null 2>&1; then
    SCENARIO90_SEED_TOKEN="$(openssl rand -hex 32)"
  else
    SCENARIO90_SEED_TOKEN="$(uuidgen | tr '[:upper:]' '[:lower:]')-$(date +%s)"
  fi
fi
export SCENARIO90_SEED_TOKEN
cp "$SCENARIO_DIR/config/app.yaml" "$BUILD_DIR/app.yaml"
awk -v token="$SCENARIO90_SEED_TOKEN" '{ gsub(/\$\{SCENARIO90_SEED_TOKEN\}/, token); print }' "$BUILD_DIR/app.yaml" > "$BUILD_DIR/app.yaml.tmp"
mv "$BUILD_DIR/app.yaml.tmp" "$BUILD_DIR/app.yaml"

require_go_module "$WORKFLOW_REPO"
echo "Building workflow server..."
(cd "$WORKFLOW_REPO" && GOWORK=off GOOS=linux GOARCH=amd64 go build -o "$BUILD_DIR/server" ./cmd/server)

build_plugin "$PLUGIN_ADMIN_REPO" "workflow-plugin-admin" "./cmd/workflow-plugin-admin"
build_plugin "$PLUGIN_AUTH_REPO" "workflow-plugin-auth" "./cmd/workflow-plugin-auth"
build_plugin "$PLUGIN_AUTHZ_UI_REPO" "workflow-plugin-authz-ui" "./cmd/workflow-plugin-authz-ui"

for repo_name in "${provider_repos[@]}"; do
  build_plugin "$WORKSPACE_ROOT/$repo_name" "$repo_name" "./cmd/$repo_name"
done

cp -R "$PLUGIN_ADMIN_REPO/internal/ui_dist/." "$BUILD_DIR/admin-ui/"
if admin_ui_dir_has_hardcoded_surfaces "$BUILD_DIR/admin-ui"; then
  echo "ERROR: selected workflow-plugin-admin UI contains hardcoded admin surfaces" >&2
  echo "       Use a contribution-driven workflow-plugin-admin build, such as v1.1.7 or newer." >&2
  exit 1
fi
if ! admin_ui_dir_has_auth_gate "$BUILD_DIR/admin-ui"; then
  echo "ERROR: selected workflow-plugin-admin UI does not include token-aware admin loading" >&2
  echo "       Use workflow-plugin-admin with login-aware shell assets, or set PLUGIN_ADMIN_REPO explicitly." >&2
  exit 1
fi
if ! admin_ui_dir_has_contribution_renderers "$BUILD_DIR/admin-ui"; then
  echo "ERROR: selected workflow-plugin-admin UI does not render config-form surfaces or iframe auth bridge requests" >&2
  echo "       Use workflow-plugin-admin with contribution renderer assets, or set PLUGIN_ADMIN_REPO explicitly." >&2
  exit 1
fi
if [ -d "$PLUGIN_AUTHZ_UI_REPO/ui/dist" ]; then
  cp -R "$PLUGIN_AUTHZ_UI_REPO/ui/dist/." "$BUILD_DIR/authz-ui/"
else
  if [ -f "$PLUGIN_AUTHZ_UI_REPO/ui/package.json" ]; then
    (cd "$PLUGIN_AUTHZ_UI_REPO/ui" && npm ci && npm run build)
  fi
fi
if [ -d "$PLUGIN_AUTHZ_UI_REPO/ui/dist" ]; then
  cp -R "$PLUGIN_AUTHZ_UI_REPO/ui/dist/." "$BUILD_DIR/authz-ui/"
else
  cp -R "$PLUGIN_AUTHZ_UI_REPO/internal/ui_dist/." "$BUILD_DIR/authz-ui/"
fi
cp -R "$SCENARIO_DIR/app-ui/." "$BUILD_DIR/app-ui/"

cat > "$BUILD_DIR/authz-ui/runtime-config.js" <<'JS'
window.__WORKFLOW_AUTHZ_UI__ = window.WORKFLOW_AUTHZ_UI_CONFIG = {
  api_base_path: "/api/authz",
  admin_base_path: "/admin/authz",
  frontend_context: "frontend",
  admin_context: "admin",
  capabilities_path: "/capabilities",
  granted_scopes: ["admin:authz.roles:read"],
  scopes: [
    { name: "frontend:orders:read", context: "frontend", resource: "orders", actions: ["read"], description: "Read customer orders in the primary app." },
    { name: "frontend:orders:update", context: "frontend", resource: "orders", actions: ["update"], description: "Update customer orders in the primary app." },
    { name: "admin:authz.roles:read", context: "admin", resource: "authz.roles", actions: ["read"], description: "View role and scope assignments in admin." },
    { name: "admin:authz.roles:update", context: "admin", resource: "authz.roles", actions: ["update"], description: "Manage role and scope assignments in admin." }
  ]
};
JS
if ! grep -q 'runtime-config.js' "$BUILD_DIR/authz-ui/index.html"; then
  tmp_index="$BUILD_DIR/authz-ui/index.html.tmp"
  sed 's#</head>#<script src="/admin/authz/runtime-config.js"></script></head>#' "$BUILD_DIR/authz-ui/index.html" > "$tmp_index"
  mv "$tmp_index" "$BUILD_DIR/authz-ui/index.html"
fi
mkdir -p "$BUILD_DIR/admin-ui/authz"
cp -R "$BUILD_DIR/authz-ui/." "$BUILD_DIR/admin-ui/authz/"
mkdir -p "$BUILD_DIR/plugins/workflow-plugin-admin/ui_dist/authz"
cp -R "$BUILD_DIR/authz-ui/." "$BUILD_DIR/plugins/workflow-plugin-admin/ui_dist/authz/"
mkdir -p "$BUILD_DIR/plugins/workflow-plugin-authz-ui/ui_dist"
cp -R "$BUILD_DIR/authz-ui/." "$BUILD_DIR/plugins/workflow-plugin-authz-ui/ui_dist/"

cat > "$BUILD_DIR/Dockerfile" <<'DOCKERFILE'
FROM gcr.io/distroless/static-debian12:nonroot
COPY --chown=nonroot:nonroot server /usr/local/bin/server
COPY --chown=nonroot:nonroot plugins/ /data/plugins/
COPY --chown=nonroot:nonroot data/ /data/data/
COPY --chown=nonroot:nonroot app.yaml /data/app.yaml
COPY --chown=nonroot:nonroot admin-ui/ /opt/workflow-admin-ui/
COPY --chown=nonroot:nonroot authz-ui/ /opt/workflow-authz-ui/
COPY --chown=nonroot:nonroot app-ui/ /opt/workflow-app-ui/
USER nonroot
WORKDIR /data
ENV WFCTL_PLUGIN_DIR=/data/plugins
ENTRYPOINT ["/usr/local/bin/server"]
DOCKERFILE

echo "Building $IMAGE_TAG..."
docker build -t "$IMAGE_TAG" "$BUILD_DIR"

cd "$SCENARIO_DIR"
docker compose down --remove-orphans 2>/dev/null || true
docker compose up -d

echo "Waiting for Workflow /healthz ..."
for i in $(seq 1 90); do
  if curl -fs http://127.0.0.1:18080/healthz >/dev/null 2>&1; then
    curl -fsS -X POST -H "X-Scenario90-Seed-Token: $SCENARIO90_SEED_TOKEN" http://127.0.0.1:18080/api/scenario90/seed/roles >/dev/null
    echo "Seeded baseline role assignments"
    echo "Stack ready at http://127.0.0.1:18080 (took ${i}s)"
    echo "Admin UI: http://127.0.0.1:18080/admin/"
    echo "Authz UI: http://127.0.0.1:18080/admin/authz/"
    exit 0
  fi
  sleep 1
done

echo "ERROR: Workflow server did not become ready" >&2
docker compose logs --tail=120 app >&2
exit 1
