#!/usr/bin/env bash
# Scenario 102 — Cross-Service Asymmetric Auth seed
#
# Image-bake pattern (mirrors scenario 101):
#   1. Cross-compile the workflow server + workflow-plugin-sso (linux/amd64).
#   2. Cross-compile the mint-token test helper (linux/amd64) into .build/mint-token.
#   3. Bake two thin distroless images:
#        auth-xservice-a:scenario-102  (server + sso plugin, no sso env needed)
#        auth-xservice-b:scenario-102  (server + sso plugin)
#      Both share the same binaries; the -config flag selects app-a.yaml / app-b.yaml.
#   4. docker compose up; wait both /healthz.
#
#   ./seed.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCENARIO_DIR="$(dirname "$SCRIPT_DIR")"
SCENARIOS_ROOT="$(cd "$SCENARIO_DIR/../.." && pwd)"
WORKFLOW_REPO="${WORKFLOW_REPO:-$(cd "$SCENARIOS_ROOT/.." && pwd)/workflow}"
PLUGIN_SSO_REPO="${PLUGIN_SSO_REPO:-$(cd "$SCENARIOS_ROOT/.." && pwd)/workflow-plugin-sso}"

APP_A_URL="${APP_A_URL:-http://127.0.0.1:18102}"
APP_B_URL="${APP_B_URL:-http://127.0.0.1:18112}"

echo ""
echo "=== Scenario 102 seed ==="
echo "  WORKFLOW_REPO=$WORKFLOW_REPO"
echo "  PLUGIN_SSO_REPO=$PLUGIN_SSO_REPO"
echo ""

[ -f "$WORKFLOW_REPO/go.mod" ]   || { echo "ERROR: WORKFLOW_REPO not a Go module: $WORKFLOW_REPO" >&2; exit 1; }
[ -f "$PLUGIN_SSO_REPO/go.mod" ] || { echo "ERROR: PLUGIN_SSO_REPO not a Go module: $PLUGIN_SSO_REPO" >&2; exit 1; }

# --- Cross-compile server + sso plugin for linux/amd64 ----------------------
BUILD_DIR="$SCENARIO_DIR/.build"
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR/plugins/workflow-plugin-sso"

echo "Building workflow server (linux/amd64)..."
(cd "$WORKFLOW_REPO" && GOWORK=off GOOS=linux GOARCH=amd64 \
    go build -o "$BUILD_DIR/server" ./cmd/server)

echo "Building workflow-plugin-sso (linux/amd64)..."
(cd "$PLUGIN_SSO_REPO" && GOWORK=off GOOS=linux GOARCH=amd64 \
    go build -o "$BUILD_DIR/plugins/workflow-plugin-sso/workflow-plugin-sso" \
    ./cmd/workflow-plugin-sso)
cp "$PLUGIN_SSO_REPO/plugin.json" "$BUILD_DIR/plugins/workflow-plugin-sso/plugin.json"

# --- Cross-compile mint-token test helper for linux/amd64 -------------------
echo "Building mint-token (linux/amd64)..."
MINT_TOKEN_DIR="$SCENARIO_DIR/test/mint-token"
(cd "$MINT_TOKEN_DIR" && GOWORK=off GOOS=linux GOARCH=amd64 \
    go build -o "$BUILD_DIR/mint-token" .)

# --- Also build a native mint-token for run.sh (same OS as the host) --------
echo "Building mint-token (native, for run.sh)..."
(cd "$MINT_TOKEN_DIR" && GOWORK=off \
    go build -o "$BUILD_DIR/mint-token-native" .)

# --- Bake images (same Dockerfile, different image tag) ---------------------
# App A and App B share the same binaries; a separate image per service so
# docker-compose can specify different -config flags independently.
cat > "$BUILD_DIR/Dockerfile" <<'EOF'
# Alpine provides busybox wget (required by the docker-compose healthcheck:
# "wget -q -O- http://127.0.0.1:8080/healthz"). distroless has no shell/wget.
FROM alpine:3.20
RUN addgroup -S nonroot && adduser -S nonroot -G nonroot
# WORKDIR /home/nonroot so ./data/plugins resolves correctly (nonroot home).
WORKDIR /home/nonroot
COPY server /usr/local/bin/server
COPY plugins/ data/plugins/
# mint-token available for debugging inside the container.
COPY mint-token /usr/local/bin/mint-token
RUN chown -R nonroot:nonroot /home/nonroot
USER nonroot
ENTRYPOINT ["/usr/local/bin/server"]
EOF

echo "Building auth-xservice-a:scenario-102..."
docker build -t auth-xservice-a:scenario-102 "$BUILD_DIR"

echo "Building auth-xservice-b:scenario-102..."
docker build -t auth-xservice-b:scenario-102 "$BUILD_DIR"

# --- Bring up the stack ------------------------------------------------------
cd "$SCENARIO_DIR"
docker compose down --remove-orphans 2>/dev/null || true
docker compose up -d

# Wait for App A /healthz (up to 60 s)
echo "Waiting for App A /healthz ($APP_A_URL)..."
for i in $(seq 1 60); do
    if curl -fs "$APP_A_URL/healthz" >/dev/null 2>&1; then
        echo "  App A ready (${i}s)"
        break
    fi
    sleep 1
    if [ "$i" -eq 60 ]; then
        echo "ERROR: App A /healthz never became ready" >&2
        docker compose logs --tail=80 app-a >&2
        exit 1
    fi
done

# Wait for App B /healthz (up to 60 s)
echo "Waiting for App B /healthz ($APP_B_URL)..."
for i in $(seq 1 60); do
    if curl -fs "$APP_B_URL/healthz" >/dev/null 2>&1; then
        echo "  App B ready (${i}s)"
        echo ""
        echo "Stack ready:"
        echo "  App A (issuer):   $APP_A_URL"
        echo "  App B (verifier): $APP_B_URL"
        exit 0
    fi
    sleep 1
    if [ "$i" -eq 60 ]; then
        echo "ERROR: App B /healthz never became ready" >&2
        docker compose logs --tail=80 app-b >&2
        exit 1
    fi
done
