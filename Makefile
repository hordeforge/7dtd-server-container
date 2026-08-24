ROOT := $(CURDIR)

# Recipes use `set -euo pipefail`, which dash rejects; every recipe here
# assumes bash semantics.
SHELL := /bin/bash

# Every shell script CI lints: one owner of the list so a new script is
# covered by bash -n, shellcheck, and the reference check automatically.
SCRIPTS := entrypoint.sh start.sh stop.sh $(sort $(wildcard scripts/*.sh))
# Python helpers + CI YAML get the same treatment (ruff, mypy, yamllint);
# their configuration lives in pyproject.toml / .yamllint.yaml.
PY := $(sort $(wildcard scripts/*.py))
YAML := $(sort $(wildcard .github/workflows/*.yml))

.DEFAULT_GOAL := test
.PHONY: lint test coverage

lint:
	set -euo pipefail; \
	for f in $(SCRIPTS); do bash -n "$$f" && echo "bash -n OK: $$f"; done
	set -euo pipefail; \
	for f in $(SCRIPTS); do shellcheck -x "$$f" && echo "shellcheck OK: $$f"; done
	set -euo pipefail; \
	for ref in $$(grep -hoE 'scripts/[-a-z_]+\.sh' $(SCRIPTS) | sort -u); do \
	  test -f "$$ref" || { echo "missing referenced script: $$ref" >&2; exit 1; }; \
	done; \
	echo "all internal script references exist"
	set -euo pipefail; \
	ruff check $(PY) && echo "ruff rules OK"
	set -euo pipefail; \
	ruff format --check $(PY) && echo "ruff format OK"
	set -euo pipefail; \
	mypy && echo "mypy strict OK"
	set -euo pipefail; \
	yamllint $(YAML) && echo "yamllint OK"

test:
	bash scripts/test_lib_env.sh
	python3 scripts/test_coverage_badge.py
	python3 scripts/test_check_config_xml.py

coverage:
	rm -rf coverage
	kcov --clean --include-pattern=lib-env.sh --exclude-pattern=fake-telnet-server.py coverage bash scripts/test_lib_env.sh
	cp coverage/cobertura.xml coverage.cobertura.xml 2>/dev/null || cp coverage/*/cobertura.xml coverage.cobertura.xml 2>/dev/null || find coverage -name cobertura.xml | head -1 | xargs -I{} cp {} coverage.cobertura.xml
