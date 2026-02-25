#!/usr/bin/env bash
set -euo pipefail

echo "Seeding scenario 13-iot-telemetry..."

echo "Waiting for workflow-server to be ready..."
kubectl wait --for=condition=ready pod -l app=workflow-server -n "$NAMESPACE" --timeout=120s

kubectl port-forward svc/workflow-server 18080:8080 -n "$NAMESPACE" &
PF_PID=$!
sleep 3

cleanup() {
    kill $PF_PID 2>/dev/null || true
}
trap cleanup EXIT

echo "Initializing database schema..."
curl -sf -X POST http://localhost:18080/internal/init-db || echo "DB init may have already run"

# Check if seed data already exists
EXISTING=$(curl -sf "http://localhost:18080/api/v1/sensors" 2>/dev/null | grep -c "seed-sensor" 2>/dev/null || echo "0")
EXISTING=$(echo "$EXISTING" | tr -d '[:space:]')
if [ "${EXISTING:-0}" -gt "0" ] 2>/dev/null; then
    echo "Seed data already present, skipping..."
    exit 0
fi

echo "Registering seed sensors..."

# Temperature sensor with threshold
TEMP_RESP=$(curl -sf -X POST http://localhost:18080/api/v1/sensors/register \
    -H "Content-Type: application/json" \
    -d '{"name":"seed-sensor-temperature","sensor_type":"temperature","location":"Server Room A","threshold_value":80,"threshold_operator":"gt"}' || echo "")
TEMP_ID=$(echo "$TEMP_RESP" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('id',''))" 2>/dev/null || echo "")

# Humidity sensor
curl -sf -X POST http://localhost:18080/api/v1/sensors/register \
    -H "Content-Type: application/json" \
    -d '{"name":"seed-sensor-humidity","sensor_type":"humidity","location":"Warehouse B","threshold_value":90,"threshold_operator":"gt"}' || true

# Push some readings for the temperature sensor
if [ -n "$TEMP_ID" ]; then
    curl -sf -X POST "http://localhost:18080/api/v1/sensors/$TEMP_ID/data" \
        -H "Content-Type: application/json" \
        -d '{"value":72.5,"unit":"celsius"}' || true

    curl -sf -X POST "http://localhost:18080/api/v1/sensors/$TEMP_ID/data" \
        -H "Content-Type: application/json" \
        -d '{"value":75.1,"unit":"celsius"}' || true
fi

echo "Seed complete."
