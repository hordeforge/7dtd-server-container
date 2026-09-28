#!/usr/bin/env python3
"""Pin the remote-restart transport contract of scripts/deploy.sh by executing it.

Methodology: deploy.sh --restart pipes SEVENDTD_SERVER_DIR into ssh as stdin
data, never inside the remote command string, so no character in the path can
change what the remote shell runs. The local time bound on that ssh is a
capability probe, not an assumption: timeout(1) is GNU coreutils and missing
from stock macOS workstations (stage_mods.sh targets those too via its bash
3.x arrays), so gtimeout must count as the same capability and a missing both
must degrade to an unsupervised run with a WARN instead of dying after rsync
already pushed the tree.

Everything external runs against stubs on a sandboxed PATH that contains no
system directories, so the probe cannot accidentally see the host's timeout:

  rsync    records argv, transfers nothing
  ssh      records argv plus the stdin bytes it received
  timeout  records argv, then execs the wrapped command so exit codes flow

Scenarios:
  plain       no --restart: staging runs, rsync runs once with the pinned
              argv (--delete, --timeout, and the data/backups excludes), ssh
              never does
  supervised  --restart with timeout on PATH: ssh runs under it, bound to
              300s, and the destination reaches ssh via stdin only
  degraded    --restart with neither timeout nor gtimeout: exit 0, WARN
              names the lost bound, ssh still carries the restart
  failing     --restart whose ssh exits nonzero: deploy exits nonzero and
              the FATAL names phase, host, and the deployed-tree/stale-mods
              state plus the recovery command

Each failed check prints FAIL; the process exits nonzero if any failed.
"""

from __future__ import annotations

import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

from harness import SCRIPTS, check, exit_status

DEPLOY_SH = SCRIPTS / "deploy.sh"


def invocations(log: Path) -> list[list[bytes]]:
    """Split a stub's NUL-separated log into one argv list per invocation."""
    if not log.exists():
        return []
    return [rec.split(b"\0") for rec in log.read_bytes().split(b"\0\0") if rec]


RSYNC_STUB = """#!/usr/bin/env python3
import os
import sys

with open(os.environ["DEPLOY_TEST_RSYNC_LOG"], "ab") as f:
    f.write(b"\\0".join(a.encode() for a in sys.argv[1:]) + b"\\0\\0")
"""

SSH_STUB = """#!/usr/bin/env python3
import os
import sys

with open(os.environ["DEPLOY_TEST_SSH_LOG"], "ab") as f:
    f.write(b"\\0".join(a.encode() for a in sys.argv[1:]) + b"\\0\\0")
with open(os.environ["DEPLOY_TEST_SSH_STDIN"], "ab") as f:
    f.write(sys.stdin.buffer.read())
sys.exit(int(os.environ.get("DEPLOY_TEST_SSH_RC", "0")))
"""

TIMEOUT_STUB = """#!/usr/bin/env python3
import os
import sys

argv = sys.argv[1:]
with open(os.environ["DEPLOY_TEST_TIMEOUT_LOG"], "ab") as f:
    f.write(b"\\0".join(a.encode() for a in argv) + b"\\0\\0")
os.execvp(argv[1], argv[1:])
"""

# External binaries deploy.sh and stage_mods.sh need beyond shell builtins;
# symlinked from the host into the sandbox bin dir so PATH can exclude every
# system directory (and with it any real timeout/gtimeout). cat is needed by
# the usage() heredocs the usage-error scenarios exercise.
NEEDED_BINS = ("bash", "cat", "dirname", "mkdir", "rm", "cp", "mv", "ls", "python3", "pwd")

# stage_mods.sh's SRCS array, keyed the way it enables them: a deploy from a
# workstation with no built sibling repos stages nothing and must fail before
# rsync, never --delete the mods/ set the server host is running.
SIBLING_DIST = {
    "EfficientServer": "7dtd-server-optimizer",
    "7dtd-server-apm-bridge": "7dtd-server-apm",
    "BotMod": "7dtd-fps-bots",
}

HOST = "sentinel-host.lan"
SSH_USER = "sentinel-user"
DEST_DIR = "/home/sentinel-user/7dtd-server"
REMOTE_CMD = 'read -r dest_dir && cd "$dest_dir" && ./scripts/update_mods.sh'
EXPECTED_SSH_ARGV = [
    b"-o",
    b"ConnectTimeout=10",
    f"{SSH_USER}@{HOST}".encode(),
    REMOTE_CMD.encode(),
]

