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

stop() is the world-save path, so its three shapes run against the same
stub plus the real fake telnet endpoint:

  graceful   container running + telnet answering: password + `shutdown`
             reach the wire byte-exact and podman sees ps -> wait -> stop
  fallback   container running + telnet dead: the same wait -> stop tail
             still runs (never skip the stop because the console is down)
  idle       nothing running: a bare no-op that never creates a secret
             env file (stop must not call make_common)

start() must not report success for a boot that died instantly (`run -d`
returns before the entrypoint can fail), so the post-start smoke check is
pinned too: with the stub reporting nothing running, start exits nonzero
after dumping the log tail instead of printing the green line.

backup() archives data/userdata/Saves into backups/ and keeps the newest
few archives; its contract runs against a sandboxed copy of the tree:

  stopped    plain tar.gz of the planted saves, owner-only mode, pruning
             down to KEEP_BACKUPS newest archives
  running    telnet answers: password + `saveworld` reach the wire first
  live-warn  container running + telnet dead: warns and still archives
  fresh      no saves yet: a loud refusal, not an empty archive

restore() is the other half of it, so it runs against the same sandbox:
newest-by-default and explicit-archive selection, a pre-restore snapshot of
the replaced saves, and loud refusals (running server, no archives, corrupt
or payload-free archive) that leave data/userdata untouched. A second bare
restore re-applies the same archive rather than its own pre-restore snapshot,
which is what a retried recovery produces.

build is the artifact command: podman stamps layer mtimes with the wall-clock
time unless --timestamp says otherwise, so the build forwards SOURCE_DATE_EPOCH
as --timestamp and rejects a malformed value before podman runs.

Each failed check prints a FAIL line; the process exits nonzero if any failed.
"""

from __future__ import annotations

import contextlib
import datetime
import fcntl
import io
import os
import re
import shutil
import signal
import socket
import subprocess
import sys
import tarfile
import tempfile
import time
from collections.abc import Iterator
from pathlib import Path

from harness import ROOT, SCRIPTS, check, exit_status

RUN_SH = SCRIPTS / "run.sh"


def install_podman_stub(root: Path, stub_text: str) -> Path:
    """Write stub_text as an executable <root>/bin/podman; return the bin dir."""
    bindir = root / "bin"
    bindir.mkdir()
    stub = bindir / "podman"
    stub.write_text(stub_text, encoding="utf-8")
    stub.chmod(0o755)
    return bindir


def stub_invocations(log: Path) -> list[list[bytes]]:
    """Split the stub's log into one argv list per podman invocation."""
    return [rec.split(b"\0") for rec in log.read_bytes().split(b"\0\0") if rec]


def parse_backup_stamp(name: str) -> datetime.datetime | None:
    """An archive name's stamp as UTC, or None when the name is not one."""
    with contextlib.suppress(ValueError):
        return datetime.datetime.strptime(name, "%Y%m%d-%H%M%S").replace(
            tzinfo=datetime.timezone.utc
        )
    return None


def envfile_paths(records: list[list[bytes]]) -> list[str]:
    """Paths passed to --env-file across invocations, in order."""
    return [
        rec[i + 1].decode("utf-8")
        for rec in records
        for i, arg in enumerate(rec)
        if arg == b"--env-file"
    ]


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
    log.write(b"\\0".join(a.encode("utf-8") for a in argv) + b"\\0\\0")
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
BLOCKING_PODMAN_STUB = (
    PODMAN_STUB.replace("import sys\n", "import sys\nimport time\n")
    + 'if "run" in argv:\n    time.sleep(30)\n'
)


def stub_env(tmpdir: Path, **extra: str) -> dict[str, str]:
    """Environment for run.sh under the stubbed podman: the stub's recording
    hooks (always present so every scenario can snapshot env files), explicit
    telnet values that win over any local .env, and scenario extras last."""
    return {
        **os.environ,
        "PATH": f"{tmpdir / 'bin'}{os.pathsep}{os.environ.get('PATH', '')}",
        "STUB_LOG": str(tmpdir / "podman-argv.log"),
        "STUB_SNAPSHOT": str(tmpdir / "envfile.snapshot"),
        "STUB_MODE": str(tmpdir / "envfile.mode"),
        "TELNET_PASSWORD": TELNET_PASSWORD,
        # A closed port, not the real 8087: scenarios that do not stage a
        # telnet endpoint must fail their probe instantly instead of poking
        # whatever happens to listen on the default port on this host.
        "TELNET_PORT": closed_ephemeral_port(),
        **extra,
    }


def closed_ephemeral_port() -> str:
    """Bind an ephemeral port, close it, return the number: connects refuse."""
    sock = socket.socket()
    sock.bind(("127.0.0.1", 0))
    port = str(sock.getsockname()[1])
    sock.close()
    return port


def make_sandbox(tmpdir: Path) -> Path:
    """Copy run.sh and its lib into a sandbox tree so its ROOT (derived from
    the script location) points there: backup writes archives and reads
    data/userdata under the sandbox, never in the real checkout."""
    scripts = tmpdir / "scripts"
    scripts.mkdir()
    shutil.copy2(RUN_SH, scripts / "run.sh")
    shutil.copy2(SCRIPTS / "lib-env.sh", scripts / "lib-env.sh")
    (scripts / "run.sh").chmod(0o755)
    return tmpdir


