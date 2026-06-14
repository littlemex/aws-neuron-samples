.PHONY: help test test-unit test-pipelines test-rules test-fast test-watch

help:
	@echo "make test            - run every test layer (unit + pipelines + rules)"
	@echo "make test-unit       - runner internals only (~10s)"
	@echo "make test-pipelines  - YAML+bash pipelines static checks (~30s)"
	@echo "make test-rules      - language / style / policy enforcement"
	@echo "make test-fast       - everything except the per-pipeline dry-run"
	@echo "make test-watch      - re-run unit tests on every save (requires entr)"

PYTEST ?= python3 -m pytest
PYTEST_ARGS ?= --tb=short -q

test: test-unit test-pipelines test-rules
	@echo "[OK] all test layers passed"

test-unit:
	@echo "[unit] runner internals"
	@$(PYTEST) tools/pipeline-runner/tests/ $(PYTEST_ARGS)

test-pipelines:
	@echo "[pipelines] bash -n + dry-run + persistence + required_vars"
	@$(PYTEST) tests/pipelines/ $(PYTEST_ARGS)

test-rules:
	@echo "[rules] english only / no emoji / env_required / no co-authored"
	@$(PYTEST) tests/rules/ $(PYTEST_ARGS)

test-fast:
	@echo "[fast] unit + rules + pipeline static checks (no dry-run)"
	@$(PYTEST) tools/pipeline-runner/tests/ tests/rules/ \
	    tests/pipelines/test_bash_syntax.py \
	    tests/pipelines/test_required_vars.py \
	    tests/pipelines/test_persistence.py \
	    $(PYTEST_ARGS)

test-watch:
	@command -v entr >/dev/null || { echo "[NG] install 'entr' first"; exit 1; }
	@find tools/pipeline-runner tests -type f \( -name '*.py' -o -name '*.sh' -o -name '*.yml' \) \
	    | entr -c $(MAKE) test-unit
