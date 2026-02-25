.PHONY: deploy test status teardown upgrade list test-all verify-persistence verify-all-persistence

SCENARIO ?=
COMPONENT ?=
VERSION ?=

deploy:
	@test -n "$(SCENARIO)" || (echo "Usage: make deploy SCENARIO=01-idp" && exit 1)
	@./scripts/deploy.sh $(SCENARIO)

test:
	@test -n "$(SCENARIO)" || (echo "Usage: make test SCENARIO=01-idp" && exit 1)
	@./scripts/test.sh $(SCENARIO)

status:
	@./scripts/status.sh $(SCENARIO)

teardown:
	@test -n "$(SCENARIO)" || (echo "Usage: make teardown SCENARIO=01-idp" && exit 1)
	@./scripts/teardown.sh $(SCENARIO)

upgrade:
	@test -n "$(COMPONENT)" || (echo "Usage: make upgrade COMPONENT=workflow VERSION=v0.3.0" && exit 1)
	@./scripts/upgrade.sh $(COMPONENT) $(VERSION)

verify-persistence:
	@test -n "$(SCENARIO)" || (echo "Usage: make verify-persistence SCENARIO=02-event-driven" && exit 1)
	@./scripts/verify-persistence.sh $(SCENARIO)

verify-all-persistence:
	@./scripts/test-all-persistence.sh

list:
	@echo "Available scenarios:"
	@ls -1 scenarios/ | while read s; do \
		status=$$(python3 -c "import json; d=json.load(open('scenarios.json')); print(d['scenarios'].get('$$s',{}).get('status','unknown'))" 2>/dev/null || echo "unknown"); \
		printf "  %-25s %s\n" "$$s" "$$status"; \
	done

test-all:
	@for s in $$(ls scenarios/); do \
		if [ -f "scenarios/$$s/test/run.sh" ]; then \
			echo "=== Testing $$s ==="; \
			./scripts/test.sh $$s || true; \
		fi; \
	done