with tempfile.TemporaryDirectory() as tmp:
    tmpdir = Path(tmp)
    install_podman_stub(tmpdir, PODMAN_STUB)

    log = tmpdir / "podman-argv.log"
    snapshot = tmpdir / "envfile.snapshot"
    mode_file = tmpdir / "envfile.mode"

    # Explicit values win over any local .env (load_env_file precedence), so
    # the run sees known secrets regardless of host state. STUB_PS_OUTPUT
    # reports the container as running so the post-start smoke check passes.
    env = stub_env(
        tmpdir,
        WEBADMIN_PASSWORD=WEBADMIN_PASSWORD,
        STUB_PS_OUTPUT=f"{NAME}\n",
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

    invocations = stub_invocations(log)
    args = [a for rec in invocations for a in rec]
    check("podman was invoked", bool(invocations))

    # Liveness for a server process that is up but no longer serving (a wedged
    # world load never exits the game). The probe must go through the lib the
    # image ships, not a second hardcoded port, and the boot that steamcmd
    # installs a depot before the game listens must sit inside the start
    # period.
    run_args = [a for rec in invocations if rec[:1] == [b"run"] for a in rec]
    run_args_text = b" ".join(run_args).decode("utf-8")
    check(
        "start passes a health probe that calls the shipped lib",
        "--health-cmd" in run_args_text and "health_check" in run_args_text,
    )
    check(
        "the health start period covers the depot download",
        "--health-start-period" in run_args_text,
    )
    # The game and steamcmd run as container root by design, so the flag that
    # keeps them from gaining anything more is the point: nothing in the image
    # is setuid, and the quadlet unit passes the same one.
    check(
        "start runs the container with no-new-privileges",
        "--security-opt no-new-privileges" in run_args_text,
    )

    envfile_args = envfile_paths(invocations)
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
    install_podman_stub(tmpdir, PODMAN_STUB)
    log = tmpdir / "podman-argv.log"

    base_env = stub_env(
        tmpdir,
        # The value a fast-restart .env would carry; the forced 1 must win.
        STEAMCMD_ONLY="0",
    )

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
    invocations = stub_invocations(log)
    tokens = [a for rec in invocations for a in rec]
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
    install_podman_stub(tmpdir, BLOCKING_PODMAN_STUB)
    log = tmpdir / "podman-argv.log"

    # Keep mktemp's output inside this sandbox so assertions and the
    # sweep's glob stay local to it (run.sh honors TMPDIR).
    env = stub_env(tmpdir, TMPDIR=str(tmpdir))
    sig_proc = subprocess.Popen(
        [str(RUN_SH), "start"],
        env=env,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        start_new_session=True,  # its own process group, as a foreground Ctrl-C target
    )
    # SIGINT only once the stub has recorded --env-file: killing on the env
    # file's mere existence can land before the stub's first log write, which
    # would leave the deletion assert below with no recorded path to check.
    deadline = time.monotonic() + 30
    while time.monotonic() < deadline:
        if log.exists() and b"--env-file" in log.read_bytes():
            break
        if sig_proc.poll() is not None:
            break
        time.sleep(0.05)
    check("wedged start reached env-file acquisition", sig_proc.poll() is None)
    os.killpg(sig_proc.pid, signal.SIGINT)
    rc = sig_proc.wait(timeout=30)

    invocations = stub_invocations(log)
    sig_envfiles = envfile_paths(invocations)
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
    install_podman_stub(tmpdir, PODMAN_STUB)
    log = tmpdir / "podman-argv.log"

    dead = subprocess.Popen(["true"])
    dead.wait()  # reaped: dead.pid is a gone owner
    orphan = tmpdir / f"7dtd-container-env.{dead.pid}.stale"
    orphan.write_bytes(b"TELNET_PASSWORD=stale\n")
    live = tmpdir / f"7dtd-container-env.{os.getpid()}.live"
    live.write_bytes(b"TELNET_PASSWORD=live\n")

    env = stub_env(tmpdir, TMPDIR=str(tmpdir), STUB_PS_OUTPUT=f"{NAME}\n")
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

    invocations = stub_invocations(log)
    envfile_args = envfile_paths(invocations)
    name = Path(envfile_args[-1]).name if envfile_args else ""
    check(
        "the fresh env file name carries the owning PID (sweep contract)",
        bool(re.fullmatch(rf"7dtd-container-env\.{sweep_proc.pid}\.[A-Za-z0-9_]+", name)),
    )


# Graceful stop against a live telnet endpoint: the shutdown request is the
# only thing standing between a running game and a forced stop without a
# world save, so the wire bytes and the podman verb sequence are pinned here.
@contextlib.contextmanager
def start_fake_telnet(output: Path) -> Iterator[str]:
    """Run fake-telnet-server.py on an ephemeral port, yielding the port.

    The process is reaped and its stdout pipe closed on every exit from the
    block, including a failing check: a reader fd left open pins the endpoint
    process's output, and an unreaped one keeps the server alive past the case
    that started it.
    """
    proc = subprocess.Popen(
        [sys.executable, str(SCRIPTS / "fake-telnet-server.py"), "0", str(output)],
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
    )
    assert proc.stdout is not None
    try:
        yield proc.stdout.readline().decode("utf-8").strip()
    finally:
        proc.kill()
        proc.wait()
        proc.stdout.close()


with tempfile.TemporaryDirectory() as tmp:
    tmpdir = Path(tmp)
    install_podman_stub(tmpdir, PODMAN_STUB)
    log = tmpdir / "podman-argv.log"
    wire = tmpdir / "wire.bin"
    with start_fake_telnet(wire) as port:
        check("fake telnet endpoint reported a port", port.isdigit())
        env = stub_env(tmpdir, STUB_PS_OUTPUT=f"{NAME}\n", TELNET_PORT=port)
        proc = subprocess.run(
            [str(RUN_SH), "stop"],
            env=env,
            capture_output=True,
            check=False,
            timeout=120,
        )
    check("graceful stop exits 0", proc.returncode == 0)
    if proc.returncode != 0:
        print(proc.stderr.decode(errors="replace"), file=sys.stderr)
    check(
        "graceful stop sent password + shutdown over telnet",
        wire.read_bytes() == f"{TELNET_PASSWORD}\nshutdown\n".encode(),
    )
    verbs = [rec[0] for rec in stub_invocations(log) if rec]
    check("graceful stop drives podman ps -> wait -> stop", verbs == [b"ps", b"wait", b"stop"])
    check("stop never writes the secret env file", b"--env-file" not in log.read_bytes())

# Telnet unreachable mid-stop: the forced-stop fallback must still drive the
# same wait -> stop tail and exit 0; skipping the stop because the console is
# down would leave the container running (or kill it without a save).
with tempfile.TemporaryDirectory() as tmp:
    tmpdir = Path(tmp)
    install_podman_stub(tmpdir, PODMAN_STUB)
    log = tmpdir / "podman-argv.log"
    # A just-bound-then-closed ephemeral port: connect gets refused now.
    probe_sock = socket.socket()
    probe_sock.bind(("127.0.0.1", 0))
    dead_port = str(probe_sock.getsockname()[1])
    probe_sock.close()
    env = stub_env(tmpdir, STUB_PS_OUTPUT=f"{NAME}\n", TELNET_PORT=dead_port)
    proc = subprocess.run(
        [str(RUN_SH), "stop"],
        env=env,
        capture_output=True,
        check=False,
        timeout=120,
    )
    out = proc.stdout + proc.stderr
    check("stop with dead telnet exits 0", proc.returncode == 0)
    check(
        "dead-telnet stop names its fallback",
        b"not reachable" in out or b"forcing stop" in out,
    )
    verbs = [rec[0] for rec in stub_invocations(log) if rec]
    check("forced-stop fallback still drives wait -> stop", verbs == [b"ps", b"wait", b"stop"])

# Nothing running: stop must be a fast no-op -- only the state probe plus the
# idempotent final stop -- and never create a secret env file.
with tempfile.TemporaryDirectory() as tmp:
    tmpdir = Path(tmp)
    install_podman_stub(tmpdir, PODMAN_STUB)
    log = tmpdir / "podman-argv.log"
    env = stub_env(tmpdir, STUB_PS_OUTPUT="")
    proc = subprocess.run(
        [str(RUN_SH), "stop"],
        env=env,
        capture_output=True,
        check=False,
        timeout=120,
    )
    check("stop with nothing running exits 0", proc.returncode == 0)
    if proc.returncode != 0:
        print(proc.stderr.decode(errors="replace"), file=sys.stderr)
    verbs = [rec[0] for rec in stub_invocations(log) if rec]
    check("idle stop only probes state then stops", verbs == [b"ps", b"stop"])
    check("idle stop never writes the secret env file", b"--env-file" not in log.read_bytes())

# Post-start smoke check: with the stub reporting nothing running, start must
# fail loudly after dumping the log tail instead of printing the success line
# (`podman run -d` returns before the entrypoint can fail).
with tempfile.TemporaryDirectory() as tmp:
    tmpdir = Path(tmp)
    install_podman_stub(tmpdir, PODMAN_STUB)
    env = stub_env(tmpdir, WEBADMIN_PASSWORD=WEBADMIN_PASSWORD)  # nothing running
    proc = subprocess.run(
        [str(RUN_SH), "start"],
        env=env,
        capture_output=True,
        check=False,
        timeout=120,
    )
    out = proc.stdout + proc.stderr
    check("start with an instantly-dead container exits nonzero", proc.returncode != 0)
    check(
        "the failed start names its cause",
        b"FATAL" in out and b"not running right after start" in out,
    )
    verbs = [rec[0] for rec in stub_invocations(tmpdir / "podman-argv.log") if rec]
    check("the failed start dumps the container log tail", verbs[-1:] == [b"logs"])
    sig_envfiles = envfile_paths(stub_invocations(tmpdir / "podman-argv.log"))
    check(
        "the failed start still removed the secret env file",
        bool(sig_envfiles) and all(not Path(p).exists() for p in sig_envfiles),
    )


# backup(): archive + prune against a sandboxed tree, nothing running.
with tempfile.TemporaryDirectory() as tmp:
    tmpdir = Path(tmp)
    make_sandbox(tmpdir)
    install_podman_stub(tmpdir, PODMAN_STUB)
    saves = tmpdir / "data" / "userdata" / "Saves"
    (saves / "region").mkdir(parents=True)
    (saves / "region" / "r.0.0.region").write_bytes(b"chunkdata")
    backups = tmpdir / "backups"
    backups.mkdir()
    for i in range(9):
        (backups / f"7dtd-saves-2020010{i}-000000.tar.gz").write_bytes(b"old")
    env = stub_env(tmpdir)
    proc = subprocess.run(
        [str(tmpdir / "scripts" / "run.sh"), "backup"],
        env=env,
        capture_output=True,
        check=False,
        timeout=120,
    )
    check("backup with nothing running exits 0", proc.returncode == 0)
    if proc.returncode != 0:
        print(proc.stderr.decode(errors="replace"), file=sys.stderr)
    remaining = sorted(backups.glob("7dtd-saves-*.tar.gz"))
    check("backup prunes to KEEP_BACKUPS newest archives", len(remaining) == 7)
    fresh = [p for p in remaining if p.name > "7dtd-saves-20200109-000000.tar.gz"]
    check("backup wrote exactly one fresh archive", len(fresh) == 1)
    if fresh:
        check(
            "the fresh archive is owner-only (0600)",
            oct(fresh[0].stat().st_mode & 0o777) == "0o600",
        )
        with tarfile.open(fresh[0]) as tf:
            names = tf.getnames()
        check(
            "the fresh archive contains the planted save",
            "Saves/region/r.0.0.region" in names,
        )
    # The archives are owner-only files, but the directory holding them, and the
    # data/ trees the archives copy from, are what another local account can
    # still traverse and read.
    dir_modes = {
        p: oct(p.stat().st_mode & 0o777)
        for p in (backups, tmpdir / "data" / "userdata", tmpdir / "data" / "game")
    }
    check(
        f"data/ and backups/ are owner-only (modes: {dir_modes})",
        all(mode == "0o700" for mode in dir_modes.values()),
    )
    oldest = [
        backups / "7dtd-saves-20200100-000000.tar.gz",
        backups / "7dtd-saves-20200101-000000.tar.gz",
    ]
    check(
        "the two oldest archives were pruned first",
        all(not p.exists() for p in oldest),
    )
    check(
        "backup never writes a secret env file",
        b"--env-file" not in (tmpdir / "podman-argv.log").read_bytes(),
    )

# Two backups in the same second (the daily timer and an operator's own
# backup, or a backup and restore's pre-restore archive) must claim distinct
# archive names. The name used to be picked with `[[ -e ]]` and then written
# by tar, a check-then-act: both runs passed the test and gzipped into one
# path, interleaving two streams into an archive neither could read.
with tempfile.TemporaryDirectory() as tmp:
    tmpdir = Path(tmp)
    make_sandbox(tmpdir)
    install_podman_stub(tmpdir, PODMAN_STUB)
    saves = tmpdir / "data" / "userdata" / "Saves"
    (saves / "region").mkdir(parents=True)
    (saves / "region" / "r.0.0.region").write_bytes(b"chunkdata")
    backups = tmpdir / "backups"
    backups.mkdir()
    env = stub_env(tmpdir)
    racing = [
        subprocess.Popen(
            [str(tmpdir / "scripts" / "run.sh"), "backup"],
            env=env,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        for _ in range(4)
    ]
    for racer in racing:
        _, racer_err = racer.communicate(timeout=120)
        check("concurrent backup exits 0", racer.returncode == 0)
        if racer.returncode != 0:
            print(racer_err.decode(errors="replace"), file=sys.stderr)
    archives = sorted(backups.glob("7dtd-saves-*.tar.gz"))
    check("concurrent backups claimed distinct names", len(archives) == len(racing))
    for archive in archives:
        try:
            with tarfile.open(archive) as tf:
                names = tf.getnames()
        except tarfile.TarError as exc:
            check(f"{archive.name} is a readable archive ({exc})", False)
            continue
        check(
            f"{archive.name} holds the planted save, not an interleaved stream",
            "Saves/region/r.0.0.region" in names,
        )


# backup() stamp zone: the prune reads it as the age sort key, so it has to be
# the instant (UTC), not the host wall clock. In a zone with a nonzero offset
# a local stamp is hours off, which is what a TZ change or a DST transition
# reorders; a fall-back transition also repeats a local stamp outright.
with tempfile.TemporaryDirectory() as tmp:
    tmpdir = Path(tmp)
    make_sandbox(tmpdir)
    install_podman_stub(tmpdir, PODMAN_STUB)
    (tmpdir / "data" / "userdata" / "Saves" / "region").mkdir(parents=True)
    (tmpdir / "data" / "userdata" / "Saves" / "region" / "r.0.0.region").write_bytes(b"chunkdata")
    before = datetime.datetime.now(datetime.timezone.utc)
    env = stub_env(tmpdir, TZ="Europe/Warsaw")
    proc = subprocess.run(
        [str(tmpdir / "scripts" / "run.sh"), "backup"],
        env=env,
        capture_output=True,
        check=False,
        timeout=120,
    )
    check("backup under a DST zone exits 0", proc.returncode == 0)
    if proc.returncode != 0:
        print(proc.stderr.decode(errors="replace"), file=sys.stderr)
    stamps = [
        p.name.removeprefix("7dtd-saves-").removesuffix(".tar.gz")
        for p in (tmpdir / "backups").glob("7dtd-saves-*.tar.gz")
    ]
    check("backup wrote one archive to name", len(stamps) == 1)
    parsed_stamps = [s for s in (parse_backup_stamp(name) for name in stamps) if s is not None]
    check(
        "backup stamp parses as %Y%m%d-%H%M%S",
        len(stamps) == 1 and len(parsed_stamps) == 1,
    )
    if parsed_stamps:
        drift = abs((parsed_stamps[0] - before).total_seconds())
        check(
            "the backup stamp is UTC, not the host wall clock (Europe/Warsaw)",
            drift < 120,
        )


# backup() while the server runs: saveworld goes over telnet before tar.
with tempfile.TemporaryDirectory() as tmp:
    tmpdir = Path(tmp)
    make_sandbox(tmpdir)
    install_podman_stub(tmpdir, PODMAN_STUB)
    saves = tmpdir / "data" / "userdata" / "Saves"
    saves.mkdir(parents=True)
    (saves / "region.zip").write_bytes(b"save")
    wire = tmpdir / "wire.bin"
    with start_fake_telnet(wire) as port:
        env = stub_env(tmpdir, STUB_PS_OUTPUT=f"{NAME}\n", TELNET_PORT=port)
        proc = subprocess.run(
            [str(tmpdir / "scripts" / "run.sh"), "backup"],
            env=env,
            capture_output=True,
            check=False,
            timeout=120,
        )
    check("live backup exits 0", proc.returncode == 0)
    if proc.returncode != 0:
        print(proc.stderr.decode(errors="replace"), file=sys.stderr)
    check(
        "live backup sent password + saveworld over telnet",
        wire.read_bytes() == f"{TELNET_PASSWORD}\nsaveworld\n".encode(),
    )
    fresh_archives = list((tmpdir / "backups").glob("7dtd-saves-*.tar.gz"))
    check("live backup produced an archive", bool(fresh_archives))
    verbs = [rec[0] for rec in stub_invocations(tmpdir / "podman-argv.log") if rec]
    check("backup only probes state (never stops the server)", verbs == [b"ps"])


# backup() while the server runs but the console is down: warn and still
# archive (an inconsistent-but-present backup beats none).
with tempfile.TemporaryDirectory() as tmp:
    tmpdir = Path(tmp)
    make_sandbox(tmpdir)
    install_podman_stub(tmpdir, PODMAN_STUB)
    (tmpdir / "data" / "userdata" / "Saves").mkdir(parents=True)
    dead_port = closed_ephemeral_port()
    env = stub_env(tmpdir, STUB_PS_OUTPUT=f"{NAME}\n", TELNET_PORT=dead_port)
    proc = subprocess.run(
        [str(tmpdir / "scripts" / "run.sh"), "backup"],
        env=env,
        capture_output=True,
        check=False,
        timeout=120,
    )
    out = proc.stdout + proc.stderr
    check("backup with dead telnet exits 0", proc.returncode == 0)
    check(
        "backup with dead telnet warns about the skipped save",
        b"archiving without a fresh save" in out,
    )
    check(
        "backup with dead telnet still archived",
        bool(list((tmpdir / "backups").glob("7dtd-saves-*.tar.gz"))),
    )


# backup() on a tree where the server never started: loud refusal.
with tempfile.TemporaryDirectory() as tmp:
    tmpdir = Path(tmp)
    make_sandbox(tmpdir)
    install_podman_stub(tmpdir, PODMAN_STUB)
    env = stub_env(tmpdir)
    proc = subprocess.run(
        [str(tmpdir / "scripts" / "run.sh"), "backup"],
        env=env,
        capture_output=True,
        check=False,
        timeout=120,
    )
    out = proc.stdout + proc.stderr
    check(
        "backup without any saves refuses loudly",
        proc.returncode != 0 and b"nothing to back up" in out,
    )


# restore(): the other half of backup(). A backup nobody can put back is a
# hypothesis, so the restore path is pinned against a sandboxed tree the same
# way backup() is: newest-by-default selection, the pre-restore snapshot that
# makes the operation reversible, and loud refusals for every case where
# touching data/userdata would be wrong.
def plant_archive(path: Path, region_bytes: bytes) -> None:
    """Write a run.sh-shaped Saves archive (0600) holding one region file."""
    with tempfile.TemporaryDirectory() as stage:
        saves = Path(stage) / "Saves" / "region"
        saves.mkdir(parents=True)
        (saves / "r.0.0.region").write_bytes(region_bytes)
        path.parent.mkdir(parents=True, exist_ok=True)
        with tarfile.open(path, "w:gz") as tf:
            tf.add(Path(stage) / "Saves", arcname="Saves")
    path.chmod(0o600)


# restore with an empty backups/: nothing to restore is a loud refusal, not a
# no-op that reads as a successful recovery.
with tempfile.TemporaryDirectory() as tmp:
    tmpdir = Path(tmp)
    make_sandbox(tmpdir)
    install_podman_stub(tmpdir, PODMAN_STUB)
    env = stub_env(tmpdir)
    proc = subprocess.run(
        [str(tmpdir / "scripts" / "run.sh"), "restore"],
        env=env,
        capture_output=True,
        check=False,
        timeout=120,
    )
    out = proc.stdout + proc.stderr
    check(
        "restore with no archives refuses loudly",
        proc.returncode != 0 and b"no backup archive" in out,
    )


# restore: no argument picks the newest archive by the UTC stamp and the saves
# it replaces are archived first, so the operator can undo the restore.
with tempfile.TemporaryDirectory() as tmp:
    tmpdir = Path(tmp)
    make_sandbox(tmpdir)
    install_podman_stub(tmpdir, PODMAN_STUB)
    saves = tmpdir / "data" / "userdata" / "Saves" / "region"
    saves.mkdir(parents=True)
    (saves / "r.0.0.region").write_bytes(b"current-world")
    backups = tmpdir / "backups"
    plant_archive(backups / "7dtd-saves-20200101-000000.tar.gz", b"old-world")
    plant_archive(backups / "7dtd-saves-20200102-000000.tar.gz", b"new-world")
    env = stub_env(tmpdir)
    proc = subprocess.run(
        [str(tmpdir / "scripts" / "run.sh"), "restore"],
        env=env,
        capture_output=True,
        check=False,
        timeout=120,
    )
    out = proc.stdout + proc.stderr
    check("restore exits 0", proc.returncode == 0)
    if proc.returncode != 0:
        print(proc.stderr.decode(errors="replace"), file=sys.stderr)
    check(
        "restore loaded the newest archive's world",
        (saves / "r.0.0.region").read_bytes() == b"new-world",
    )
    # The discarded state must still be recoverable from backups/.
    recovered = [
        name
        for name in (p.name for p in backups.glob("7dtd-saves-*.tar.gz"))
        if name > "7dtd-saves-20200102-000000.tar.gz"
    ]
    check("restore archived the saves it replaced", bool(recovered))
    if recovered:
        with tarfile.open(backups / recovered[0]) as tf:
            payload = tf.extractfile("Saves/region/r.0.0.region")
            check(
                "the pre-restore archive holds the replaced world",
                payload is not None and payload.read() == b"current-world",
            )
    check(
        "restore never stops or starts the server",
        {rec[0] for rec in stub_invocations(tmpdir / "podman-argv.log") if rec} == {b"ps"},
    )


# Two backups inside one second cannot share a name, so the loser of the
# exclusive create takes a counter suffix, and both the prune and the bare
# restore read the name as the age order. That order has to survive the
# caller's locale, which a glob's own collation does not: en_US.UTF-8 puts
# the plain '…-000000.tar.gz' after the '…-000000~01.tar.gz' written after it.
# The non-default locale is the point, since the C order it falls back on is
# the one the fixed-width stamp and the zero-padded counter are built for.
with tempfile.TemporaryDirectory() as tmp:
    tmpdir = Path(tmp)
    make_sandbox(tmpdir)
    install_podman_stub(tmpdir, PODMAN_STUB)
    saves = tmpdir / "data" / "userdata" / "Saves" / "region"
    saves.mkdir(parents=True)
    (saves / "r.0.0.region").write_bytes(b"current-world")
    backups = tmpdir / "backups"
    collided = "7dtd-saves-20200101-000000"
    plant_archive(backups / f"{collided}.tar.gz", b"plain-world")
    plant_archive(backups / f"{collided}~01.tar.gz", b"first-collider")
    plant_archive(backups / f"{collided}~10.tar.gz", b"newest-world")
    env = stub_env(tmpdir, LC_ALL="en_US.UTF-8")
    proc = subprocess.run(
        [str(tmpdir / "scripts" / "run.sh"), "restore"],
        env=env,
        capture_output=True,
        check=False,
        timeout=120,
    )
    out = proc.stdout + proc.stderr
    check("restore over a collided second exits 0", proc.returncode == 0)
    if proc.returncode != 0:
        print(out.decode(errors="replace"), file=sys.stderr)
    check(
        "the bare restore picks the newest of one second's colliding archives",
        (saves / "r.0.0.region").read_bytes() == b"newest-world",
    )


# restore run twice is the operation a retry produces, and it must land on the
# same world as one run: the pre-restore snapshot the first run leaves behind
# is the newest archive, so a bare restore that treated it as a target would
# silently undo the recovery on the second attempt. The second run finds Saves
# already holding the archive's content, so it takes no second snapshot and
# spends no retention slot on a no-op.
with tempfile.TemporaryDirectory() as tmp:
    tmpdir = Path(tmp)
    make_sandbox(tmpdir)
    install_podman_stub(tmpdir, PODMAN_STUB)
    saves = tmpdir / "data" / "userdata" / "Saves" / "region"
    saves.mkdir(parents=True)
    (saves / "r.0.0.region").write_bytes(b"current-world")
    backups = tmpdir / "backups"
    plant_archive(backups / "7dtd-saves-20200101-000000.tar.gz", b"old-world")
    plant_archive(backups / "7dtd-saves-20200102-000000.tar.gz", b"new-world")
    env = stub_env(tmpdir)
    first = subprocess.run(
        [str(tmpdir / "scripts" / "run.sh"), "restore"],
        env=env,
        capture_output=True,
        check=False,
        timeout=120,
    )
    archives_after_first = sorted(p.name for p in backups.glob("*.tar.gz"))
    second = subprocess.run(
        [str(tmpdir / "scripts" / "run.sh"), "restore"],
        env=env,
        capture_output=True,
        check=False,
        timeout=120,
    )
    check("restore run twice exits 0 both times", first.returncode == second.returncode == 0)
    for proc in (first, second):
        if proc.returncode != 0:
            print(proc.stderr.decode(errors="replace"), file=sys.stderr)
    check(
        "the second restore left the first one's world in place",
        (saves / "r.0.0.region").read_bytes() == b"new-world",
    )
    check(
        "the repeated restore said there was nothing to do",
        b"nothing to restore" in second.stdout,
    )
    check(
        "the repeated restore wrote no second pre-restore snapshot",
        sorted(p.name for p in backups.glob("*.tar.gz")) == archives_after_first,
    )
    check(
        "the repeated restore left no staging litter in data/userdata",
        sorted(p.name for p in (tmpdir / "data" / "userdata").glob(".restore.tmp.*")) == [],
    )
    snapshots = sorted(backups.glob("7dtd-saves-*-prerestore*.tar.gz"))
    check(
        "the restore pre-restore snapshot is marked, not a plain archive",
        len(snapshots) == 1,
    )
    recoverable = []
    for snapshot in snapshots:
        with tarfile.open(snapshot) as tf:
            recoverable.append(tf.extractfile("Saves/region/r.0.0.region") is not None)
    check(
        "the pre-restore snapshot stays recoverable as an explicit target",
        len(recoverable) == 1 and all(recoverable),
    )


# A backups/ holding nothing but pre-restore snapshots has no recovery target,
# so a bare restore refuses instead of restoring the state a restore discarded.
with tempfile.TemporaryDirectory() as tmp:
    tmpdir = Path(tmp)
    make_sandbox(tmpdir)
    install_podman_stub(tmpdir, PODMAN_STUB)
    saves = tmpdir / "data" / "userdata" / "Saves" / "region"
    saves.mkdir(parents=True)
    (saves / "r.0.0.region").write_bytes(b"current-world")
    plant_archive(
        tmpdir / "backups" / "7dtd-saves-20200101-000000-prerestore.tar.gz", b"current-world"
    )
    env = stub_env(tmpdir)
    proc = subprocess.run(
        [str(tmpdir / "scripts" / "run.sh"), "restore"],
        env=env,
        capture_output=True,
        check=False,
        timeout=120,
    )
    out = proc.stdout + proc.stderr
    check(
        "restore with only pre-restore snapshots refuses",
        proc.returncode != 0 and b"no backup archive" in out,
    )
    check(
        "the refused restore left the saves alone",
        (saves / "r.0.0.region").read_bytes() == b"current-world",
    )


# restore <archive>: an explicit path wins over the newest-by-default pick.
with tempfile.TemporaryDirectory() as tmp:
    tmpdir = Path(tmp)
    make_sandbox(tmpdir)
    install_podman_stub(tmpdir, PODMAN_STUB)
    saves = tmpdir / "data" / "userdata" / "Saves" / "region"
    saves.mkdir(parents=True)
    (saves / "r.0.0.region").write_bytes(b"current-world")
    backups = tmpdir / "backups"
    plant_archive(backups / "7dtd-saves-20200101-000000.tar.gz", b"old-world")
    plant_archive(backups / "7dtd-saves-20200102-000000.tar.gz", b"new-world")
    chosen = backups / "7dtd-saves-20200101-000000.tar.gz"
    env = stub_env(tmpdir)
    proc = subprocess.run(
        [str(tmpdir / "scripts" / "run.sh"), "restore", str(chosen)],
        env=env,
        capture_output=True,
        check=False,
        timeout=120,
    )
    check("restore with an explicit archive exits 0", proc.returncode == 0)
    check(
        "restore loaded the named archive, not the newest",
        (saves / "r.0.0.region").read_bytes() == b"old-world",
    )


# restore while the server runs: the game would write over the restored files,
# so refuse before touching data/userdata.
with tempfile.TemporaryDirectory() as tmp:
    tmpdir = Path(tmp)
    make_sandbox(tmpdir)
    install_podman_stub(tmpdir, PODMAN_STUB)
    saves = tmpdir / "data" / "userdata" / "Saves" / "region"
    saves.mkdir(parents=True)
    (saves / "r.0.0.region").write_bytes(b"current-world")
    plant_archive(tmpdir / "backups" / "7dtd-saves-20200101-000000.tar.gz", b"old-world")
    env = stub_env(tmpdir, STUB_PS_OUTPUT=f"{NAME}\n")
    proc = subprocess.run(
        [str(tmpdir / "scripts" / "run.sh"), "restore"],
        env=env,
        capture_output=True,
        check=False,
        timeout=120,
    )
    out = proc.stdout + proc.stderr
    check(
        "restore with a running server refuses",
        proc.returncode != 0 and b"is running" in out,
    )
    check(
        "the refused restore left the live saves alone",
        (saves / "r.0.0.region").read_bytes() == b"current-world",
    )


# restore of an unreadable or payload-free archive: the preflight must fail
# before Saves/ is removed, or a bad archive destroys the state it meant to
# recover.
with tempfile.TemporaryDirectory() as tmp:
    tmpdir = Path(tmp)
    make_sandbox(tmpdir)
    install_podman_stub(tmpdir, PODMAN_STUB)
    saves = tmpdir / "data" / "userdata" / "Saves" / "region"
    saves.mkdir(parents=True)
    (saves / "r.0.0.region").write_bytes(b"current-world")
    backups = tmpdir / "backups"
    backups.mkdir(parents=True)
    (backups / "7dtd-saves-20200101-000000.tar.gz").write_bytes(b"not-a-tarball")
    env = stub_env(tmpdir)
    proc = subprocess.run(
        [str(tmpdir / "scripts" / "run.sh"), "restore"],
        env=env,
        capture_output=True,
        check=False,
        timeout=120,
    )
    out = proc.stdout + proc.stderr
    check(
        "restore of a corrupt archive refuses",
        proc.returncode != 0 and b"not a readable tar.gz" in out,
    )
    check(
        "the corrupt restore left the saves alone",
        (saves / "r.0.0.region").read_bytes() == b"current-world",
    )

with tempfile.TemporaryDirectory() as tmp:
    tmpdir = Path(tmp)
    make_sandbox(tmpdir)
    install_podman_stub(tmpdir, PODMAN_STUB)
    saves = tmpdir / "data" / "userdata" / "Saves" / "region"
    saves.mkdir(parents=True)
    (saves / "r.0.0.region").write_bytes(b"current-world")
    with tempfile.TemporaryDirectory() as stage:
        (Path(stage) / "somethingelse").write_text("x", encoding="utf-8")
        (tmpdir / "backups").mkdir(parents=True)
        with tarfile.open(tmpdir / "backups" / "7dtd-saves-20200101-000000.tar.gz", "w:gz") as tf:
            tf.add(Path(stage) / "somethingelse", arcname="somethingelse")
    env = stub_env(tmpdir)
    proc = subprocess.run(
        [str(tmpdir / "scripts" / "run.sh"), "restore"],
        env=env,
        capture_output=True,
        check=False,
        timeout=120,
    )
    out = proc.stdout + proc.stderr
    check(
        "restore of a Saves-less archive refuses",
        proc.returncode != 0 and b"no Saves/ payload" in out,
    )
    check(
        "the payload-free restore left the saves alone",
        (saves / "r.0.0.region").read_bytes() == b"current-world",
    )


# An entry that climbs out of the tree is refused even when it starts inside
# Saves/: a case matches the first pattern that fits, and Saves/../../escape
# also matches Saves/*, so the escape check has to be tested first or the
# guard silently accepts the very shape it exists to reject.
with tempfile.TemporaryDirectory() as tmp:
    tmpdir = Path(tmp)
    make_sandbox(tmpdir)
    install_podman_stub(tmpdir, PODMAN_STUB)
    saves = tmpdir / "data" / "userdata" / "Saves" / "region"
    saves.mkdir(parents=True)
    (saves / "r.0.0.region").write_bytes(b"current-world")
    (tmpdir / "backups").mkdir(parents=True)
    crafted = tmpdir / "backups" / "7dtd-saves-20200101-000000.tar.gz"
    with tarfile.open(crafted, "w:gz") as tf:
        for name in ("Saves", "Saves/world", "Saves/../../escape", "Saves/.."):
            info = tarfile.TarInfo(name)
            info.size = 0
            tf.addfile(info)
    env = stub_env(tmpdir)
    proc = subprocess.run(
        [str(tmpdir / "scripts" / "run.sh"), "restore"],
        env=env,
        capture_output=True,
        check=False,
        timeout=120,
    )
    out = proc.stdout + proc.stderr
    check(
        "restore of an archive escaping through Saves/ refuses",
        proc.returncode != 0 and b"outside the archive root" in out,
    )
    check(
        "the escaping restore left the saves alone",
        (saves / "r.0.0.region").read_bytes() == b"current-world",
    )


# A link member is the same escape by another route. Every name in the archive
# sits inside Saves/, so the path walk accepts it, and extraction writes
# through the symlink to whatever it points at: the victim file below is the
# proof, and it has to come back unchanged.
with tempfile.TemporaryDirectory() as tmp:
    tmpdir = Path(tmp)
    make_sandbox(tmpdir)
    install_podman_stub(tmpdir, PODMAN_STUB)
    saves = tmpdir / "data" / "userdata" / "Saves" / "region"
    saves.mkdir(parents=True)
    (saves / "r.0.0.region").write_bytes(b"current-world")
    (tmpdir / "backups").mkdir(parents=True)
    victim_dir = tmpdir / "victim"
    victim_dir.mkdir()
    (victim_dir / "secret").write_bytes(b"original")
    crafted = tmpdir / "backups" / "7dtd-saves-20200101-000000.tar.gz"
    with tarfile.open(crafted, "w:gz") as tf:
        saves_dir = tarfile.TarInfo("Saves")
        saves_dir.type = tarfile.DIRTYPE
        saves_dir.mode = 0o755
        tf.addfile(saves_dir)
        link = tarfile.TarInfo("Saves/escape")
        link.type = tarfile.SYMTYPE
        link.linkname = str(victim_dir)
        tf.addfile(link)
        link_bytes = b"written through the link"
        member = tarfile.TarInfo("Saves/escape/secret")
        member.size = len(link_bytes)
        tf.addfile(member, io.BytesIO(link_bytes))
    crafted.chmod(0o600)
    env = stub_env(tmpdir)
    proc = subprocess.run(
        [str(tmpdir / "scripts" / "run.sh"), "restore"],
        env=env,
        capture_output=True,
        check=False,
        timeout=120,
    )
    out = proc.stdout + proc.stderr
    check(
        "restore of an archive carrying a link member refuses",
        proc.returncode != 0 and b"link" in out,
    )
    check(
        "the link archive wrote nothing outside the archive root",
        (victim_dir / "secret").read_bytes() == b"original",
    )
    check(
        "the refusing restore left the saves alone",
        (saves / "r.0.0.region").read_bytes() == b"current-world",
    )
    verify = subprocess.run(
        [str(tmpdir / "scripts" / "run.sh"), "verify-backup", str(crafted)],
        env=env,
        capture_output=True,
        check=False,
        timeout=120,
    )
    # stderr, like every other verify-backup refusal: stdout carries only the
    # OK lines a recovery counts.
    check(
        "verify-backup calls the same archive un-restorable",
        verify.returncode != 0 and b"FAIL" in verify.stderr,
    )


# CLI surface: --help answers without any setup side effect, and a bad
# invocation must be distinguishable from a failed operation by scripts
# consuming this CLI, so usage errors exit 2 (not 1 like real failures).
with tempfile.TemporaryDirectory() as tmp:
    tmpdir = Path(tmp)
    make_sandbox(tmpdir)
    run_sh = tmpdir / "scripts" / "run.sh"
    env = stub_env(tmpdir)

    proc = subprocess.run(
        [str(run_sh), "--help"], env=env, capture_output=True, check=False, timeout=30
    )
    check("--help exits 0", proc.returncode == 0)
    check("--help prints usage on stdout", b"usage: run.sh" in proc.stdout)
    check("--help writes nothing to stderr", proc.stderr == b"")

    proc = subprocess.run(
        [str(run_sh), "-h"], env=env, capture_output=True, check=False, timeout=30
    )
    check("-h behaves like --help", proc.returncode == 0 and b"usage: run.sh" in proc.stdout)

    # Help must answer even when the environment itself is broken.
    proc = subprocess.run(
        [str(run_sh), "--help"],
        env={**env, "TELNET_PORT": "not-a-port"},
        capture_output=True,
        check=False,
        timeout=30,
    )
    check("--help ignores an invalid TELNET_PORT", proc.returncode == 0)

    proc = subprocess.run(
        [str(run_sh), "frobnicate"], env=env, capture_output=True, check=False, timeout=30
    )
    check("unknown command exits 2", proc.returncode == 2)
    check(
        "unknown command prints usage on stderr only",
        b"usage:" in proc.stderr and proc.stdout == b"",
    )
    # Name the offender: an error that never says which word was wrong sends
    # the operator re-reading the invocation.
    check("unknown command is named in the error", b"frobnicate" in proc.stderr)

    # A typo'd command must be a usage error even when the environment itself
    # is broken (same rule as --help): validation of the word happens before
    # any .env load or value validation, so no setup side effect runs either.
    broken_env = {**env, "TELNET_PORT": "not-a-port"}
    data_dir = tmpdir / "data"
    proc = subprocess.run(
        [str(run_sh), "frobnicate"], env=broken_env, capture_output=True, check=False, timeout=30
    )
    check(
        "unknown command exits 2 even with a broken environment",
        proc.returncode == 2 and b"unknown command 'frobnicate'" in proc.stderr,
    )
    check(
        "the rejected command created no runtime dirs",
        not data_dir.exists(),
    )

    # `version` answers from the committed file alone, in the same place
    # --help does: no .env load, no value rules, no data dir. A host whose
    # environment is broken must still be able to say which build it runs.
    (tmpdir / "VERSION").write_text("9.9.9\n", encoding="utf-8")
    proc = subprocess.run(
        [str(run_sh), "version"], env=broken_env, capture_output=True, check=False, timeout=30
    )
    check(
        "version answers with a broken environment",
        proc.returncode == 0 and proc.stdout == b"9.9.9\n" and proc.stderr == b"",
    )
    check("version created no runtime dirs", not data_dir.exists())
    proc = subprocess.run(
        [str(run_sh), "version", "9.9.9"], env=env, capture_output=True, check=False, timeout=30
    )
    check("version still rejects a stray argument", proc.returncode == 2)

    proc = subprocess.run(
        [str(run_sh), "stop", "--keep", "3"],
        env=env,
        capture_output=True,
        check=False,
        timeout=30,
    )
    check("extra argument exits 2 naming it", proc.returncode == 2 and b"--keep" in proc.stderr)

    # Only restore takes an archive path, and exactly one: a second word
    # there is the same usage error as anywhere else.
    proc = subprocess.run(
        [str(run_sh), "restore", "a.tar.gz", "b.tar.gz"],
        env=env,
        capture_output=True,
        check=False,
        timeout=30,
    )
    check(
        "restore rejects a second archive argument",
        proc.returncode == 2 and b"b.tar.gz" in proc.stderr,
    )

    # The daily wrappers forward everything except help: asking either for
    # --help must answer 0 on stdout here (never a FATAL from run.sh), while
    # any other stray argument still fails loudly there.
    for wrapper, verb in (("start.sh", "start"), ("stop.sh", "stop")):
        shutil.copy2(ROOT / wrapper, tmpdir / wrapper)
        (tmpdir / wrapper).chmod(0o755)
        proc = subprocess.run(
            [str(tmpdir / wrapper), "--help"], env=env, capture_output=True, check=False, timeout=30
        )
        check(f"{wrapper} --help exits 0", proc.returncode == 0)
        check(
            f"{wrapper} --help names its run.sh {verb} shortcut",
            b"run.sh" in proc.stdout and verb.encode() in proc.stdout,
        )
        check(f"{wrapper} --help writes nothing to stderr", proc.stderr == b"")
        proc = subprocess.run(
            [str(tmpdir / wrapper), "frobnicate"],
            env=env,
            capture_output=True,
            check=False,
            timeout=30,
        )
        check(
            f"{wrapper} frobnicate fails loudly in run.sh",
            proc.returncode == 2 and b"frobnicate" in proc.stderr,
        )

# `build` is the one command that produces the artifact the server runs, and
# podman stamps layer mtimes with the wall-clock time unless --timestamp says
# otherwise, so an unpinned build can never be rebuilt to the same digest.
# SOURCE_DATE_EPOCH is the reproducible-builds.org stamp for that; a value podman
# would reject must fail before the build rather than produce a half-stamped
# image.
#
# `config` is the operator's view of the effective configuration: every value
# the next start would use, where it came from, and no secret. It also has to
# survive the misconfiguration it diagnoses, so a rejected value is a reported
# verdict rather than the end of the report.
with tempfile.TemporaryDirectory() as tmp:
    tmpdir = Path(tmp)
    install_podman_stub(tmpdir, PODMAN_STUB)
    run_sh = make_sandbox(tmpdir) / "scripts" / "run.sh"
    log = tmpdir / "podman-argv.log"
    epoch = "1700000000"

    def run_build(epoch_value: str, *, expect_build: bool = True) -> tuple[int, bytes, list[bytes]]:
        """run.sh build with the given SOURCE_DATE_EPOCH; returns rc, stderr, argv."""
        log.unlink(missing_ok=True)
        env = stub_env(tmpdir)
        env["SOURCE_DATE_EPOCH"] = epoch_value
        proc = subprocess.run(
            [str(run_sh), "build"],
            env=env,
            capture_output=True,
            check=False,
            timeout=30,
        )
        records = stub_invocations(log) if log.exists() else []
        if expect_build:
            epoch_shown = epoch_value or "<unset>"
            check(
                f"run.sh build with SOURCE_DATE_EPOCH={epoch_shown} runs podman build once",
                len(records) == 1 and records[0][:1] == [b"build"],
            )
        return proc.returncode, proc.stderr, records[0] if records else []

    rc, _, stamped = run_build(epoch)
    check("build with SOURCE_DATE_EPOCH exits 0", rc == 0)
    check(
        "SOURCE_DATE_EPOCH reaches podman as --timestamp",
        b"--timestamp" in stamped and stamped[stamped.index(b"--timestamp") + 1] == epoch.encode(),
    )
    rc, _, plain = run_build("")
    check("build without SOURCE_DATE_EPOCH exits 0", rc == 0)
    check("no SOURCE_DATE_EPOCH leaves the build untimestamped", b"--timestamp" not in plain)
    check(
        "the build still names the image and the tree",
        b"-t" in plain and plain[-1] == str(tmpdir).encode(),
    )
    rc, err, malformed = run_build("not-a-number", expect_build=False)
    check(
        "a malformed SOURCE_DATE_EPOCH fails loudly instead of building",
        rc != 0 and b"FATAL" in err and b"not-a-number" in err,
    )
    check("a malformed SOURCE_DATE_EPOCH never reaches podman", b"--timestamp" not in malformed)
    # podman reads --timestamp as seconds, so the millisecond stamp a JS or Go
    # caller hands out is a digits-only value that pins the build to a date in
    # the year 55000. It has to be refused, not stamped.
    for wrong_unit, label in (
        ("1700000000000", "milliseconds"),
        ("1700000000000000", "microseconds"),
    ):
        rc, err, unit = run_build(wrong_unit, expect_build=False)
        check(
            f"a SOURCE_DATE_EPOCH in {label} fails loudly instead of building",
            rc != 0 and b"FATAL" in err and wrong_unit.encode() in err,
        )
        check(f"a SOURCE_DATE_EPOCH in {label} never reaches podman", b"--timestamp" not in unit)
    # 2**64 and up wrap int64 arithmetic back to 0, so a length cap is what
    # keeps them from reading as a valid seconds stamp.
    rc, _, wrapped = run_build("18446744073709551616", expect_build=False)
    check("a SOURCE_DATE_EPOCH past int64 never reaches podman", b"--timestamp" not in wrapped)
    check("a SOURCE_DATE_EPOCH past int64 fails loudly", rc != 0)
    # Zero padding is a decimal stamp, not octal (00001000 is 512 bare).
    rc, _, padded_epoch = run_build("00001700000")
    check(
        "a zero-padded SOURCE_DATE_EPOCH is read as decimal",
        b"--timestamp" in padded_epoch
        and padded_epoch[padded_epoch.index(b"--timestamp") + 1] == b"00001700000",
    )

    env = stub_env(tmpdir)
    # A .env that fills exactly one value: everything else must be reported as
    # coming from the committed default, and the .env value from the file.
    (tmpdir / ".env").write_text("SEVENDTD_IMAGE=localhost/from-env-file:tag\n", encoding="utf-8")

    proc = subprocess.run(
        [str(run_sh), "config"], env=env, capture_output=True, check=False, timeout=30
    )
    report = proc.stdout.decode("utf-8")
    check("config exits 0", proc.returncode == 0)
    check(
        "config reports the .env value and attributes it to the file",
        "localhost/from-env-file:tag" in report and "(.env)" in report,
    )
    check(
        "config reports the committed default",
        "SEVENDTD_CONTAINER_NAME" in report and "(default)" in report,
    )
    check("config names the environment as the source", "(environment)" in report)
    check(
        "config never prints a secret value",
        TELNET_PASSWORD not in report and "pass word 12" not in report,
    )
    check(
        "config says an unset webadmin password is minted", b"minted at first seed" in proc.stdout
    )
    check(
        "config reports no rejected value on a clean configuration",
        b"values rejected: none" in proc.stdout,
    )

    # A rejected value must not take the report down with it: the operator
    # needs the other values while fixing this one.
    proc = subprocess.run(
        [str(run_sh), "config"],
        env={**env, "STEAMCMD_UPDATE": "true"},
        capture_output=True,
        check=False,
        timeout=30,
    )
    check("config exits 0 with a rejected value", proc.returncode == 0)
    check("config names the rejected value", b"STEAMCMD_UPDATE must be 0 or 1" in proc.stdout)
    check("config still reports the values", b"TELNET_PORT" in proc.stdout)

    # The report reads the same file the loader does, and a key no script
    # configures is a hard error rather than a silently ignored line.
    (tmpdir / ".env").write_text("TELEMET_PORT=9000\n", encoding="utf-8")
    proc = subprocess.run(
        [str(run_sh), "config"], env=env, capture_output=True, check=False, timeout=30
    )
    check(
        "a misspelled .env key is refused",
        proc.returncode == 1 and b"unknown key 'TELEMET_PORT'" in proc.stderr,
    )
    (tmpdir / ".env").unlink()

    # A line the loader skips must not be credited to the file. Leading
    # whitespace makes the key invalid, so the loader warns and the committed
    # default is what runs; a report answering ".env" here would send the
    # operator to edit a setting that never took effect.
    (tmpdir / ".env").write_text("  TELNET_PORT=9099\n", encoding="utf-8")
    # TELNET_PORT out of the environment: an environment value wins over the
    # file and the report would say "environment" whichever way the .env line
    # is spelled, which is not the question here.
    portless_env = {k: v for k, v in env.items() if k != "TELNET_PORT"}
    proc = subprocess.run(
        [str(run_sh), "config"], env=portless_env, capture_output=True, check=False, timeout=30
    )
    port_line = next(
        (ln for ln in proc.stdout.decode("utf-8").splitlines() if ln.startswith("TELNET_PORT")),
        "",
    )
    check("a .env line the loader skipped is named as skipped", b"invalid key" in proc.stderr)
    check(
        f"config does not attribute the default to a skipped .env line (got {port_line!r})",
        proc.returncode == 0 and port_line.endswith("(default)"),
    )
    (tmpdir / ".env").unlink()

    # .env carries both passwords, so the mode the operator's copy landed with
    # is part of the control, not a detail: a file copied under a permissive
    # umask reads as 0644 and hands the telnet and webadmin passwords to every
    # other account on the host. The run tightens it in place, and tightening
    # must not stop the report from working.
    env_file = tmpdir / ".env"
    env_file.write_text("SEVENDTD_IMAGE=localhost/mode-check:tag\n", encoding="utf-8")
    env_file.chmod(0o644)
    proc = subprocess.run(
        [str(run_sh), "config"], env=env, capture_output=True, check=False, timeout=30
    )
    check(
        "a world-readable .env is tightened to 0600",
        proc.returncode == 0 and oct(env_file.stat().st_mode & 0o777) == "0o600",
    )
    check(
        "tightening .env does not stop the config report",
        "localhost/mode-check:tag" in proc.stdout.decode("utf-8"),
    )
    env_file.unlink()

    # The container name is the body of the anchored `podman ps --filter
    # name=^${NAME}$` regex and the image reference is a podman -t argument, so
    # a value carrying regex or option syntax is refused here rather than
    # making `status` report a container that was never started.
    for key, bad_value in (
        ("SEVENDTD_CONTAINER_NAME", "srv|name"),
        ("SEVENDTD_CONTAINER_NAME", "-leading-dash"),
        ("SEVENDTD_CONTAINER_NAME", "srv name"),
        ("SEVENDTD_IMAGE", "-rf"),
        ("SEVENDTD_IMAGE", "localhost/7dtd server:latest"),
    ):
        proc = subprocess.run(
            [str(run_sh), "status"],
            env={**env, key: bad_value},
            capture_output=True,
            check=False,
            timeout=30,
        )
        check(
            f"{key}={bad_value!r} is refused",
            proc.returncode == 1 and f"{key} must match".encode() in proc.stderr,
        )
    # A registry and a tag are legitimate image syntax and must survive.
    proc = subprocess.run(
        [str(run_sh), "config"],
        env={**env, "SEVENDTD_IMAGE": "quay.io/horde/7dtd-server:v1.2.3"},
        capture_output=True,
        check=False,
        timeout=30,
    )
    check(
        "a registry-qualified image reference is accepted",
        proc.returncode == 0 and b"quay.io/horde/7dtd-server:v1.2.3" in proc.stdout,
    )
    # A rejected podman value is a report line, not the end of the report,
    # the same way a rejected BACKUP_KEEP is.
    proc = subprocess.run(
        [str(run_sh), "config"],
        env={**env, "SEVENDTD_CONTAINER_NAME": "srv|name"},
        capture_output=True,
        check=False,
        timeout=30,
    )
    check(
        "config reports a rejected container name instead of dying on it",
        proc.returncode == 0
        and b"values rejected: FATAL: SEVENDTD_CONTAINER_NAME must match" in proc.stdout,
    )
    # The opt-in that authorizes the committed public telnet password is a
    # config value like any other, so the report has to carry it.
    for allow in ("0", "1"):
        proc = subprocess.run(
            [str(run_sh), "config"],
            env={**env, "ALLOW_PUBLIC_DEFAULT_TELNET_PASSWORD": allow},
            capture_output=True,
            check=False,
            timeout=30,
        )
        check(
            f"config reports ALLOW_PUBLIC_DEFAULT_TELNET_PASSWORD={allow}",
            proc.returncode == 0
            and re.search(
                rf"^ALLOW_PUBLIC_DEFAULT_TELNET_PASSWORD\s+{allow}\s+\(environment\)",
                proc.stdout.decode(),
                re.MULTILINE,
            )
            is not None,
        )

    # BACKUP_KEEP is a validated config value: a bad one fails before the run
    # does anything, instead of reaching the prune arithmetic. 18446744073709551617
    # is 2^64+1, which bash arithmetic wraps to 1 with no error: a bound tested
    # only with (( )) accepts it as a retention of one archive.
    for bad in ("abc", "0", "-1", "00", "99999999999999999999", "18446744073709551617"):
        proc = subprocess.run(
            [str(run_sh), "status"],
            env={**env, "BACKUP_KEEP": bad},
            capture_output=True,
            check=False,
            timeout=30,
        )
        check(
            f"BACKUP_KEEP={bad!r} is refused",
            proc.returncode == 1 and b"BACKUP_KEEP must be" in proc.stderr,
        )
    # A leading zero is a plain count, not an octal literal: 08 must report as
    # eight archives, not abort the run inside the prune arithmetic.
    for zero_padded in ("08", "09", "0007", "007"):
        proc = subprocess.run(
            [str(run_sh), "config"],
            env={**env, "BACKUP_KEEP": zero_padded},
            capture_output=True,
            check=False,
            timeout=30,
        )
        report = proc.stdout.decode()
        want = rf"^BACKUP_KEEP\s+{int(zero_padded)}\s"
        check(
            f"BACKUP_KEEP={zero_padded!r} is read in base 10",
            proc.returncode == 0 and re.search(want, report, re.MULTILINE) is not None,
        )
    # The upper bound is enforced on the digit string, not on bash's
    # evaluation of it. A value wider than 2^64 wraps in bash's arithmetic
    # rather than failing, so the first case below is the one that separates
    # the two: 18446744073709551616 + 1 evaluates to exactly 1 and would sail
    # through a numeric range check, while the documented maximum must still
    # be accepted, so the bound cannot be enforced by refusing anything long.
    # `config` exits 0 on a rejected value by design (it exists to diagnose
    # one), so the verdict line, not the return code, carries the answer.
    for wide, accepted in (
        ("18446744073709551617", False),
        ("999999999", True),
        ("1000000000", False),
    ):
        proc = subprocess.run(
            [str(run_sh), "config"],
            env={**env, "BACKUP_KEEP": wide},
            capture_output=True,
            check=False,
            timeout=30,
        )
        check(
            f"BACKUP_KEEP={wide!r} is {'accepted' if accepted else 'refused'} at the bound",
            proc.returncode == 0
            and (b"values rejected: FATAL: BACKUP_KEEP" in proc.stdout) is not accepted,
        )
    proc = subprocess.run(
        [str(run_sh), "config"],
        env={**env, "BACKUP_KEEP": "3"},
        capture_output=True,
        check=False,
        timeout=30,
    )
    check(
        "config reports the BACKUP_KEEP override",
        b"BACKUP_KEEP" in proc.stdout and b"3" in proc.stdout,
    )
    # An empty value is "not set", the same convention the steamcmd switches
    # use, so it falls back to the committed default instead of failing.
    proc = subprocess.run(
        [str(run_sh), "config"],
        env={**env, "BACKUP_KEEP": ""},
        capture_output=True,
        check=False,
        timeout=30,
    )
    check("an empty BACKUP_KEEP falls back to the default", proc.returncode == 0)
    # config exists to diagnose a broken value, so a rejected BACKUP_KEEP must
    # reach the report as a "values rejected:" line like every other key it
    # prints, not abort the run before a single line is written.
    proc = subprocess.run(
        [str(run_sh), "config"],
        env={**env, "BACKUP_KEEP": "abc"},
        capture_output=True,
        check=False,
        timeout=30,
    )
    check(
        "config reports a rejected BACKUP_KEEP instead of dying on it",
        proc.returncode == 0
        and b"values rejected: FATAL: BACKUP_KEEP must be numeric" in proc.stdout,
    )


# Personal data lives in data/ and in the archives backup copies out of it, so
# both trees are kept owner-only. A chmod that cannot complete (the directory is
# not the caller's to restrict) must fail the run rather than proceed and leave
# player names, platform ids, world saves and join logs world-readable.
CHMOD_FAILING_STUB = """#!/bin/sh
echo "chmod: changing permissions: Operation not permitted" >&2
exit 1
"""
with tempfile.TemporaryDirectory() as tmp:
    tmpdir = Path(tmp)
    make_sandbox(tmpdir)
    install_podman_stub(tmpdir, PODMAN_STUB)
    (tmpdir / "bin" / "chmod").write_text(CHMOD_FAILING_STUB, encoding="utf-8")
    (tmpdir / "bin" / "chmod").chmod(0o755)
    saves = tmpdir / "data" / "userdata" / "Saves" / "region"
    saves.mkdir(parents=True)
    (saves / "r.0.0.region").write_bytes(b"chunkdata")
    env = stub_env(tmpdir)
    proc = subprocess.run(
        [str(tmpdir / "scripts" / "run.sh"), "backup"],
        env=env,
        capture_output=True,
        check=False,
        timeout=60,
    )
    out = proc.stdout + proc.stderr
    check(
        "a data/ tree that cannot be made owner-only fails the run",
        proc.returncode == 1 and b"cannot keep" in out and b"owner-only" in out,
    )
    check("the failed run named the directory it would not restrict", b"data/" in out)
    check("the failed run wrote no archive", not list((tmpdir / "backups").glob("*")))


# The archive name is claimed with an exclusive create, and a name it cannot
# claim (a full disk, a filesystem that refuses the create) used to send the
# loop around suffixes with no bound, so the run spun forever instead of
# reporting the one failure no further suffix can fix and the daily timer never
# came back. The clock is stubbed so the planted collisions are the exact names
# this second's claim walks, which is the only way to reach the bound without a
# real full disk.
DATE_STUB = """#!/bin/sh
if [ "$1" = "-u" ] && [ "$2" = "+%Y%m%d-%H%M%S" ]; then
  echo "${STUB_STAMP:?}"
  exit 0
fi
exec /bin/date "$@"
"""
with tempfile.TemporaryDirectory() as tmp:
    tmpdir = Path(tmp)
    make_sandbox(tmpdir)
    install_podman_stub(tmpdir, PODMAN_STUB)
    date_stub = tmpdir / "bin" / "date"
    date_stub.write_text(DATE_STUB, encoding="utf-8")
    date_stub.chmod(0o755)
    saves = tmpdir / "data" / "userdata" / "Saves" / "region"
    saves.mkdir(parents=True)
    (saves / "r.0.0.region").write_bytes(b"chunkdata")
    backups = tmpdir / "backups"
    backups.mkdir()
    # Every name ARCHIVE_CLAIM_TRIES suffixes reaches, plus the plain one.
    stem = "7dtd-saves-20200101-000000"
    for name in [f"{stem}.tar.gz", *(f"{stem}~{n:02d}.tar.gz" for n in range(1, 101))]:
        (backups / name).write_bytes(b"planted")
    env = stub_env(tmpdir, STUB_STAMP="20200101-000000")
    claim: subprocess.CompletedProcess[bytes] | None = None
    try:
        claim = subprocess.run(
            [str(tmpdir / "scripts" / "run.sh"), "backup"],
            env=env,
            capture_output=True,
            check=False,
            timeout=120,
        )
    except subprocess.TimeoutExpired:
        claim = None
    check("a backups/ where no name can be claimed fails instead of spinning", claim is not None)
    if claim is not None:
        out = claim.stdout + claim.stderr
        check(
            "the failed claim names the directory and the cause",
            claim.returncode == 1 and b"cannot create a backup archive" in out,
        )
        check(
            "the failed claim says nothing was archived",
            b"backups" in out and b"nothing was archived" in out,
        )
    check(
        "the failed claim left every planted archive in place",
        len(list(backups.glob("*.tar.gz"))) == 101,
    )


# A corrupt archive fails restore's preflight. tar's own diagnostic has to
# reach the operator: "truncated or corrupt" alone does not say whether the
# file is a short gzip stream, an unreadable path, or something else, and the
# restore preflight is exactly where that question is answered.
with tempfile.TemporaryDirectory() as tmp:
    tmpdir = Path(tmp)
    make_sandbox(tmpdir)
    install_podman_stub(tmpdir, PODMAN_STUB)
    saves = tmpdir / "data" / "userdata" / "Saves" / "region"
    saves.mkdir(parents=True)
    (saves / "r.0.0.region").write_bytes(b"current-world")
    backups = tmpdir / "backups"
    backups.mkdir()
    (backups / "7dtd-saves-20200101-000000.tar.gz").write_bytes(b"not-a-tarball")
    env = stub_env(tmpdir)
    proc = subprocess.run(
        [str(tmpdir / "scripts" / "run.sh"), "restore"],
        env=env,
        capture_output=True,
        check=False,
        timeout=120,
    )
    out = proc.stdout + proc.stderr
    check(
        "restore of a corrupt archive still refuses",
        proc.returncode != 0 and b"not a readable tar.gz" in out,
    )
    check(
        "the corrupt-archive refusal carries tar's own diagnostic",
        b"tar:" in out or b"gzip:" in out,
    )


# An archive that lists cleanly and then fails mid-extraction (here: an entry
# nested under a path the archive already stored as a file) is the failure a
# preflight cannot catch: tar -tzf reads every entry, so the archive is
# accepted and the refusal comes from tar itself part-way through the write.
# It is also the recovery path that would destroy the world it was replacing if
# extraction ran in place. It does not: extraction lands in a staging dir
# first, so the run dies with Saves untouched, no retention slot spent on a
# pre-restore snapshot of a world nothing replaced, and no staging litter for
# the next restore to find. The message names the archive that failed and says
# Saves is unchanged.
with tempfile.TemporaryDirectory() as tmp:
    tmpdir = Path(tmp)
    make_sandbox(tmpdir)
    install_podman_stub(tmpdir, PODMAN_STUB)
    userdata = tmpdir / "data" / "userdata"
    saves = userdata / "Saves" / "region"
    saves.mkdir(parents=True)
    world = saves / "r.0.0.region"
    world.write_bytes(b"current-world")
    backups = tmpdir / "backups"
    backups.mkdir()
    broken = backups / "7dtd-saves-20200101-000000.tar.gz"
    with tempfile.TemporaryDirectory() as stage:
        (Path(stage) / "Saves").mkdir()
        (Path(stage) / "Saves" / "region").write_bytes(b"not-a-directory")
        with tarfile.open(broken, "w:gz") as tf:
            # Both entries list as Saves/... so the preflight accepts them;
            # extracting nests a file under a file, which tar refuses.
            tf.add(Path(stage) / "Saves" / "region", arcname="Saves/region")
            tf.add(Path(stage) / "Saves", arcname="Saves/region/inner")
    broken.chmod(0o600)
    env = stub_env(tmpdir)
    proc = subprocess.run(
        [str(tmpdir / "scripts" / "run.sh"), "restore"],
        env=env,
        capture_output=True,
        check=False,
        timeout=120,
    )
    out = proc.stdout + proc.stderr
    check("a half-extractable archive fails the restore", proc.returncode != 0)
    check(
        "the failed restore left the world in place",
        (saves / "r.0.0.region").read_bytes() == b"current-world",
    )
    check(
        "the failed restore spent no pre-restore snapshot",
        not list(backups.glob("7dtd-saves-*-prerestore*.tar.gz")),
    )
    check(
        "the extraction failure names the archive and the unchanged saves",
        broken.name.encode() in out and b"Saves is unchanged" in out,
    )
    check(
        "the failed restore left no staging dir behind",
        not list((tmpdir / "data" / "userdata").glob(".restore.tmp.*")),
    )


# verify-backup: the periodic proof that a backup is still readable. A backup
# job that exited 0 is a hypothesis about the file it wrote, and a truncated
# copy, a bit-rotted tail or a pruned archive is invisible until a restore
# needs it. The check runs the same preflight restore() runs, exits nonzero on
# an unreadable archive, and fails on a stale schedule (nothing new to restore
# from is the disaster this command exists to catch early).
with tempfile.TemporaryDirectory() as tmp:
    tmpdir = Path(tmp)
    make_sandbox(tmpdir)
    install_podman_stub(tmpdir, PODMAN_STUB)
    saves = tmpdir / "data" / "userdata" / "Saves" / "region"
    saves.mkdir(parents=True)
    (saves / "r.0.0.region").write_bytes(b"current-world")
    backups = tmpdir / "backups"
    backups.mkdir()
    plant_archive(backups / "7dtd-saves-20200101-000000.tar.gz", b"old-world")
    env = stub_env(tmpdir)
    run = tmpdir / "scripts" / "run.sh"

    proc = subprocess.run(
        [str(run), "verify-backup"],
        env=env,
        capture_output=True,
        check=False,
        timeout=120,
    )
    out = proc.stdout + proc.stderr
    check("verify-backup exits 0 on a readable archive", proc.returncode == 0)
    check("verify-backup names the archive it checked", b"7dtd-saves-20200101-000000.tar.gz" in out)
    check(
        "verify-backup reports the archive's age (the RPO)",
        re.search(rb"written \S+ ago", out) is not None,
    )
    check(
        "verify-backup never touches the saves",
        (saves / "r.0.0.region").read_bytes() == b"current-world",
    )
    check("verify-backup wrote no archive of its own", len(list(backups.glob("*.tar.gz"))) == 1)

    # A corrupt archive is the case the command exists for: the backup that
    # wrote it exited 0, and only reading the file back catches it.
    (backups / "7dtd-saves-20200101-000000.tar.gz").write_bytes(b"not-a-tarball")
    proc = subprocess.run(
        [str(run), "verify-backup"],
        env=env,
        capture_output=True,
        check=False,
        timeout=120,
    )
    out = proc.stdout + proc.stderr
    check(
        "verify-backup fails on an unreadable archive",
        proc.returncode == 1 and b"not a readable tar.gz" in out,
    )
    check(
        "the failed verify says the archive would not save an incident",
        b"not restorable" in out,
    )
    check(
        "the failed verify carries tar's own diagnostic",
        b"tar:" in out or b"gzip:" in out,
    )
    # stdout is the verified-archive report; a refusal is a diagnostic and
    # belongs on stderr, so a redirected run keeps its failures out of the
    # data stream and `verify-backup | grep '^OK:'` counts only archives a
    # recovery can use.
    check(
        "the failed verify reports its failures on stderr",
        b"FAIL:" in proc.stderr and b"FAIL:" not in proc.stdout,
    )

    # A named archive is verified on its own, so an operator can check one
    # copy without the rest of backups/.
    plant_archive(backups / "7dtd-saves-20200101-000000.tar.gz", b"old-world")
    proc = subprocess.run(
        [str(run), "verify-backup", "backups/7dtd-saves-20200101-000000.tar.gz"],
        env=env,
        capture_output=True,
        check=False,
        timeout=120,
    )
    check("verify-backup accepts one named archive", proc.returncode == 0)
    check(
        "the named-archive verify checked only that archive",
        proc.stdout.count(b"OK:") == 1,
    )
    proc = subprocess.run(
        [str(run), "verify-backup", "backups/7dtd-saves-19990101-000000.tar.gz"],
        env=env,
        capture_output=True,
        check=False,
        timeout=120,
    )
    check(
        "verify-backup fails on a named archive that is not there",
        proc.returncode == 1 and b"no such backup archive" in proc.stderr,
    )
    check(
        "a verify with nothing to report writes nothing to stdout",
        proc.stdout == b"",
    )

    # A readable archive nobody has refreshed: the backup schedule is not
    # running, and the world is only as safe as the oldest surviving archive.
    stale = backups / "7dtd-saves-20200101-000000.tar.gz"
    old = time.time() - 30 * 86400
    os.utime(stale, (old, old))
    proc = subprocess.run(
        [str(run), "verify-backup"],
        env=env,
        capture_output=True,
        check=False,
        timeout=120,
    )
    out = proc.stdout + proc.stderr
    check("verify-backup fails on a stale archive set", proc.returncode == 1)
    check("the stale failure names the RPO", b"RPO is unbounded" in out)

# An empty backups/ is the state a host is in before the first backup ever
# ran: loud, not a silent pass over zero archives.
with tempfile.TemporaryDirectory() as tmp:
    tmpdir = Path(tmp)
    make_sandbox(tmpdir)
    install_podman_stub(tmpdir, PODMAN_STUB)
    saves = tmpdir / "data" / "userdata" / "Saves" / "region"
    saves.mkdir(parents=True)
    (saves / "r.0.0.region").write_bytes(b"current-world")
    (tmpdir / "backups").mkdir()
    proc = subprocess.run(
        [str(tmpdir / "scripts" / "run.sh"), "verify-backup"],
        env=stub_env(tmpdir),
        capture_output=True,
        check=False,
        timeout=120,
    )
    out = proc.stdout + proc.stderr
    check(
        "verify-backup with no archives refuses loudly",
        proc.returncode == 1 and b"no backup archive" in out,
    )


# The daily backup timer, a systemd-driven stop (the quadlet ExecStop runs
# `run.sh stop`) and an operator's restore all reach the host independently, and
# nothing in the scripts excluded one another: backup()'s tar and restore()'s
# `rm -rf Saves` + extract interleave into a half-deleted, half-extracted tree
# that tar still writes as a usable-looking archive. run.sh serializes every
# command that writes data/ or backups/ on one flock, so a second one waits
# instead of interleaving.
with tempfile.TemporaryDirectory() as tmp:
    tmpdir = Path(tmp)
    make_sandbox(tmpdir)
    install_podman_stub(tmpdir, PODMAN_STUB)
    saves = tmpdir / "data" / "userdata" / "Saves" / "region"
    saves.mkdir(parents=True)
    (saves / "r.0.0.region").write_bytes(b"world")
    backups = tmpdir / "backups"
    backups.mkdir(parents=True)
    lock_env = stub_env(tmpdir)
    run_sh = tmpdir / "scripts" / "run.sh"

    # The lock lives in the sandbox data/ dir, and a read-only command must not
    # queue behind it: `status` only reads podman's state.
    lock = tmpdir / "data" / ".ops.lock"
    lock.touch()
    holder = lock.open("r+b")
    fcntl.flock(holder.fileno(), fcntl.LOCK_EX)
    try:
        proc = subprocess.run(
            [str(run_sh), "status"],
            env=lock_env,
            capture_output=True,
            check=False,
            timeout=30,
        )
        check("a read-only command does not wait on the ops lock", proc.returncode == 0)

        waiter = subprocess.Popen(
            [str(run_sh), "backup"],
            env=lock_env,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        # Held lock, live child: it must still be running and must not have
        # written an archive, which is the whole point of the lock.
        time.sleep(2)
        check("a mutating command waits instead of running", waiter.poll() is None)
        check("the waiting command wrote no archive", not list(backups.iterdir()))
    finally:
        fcntl.flock(holder.fileno(), fcntl.LOCK_UN)
        holder.close()

    _out, err = waiter.communicate(timeout=120)
    check("the queued backup succeeds once the lock is free", waiter.returncode == 0)
    check("the queued backup says what it waited for", b"waiting:" in err)
    check("the queued backup wrote its archive", len(list(backups.iterdir())) == 1)

exit_status()
print("run.sh secret-transport and build contract OK")
