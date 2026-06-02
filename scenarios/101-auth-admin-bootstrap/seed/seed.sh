#!/usr/bin/env bash
# Scenario 101 — Auth Admin Bootstrap seed
#
# Image-bake pattern (mirrors scenario 92): cross-compile the workflow server +
# workflow-plugin-auth for linux/amd64, bake into a thin distroless image, then
# bring up postgres + app via docker-compose. Creates the consumer-owned
# `users` + `credentials` tables (the plugin is stateless; persistence is the
# consumer's, per V-B3).
#
#   ./seed.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCENARIO_DIR="$(dirname "$SCRIPT_DIR")"
SCENARIOS_ROOT="$(cd "$SCENARIO_DIR/../.." && pwd)"
WORKFLOW_REPO="${WORKFLOW_REPO:-$(cd "$SCENARIOS_ROOT/.." && pwd)/workflow}"
PLUGIN_AUTH_REPO="${PLUGIN_AUTH_REPO:-$(cd "$SCENARIOS_ROOT/.." && pwd)/workflow-plugin-auth}"
IMAGE_TAG="${IMAGE_TAG:-auth-admin:scenario-101}"
BASE_URL="${BASE_URL:-http://127.0.0.1:18101}"

echo ""
echo "=== Scenario 101 seed ==="
echo "  WORKFLOW_REPO=$WORKFLOW_REPO"
echo "  PLUGIN_AUTH_REPO=$PLUGIN_AUTH_REPO"
echo "  IMAGE_TAG=$IMAGE_TAG"
echo ""

[ -f "$WORKFLOW_REPO/go.mod" ]    || { echo "ERROR: WORKFLOW_REPO not a Go module: $WORKFLOW_REPO" >&2; exit 1; }
[ -f "$PLUGIN_AUTH_REPO/go.mod" ] || { echo "ERROR: PLUGIN_AUTH_REPO not a Go module: $PLUGIN_AUTH_REPO" >&2; exit 1; }

# --- Cross-compile server + auth plugin for the linux/amd64 container ----------
BUILD_DIR="$SCENARIO_DIR/.build"
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR/plugins/workflow-plugin-auth"

echo "Building workflow server (linux/amd64)..."
(cd "$WORKFLOW_REPO" && GOWORK=off GOOS=linux GOARCH=amd64 \
    go build -o "$BUILD_DIR/server" ./cmd/server)

echo "Building workflow-plugin-auth (linux/amd64)..."
(cd "$PLUGIN_AUTH_REPO" && GOWORK=off GOOS=linux GOARCH=amd64 \
    go build -o "$BUILD_DIR/plugins/workflow-plugin-auth/workflow-plugin-auth" \
    ./cmd/workflow-plugin-auth)
cp "$PLUGIN_AUTH_REPO/plugin.json" "$BUILD_DIR/plugins/workflow-plugin-auth/plugin.json"

# --- Bake the scenario image --------------------------------------------------
cat > "$BUILD_DIR/Dockerfile" <<'EOF'
FROM gcr.io/distroless/static-debian12:nonroot
# cmd/server discovers external plugins from <-data-dir>/plugins (default ./data/plugins,
# relative to CWD). The nonroot base sets WORKDIR=/home/nonroot, so bake the plugins where
# ./data/plugins resolves AND nonroot can write the sqlite/data files at runtime.
WORKDIR /home/nonroot
COPY --chown=nonroot:nonroot server /usr/local/bin/server
COPY --chown=nonroot:nonroot plugins/ data/plugins/
USER nonroot
ENTRYPOINT ["/usr/local/bin/server"]
EOF

echo "Building $IMAGE_TAG..."
docker build -t "$IMAGE_TAG" "$BUILD_DIR"

# --- Bring up postgres, create consumer tables, then the app ------------------
cd "$SCENARIO_DIR"
docker compose down --remove-orphans 2>/dev/null || true
docker compose up -d postgres

echo "Waiting for postgres ..."
for i in $(seq 1 30); do
    if docker compose exec -T postgres pg_isready -U scenario101 -d scenario101 >/dev/null 2>&1; then break; fi
    sleep 1
done

echo "Creating consumer-owned users + credentials tables ..."
docker compose exec -T postgres psql -U scenario101 -d scenario101 <<'SQL'
CREATE TABLE IF NOT EXISTS users (
    email TEXT PRIMARY KEY,
    role  TEXT NOT NULL DEFAULT 'super_admin',
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE TABLE IF NOT EXISTS credentials (
    id              BIGSERIAL PRIMARY KEY,
    user_email      TEXT NOT NULL REFERENCES users(email) ON DELETE CASCADE,
    kind            TEXT NOT NULL CHECK (kind IN ('passkey','google','facebook')),
    external_id     TEXT,
    public_key      BYTEA,
    device_name     TEXT,
    credential_json TEXT,  -- full webauthn.Credential JSON for login validation
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    last_used_at    TIMESTAMPTZ,
    UNIQUE (kind, external_id)
);
SQL

docker compose up -d app

echo "Waiting for /healthz ..."
for i in $(seq 1 60); do
    if curl -fs "$BASE_URL/healthz" >/dev/null 2>&1; then
        echo "Stack ready at $BASE_URL (took ${i}s)"
        exit 0
    fi
    sleep 1
done

echo "ERROR: /healthz never became ready" >&2
docker compose logs --tail=80 app >&2
exit 1
