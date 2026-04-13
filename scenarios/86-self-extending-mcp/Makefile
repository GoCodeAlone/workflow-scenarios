.PHONY: up down pull-model test test-e2e logs clean

# Start all services (Ollama + app + agent)
up:
	docker compose up -d

# Pull the Gemma 4 model into the running Ollama service
pull-model:
	docker compose exec ollama ollama pull gemma4

# Run config validation and unit tests (no E2E)
test:
	cd tests && go test -v -count=1 ./...

# Run full E2E test (requires running docker compose)
test-e2e:
	cd tests && E2E=true go test -v -timeout 15m -run TestE2E ./...

# Stream agent logs
logs:
	docker compose logs -f agent

# Tear down and remove volumes
clean:
	docker compose down -v
