.PHONY: up down pull-model logs test test-config clean

SCENARIO := 85-self-improving-api

up: pull-model
	docker compose up -d

down:
	docker compose down

pull-model:
	docker compose run --rm ollama bash -c "ollama pull gemma4 && echo 'Model ready.'"

logs:
	docker compose logs -f

test:
	go test ./tests/... -v -timeout 30m

test-config:
	go test ./tests/ -run TestConfigValidation -v

test-guardrails:
	go test ./tests/ -run TestGuardrails -v

test-short:
	go test ./tests/... -v -short

clean:
	docker compose down -v
	rm -f /data/tasks.db /data/agent.db /data/agent-state.db
