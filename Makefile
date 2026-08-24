# Recipes use `set -euo pipefail`, which dash rejects; every recipe here
# assumes bash semantics.
SHELL := /bin/bash

# Every shell script CI lints: one owner of the list so a new script is
# covered by bash -n, shellcheck, and the reference check automatically.
SCRIPTS := entrypoint.sh start.sh stop.sh $(sort $(wildcard scripts/*.sh))
# Python helpers + CI YAML get the same treatment (ruff, mypy, yamllint);
# their configuration lives in pyproject.toml / .yamllint.yaml.
PY := $(sort $(wildcard scripts/*.py))
# The yamllint config itself is YAML; a broken config must fail lint, not
# silently fall back to defaults. Dependabot's file is YAML too and gets the
# same gate as the workflows. Workflows match on both .yml and .yaml so a
# differently-suffixed file cannot slip past the gate.
YAML := $(sort $(wildcard .github/workflows/*.yml) $(wildcard .github/workflows/*.yaml)) .yamllint.yaml .github/dependabot.yml

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
	# Containerfile structure: entrypoint.sh sources lib-env.sh from the exact
	# path this file COPYs it to, so the image shape is load-bearing; pin it
	# here so dev and CI run one identical gate (single-owner rule as above).
	set -euo pipefail; \
	grep -Eq '^FROM[[:space:]]+' Containerfile; \
	grep -Eq '^COPY[[:space:]]+entrypoint\.sh' Containerfile; \
	grep -Eq '^COPY[[:space:]]+scripts/lib-env\.sh' Containerfile; \
	grep -Eq '^ENTRYPOINT[[:space:]]+\[' Containerfile; \
	test -x entrypoint.sh || { echo "entrypoint.sh is not executable" >&2; exit 1; }; \
	while read -r kw; do \
	  case "$$kw" in \
	    FROM|RUN|COPY|ENTRYPOINT|USER) ;; \
	    *) echo "unknown Containerfile directive: $$kw" >&2; exit 1 ;; \
	  esac; \
	done < <(awk '/^[A-Z]+[[:space:]]/ {print $$1}' Containerfile | sort -u); \
	echo "Containerfile OK"

test:
	bash scripts/test_lib_env.sh
	python3 scripts/test_coverage_badge.py
	python3 scripts/test_check_config_xml.py
	python3 scripts/test_config_templates.py
	python3 scripts/test_entrypoint_boot.py
	python3 scripts/test_systemd_unit.py
	python3 scripts/test_run_sh.py
	python3 scripts/test_perf_sh.py
	python3 scripts/test_stage_mods.py

coverage:
	rm -rf coverage
	# Direct exec (not `bash script`): kcov traces the shebang interpreter;
	# through an extra bash layer it produces an empty report.
	kcov --clean --include-pattern=lib-env.sh coverage ./scripts/test_lib_env.sh
	find coverage -name cobertura.xml | head -1 | xargs -I{} cp {} coverage.cobertura.xml
