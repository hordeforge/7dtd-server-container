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

  status     reports on/off/missing (missing is reported, not fatal)
  off        rewrites only the top-level flag byte-exactly, leaves every
             nested flag untouched, reports (was <old>), and restarts once
  on         same contract in reverse
  negatives  off without a config, and off against a config whose format
             drifted out of the sed's reach, must fatal-exit naming the
             cause and must not restart the container
  measure    against an unreachable console must fatal-exit carrying the
              session's own diagnostics (the connect refusal), not just a
              generic message

Each failed check prints a FAIL line; the process exits nonzero if any failed.
"""

from __future__ import annotations

import os
import shutil
import socket
import subprocess
import sys
import tempfile
from pathlib import Path

from harness import SCRIPTS, check, exit_status


def resolved_bin_path(*bins: str) -> str:
    """A PATH carrying the tools the scripts under test shell out to.

    perf.sh runs through /usr/bin/env bash, so PATH must resolve sed, grep,
    tail, and tr. Resolve those directories from the running host instead of
    assuming a fixed /usr/bin:/bin, which is not where coreutils lives on
    NixOS, a brew-only prefix, or a slim test image.
    """
    dirs: set[Path] = set()
    for binary in bins:
        found = shutil.which(binary)
        if found is None:
            print(f"FAIL: required binary not found on PATH: {binary}", file=sys.stderr)
            sys.exit(1)
        dirs.add(Path(found).parent)
    return os.pathsep.join(str(d) for d in sorted(dirs))


SANDBOX_PATH = resolved_bin_path("bash", "sed", "grep", "tail", "tr", "ls")

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

# Stand-in for BSD sed (macOS): rejects the GNU-only spellings perf.sh must
# not use and normalizes the BSD in-place form onto the local sed, so the real
# edit still lands and only the argument shape is under test. BSD sed has no
# --version and treats the word after -i as a mandatory backup suffix, so
# `sed -i -E ...` misparses there instead of editing in place.
BSD_SED_STUB = """#!/usr/bin/env python3
import os
import sys

real_sed = os.environ["PERF_TEST_REAL_SED"]
if "--version" in sys.argv[1:]:
    sys.exit(1)
kept = []
skip_suffix = False
for i, arg in enumerate(sys.argv[1:]):
    if skip_suffix:
        skip_suffix = False
        continue
    if arg == "-i":
        if i + 1 >= len(sys.argv) - 1 or sys.argv[i + 2].startswith("-"):
            print("sed: BSD sed -i requires a backup suffix", file=sys.stderr)
            sys.exit(1)
        kept.append("-i")
        skip_suffix = True
        continue
    kept.append(arg)