# The whole rsync argv is load-bearing, not just its last word: --delete with a
# dropped --exclude data/backups would wipe server-owned saves and backup
# archives, and a dropped --timeout=60 would leave a stalled transfer hanging.
EXPECTED_RSYNC_ARGV = [
    b"-a",
    b"--delete",
    b"--timeout=60",
    b"-e",
    b"ssh -o ConnectTimeout=10",
    b"--exclude",
    b".git",
    b"--exclude",
    b"data",
    b"--exclude",
    b"backups",
    b"--exclude",
    b".mypy_cache",
    b"--exclude",
    b".ruff_cache",
    b"--exclude",
    b".venv",
    b"--exclude",
    b"__pycache__",
    b"--exclude",
    b"coverage",
    b"--exclude",
    b"coverage.cobertura.xml",
    b"--exclude",
    b".scratch*",
]


def make_sandbox(
    tmpdir: Path, timeout_name: str | None, with_dists: bool = True
) -> tuple[Path, dict[str, str]]:
    """Copy the deploy path into a sandbox; return (project root, run env).

    timeout_name installs the time-bound stub under that binary name (timeout,
    gtimeout); None leaves both out so the probe finds neither. with_dists
    seeds the sibling dist/ dirs stage_mods.sh stages from, which is what a
    workstation running a deploy actually has.
    """
    project = tmpdir / "project"
    (project / "scripts").mkdir(parents=True)
    shutil.copy2(DEPLOY_SH, project / "scripts" / "deploy.sh")
    shutil.copy2(SCRIPTS / "stage_mods.sh", project / "scripts" / "stage_mods.sh")
    shutil.copy2(SCRIPTS / "lib-env.sh", project / "scripts" / "lib-env.sh")
    if with_dists:
        for mod, sibling in SIBLING_DIST.items():
            (tmpdir / sibling / "dist" / mod / "Config").mkdir(parents=True)
            (tmpdir / sibling / "dist" / mod / "Config" / "config.json").write_text(mod)

    bindir = tmpdir / "bin"
    bindir.mkdir()
    for name in NEEDED_BINS:
        resolved = shutil.which(name)
        if resolved is None:
            print(f"FAIL: required binary {name} not found on PATH", file=sys.stderr)
            sys.exit(1)
        bindir.joinpath(name).symlink_to(resolved)
    stubs: dict[str, str] = {"rsync": RSYNC_STUB, "ssh": SSH_STUB}
    if timeout_name is not None:
        stubs[timeout_name] = TIMEOUT_STUB
    for name, text in stubs.items():
        stub = bindir / name
        stub.write_text(text, encoding="utf-8")
        stub.chmod(0o755)

    env = {
        **os.environ,
        # Sandbox bin dir only: the degraded scenario needs proof that neither
        # timeout nor gtimeout is reachable from deploy.sh's probe.
        "PATH": str(bindir),
        "SEVENDTD_SERVER_HOST": HOST,
        "SEVENDTD_SERVER_USER": SSH_USER,
        "SEVENDTD_SERVER_DIR": DEST_DIR,
        "DEPLOY_TEST_RSYNC_LOG": str(tmpdir / "rsync-argv.log"),
        "DEPLOY_TEST_SSH_LOG": str(tmpdir / "ssh-argv.log"),
        "DEPLOY_TEST_SSH_STDIN": str(tmpdir / "ssh-stdin.log"),
        "DEPLOY_TEST_TIMEOUT_LOG": str(tmpdir / "timeout-argv.log"),
    }
    return project, env


def run_deploy(
    project: Path, env: dict[str, str], *args: str
) -> subprocess.CompletedProcess[bytes]:
    return subprocess.run(
        [str(project / "scripts" / "deploy.sh"), *args],
        env=env,
        capture_output=True,
        check=False,
        timeout=120,
    )


def fail_stderr(proc: subprocess.CompletedProcess[bytes]) -> None:
    print(proc.stderr.decode(errors="replace"), file=sys.stderr)


def expected_rsync_argv(project: Path) -> list[bytes]:
    """rsync's full argv for this sandbox: pinned flags, source, destination."""
    return [
        *EXPECTED_RSYNC_ARGV,
        f"{project}/".encode(),
        f"{SSH_USER}@{HOST}:{DEST_DIR}/".encode(),
    ]


