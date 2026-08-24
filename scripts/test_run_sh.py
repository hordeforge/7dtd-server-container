#!/usr/bin/env python3
"""Pin the secret-transport contract of scripts/run.sh by executing it.

Methodology: TELNET_PASSWORD and WEBADMIN_PASSWORD must reach the container
through an owner-only env file passed via podman --env-file. Interpolating
them into -e K=V arguments would keep them world-readable in
/proc/<pid>/cmdline for the whole `podman run` (minutes during an
install-only download) and persist them in the container config; lib-env.sh
applies the same argv-versus-environment rule to telnet_session.

Grepping run.sh for the current spelling would pin implementation text, not
behavior: a reformatted leak (`--env 'K=V'`) passes, a harmless refactor
fails. So `start` runs against a podman stub on PATH that records every
invocation's argv and snapshots the secret env file at call time, then:

  transport  podman received --env-file <path>; the snapshot carries both
             secrets byte-exact (interior space survives) with mode 0600
  lifetime   that exact path no longer exists once run.sh exits (EXIT trap)
  argv       no argument of any podman invocation names either secret

Each failed check prints a FAIL line; the process exits nonzero if any failed.
"""

from __future__ import annotations

import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
RUN_SH = ROOT / "scripts" / "run.sh"

failed_checks: list[str] = []


def check(name: str, cond: bool) -> None:
    if cond:
        print(f"OK: {name}")
    else:
        print(f"FAIL: {name}", file=sys.stderr)
        failed_checks.append(name)


# Recording stand-in for podman: append each invocation's argv NUL-separated,
# and snapshot the secret env file (bytes + mode) whenever it is named, since
# run.sh deletes it via its EXIT trap before the test can read it.
PODMAN_STUB = """#!/usr/bin/env python3
import os
import shutil
import sys

argv = sys.argv[1:]
with open(os.environ["STUB_LOG"], "ab") as log:
    log.write(b"\\0".join(a.encode() for a in argv) + b"\\0\\0")
if "--env-file" in argv:
    src = argv[argv.index("--env-file") + 1]
    shutil.copy2(src, os.environ["STUB_SNAPSHOT"])
    mode = oct(os.stat(src).st_mode & 0o777)
    with open(os.environ["STUB_MODE"], "w", encoding="utf-8") as f:
        f.write(mode)
"""

TELNET_PASSWORD = "s3cret-pass"
WEBADMIN_PASSWORD = "pass word 12"  # interior space must survive byte-exact

with tempfile.TemporaryDirectory() as tmp:
    tmpdir = Path(tmp)
    bindir = tmpdir / "bin"
    bindir.mkdir()
    stub = bindir / "podman"
    stub.write_text(PODMAN_STUB)
    stub.chmod(0o755)

    log = tmpdir / "podman-argv.log"
    snapshot = tmpdir / "envfile.snapshot"
    mode_file = tmpdir / "envfile.mode"

    env = os.environ.copy()
    # Explicit values win over any local .env (load_env_file precedence), so
    # the run sees known secrets regardless of host state.
    env.update(
        PATH=f"{bindir}{os.pathsep}{env.get('PATH', '')}",
        STUB_LOG=str(log),
        STUB_SNAPSHOT=str(snapshot),
        STUB_MODE=str(mode_file),
        TELNET_PASSWORD=TELNET_PASSWORD,
        TELNET_PORT="8087",
        WEBADMIN_PASSWORD=WEBADMIN_PASSWORD,
    )

    try:
        proc = subprocess.run(
            [str(RUN_SH), "start"],
            env=env,
            capture_output=True,
            check=False,
            timeout=120,
        )
    except subprocess.TimeoutExpired:
        print("FAIL: run.sh start did not finish within 120s", file=sys.stderr)
        sys.exit(1)
    check("run.sh start exits 0 under the stubbed podman", proc.returncode == 0)
    if proc.returncode != 0:
        print(proc.stderr.decode(errors="replace"), file=sys.stderr)

    invocations = [i for i in log.read_bytes().split(b"\0\0") if i]
    args = [a for inv in invocations for a in inv.split(b"\0")]
    check("podman was invoked", bool(invocations))

    envfile_args = [
        inv.split(b"\0")[i + 1].decode()
        for inv in invocations
        for i, a in enumerate(inv.split(b"\0"))
        if a == b"--env-file"
    ]
    check("podman received --env-file", len(envfile_args) > 0)
    live_envfile = envfile_args[-1] if envfile_args else ""

    expected_snapshot = (
        f"TELNET_PASSWORD={TELNET_PASSWORD}\nWEBADMIN_PASSWORD={WEBADMIN_PASSWORD}\n"
    ).encode()
    got_snapshot = snapshot.read_bytes() if snapshot.exists() else b""
    check(
        "the env file carries both secrets byte-exact",
        got_snapshot == expected_snapshot,
    )
    check(
        "the env file is owner-only (0600) at call time",
        mode_file.read_text(encoding="utf-8") == "0o600",
    )

    leaked = [
        a.decode(errors="replace") for a in args if re.search(rb"(TELNET|WEBADMIN)_PASSWORD=", a)
    ]
    check(
        f"no podman argument carries a secret (found: {leaked})",
        leaked == [],
    )

    # EXIT trap contract, verified on the real path podman was handed.
    check(
        "the secret env file is removed once run.sh exits",
        bool(live_envfile) and not Path(live_envfile).exists(),
    )

if failed_checks:
    sys.exit(1)
print("run.sh secret-transport contract OK")