os.execv(real_sed, [real_sed, *kept])
"""


def make_bsd_sed_stub(root: Path) -> Path:
    """Write a BSD sed stand-in into the sandbox; return its bin directory."""
    real_sed = shutil.which("sed")
    assert real_sed is not None
    bindir = root / "bsdbin"
    bindir.mkdir()
    stub = bindir / "sed"
    stub.write_text(BSD_SED_STUB)
    stub.chmod(0o755)
    return bindir


def make_sandbox(tmpdir: Path, config: str | None) -> Path:
    scripts = tmpdir / "scripts"
    scripts.mkdir(parents=True)
    shutil.copy2(SCRIPTS / "perf.sh", scripts / "perf.sh")
    shutil.copy2(SCRIPTS / "lib-env.sh", scripts / "lib-env.sh")
    stub = scripts / "run.sh"
    stub.write_text(RUN_STUB, encoding="utf-8")
    stub.chmod(0o755)
    if config is not None:
        cfg = tmpdir / "mods" / "EfficientServer" / "Config"
        cfg.mkdir(parents=True)
        (cfg / "efficientserver.json").write_text(config, encoding="utf-8")
    return tmpdir


def run_perf(
    args: list[str], root: Path, extra_env: dict[str, str] | None = None
) -> subprocess.CompletedProcess[bytes]:
    return subprocess.run(
        [str(root / "scripts" / "perf.sh"), *args],
        cwd=root,
        env={
            "PATH": SANDBOX_PATH,
            "PERF_STUB_LOG": str(root / "restarts.log"),
            **(extra_env or {}),
        },
        capture_output=True,
        check=False,
        timeout=60,
    )


def cfg_path(root: Path) -> Path:
    return root / "mods" / "EfficientServer" / "Config" / "efficientserver.json"


def expect(name: str, proc: subprocess.CompletedProcess[bytes], stdout: str, rc: int) -> None:
    # These commands print exactly one line, so compare the whole stream: a
    # substring match would accept a duplicated or prefixed line and would not
    # notice a command that started printing more than it should.
    ok = proc.returncode == rc and proc.stdout.decode() == f"{stdout}\n"
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
    check(
        "on restarted the container once more (one restart per flip)",
        (root / "restarts.log").read_text(encoding="utf-8") == "restart\nrestart\n",
    )

    # Same contract under BSD sed (macOS): `sed -i -E` is a GNU spelling, and
    # BSD sed reads -E as the backup suffix, so the toggle would run in BRE
    # mode and litter a `efficientserver.json-E` file in the mod dir. The stub
    # rejects both GNU-only shapes, so only the portable spelling survives.
    root = make_sandbox(Path(tmp) / "bsd-sed", CONFIG_ON)
    bsd_bin = make_bsd_sed_stub(root)
    expect(
        "off flips the flag under BSD sed",
        run_perf(
            ["off"],
            root,
            {
                "PATH": f"{bsd_bin}:/usr/bin:/bin",
                "PERF_TEST_REAL_SED": shutil.which("sed") or "",
            },
        ),
        "EfficientServer -> false (was on)",
        0,
    )
    check(
        "BSD sed rewrote only the top-level Enabled flag",
        cfg_path(root).read_text(encoding="utf-8") == CONFIG_OFF,
    )
    check(
        "BSD sed left no -i backup file behind",
        sorted(p.name for p in cfg_path(root).parent.iterdir()) == ["efficientserver.json"],
    )

    # Negative: off without a config must refuse loudly instead of restarting
    # an unchanged container and reporting success.
    root = make_sandbox(Path(tmp) / "missing-off", None)
    proc = run_perf(["off"], root)
    check(
        "off without a config fatal-exits naming it",
        proc.returncode != 0 and "FATAL" in proc.stderr.decode(errors="replace"),
    )
    check("refused off restarted nothing", not (root / "restarts.log").exists())

    # The documented silent-no-op mode: a future mod build reformats the
    # top-level flag out of the sed's reach (here: deeper indent). The
    # post-edit verify must catch that, fatal-exit, leave the config
    # untouched, and never restart.
    reformatted = CONFIG_ON.replace('\n  "Enabled"', '\n      "Enabled"')
    root = make_sandbox(Path(tmp) / "drifted-off", reformatted)
    proc = run_perf(["off"], root)
    err = proc.stderr.decode(errors="replace")
    check(
        "off on a drifted config fatal-exits naming the format change",
        proc.returncode != 0 and "config format changed" in err,
    )
    check(
        "drifted off left the config byte-exact",
        cfg_path(root).read_text(encoding="utf-8") == reformatted,
    )
    check("drifted off restarted nothing", not (root / "restarts.log").exists())

    # measure against a dead console: the FATAL must carry the session's own
    # captured output (the connect refusal), so the operator sees what
    # actually happened instead of only which step failed.
    root = make_sandbox(Path(tmp) / "measure-dead", CONFIG_ON)
    probe_sock = socket.socket()
    probe_sock.bind(("127.0.0.1", 0))
    dead_port = str(probe_sock.getsockname()[1])
    probe_sock.close()
    proc = run_perf(["measure"], root, {"TELNET_PORT": dead_port})
    err = proc.stderr.decode(errors="replace")
    check("measure against a dead console fatal-exits", proc.returncode != 0 and "FATAL" in err)
    check(
        "measure failure names the port",
        f"port {dead_port}" in err,
    )
    check(
        "measure failure carries the session's diagnostics",
        "connection refused" in err.lower(),
    )

    # CLI surface: help answers before any env load or config access, and a
    # bad invocation is a usage error (exit 2), distinct from the fatal
    # operation failures above.
    root = make_sandbox(Path(tmp) / "cli-help", CONFIG_ON)
    proc = run_perf(["--help"], root)
    check(
        "--help exits 0 on stdout",
        proc.returncode == 0 and b"usage: perf.sh" in proc.stdout and not proc.stderr,
    )
    check("-h answers the same as --help", run_perf(["-h"], root).stdout == proc.stdout)
    # No command word at all defaults to status, so a bare `./perf.sh` reports
    # instead of usage-erroring on the empty word.
    expect("no command defaults to status", run_perf([], root), "EfficientServer: on", 0)
    proc = run_perf(["frobnicate"], root)
    check(
        "unknown command exits 2 with usage on stderr",
        proc.returncode == 2 and b"usage:" in proc.stderr and not proc.stdout,
    )
    # Name the offender, and reject the word before any .env load or value
    # validation so a typo stays a usage error on a broken environment too.
    check("unknown command is named in the error", b"frobnicate" in proc.stderr)
    broken = {"TELNET_PORT": "not-a-port"}
    proc = run_perf(["frobnicate"], root, extra_env=broken)
    check(
        "unknown command exits 2 even with a broken environment",
        proc.returncode == 2 and b"unknown command 'frobnicate'" in proc.stderr,
    )

    # Exactly one command word: a silently ignored second word would read as
    # a supported option while status ran with its plain output.
    proc = run_perf(["status", "--json"], root)
    err = proc.stderr.decode(errors="replace")
    check(
        "extra argument exits 2 naming it",
        proc.returncode == 2 and "--json" in err and "usage:" in err,
    )
    check("the refused invocation restarted nothing", not (root / "restarts.log").exists())

exit_status()
print("perf.sh toggle contract OK")