# Plain deploy: staging + rsync only; nothing may reach ssh.
with tempfile.TemporaryDirectory() as tmp:
    tmpdir = Path(tmp)
    project, env = make_sandbox(tmpdir, timeout_name=None)
    proc = run_deploy(project, env)
    check("plain deploy exits 0", proc.returncode == 0)
    if proc.returncode != 0:
        fail_stderr(proc)
    rsync_calls = invocations(Path(env["DEPLOY_TEST_RSYNC_LOG"]))
    check("plain deploy rsyncs exactly once", len(rsync_calls) == 1)
    check(
        "rsync argv pins the transfer flags, the source tree, and the host destination",
        rsync_calls == [expected_rsync_argv(project)],
    )
    check(
        "plain deploy staged before transferring (both mod dirs exist)",
        (project / "mods").is_dir() and (project / "mods-available").is_dir(),
    )
    check(
        "plain deploy never opens an ssh session",
        invocations(Path(env["DEPLOY_TEST_SSH_LOG"])) == [],
    )

# Staging that cannot produce the enabled set must abort the deploy before
# rsync runs: rsync --delete would otherwise strip the mods/ set the server
# host is running, and the deploy would report success.
with tempfile.TemporaryDirectory() as tmp:
    tmpdir = Path(tmp)
    project, env = make_sandbox(tmpdir, timeout_name=None, with_dists=False)
    proc = run_deploy(project, env)
    err = proc.stderr.decode(errors="replace")
    check("deploy without built sibling mods exits nonzero", proc.returncode != 0)
    check("deploy without built sibling mods names staging", "mods-available" in err)
    check(
        "deploy without built sibling mods never reached rsync",
        invocations(Path(env["DEPLOY_TEST_RSYNC_LOG"])) == [],
    )

# Supervised restart: ssh under the probed wrapper, destination via stdin only.
with tempfile.TemporaryDirectory() as tmp:
    tmpdir = Path(tmp)
    project, env = make_sandbox(tmpdir, timeout_name="timeout")
    proc = run_deploy(project, env, "--restart")
    check("--restart with timeout(1) exits 0", proc.returncode == 0)
    if proc.returncode != 0:
        fail_stderr(proc)
    ssh_calls = invocations(Path(env["DEPLOY_TEST_SSH_LOG"]))
    check("the restart drives exactly one ssh session", len(ssh_calls) == 1)
    check(
        "ssh argv pins connect timeout, host, and remote command",
        bool(ssh_calls) and ssh_calls[0] == EXPECTED_SSH_ARGV,
    )
    timeout_calls = invocations(Path(env["DEPLOY_TEST_TIMEOUT_LOG"]))
    check(
        "ssh runs under the local 300s bound",
        timeout_calls == [[b"300", b"ssh", *EXPECTED_SSH_ARGV]],
    )
    stdin_log = Path(env["DEPLOY_TEST_SSH_STDIN"])
    got_stdin = stdin_log.read_bytes() if stdin_log.exists() else b""
    check(
        "the destination travels as stdin data byte-exact",
        got_stdin == f"{DEST_DIR}\n".encode(),
    )
    leaked = [a for call in ssh_calls for a in call if DEST_DIR.encode() in a]
    check(
        f"no ssh argument names the destination (found: {leaked})",
        leaked == [],
    )

# gtimeout (coreutils via brew, the usual macOS install) must count as the
# same capability: the probe falls back to it and supervision still applies.
with tempfile.TemporaryDirectory() as tmp:
    tmpdir = Path(tmp)
    project, env = make_sandbox(tmpdir, timeout_name="gtimeout")
    proc = run_deploy(project, env, "--restart")
    check("--restart with only gtimeout exits 0", proc.returncode == 0)
    if proc.returncode != 0:
        fail_stderr(proc)
    check(
        "gtimeout supervises ssh with the same 300s bound",
        invocations(Path(env["DEPLOY_TEST_TIMEOUT_LOG"])) == [[b"300", b"ssh", *EXPECTED_SSH_ARGV]],
    )

# Degraded restart: neither timeout nor gtimeout reachable; warn and continue.
with tempfile.TemporaryDirectory() as tmp:
    tmpdir = Path(tmp)
    project, env = make_sandbox(tmpdir, timeout_name=None)
    proc = run_deploy(project, env, "--restart")
    check("--restart without timeout or gtimeout exits 0", proc.returncode == 0)
    if proc.returncode != 0:
        fail_stderr(proc)
    check(
        "stderr names the lost local time bound",
        b"WARN" in proc.stderr and b"timeout" in proc.stderr,
    )
    ssh_calls = invocations(Path(env["DEPLOY_TEST_SSH_LOG"]))
    check(
        "degraded restart still sends the restart command over ssh",
        len(ssh_calls) == 1 and ssh_calls[0] == EXPECTED_SSH_ARGV,
    )
    stdin_log = Path(env["DEPLOY_TEST_SSH_STDIN"])
    got_stdin = stdin_log.read_bytes() if stdin_log.exists() else b""
    check(
        "degraded restart still pipes the destination",
        got_stdin == f"{DEST_DIR}\n".encode(),
    )

