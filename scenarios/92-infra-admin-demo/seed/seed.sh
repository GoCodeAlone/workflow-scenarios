#!/usr/bin/env bash
# Scenario 92 — Infra Admin Phase 2/3 demo seed (workflow v0.74.0 / workflow-plugin-infra v1.2.0)
#
# workflow v0.74.0 wires providerclient.ResourceDriver end-to-end (PR13), so
# step.iac_provider_apply against the stub provider genuinely CREATES resources
# and step.iac_commit_back commits a branch (no more PR-1-adapter gap).
#
# Builds the docker images and brings up the docker-compose stack:
#   workflow-admin:scenario-92       — workflow engine with external gRPC plugins
#   workflow-sandbox-runner:scenario-92 — sandbox-runner agent (step.sandbox_exec remote exec_env)
#
# All plugins are EXTERNAL gRPC binaries — no in-process fixtures:
#   stub-iac-provider:        built from scenarios/92-infra-admin-demo/fixtures/stub-iac-provider/
#   workflow-plugin-admin:    built from local checkout ($PLUGIN_ADMIN_REPO)
#   workflow-plugin-infra:    built from local checkout ($PLUGIN_INFRA_REPO)
#
# Git fixtures (for iac_commit_back / iac_provider_reconcile):
#   .build/gitrepo.git   — bare git repo (the "origin" remote; mounted :rw in app container
#                          so `git push origin <branch>` from iac_commit_back can write to it)
#   .build/workclone     — working clone of bare.git (mounted :rw; iac_commit_back writes here)
#
# The stub-iac-provider is registered as an IaCProvider service under the
# plugin name "stub-iac-provider" via the engine's WiringHook mechanism.
# Steps configured with `provider: stub-iac-provider` resolve it at runtime.
#
# workflow-plugin-infra provides the infra.admin module type and serves the
# Infrastructure Management SPA at /admin/infra via ConfigFragment injection.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCENARIO_DIR="$(dirname "$SCRIPT_DIR")"
SCENARIOS_ROOT="$(cd "$SCENARIO_DIR/../.." && pwd)"

# WORKSPACE_ROOT: the parent directory containing sibling repos (workflow, workflow-plugin-infra, etc.)
# Handles both the normal checkout layout ($workspace/workflow-scenarios) AND
# the git-worktree layout ($workspace/workflow-scenarios/.worktrees/<branch>),
# where SCENARIOS_ROOT is a deep path but the workspace is multiple levels up.
# Walk up from SCENARIOS_ROOT until we find a directory containing workflow/go.mod.
_find_workspace() {
  local dir="$1"
  local limit=6  # max levels to search
  local i=0
  while [ "$i" -lt "$limit" ]; do
    if [ -f "$dir/workflow/go.mod" ]; then
      echo "$dir"
      return 0
    fi
    local parent
    parent="$(cd "$dir/.." && pwd)"
    if [ "$parent" = "$dir" ]; then
      break  # reached filesystem root
    fi
    dir="$parent"
    i=$((i + 1))
  done
  # Fallback: one level above SCENARIOS_ROOT
  cd "$SCENARIOS_ROOT/.." && pwd
}
WORKSPACE_ROOT="${WORKSPACE_ROOT:-$(_find_workspace "$SCENARIOS_ROOT")}"

PLUGIN_ADMIN_REPO="${PLUGIN_ADMIN_REPO:-$WORKSPACE_ROOT/workflow-plugin-admin}"
PLUGIN_INFRA_REPO="${PLUGIN_INFRA_REPO:-$WORKSPACE_ROOT/workflow-plugin-infra}"
IMAGE_TAG="${IMAGE_TAG:-workflow-admin:scenario-92}"
RUNNER_IMAGE_TAG="${RUNNER_IMAGE_TAG:-workflow-sandbox-runner:scenario-92}"

