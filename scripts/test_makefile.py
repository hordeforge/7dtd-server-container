#!/usr/bin/env python3
"""The task runner a contributor drives: help, single-suite runs, full check.

`make -n` keeps this suite fast and side-effect free: it prints the recipes
make would run without executing any of them, so nothing is installed, no
suite runs twice, and the assertions below are about the runner's shape
rather than about a second copy of what `make test` already covers.
"""

from __future__ import annotations

import re
import subprocess

from harness import ROOT, check, exit_status

MAKEFILE = (ROOT / "Makefile").read_text()


def dry_run(*args: str) -> str:
    """What make would run for these arguments, with no recipe executed."""
    return subprocess.run(
        ["make", "-n", *args],
        cwd=ROOT,
        capture_output=True,
        text=True,
        check=True,
    ).stdout


def phony_targets(text: str) -> set[str]:
    """Every target the Makefile promises never maps to a file."""
    match = re.search(r"^\.PHONY: (.+)$", text, re.MULTILINE)
    return set(match.group(1).split()) if match else set()


phony = phony_targets(MAKEFILE)
check("the Makefile declares its phony targets", bool(phony))
check(
    "a bare make prints the task list instead of running the gate",
    re.search(r"^\.DEFAULT_GOAL := help$", MAKEFILE, re.MULTILINE) is not None,
)

help_text = dry_run("help")
missing = sorted(t for t in phony - {"help"} if f"make {t}" not in help_text)
check("help lists every phony target", not missing)
check("help names the single-suite target with its variable", "SUITE=" in help_text)

python_suite = dry_run("test-one", "SUITE=test_run_sh.py")
# -n prints the recipe without running it, so what is asserted here is the
# resolution and the dispatch, not a second run of the suite.
check(
    "a bare suite name resolves under scripts/ and runs the venv interpreter",
    'suite="scripts/$s"' in python_suite
    and '.venv/bin/python "$suite"' in python_suite
    and 'test -f "$suite"' in python_suite,
)
check(
    "the suite runs directly, not through the whole test target",
    "for t in" not in python_suite and "bash scripts/test_lib_env.sh" not in python_suite,
)

bash_suite = dry_run("test-one", "SUITE=test_lib_env.sh")
check("a .sh suite is run with bash, not with python", 'bash "$suite"' in bash_suite)

check_text = dry_run("check")
check(
    "the full local check runs lint and test, the two CI steps",
    "shellcheck" in check_text and "scripts/test_lib_env.sh" in check_text,
)

check(
    "a missing uv is named before the venv is built",
    "uv not found on PATH" in MAKEFILE,
)
check(
    "a missing shellcheck is named before the lint loop",
    "shellcheck not found on PATH" in MAKEFILE,
)
check(
    "a missing kcov is named before the coverage run",
    "kcov not found on PATH" in MAKEFILE,
)

# The venv is the interpreter the whole gate runs on, so which Python it gets
# is a build property, not a contributor's local state. A .python-version bump
# has to reach the venv, and the venv has to be built for that version rather
# than for whatever python3 happens to be first on PATH.
pyver = (ROOT / ".python-version").read_text(encoding="utf-8").strip()
venv_dry = dry_run("-B", "venv")
check(
    "the venv is rebuilt when the pinned interpreter version changes",
    re.search(r"^\$\(PYBIN\)/ruff: .*\.python-version\s*$", MAKEFILE, re.MULTILINE) is not None,
)
check(
    f"the venv is built for the pinned interpreter ({pyver})",
    f"--python {pyver}" in venv_dry,
)

exit_status()
print("makefile rules OK")
