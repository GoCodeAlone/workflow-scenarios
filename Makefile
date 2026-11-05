.PHONY: deploy test status teardown upgrade list test-all verify-persistence verify-all-persistence validate playwright-test playwright-test-all

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
	@passed=0; failed=0; skipped=0; \
	for script in scenarios/*/test/run.sh; do \
		[ -f "$$script" ] || continue; \
		s=$${script#scenarios/}; s=$${s%/test/run.sh}; \
		echo "=== Testing $$s ==="; \
		if ./scripts/test.sh "$$s"; then \
			passed=$$((passed + 1)); \
		else \
			rc=$$?; \
			if [ "$$rc" -eq 77 ]; then skipped=$$((skipped + 1)); \
			else failed=$$((failed + 1)); fi; \
		fi; \
	done; \
	echo "Scenario results: $$passed passed, $$failed failed, $$skipped skipped"; \
	if [ "$$failed" -gt 0 ]; then echo "RESULT: SCENARIO TESTS FAILED"; exit 1; fi; \
	if [ "$$skipped" -gt 0 ]; then echo "RESULT: SCENARIO TESTS INCOMPLETE"; exit 77; fi; \
	if [ "$$passed" -eq 0 ]; then echo "SKIP: No runnable scenarios"; exit 77; fi

validate:
	@echo "Validating all scenario configs..."
	@./scripts/pre-push

playwright-test:
	@test -n "$(SCENARIO)" || (echo "Usage: make playwright-test SCENARIO=20-auth-service" && exit 1)
	@cd e2e && ./run-scenario-tests.sh $(SCENARIO)

playwright-test-all:
	@cd e2e && ./run-scenario-tests.sh 20-auth-service; \
	 ./run-scenario-tests.sh 21-payment-service; \
	 ./run-scenario-tests.sh 22-ecommerce-app
