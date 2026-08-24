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

The env file's resource lifecycle gets the same treatment on real paths:

  signals    SIGINT into a start wedged inside podman ends run.sh with 130
             and still removes the file (bash skips EXIT traps when killed
             by an untrapped signal, so dedicated INT/TERM/HUP handlers
             route the cleanup)
  orphans    a file stranded by a SIGKILLed previous run is swept by the
             next start (owner PID embedded in the name); a live owner's
             file survives, and the freshly created name carries the PID

Each failed check prints a FAIL line; the process exits nonzero if any failed.
"""

from __future__ import annotations

import glob
import os
import re
import signal
import subprocess
import sys
import tempfile
import time
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
# run.sh deletes it via its EXIT trap before the test can read it. `ps`
# subcommands print $STUB_PS_OUTPUT verbatim, so tests can simulate a running
# container (default: nothing is running).
PODMAN_STUB = """#!/usr/bin/env python3
import os
import shutil
import sys

argv = sys.argv[1:]
with open(os.environ["STUB_LOG"], "ab") as log:
    log.write(b"\\0".join(a.encode() for a in argv) + b"\\0\\0")
if "ps" in argv:
    sys.stdout.write(os.environ.get("STUB_PS_OUTPUT", ""))
if "--env-file" in argv:
    src = argv[argv.index("--env-file") + 1]
    shutil.copy2(src, os.environ["STUB_SNAPSHOT"])
    mode = oct(os.stat(src).st_mode & 0o777)
    with open(os.environ["STUB_MODE"], "w", encoding="utf-8") as f:
        f.write(mode)
"""

TELNET_PASSWORD = "s3cret-pass"
WEBADMIN_PASSWORD = "pass word 12"  # interior space must survive byte-exact
NAME = "7dtd-server"  # run.sh's default SEVENDTD_CONTAINER_NAME

# Same recorder, but `podman run` blocks long enough for the signal-path test
# to interrupt run.sh while the env file exists and cleanup is still pending.
BLOCKING_PODMAN_STUB = """#!/usr/bin/env python3
import os
import shutil
import sys
import time

argv = sys.argv[1:]
with open(os.environ["STUB_LOG"], "ab") as log:
    log.write(b"\\0".join(a.encode() for a in argv) + b"\\0\\0")
if "ps" in argv:
    sys.stdout.write(os.environ.get("STUB_PS_OUTPUT", ""))
if "--env-file" in argv:
    src = argv[argv.index("--env-file") + 1]
    shutil.copy2(src, os.environ["STUB_SNAPSHOT"])
    mode = oct(os.stat(src).st_mode & 0o777)
    with open(os.environ["STUB_MODE"], "w", encoding="utf-8") as f:
        f.write(mode)
if "run" in argv:
    time.sleep(30)