# Failing remote restart: rsync already pushed the tree, so a bare nonzero
# exit would leave the operator guessing which phase broke and whether the
# server host is now inconsistent. The failure must name the host and phase
# and say how to finish (update_mods.sh there, or re-run --restart).
with tempfile.TemporaryDirectory() as tmp:
    tmpdir = Path(tmp)
    project, env = make_sandbox(tmpdir, timeout_name="timeout")
    env["DEPLOY_TEST_SSH_RC"] = "255"
    proc = run_deploy(project, env, "--restart")
    # The FATAL is the only message here that may carry the failure: the
    # pre-restart "deployed ..." line goes to stdout and already names the host,
    # so a combined-stream match would pass on the success line alone.
    err = proc.stderr
    fatal = next((line for line in err.splitlines() if line.startswith(b"FATAL:")), b"")
    check("failing remote restart exits 1", proc.returncode == 1)
    check(
        f"the failed restart names the phase and host (stderr: {err!r})",
        fatal.startswith(b"FATAL: remote restart on ")
        and f"{SSH_USER}@{HOST}".encode() in fatal
        and b"failed (exit 255)" in fatal,
    )
    check(
        "the failed restart reports deployed-tree/stale-mods state",
        b"the tree is deployed" in err and b"old mods" in err,
    )
    check(
        "the failed restart names the recovery command",
        b"./scripts/update_mods.sh" in err and b"deploy.sh --restart" in err,
    )
    check(
        "rsync still ran before the failing restart, with the pinned argv",
        invocations(Path(env["DEPLOY_TEST_RSYNC_LOG"])) == [expected_rsync_argv(project)]
        and len(invocations(Path(env["DEPLOY_TEST_SSH_LOG"]))) == 1,
    )

# Usage errors are refused before staging touches anything: a silently
# ignored second word would let e.g. `deploy.sh --restart dry-run` read as
# a supported option while the full deploy ran anyway.
with tempfile.TemporaryDirectory() as tmp:
    tmpdir = Path(tmp)
    project, env = make_sandbox(tmpdir, timeout_name=None)
    proc = run_deploy(project, env, "--restart", "frobnicate")
    out = proc.stdout + proc.stderr
    check("extra argument exits 2 naming it", proc.returncode == 2 and b"frobnicate" in out)
    check(
        "the refused deploy staged and rsynced nothing",
        invocations(Path(env["DEPLOY_TEST_RSYNC_LOG"])) == []
        and not (project / "mods").exists()
        and not (project / "mods-available").exists(),
    )
    proc = run_deploy(project, env, "frobnicate")
    out = proc.stdout + proc.stderr
    check(
        "unknown argument exits 2 naming it with usage",
        proc.returncode == 2 and b"frobnicate" in out and b"usage:" in out,
    )
    check(
        "the rejected unknown argument also staged nothing",
        invocations(Path(env["DEPLOY_TEST_RSYNC_LOG"])) == []
        and not (project / "mods").exists()
        and not (project / "mods-available").exists(),
    )

# The three SEVENDTD_* values land in ssh/rsync argv, where a token starting
# with '-' is an option, not a destination: '-oProxyCommand=...' would run a
# command on the deploy workstation. The shape check must refuse that before
# anything is staged or transferred.
with tempfile.TemporaryDirectory() as tmp:
    tmpdir = Path(tmp)
    for var, hostile in (
        ("SEVENDTD_SERVER_HOST", "-oProxyCommand=touch /tmp/pwned"),
        ("SEVENDTD_SERVER_USER", "-oProxyCommand=touch /tmp/pwned"),
        ("SEVENDTD_SERVER_DIR", "~/7dtd-server; touch /tmp/pwned"),
    ):
        project, env = make_sandbox(tmpdir / var, timeout_name=None)
        env[var] = hostile
        proc = run_deploy(project, env)
        out = proc.stdout + proc.stderr
        check(f"{var} rejects an argv-injection shape", proc.returncode == 2)
        check(f"{var} rejection names the variable", var.encode() in out)
        check(
            f"{var} rejection transferred nothing",
            invocations(Path(env["DEPLOY_TEST_RSYNC_LOG"])) == []
            and invocations(Path(env["DEPLOY_TEST_SSH_LOG"])) == [],
        )

exit_status()
print("deploy.sh remote-restart contract OK")