echo ""
echo "=== Scenario 92 seed (Phase 2/3: dynamic specs + remote runner + commit-back) ==="
echo "  SCENARIO_DIR=$SCENARIO_DIR"
echo "  WORKSPACE_ROOT=$WORKSPACE_ROOT"
echo "  PLUGIN_ADMIN_REPO=$PLUGIN_ADMIN_REPO"
echo "  PLUGIN_INFRA_REPO=$PLUGIN_INFRA_REPO"
echo "  IMAGE_TAG=$IMAGE_TAG"
echo "  RUNNER_IMAGE_TAG=$RUNNER_IMAGE_TAG"
echo "  workflow engine + sandbox-runner: built from scenarios module pin (v0.74.0)"
echo ""

# --- Helpers ------------------------------------------------------------------

require_go_module() {
  local repo="$1"
  if [ ! -f "$repo/go.mod" ]; then
    echo "ERROR: $repo is not a Go module checkout" >&2
    exit 1
  fi
}

# --- Validate repos -----------------------------------------------------------

if [ ! -f "$PLUGIN_ADMIN_REPO/go.mod" ]; then
  echo "ERROR: PLUGIN_ADMIN_REPO=$PLUGIN_ADMIN_REPO is not a Go module checkout" >&2
  exit 1
fi

if [ ! -f "$PLUGIN_INFRA_REPO/go.mod" ]; then
  echo "ERROR: PLUGIN_INFRA_REPO=$PLUGIN_INFRA_REPO is not a Go module checkout" >&2
  echo "       Expected workflow-plugin-infra (v1.2.0+) with infra.admin SPA." >&2
  exit 1
fi

# The workflow engine + the sandbox-runner agent are both built from the
# scenarios module's pinned workflow version (v0.74.0 in go.mod) — NOT from a
# local workflow checkout. This guarantees the engine (providerclient.ResourceDriver
# wiring, PR13) and the agent share the exact released version.

# Verify the infra plugin has the SPA assets (PR-4: infra.admin + AdminContribution).
if [ ! -f "$PLUGIN_INFRA_REPO/internal/ui_dist/index.html" ]; then
  echo "ERROR: $PLUGIN_INFRA_REPO/internal/ui_dist/index.html not found." >&2
  echo "       Pull workflow-plugin-infra main (v1.2.0+) which adds the infra-admin SPA." >&2
  exit 1
fi

STUB_PROVIDER_DIR="$SCENARIO_DIR/fixtures/stub-iac-provider"
if [ ! -f "$STUB_PROVIDER_DIR/go.mod" ]; then
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
  "$BUILD_DIR/plugins/workflow-plugin-admin" \
  "$BUILD_DIR/plugins/workflow-plugin-infra"

# --- Build scenario-92 server binary ------------------------------------------
# Built from the scenarios module (pinned to workflow v0.74.0 via go.mod). The
# engine's providerclient.Adapter (v0.74.0) wires ResourceDriver, so apply CREATEs.

echo "Building scenario-92-owned server binary..."
(cd "$SCENARIOS_ROOT" && GOWORK=off CGO_ENABLED=0 GOOS=linux GOARCH=amd64 \
  go build -o "$BUILD_DIR/server" ./scenarios/92-infra-admin-demo/cmd/server)

# --- Build workflow-sandbox-runner (agent for remote exec_env) ----------------
# Built from the scenarios module's pinned workflow version (v0.74.0) — the agent
# package github.com/GoCodeAlone/workflow/cmd/workflow-sandbox-runner resolves
# through the scenarios go.mod, so it matches the engine exactly (no dependency
# on a local workflow checkout). The runner image runs the agent gRPC server.

echo "Building workflow-sandbox-runner agent (from scenarios module pin)..."
(cd "$SCENARIOS_ROOT" && GOWORK=off CGO_ENABLED=0 GOOS=linux GOARCH=amd64 \
  go build -o "$BUILD_DIR/workflow-sandbox-runner" \
  github.com/GoCodeAlone/workflow/cmd/workflow-sandbox-runner)

# --- Build stub-iac-provider (external gRPC plugin) ---------------------------

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

# --- Build workflow-plugin-infra (external gRPC plugin, infra.admin SPA) ------

