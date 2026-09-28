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
               owns, every token has a sed substitution in entrypoint.sh,
               and entrypoint.sh substitutes no token outside this contract
  rendered     re-rendering through the sed expressions read out of
               entrypoint.sh leaves no '@' behind, carries the substituted
               values, and passes scripts/check-config-xml.py (the CI gate)
  no ids       the committed admin seed carries no platform user id, and the
               seeded webuser holds a name and a password and nothing else
Each failed check prints a FAIL line; the process exits nonzero if any failed.
"""

from __future__ import annotations

import re
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET
from pathlib import Path

from harness import ROOT, SCRIPTS, check, exit_status

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
# The values the sed expressions read, keyed by shell variable name. seed_admin
# derives its hash into `b64` before rendering, so that variable is named
# separately from the token it fills.
EXPR_VALUES: dict[str, str] = {
    "TELNET_PASSWORD": SUBSTITUTIONS["TELNET_PASSWORD"],
    "TELNET_PORT": SUBSTITUTIONS["TELNET_PORT"],
    "USERDATA_DIR": SUBSTITUTIONS["USERDATA_DIR"],
    "b64": SUBSTITUTIONS["WEBADMIN_PASSWORD_HASH"],
}

# Attributes in the admin seed that hold a platform account identifier, and so
# identify a person. Kept in one place so adding a new element type is one
# line here, not a hunt through the template.
ID_ATTRS = ("userid", "steamID", "crossuserid")


def placeholders(text: str) -> set[str]:
    return set(re.findall(r"@([A-Z_][A-Z0-9_]*)@", text))


# The substitutions entrypoint.sh really runs, read out of its own sed
# arguments. Re-rendering these (instead of a Python str.replace) is the point:
# a dropped -e, a typo in the token, or a missing g in the real pipeline would
# leave a token behind or render the wrong value, and only the real expressions
# can see that.
SED_EXPR = re.compile(r'-e "s\|@([A-Z_][A-Z0-9_]*)\@\|\$\{([A-Za-z_][A-Za-z0-9_]*)\}\|g"')

entrypoint_src = (ROOT / "entrypoint.sh").read_text(encoding="utf-8")
# Whole-line comments are prose (one says "@TOKEN@" generically); scan only
# executable lines so the token set stays substitution-site truth.
entrypoint_code = "\n".join(
    line for line in entrypoint_src.splitlines() if not line.lstrip().startswith("#")
)
SED_SUBSTITUTIONS: dict[str, str] = dict(SED_EXPR.findall(entrypoint_code))


def render_with_entrypoint_sed(text: str) -> str | None:
    """Run the entrypoint's own sed expressions over a template."""
    args = [
        "sed",
        *(
            arg
            for token, var in SED_SUBSTITUTIONS.items()
            for arg in ("-e", f"s|@{token}@|{EXPR_VALUES[var]}|g")
        ),
    ]
    r = subprocess.run(args, input=text, capture_output=True, text=True, check=False)
    return r.stdout if r.returncode == 0 else None


for tmpl_name, expected_tokens in sorted(EXPECTED.items()):
    tmpl_path = CONFIG / tmpl_name
    text = tmpl_path.read_text(encoding="utf-8")
    actual = placeholders(text)
    check(
        f"{tmpl_name} carries exactly the owned placeholders",
        actual == expected_tokens,
    )
    check(
        f"{tmpl_name} tokens are substituted by entrypoint.sh's sed",
        expected_tokens <= set(SED_SUBSTITUTIONS),
    )

    try:
        ET.fromstring(text)
        parses = True
    except ET.ParseError:
        parses = False
    check(f"{tmpl_name} is well-formed XML", parses)

    rendered = render_with_entrypoint_sed(text)
    check(f"{tmpl_name} renders through entrypoint.sh's sed", rendered is not None)

    with tempfile.TemporaryDirectory() as tmp:
        out = Path(tmp) / tmpl_name
        out.write_text(rendered if rendered is not None else "")
        r = subprocess.run(
            [sys.executable, str(CHECK_XML), str(out)],
            capture_output=True,
            check=False,
        )
        check(f"rendered {tmpl_name} passes check-config-xml.py", r.returncode == 0)
    check(
        f"no unrendered '@' survives in {tmpl_name}",
        rendered is not None and "@" not in rendered,
    )
    # The rendered values, not just the absence of "@": a substitution wired to
    # the wrong variable renders cleanly and still ships the wrong port.
    check(
        f"rendered {tmpl_name} carries the substituted values",
        rendered is not None and all(SUBSTITUTIONS[token] in rendered for token in expected_tokens),
    )

check(
    "entrypoint.sh substitutes nothing outside the contract",
    set(SED_SUBSTITUTIONS) == set().union(*EXPECTED.values()),
)

# A tracked file outlives the host it was cloned on and reaches every reader
# of the repo, so the seed may not carry an individual's platform identifier:
# a SteamID64 resolves to a Steam profile and an EOS id links the same person
# across services. Each host owns that identity in its own
# Saves/serveradmin.xml. The stock TFP examples stay put: they sit in
# comments, which ET drops, and a real id would come back as an element
# attribute.
seed_root = ET.fromstring((CONFIG / "serveradmin_seed.xml").read_text(encoding="utf-8"))
committed_ids = [
    f"{el.tag}[{attr}={el.get(attr)!r}]"
    for el in seed_root.iter()
    for attr in ID_ATTRS
    if el.get(attr)
]
check(
    "serveradmin_seed.xml commits no platform user id"
    + (f": {', '.join(committed_ids)}" if committed_ids else ""),
    not committed_ids,
)

# The seeded webuser authenticates by password alone, so it carries a name
# and a pass and nothing else; a platform attribute here is where a personal
# id sneaks back in.
webusers = seed_root.find("webusers")
seeded_users = [] if webusers is None else list(webusers)
check(
    "seeded webuser carries no platform attributes",
    all(set(u.attrib) == {"name", "pass"} for u in seeded_users if u.tag == "user"),
)

exit_status()
print("config template render contract OK")
