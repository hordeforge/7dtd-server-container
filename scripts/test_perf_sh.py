#!/usr/bin/env python3
"""Pin the EfficientServer toggle contract of scripts/perf.sh by executing it.

Methodology: perf.sh on|off rewrites mods/EfficientServer/Config/
efficientserver.json with sed and restarts the container; its documented
failure modes are a silent no-op edit (a future mod build reformats the
config) and collateral edits to group-level "Enabled" flags (AiLod/Dynamic
Mesh/Gc/Governor keep their shipped values -- only the top-level flag is
owned here). A sandbox ROOT gets copies of perf.sh + lib-env.sh, a stub
run.sh recording restart invocations, and a fixture config carrying both
top-level and nested "Enabled" flags; then:

  status   reports on/off/missing (missing is reported, not fatal)
  off      rewrites only the top-level flag byte-exactly, leaves every
           nested flag untouched, reports (was <old>), and restarts once
  on       same contract in reverse

Each failed check prints a FAIL line; the process exits nonzero if any failed.
"""

from __future__ import annotations

import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parent

failed_checks: list[str] = []


def check(name: str, cond: bool) -> None:
    if cond:
        print(f"OK: {name}")
    else:
        print(f"FAIL: {name}", file=sys.stderr)
        failed_checks.append(name)


# Top-level flag (2-space indent, comma) plus nested flags at other depths;
# only the first may ever change.
CONFIG_ON = """{
  "Enabled": true,
  "DynamicMesh": {
    "Enabled": true
  },
  "AiLod": {
    "Enabled": false
  }
}
"""
# Anchor on the newline so exactly-2-space indent matches: a plain substring
# replace would also hit the 4-space nested flags.
CONFIG_OFF = CONFIG_ON.replace('\n  "Enabled": true,', '\n  "Enabled": false,', 1)

RUN_STUB = """#!/usr/bin/env bash
printf '%s\\n' "$*" >> "$PERF_STUB_LOG"
"""


def make_sandbox(tmpdir: Path, config: str | None) -> Path:
    scripts = tmpdir / "scripts"
    scripts.mkdir(parents=True)
    shutil.copy2(SCRIPTS / "perf.sh", scripts / "perf.sh")
    shutil.copy2(SCRIPTS / "lib-env.sh", scripts / "lib-env.sh")
    stub = scripts / "run.sh"
    stub.write_text(RUN_STUB)
    stub.chmod(0o755)
    if config is not None:
        cfg = tmpdir / "mods" / "EfficientServer" / "Config"
        cfg.mkdir(parents=True)
        (cfg / "efficientserver.json").write_text(config)
    return tmpdir


def run_perf(args: list[str], root: Path) -> subprocess.CompletedProcess[bytes]:
    return subprocess.run(
        [str(root / "scripts" / "perf.sh"), *args],
        cwd=root,
        env={"PATH": "/usr/bin:/bin", "PERF_STUB_LOG": str(root / "restarts.log")},
        capture_output=True,
        check=False,
        timeout=60,
    )


def cfg_path(root: Path) -> Path:
    return root / "mods" / "EfficientServer" / "Config" / "efficientserver.json"


def expect(name: str, proc: subprocess.CompletedProcess[bytes], stdout: str, rc: int) -> None:
    ok = proc.returncode == rc and stdout in proc.stdout.decode()
    check(f"{name} (rc={proc.returncode}, out={proc.stdout.decode(errors='replace')!r})", ok)


with tempfile.TemporaryDirectory() as tmp:
    # Missing config: status says so without dying.
    root = make_sandbox(Path(tmp) / "missing", None)
    expect(
        "status without a config reports missing",
        run_perf(["status"], root),
        "EfficientServer: missing",
        0,
    )

    # status reads the current state.
    root = make_sandbox(Path(tmp) / "status-on", CONFIG_ON)
    expect("status reports on", run_perf(["status"], root), "EfficientServer: on", 0)

    # off: exact rewrite, nested flags untouched, single restart.
    root = make_sandbox(Path(tmp) / "toggle-off", CONFIG_ON)
    expect("off reports the flip", run_perf(["off"], root), "EfficientServer -> false (was on)", 0)
    check(
        "off rewrote only the top-level Enabled flag",
        cfg_path(root).read_text(encoding="utf-8") == CONFIG_OFF,
    )
    expect("status reflects off", run_perf(["status"], root), "EfficientServer: off", 0)
    check(
        "off restarted the container exactly once",
        (root / "restarts.log").read_text(encoding="utf-8") == "restart\n",
    )

    # on: same contract in reverse.
    expect("on reports the flip", run_perf(["on"], root), "EfficientServer -> true (was off)", 0)
    check(
        "on restored the exact original bytes",
        cfg_path(root).read_text(encoding="utf-8") == CONFIG_ON,
    )

if failed_checks:
    sys.exit(1)
print("perf.sh toggle contract OK")