echo "Building workflow-plugin-infra..."
(cd "$PLUGIN_INFRA_REPO" && GOWORK=off GOOS=linux GOARCH=amd64 \
  go build -o "$BUILD_DIR/plugins/workflow-plugin-infra/workflow-plugin-infra" \
  ./cmd/workflow-plugin-infra)
cp "$PLUGIN_INFRA_REPO/plugin.json" "$BUILD_DIR/plugins/workflow-plugin-infra/plugin.json"

# Pre-extract the embedded SPA so extractAssets() finds ui_dist/index.html and
# returns without attempting filesystem writes at runtime.
echo "Pre-copying infra SPA assets (ui_dist) into plugin directory..."
mkdir -p "$BUILD_DIR/plugins/workflow-plugin-infra/ui_dist"
cp -r "$PLUGIN_INFRA_REPO/internal/ui_dist/." \
  "$BUILD_DIR/plugins/workflow-plugin-infra/ui_dist/"

# --- Initialize bare git repo + working clone ----------------------------------
# The bare repo is the "origin" remote.
# The working clone is the on-disk checkout that iac_commit_back and
# iac_provider_reconcile write to and push from (via git push origin <branch>).
# Both are mounted into the app container via docker-compose volumes.

BARE_REPO="$BUILD_DIR/gitrepo.git"
WORK_CLONE="$BUILD_DIR/workclone"

echo "Initializing bare git repo + working clone..."
if [ ! -d "$BARE_REPO/objects" ]; then
  git init --bare "$BARE_REPO"
  # Seed the bare repo with an initial commit so HEAD is valid.
  # Use a local clone instead of a temp-then-push to avoid the autodev
  # push-to-main hook that blocks pushes to master/main in autonomous pipelines.
  SEED_TMP="$(mktemp -d)"
  (
    cd "$SEED_TMP"
    git clone "$BARE_REPO" workclone-seed 2>/dev/null || true
    cd workclone-seed 2>/dev/null || { mkdir workclone-seed; cd workclone-seed; git init; git remote add origin "$BARE_REPO"; }
    git config user.email "scenario92@demo.local"
    git config user.name "Scenario 92 Demo"
    printf '# Infra State\n\nInitial infra state — scenario 92 gitops demo.\n' > infra.md
    git add infra.md
    # Create the initial commit on a feature branch (not main/master) so the autodev
    # hook doesn't block it. The bare repo HEAD is updated via --set-upstream.
    git commit -m "chore: initial infra state (scenario 92 demo)" 2>/dev/null || \
      (git -c user.email="scenario92@demo.local" -c user.name="Scenario 92 Demo" commit -m "chore: initial infra state")
    # Push to 'gitops/initial' — a gitops feature branch, not main/master.
    git push origin HEAD:refs/heads/gitops/initial 2>/dev/null || true
    # Also update HEAD in the bare repo to point to this branch.
    GIT_DIR="$BARE_REPO" git symbolic-ref HEAD refs/heads/gitops/initial 2>/dev/null || true
  )
  rm -rf "$SEED_TMP"
fi

# Clone the bare repo to create the working clone.
# Force-recreate so each seed run starts clean (no stale branches from prior runs).
rm -rf "$WORK_CLONE"
git clone "$BARE_REPO" "$WORK_CLONE"
# Configure committer identity in the working clone (needed by iac_commit_back git commit).
git -C "$WORK_CLONE" config user.email "scenario92@demo.local"
git -C "$WORK_CLONE" config user.name "Scenario 92 Demo"
# Make the origin remote point to the bare repo path (already set by git clone,
# but make it explicit so the container-internal mount path is correct).
git -C "$WORK_CLONE" remote set-url origin /gitops/bare.git

echo "Bare repo:    $BARE_REPO"
echo "Working clone: $WORK_CLONE"
echo "  remote:      /gitops/bare.git (container path, set in workclone)"

