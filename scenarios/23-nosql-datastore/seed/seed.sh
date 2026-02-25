#!/usr/bin/env bash
set -euo pipefail

BASE="${1:-http://localhost:18023}"

echo "Seeding scenario 23: NoSQL Data Store"
echo "Base URL: $BASE"
echo ""

# Create initial items
for i in 1 2 3; do
    RESP=$(curl -sf -X POST "$BASE/api/items" \
        -H "Content-Type: application/json" \
        -d "{\"id\":\"seed-$i\",\"name\":\"Seed Item $i\",\"value\":$((i * 10))}" 2>/dev/null || echo "")
    if echo "$RESP" | grep -q '"stored":true'; then
        echo "Created seed item $i"
    else
        echo "WARNING: Failed to create seed item $i: $RESP"
    fi
done

echo ""
echo "Seed complete."
