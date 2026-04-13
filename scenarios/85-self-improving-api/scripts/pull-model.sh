#!/usr/bin/env bash
# Pull the Gemma 4 model from Ollama before starting the agent.
set -e

OLLAMA_BASE_URL="${OLLAMA_BASE_URL:-http://localhost:11434}"

echo "Waiting for Ollama to be ready at ${OLLAMA_BASE_URL}..."
for i in $(seq 1 30); do
    if curl -sf "${OLLAMA_BASE_URL}/api/tags" >/dev/null 2>&1; then
        echo "Ollama is ready."
        break
    fi
    echo "  attempt ${i}/30..."
    sleep 5
done

echo "Pulling Gemma 4 model..."
curl -sf "${OLLAMA_BASE_URL}/api/pull" \
    -d '{"name": "gemma4"}' \
    -H "Content-Type: application/json" | tail -1

echo "Model gemma4 ready."