"""

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

# install-only contract, exercised the same way (real run.sh, stubbed podman):
#   overlap    steamcmd rewrites data/game in place, so a pre-warm while the
#              server container runs must refuse before touching anything
#   force      install-only must download/validate then exit: STEAMCMD_ONLY is
#              forced to 1 even when the environment says 0, and the pre-warm
#              uses its own --rm container name
with tempfile.TemporaryDirectory() as tmp:
    tmpdir = Path(tmp)
    bindir = tmpdir / "bin"
    bindir.mkdir()
    stub = bindir / "podman"
    stub.write_text(PODMAN_STUB)
    stub.chmod(0o755)
    log = tmpdir / "podman-argv.log"

    base_env = {
        **os.environ,
        "PATH": f"{bindir}{os.pathsep}{os.environ.get('PATH', '')}",
        "STUB_LOG": str(log),
        # The snapshot/mode hooks exist for the start-path test above; the
        # install-only runs still need them so the stub can record env files.
        "STUB_SNAPSHOT": str(tmpdir / "envfile.snapshot"),
        "STUB_MODE": str(tmpdir / "envfile.mode"),
        "TELNET_PASSWORD": TELNET_PASSWORD,
        "TELNET_PORT": "8087",
        # The value a fast-restart .env would carry; the forced 1 must win.
        "STEAMCMD_ONLY": "0",
    }

    def run_install(extra_env: dict[str, str]) -> subprocess.CompletedProcess[bytes]:
        log.write_bytes(b"")
        return subprocess.run(
            [str(RUN_SH), "install-only"],
            env={**base_env, **extra_env},
            capture_output=True,
            check=False,
            timeout=120,
        )

    blocked = run_install({"STUB_PS_OUTPUT": f"{NAME}\n"})
    check(
        "install-only refuses while the server container is running",
        blocked.returncode != 0 and "FATAL" in blocked.stderr.decode(errors="replace"),
    )
    check(
        "the refused install-only started no container",
        b"--env-file" not in log.read_bytes(),
    )

    allowed = run_install({})
    check(
        "install-only proceeds when nothing is running",
        allowed.returncode == 0,
    )
    if allowed.returncode != 0:
        print(allowed.stderr.decode(errors="replace"), file=sys.stderr)
    invocations = [i for i in log.read_bytes().split(b"\0\0") if i]
    tokens = [t for inv in invocations for t in inv.split(b"\0")]
    check(
        "pre-warm forces STEAMCMD_ONLY=1 despite the environment's 0",
        b"STEAMCMD_ONLY=1" in tokens,
    )
    check("no podman argument carries STEAMCMD_ONLY=0", b"STEAMCMD_ONLY=0" not in tokens)
    check(
        "pre-warm runs under the dedicated -install name",
        f"{NAME}-install".encode() in tokens,
    )
    check("the pre-warm container is disposable (--rm)", b"--rm" in tokens)

# Signal-path cleanup: run.sh wedged inside the blocking podman stub while the
# secret env file exists, interrupted the way a Ctrl-C does (SIGINT to the
# whole foreground process group). The untrapped-signal death would strand the
# file; the INT handler must route through the EXIT cleanup and exit 130.
with tempfile.TemporaryDirectory() as tmp:
    tmpdir = Path(tmp)
    bindir = tmpdir / "bin"
    bindir.mkdir()
    stub = bindir / "podman"
    stub.write_text(BLOCKING_PODMAN_STUB)
    stub.chmod(0o755)
    log = tmpdir / "podman-argv.log"

    env = {
        **os.environ,
        "PATH": f"{bindir}{os.pathsep}{os.environ.get('PATH', '')}",
        "STUB_LOG": str(log),
        # The blocking stub snapshots env files like PODMAN_STUB does; without
        # these it would die on the run invocation instead of wedging.
        "STUB_SNAPSHOT": str(tmpdir / "envfile.snapshot"),
        "STUB_MODE": str(tmpdir / "envfile.mode"),
        # Keep mktemp's output inside this sandbox so assertions and the
        # sweep's glob stay local to it (run.sh honors TMPDIR).
        "TMPDIR": str(tmpdir),
        "TELNET_PASSWORD": TELNET_PASSWORD,
        "TELNET_PORT": "8087",
    }
    sig_proc = subprocess.Popen(
        [str(RUN_SH), "start"],
        env=env,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        start_new_session=True,  # its own process group, as a foreground Ctrl-C target
    )
    deadline = time.monotonic() + 30
    while time.monotonic() < deadline:
        if glob.glob(str(tmpdir / "7dtd-container-env.*")):
            break
        if sig_proc.poll() is not None:
            break
        time.sleep(0.05)
    check("wedged start reached env-file acquisition", sig_proc.poll() is None)
    os.killpg(sig_proc.pid, signal.SIGINT)
    rc = sig_proc.wait(timeout=30)

    invocations = [i for i in log.read_bytes().split(b"\0\0") if i]
    sig_envfiles = [
        inv.split(b"\0")[i + 1].decode()
        for inv in invocations
        for i, a in enumerate(inv.split(b"\0"))
        if a == b"--env-file"
    ]
    check("SIGINT mid-start ends run.sh with 130", rc == 130)
    check(
        "SIGINT mid-start removed the secret env file",
        bool(sig_envfiles) and not Path(sig_envfiles[-1]).exists(),
    )

# Orphan sweep: files stranded by a SIGKILLed previous run must be reclaimed
# by the next start, keyed on the owner PID embedded in their names, while a
# live owner's file is never touched.
with tempfile.TemporaryDirectory() as tmp:
    tmpdir = Path(tmp)
    bindir = tmpdir / "bin"
    bindir.mkdir()
    stub = bindir / "podman"
    stub.write_text(PODMAN_STUB)
    stub.chmod(0o755)
    log = tmpdir / "podman-argv.log"

    dead = subprocess.Popen(["true"])
    dead.wait()  # reaped: dead.pid is a gone owner
    orphan = tmpdir / f"7dtd-container-env.{dead.pid}.stale"
    orphan.write_bytes(b"TELNET_PASSWORD=stale\n")
    live = tmpdir / f"7dtd-container-env.{os.getpid()}.live"
    live.write_bytes(b"TELNET_PASSWORD=live\n")

    env = {
        **os.environ,
        "PATH": f"{bindir}{os.pathsep}{os.environ.get('PATH', '')}",
        "STUB_LOG": str(log),
        "STUB_SNAPSHOT": str(tmpdir / "envfile.snapshot"),
        "STUB_MODE": str(tmpdir / "envfile.mode"),
        "TMPDIR": str(tmpdir),
        "TELNET_PASSWORD": TELNET_PASSWORD,
        "TELNET_PORT": "8087",
    }
    sweep_proc = subprocess.Popen(
        [str(RUN_SH), "start"],
        env=env,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    _, sweep_err = sweep_proc.communicate(timeout=120)
    check("start with orphans exits 0", sweep_proc.returncode == 0)
    if sweep_proc.returncode != 0:
        print(sweep_err.decode(errors="replace"), file=sys.stderr)
    check("the orphaned secret file was swept", not orphan.exists())
    check(
        "a live owner's secret file is left alone",
        live.exists() and live.read_bytes() == b"TELNET_PASSWORD=live\n",
    )

    invocations = [i for i in log.read_bytes().split(b"\0\0") if i]
    envfile_args = [
        inv.split(b"\0")[i + 1].decode()
        for inv in invocations
        for i, a in enumerate(inv.split(b"\0"))
        if a == b"--env-file"
    ]
    name = Path(envfile_args[-1]).name if envfile_args else ""
    check(
        "the fresh env file name carries the owning PID (sweep contract)",
        bool(re.fullmatch(rf"7dtd-container-env\.{sweep_proc.pid}\.[A-Za-z0-9_]+", name)),
    )

if failed_checks:
    sys.exit(1)
print("run.sh secret-transport contract OK")
