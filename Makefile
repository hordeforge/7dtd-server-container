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
# Same single-owner rule for the suites `test` runs: a new scripts/test_*.py
# is executed by the gate as soon as it exists, not when someone remembers to
# list it here. test_lib_env.sh is bash and runs separately below.
TESTS := $(sort $(wildcard scripts/test_*.py))

# Analyzer toolchain: one uv-managed venv built from the hash-pinned closure
# in requirements-lint.txt. uv is the only Python toolchain this repo uses, so
# dev and CI resolve identical analyzer versions from the same recipe; CI adds
# nothing but the uv binary. --require-hashes turns any artifact mismatch into
# a hard failure. Every Python the gate runs comes from this venv, including
# the test suites, so one interpreter version covers the whole gate.
VENV := .venv
PYBIN := $(VENV)/bin

.DEFAULT_GOAL := help
.PHONY: help lint test test-one check coverage venv

# The task list, so a contributor never has to read this file to find a
# command. `make` alone lands here; `make test` is the gate, not a greeting.
help:
	@echo 'make venv                  the pinned analyzer venv (.venv), nothing else'
	@echo 'make test                   every suite: scripts/test_lib_env.sh, then scripts/test_*.py'
	@echo 'make test-one SUITE=<name>  one suite, e.g. SUITE=test_run_sh.py (test_lib_env.sh works too)'
	@echo 'make lint                   bash -n, shellcheck, script references, ruff, mypy, yamllint, Containerfile'
	@echo 'make check                  lint then test: everything .github/workflows/ci.yml runs'
	@echo 'make coverage               line coverage for scripts/lib-env.sh (needs kcov on PATH)'

$(PYBIN)/ruff: requirements-lint.txt
	# Named failure beats "uv: command not found" from make: uv is the only
	# Python toolchain this repo resolves anything through, and a contributor
	# arriving without it has nothing else to fall back on.
	@command -v uv >/dev/null 2>&1 || { \
	  echo "FATAL: uv not found on PATH. It is the only Python toolchain here; install it from https://docs.astral.sh/uv/ (or 'curl -LsSf https://astral.sh/uv/install.sh | sh')." >&2; \
	  exit 1; \
	}
	# --clear, not reuse: when the pinned closure changes the venv is rebuilt
	# from scratch, so a package dropped from requirements-lint.txt cannot
	# linger and keep satisfying an import the gate should have failed on.
	uv venv --quiet --clear $(VENV)
	uv pip install --quiet --python $(VENV) --require-hashes -r requirements-lint.txt
	# uv hardlinks from its cache, so the installed files can carry an older
	# mtime than requirements-lint.txt and re-trigger this rule every run.
	touch $(PYBIN)/ruff

# The analyzer venv and nothing else. A caller that needs the pinned
# interpreter without running a whole gate depends on this, so no step ever
# downloads a second, unversioned Python to do work the venv already covers.
venv: $(PYBIN)/ruff

lint: $(PYBIN)/ruff
	# shellcheck is the one gate tool that is not a Python package, so it is
	# the one a clean machine can be missing. Name it before the loop, where
	# the raw "command not found" would otherwise be buried under the
	# bash -n output.
	set -euo pipefail; \
	command -v shellcheck >/dev/null 2>&1 || { \
	  echo "FATAL: shellcheck not found on PATH; 'make lint' needs it (Debian/Ubuntu: apt install shellcheck, Fedora: dnf install ShellCheck, macOS: brew install shellcheck)." >&2; \
	  exit 1; \
	}
	set -euo pipefail; \
	# The analyzer call stands alone in the loop body, never as the left side
	# of `&&`: `cmd && echo` is a command list, and set -e ignores a failure
	# that is not the last command in such a list, so a red file scrolled past
	# and the recipe still exited 0.
	for f in $(SCRIPTS); do bash -n "$$f"; echo "bash -n OK: $$f"; done
	set -euo pipefail; \
	for f in $(SCRIPTS); do shellcheck -x "$$f"; echo "shellcheck OK: $$f"; done
	set -euo pipefail; \
	for ref in $$(grep -hoE 'scripts/[-a-z_]+\.sh' $(SCRIPTS) | sort -u); do \
	  test -f "$$ref" || { echo "missing referenced script: $$ref" >&2; exit 1; }; \
	done; \
	echo "all internal script references exist"
	set -euo pipefail; \
	$(PYBIN)/ruff check $(PY) && echo "ruff rules OK"
	set -euo pipefail; \
	$(PYBIN)/ruff format --check $(PY) && echo "ruff format OK"
	set -euo pipefail; \
	$(PYBIN)/mypy && echo "mypy strict OK"
	set -euo pipefail; \
	$(PYBIN)/yamllint $(YAML) && echo "yamllint OK"
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
	    FROM|RUN|COPY|ENTRYPOINT|USER|LABEL|ARG) ;; \
	    *) echo "unknown Containerfile directive: $$kw" >&2; exit 1 ;; \
	  esac; \
	done < <(awk '/^[A-Z]+[[:space:]]/ {print $$1}' Containerfile | sort -u); \
	echo "Containerfile OK"

test: $(PYBIN)/ruff
	bash scripts/test_lib_env.sh
	set -euo pipefail; \
	for t in $(TESTS); do $(PYBIN)/python "$$t"; done

# One suite, for the edit-test loop. `make test` runs all twelve in sequence,
# which is the wrong cost while iterating on a single file. The suite is named
# bare (SUITE=test_run_sh.py) or by path, several at once are fine, and each
# runs through the same interpreter and entry point `make test` uses, so a
# suite that passes here passes in the gate.
test-one: $(PYBIN)/ruff
	@test -n "$(SUITE)" || { \
	  echo "usage: make test-one SUITE=<name>   (e.g. SUITE=test_run_sh.py, SUITE=test_lib_env.sh)" >&2; \
	  exit 2; \
	}
	set -euo pipefail; \
	for s in $(SUITE); do \
	  case "$$s" in \
	    */*) suite="$$s" ;; \
	    *) suite="scripts/$$s" ;; \
	  esac; \
	  test -f "$$suite" || { echo "no such suite: $$suite (see 'make help')" >&2; exit 1; }; \
	  case "$$suite" in \
	    *.sh) echo "== $$suite"; bash "$$suite" ;; \
	    *) echo "== $$suite"; $(PYBIN)/python "$$suite" ;; \
	  esac; \
	done

# Everything .github/workflows/ci.yml runs, in the order it runs it, so the
# full local verification is one command rather than the pair a contributor has
# to know about.
check: lint test

coverage:
	rm -rf coverage
	# Direct exec (not `bash script`): kcov traces the shebang interpreter;
	# through an extra bash layer it produces an empty report.
	kcov --clean --include-pattern=lib-env.sh coverage ./scripts/test_lib_env.sh
	find coverage -name cobertura.xml | head -1 | xargs -I{} cp {} coverage.cobertura.xml
