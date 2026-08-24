#!/usr/bin/env python3
"""Unit tests for the config template / entrypoint.sh render contract.

Methodology: the container renders these templates at boot (render_config,
seed_admin_file) and fatal-exits when any @TOKEN@ survives (assert_rendered),
but that guarantee used to be enforced only inside the running container; a
template token renamed without updating entrypoint.sh passed every local
check and surfaced at deploy time as a game-boot config parse error far from
the cause. Pin the contract here:
  raw          both templates are well-formed XML before rendering
  placeholders each template carries exactly the token set entrypoint.sh
               owns, every token is referenced in entrypoint.sh, and
               entrypoint.sh substitutes no token outside this contract
  rendered     applying entrypoint.sh's substitutions leaves no '@' behind
               and passes scripts/check-config-xml.py (the CI gate)
Each failed check prints a FAIL line; the process exits nonzero if any failed.
"""

from __future__ import annotations

import re
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parent
ROOT = SCRIPTS.parent
CONFIG = ROOT / "config"
CHECK_XML = SCRIPTS / "check-config-xml.py"

# The placeholder set entrypoint.sh renders (sed s|@TOKEN@|value|g), pinned so
# a rename or addition must land here together with both sides of the pair.
EXPECTED: dict[str, set[str]] = {
    "serverconfig.tmpl.xml": {"TELNET_PORT", "TELNET_PASSWORD", "USERDATA_DIR"},
    "serveradmin_seed.xml": {"WEBADMIN_PASSWORD_HASH"},
}
# Lab defaults, matching init_telnet_env and the seed path in entrypoint.sh.
SUBSTITUTIONS: dict[str, str] = {
    "TELNET_PASSWORD": "retest",
    "TELNET_PORT": "8087",
    "USERDATA_DIR": "/root/.local/share/7DaysToDie",
    # Any non-empty stand-in proves rendering, never a real credential.
    "WEBADMIN_PASSWORD_HASH": "KilgoreTrout==",
}

failed_checks: list[str] = []


def check(name: str, cond: bool) -> None:
    if cond:
        print(f"OK: {name}")
    else:
        print(f"FAIL: {name}", file=sys.stderr)
        failed_checks.append(name)


def placeholders(text: str) -> set[str]:
    return set(re.findall(r"@([A-Z_][A-Z0-9_]*)@", text))


entrypoint_src = (ROOT / "entrypoint.sh").read_text(encoding="utf-8")
# Whole-line comments are prose (one says "@TOKEN@" generically); scan only
# executable lines so the token set stays substitution-site truth.
entrypoint_code = "\n".join(
    line for line in entrypoint_src.splitlines() if not line.lstrip().startswith("#")
)

for tmpl_name, expected_tokens in sorted(EXPECTED.items()):
    tmpl_path = CONFIG / tmpl_name
    text = tmpl_path.read_text(encoding="utf-8")
    actual = placeholders(text)
    check(
        f"{tmpl_name} carries exactly the owned placeholders",
        actual == expected_tokens,
    )
    check(
        f"{tmpl_name} tokens referenced in entrypoint.sh",
        all(f"@{token}@" in entrypoint_code for token in expected_tokens),
    )

    try:
        ET.fromstring(text)
        parses = True
    except ET.ParseError:
        parses = False
    check(f"{tmpl_name} is well-formed XML", parses)

    rendered = text
    for token, value in SUBSTITUTIONS.items():
        rendered = rendered.replace(f"@{token}@", value)

    with tempfile.TemporaryDirectory() as tmp:
        out = Path(tmp) / tmpl_name
        out.write_text(rendered)
        r = subprocess.run(
            [sys.executable, str(CHECK_XML), str(out)],
            capture_output=True,
            check=False,
        )
        check(f"rendered {tmpl_name} passes check-config-xml.py", r.returncode == 0)
    check(f"no unrendered '@' survives in {tmpl_name}", "@" not in rendered)

check(
    "entrypoint.sh substitutes nothing outside the contract",
    placeholders(entrypoint_code) == set().union(*EXPECTED.values()),
)

if failed_checks:
    sys.exit(1)
print("config template render contract OK")