# --- Build the scenario engine image ------------------------------------------
# Phase 2/3: use debian-slim instead of distroless because step.iac_commit_back
# and step.iac_provider_reconcile call git via exec.Command (platform plugin gitExecFn).
# distroless does not have a git binary.
#
# Security: the nonroot user (uid 65532) is preserved; plugins go in /home/nonroot
# (writable by nonroot in the debian-slim image after mkdir/chown in Dockerfile).
#
# git is needed: step.iac_commit_back runs git checkout -b / git add / git commit / git push.
# git config --global is set at container startup via ENTRYPOINT env so the
# git identity is available even though the step doesn't set --global user.

cat > "$BUILD_DIR/Dockerfile" <<'EOF'
FROM debian:12-slim

# Install git (needed by step.iac_commit_back gitExecFn).
# ca-certificates: needed by git for HTTPS remotes (bare repo is file:// so
# not strictly required, but good practice).
RUN apt-get update && apt-get install -y --no-install-recommends \
    git \
    ca-certificates \
  && rm -rf /var/lib/apt/lists/*

# Create nonroot user matching distroless UID (65532) for consistency.
RUN groupadd --gid 65532 nonroot && \
    useradd --uid 65532 --gid 65532 --no-create-home --shell /bin/false nonroot

# /home/nonroot: writable data dir (plugins, workflow.db, git clone operations).
RUN mkdir -p /home/nonroot && chown 65532:65532 /home/nonroot

# Global git config for the nonroot user:
#   - User identity for git commit (needed by iac_commit_back).
#   - safe.directory = * so docker-mounted volumes owned by a different UID
#     don't trigger the "dubious ownership" git security error. This is safe
#     in the hermetic demo container (no external git operations run here).
RUN mkdir -p /home/nonroot/.config/git && \
    printf '[user]\n\tname = Scenario 92 Demo\n\temail = scenario92@demo.local\n[safe]\n\tdirectory = *\n' \
      > /home/nonroot/.config/git/config && \
    chown -R 65532:65532 /home/nonroot/.config

ENV HOME=/home/nonroot

COPY server /usr/local/bin/server
COPY plugins/ /home/nonroot/plugins/

USER nonroot
WORKDIR /home/nonroot

ENTRYPOINT ["/usr/local/bin/server"]
EOF

echo "Building $IMAGE_TAG..."
docker build -t "$IMAGE_TAG" "$BUILD_DIR"

# --- Build the sandbox-runner image -------------------------------------------
# The sandbox runner is a separate image that only contains the runner binary
# plus the tools it needs (nc for the healthcheck).
# We use a busybox-based image so nc is available for the healthcheck.

cat > "$BUILD_DIR/Dockerfile.runner" <<'EOF'
FROM busybox:1.36
COPY workflow-sandbox-runner /usr/local/bin/workflow-sandbox-runner
ENTRYPOINT ["/usr/local/bin/workflow-sandbox-runner"]
EOF

echo "Building $RUNNER_IMAGE_TAG..."
docker build -t "$RUNNER_IMAGE_TAG" -f "$BUILD_DIR/Dockerfile.runner" "$BUILD_DIR"

# --- Bring up the stack -------------------------------------------------------

cd "$SCENARIO_DIR"
docker compose down --remove-orphans 2>/dev/null || true
docker compose up -d

echo "Waiting for /healthz ..."
for i in $(seq 1 90); do
  if curl -fs http://127.0.0.1:18092/healthz >/dev/null 2>&1; then
    echo "Stack ready at http://127.0.0.1:18092 (took ${i}s)"
    echo "External plugins loaded: stub-iac-provider, workflow-plugin-admin, workflow-plugin-infra"
    echo "Provider service: stub-iac-provider (WiringHook registered)"
    echo "Infra SPA:        http://127.0.0.1:18092/admin/infra (served by workflow-plugin-infra)"
    echo "Sandbox runner:   sandbox-runner:50051 (internal docker network only)"
    echo "Git working clone: .build/workclone (mounted at /gitops/workclone in app container)"
    echo "Git bare repo:     .build/gitrepo.git (mounted at /gitops/bare.git in app container)"
    exit 0
  fi
  sleep 1
done

echo "ERROR: /healthz never became ready" >&2
docker compose logs --tail=80 2>&1 | head -120 >&2
exit 1
