#!/usr/bin/env python3
"""Pin the mod-staging contract of stage_mods.sh and update_mods.sh.

Methodology: staging owns what reaches the game's Mods/ dir, and its
documented failure modes are litter and drift: a cp killed midway must not
leave a half-written mod dir (staging goes through hidden .*.tmp.$$ renames),
everything in mods/ outside the owned NAMES set is wiped on every stage, and
a missing sibling dist must warn instead of silently enabling nothing.
stage_mods.sh computes the workspace root itself, so the sandbox gets a
patched copy whose WS points at fake sibling dist dirs; update_mods.sh runs
unpatched against a sandbox tree with a stub run.sh recording restarts:

  stage       exact NAMES set enabled as real copies (marker files land),
              stale enabled mods wiped, hidden staging litter swept from
              both directories
  stage-miss  a missing dist warns on stderr, stages nothing for that mod,
              and still stages the rest
  stage-wipe  a run that stages none of the owned mods, and a run whose enable
              copy fails, both leave the previously enabled set untouched
              instead of wiping it and exiting 0
  update      restage copies mods-available content over every mod already
              enabled in mods/ (marker propagates), leaves a mod that has
              no mods-available counterpart alone, never enables a mod that
              is staged but not yet enabled, sweeps litter, and restarts
              exactly once via `run.sh restart`
  update-none no mods-available/ at all: the restage is skipped, the enabled
              mods stay as they are, and the restart still happens
  mismatch    a NAMES/SRCS length mismatch is refused before anything is
              staged

Each failed check prints a FAIL line; the process exits nonzero if any failed.
"""

from __future__ import annotations

import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

from harness import SCRIPTS, check, exit_status, resolved_bin_path

# stage_mods.sh's SRCS array, keyed the way the script enables them.
SIBLING_OF = {
    "EfficientServer": "7dtd-server-optimizer",
    "7dtd-server-apm-bridge": "7dtd-server-apm",
    "BotMod": "7dtd-fps-bots",
}
NAMES = list(SIBLING_OF)

WS_LINE = 'WS="$(cd "$ROOT/.." && pwd)"'

SANDBOX_PATH = resolved_bin_path("bash", "cp", "mv", "rm", "ls", "mkdir", "basename", "dirname")


def fake_dist(ws: Path, name: str, marker: str) -> Path:
    """Create <ws>/<sibling>/dist/<name> with one marker file inside."""
    dist = ws / SIBLING_OF[name] / "dist"
    (dist / name / "Config").mkdir(parents=True)
    (dist / name / "Config" / "config.json").write_text(marker, encoding="utf-8")
    return dist / name


def make_stage_sandbox(tmpdir: Path, present: list[str]) -> Path:
    """Sandbox ROOT with a patched stage_mods.sh and fake sibling dists."""
    root = tmpdir / "srv"
    scripts = root / "scripts"
    scripts.mkdir(parents=True)
    ws = tmpdir / "ws"
    src = (SCRIPTS / "stage_mods.sh").read_text(encoding="utf-8")
    if WS_LINE not in src:
        print(f"FAIL: stage_mods.sh workspace line drifted: {WS_LINE!r} not found", file=sys.stderr)
        sys.exit(1)
    shutil.copy2(SCRIPTS / "lib-env.sh", scripts / "lib-env.sh")
    staged_script = scripts / "stage_mods.sh"
    staged_script.write_text(src.replace(WS_LINE, f'WS="{ws}"'), encoding="utf-8")
    staged_script.chmod(0o755)
    for i, name in enumerate(NAMES):
        if name in present:
            fake_dist(ws, name, f"marker-{name}-{i}")
    return root


def run_script(
    script: Path, *args: str, cwd: Path, env: dict[str, str]
) -> subprocess.CompletedProcess[bytes]:
    return subprocess.run(
        [str(script), *args],
        cwd=cwd,
        env={"PATH": SANDBOX_PATH, **env},
        capture_output=True,
        check=False,
        timeout=60,
    )


def dead_pid() -> int:
    """A PID no process owns, so the sweep must reclaim its entries.

    Reaped, not merely exited: an unreaped zombie still answers kill -0, which
    is the same liveness test the sweep applies.
    """
    proc = subprocess.Popen(["true"])
    proc.wait()
    return proc.pid


def tmp_litter(directory: Path, owner: str, pid: int) -> Path:
    """A leftover staging entry as a killed cp would strand it."""
    directory.mkdir(parents=True, exist_ok=True)
    litter = directory / f".{owner}.tmp.{pid}"
    litter.mkdir()
    (litter / "half-written").write_text("junk", encoding="utf-8")
    return litter


def litter_gone(*dirs: Path) -> bool:
    return not any(entry.name.startswith(".") for d in dirs for entry in d.iterdir())


def seeded_mod(base: Path, name: str, marker: str) -> None:
    mod = base / name / "Config"
    mod.mkdir(parents=True)
    (mod / "config.json").write_text(marker, encoding="utf-8")


with tempfile.TemporaryDirectory() as tmp:
    tmpdir = Path(tmp)
    root = make_stage_sandbox(tmpdir / "full", NAMES)
    mods = root / "mods"
    mods_available = root / "mods-available"

    # A stale hand-enabled mod and stranded staging entries must not survive,
    # but a live owner's in-flight entry must: the sweep runs on every stage,
    # so a blanket rm of the `.*.tmp.*` shape would delete a concurrent run's
    # tree between its cp and its rename.
    seeded_mod(mods, "OldMod", "stale")
    dead_a = tmp_litter(mods, "EfficientServer", dead_pid())
    dead_b = tmp_litter(mods_available, "BotMod", dead_pid())
    live = tmp_litter(mods, "7dtd-server-apm-bridge", os.getpid())
    retired = mods / f".EfficientServer.tmp.retired.{os.getpid()}"
    retired.mkdir()

    proc = run_script(root / "scripts" / "stage_mods.sh", cwd=root, env={})
    err = proc.stderr.decode(errors="replace")
    check("stage with all dists exits 0", proc.returncode == 0)
    if proc.returncode != 0:
        print(err, file=sys.stderr)
    check(
        "mods carries exactly the owned NAMES set",
        sorted(p.name for p in mods.iterdir() if not p.name.startswith(".")) == sorted(NAMES),
    )
    check(
        "staged mods are real copies (marker files landed)",
        all(
            (mods / name / "Config" / "config.json").read_text(encoding="utf-8")
            == f"marker-{name}-{i}"
            for i, name in enumerate(NAMES)
        ),
    )
    check("stale hand-enabled mod was wiped", not (mods / "OldMod").exists())
    check("dead owners' staging litter swept from both directories", not dead_a.exists())
    check("dead owners' staging litter swept from mods-available too", not dead_b.exists())
    check(
        "a live owner's in-flight staging entry is left alone",
        live.is_dir() and retired.is_dir(),
    )
    # The entries just planted stand in for concurrent runs; drop them so the
    # cases below start from a clean tree.
    shutil.rmtree(live)
    shutil.rmtree(retired)
    check("staging litter swept from both directories", litter_gone(mods, mods_available))

    # A missing sibling dist warns but must not block the other mods.
    root = make_stage_sandbox(tmpdir / "missing", ["EfficientServer"])
    proc = run_script(root / "scripts" / "stage_mods.sh", cwd=root, env={})
    err = proc.stderr.decode(errors="replace")
    check("stage with a missing dist exits 0", proc.returncode == 0)
    check(
        "missing dist warned on stderr",
        "WARN" in err and "BotMod" in err and "7dtd-server-apm-bridge" in err,
    )
    check(
        "only present dists were enabled",
        sorted(p.name for p in (root / "mods").iterdir()) == ["EfficientServer"],
    )

# The enabled set is the one thing staging must never lose: deploy.sh pushes
# whatever mods/ holds, so a run that fails part way (or stages nothing at all)
# would otherwise wipe it and still read as a successful deploy.
with tempfile.TemporaryDirectory() as tmp:
    tmpdir = Path(tmp)

    # Nothing staged at all: the previously enabled mods must survive and the
    # run must fail rather than swap an empty set in.
    root = make_stage_sandbox(tmpdir / "none", [])
    seeded_mod(root / "mods", "OldMod", "stale")
    proc = run_script(root / "scripts" / "stage_mods.sh", cwd=root, env={})
    err = proc.stderr.decode(errors="replace")
    check("stage with no dists exits 1", proc.returncode == 1)
    check("stage with no dists names the cause", "FATAL" in err and "mods-available" in err)
    check(
        "stage with no dists left the enabled set alone",
        sorted(p.name for p in (root / "mods").iterdir()) == ["OldMod"],
    )

    # A copy that fails mid-rebuild: the swap happens only after every copy
    # succeeded, so the previous set (including the not-yet-copied mods) stays.
    # Nothing writes into mods/ before the swap, so a mod the loop never
    # reached keeps its old content and a mod enabled by hand is not swept.
    root = make_stage_sandbox(tmpdir / "failing", NAMES)
    mods = root / "mods"
    seeded_mod(mods, "EfficientServer", "live-efficient")
    seeded_mod(mods, "BotMod", "live-bot")
    seeded_mod(mods, "OldMod", "stale")
    script = root / "scripts" / "stage_mods.sh"
    enable_step = 'sync_tree "$ROOT/mods-available/$name" "$enabled_staging/$name"'
    src = script.read_text(encoding="utf-8")
    if enable_step not in src:
        print(
            f"FAIL: stage_mods.sh enable step drifted: {enable_step!r} not found",
            file=sys.stderr,
        )
        sys.exit(1)
    script.write_text(
        src.replace(
            enable_step,
            f'{{ if [[ "$name" != BotMod ]]; then {enable_step}; else false; fi }}',
        ),
        encoding="utf-8",
    )
    proc = run_script(script, cwd=root, env={})
    err = proc.stderr.decode(errors="replace")
    check("a failed enable copy exits 1", proc.returncode == 1)
    check("a failed enable copy names the mod", "FATAL" in err and "BotMod" in err)
    check(
        "a failed enable copy kept the previous enabled set",
        sorted(p.name for p in mods.iterdir()) == ["BotMod", "EfficientServer", "OldMod"],
    )
    check(
        "a failed enable copy left the old mod content in place",
        (mods / "EfficientServer" / "Config" / "config.json").read_text(encoding="utf-8")
        == "live-efficient"
        and (mods / "BotMod" / "Config" / "config.json").read_text(encoding="utf-8") == "live-bot",
    )
    check("a failed enable copy swept its staging dir", litter_gone(mods))

# NAMES and SRCS are read by index: a mod listed in one and not the other would
# stage a sibling's dist under another mod's name, so the script must refuse
# before it stages anything.
with tempfile.TemporaryDirectory() as tmp:
    tmpdir = Path(tmp)
    root = make_stage_sandbox(tmpdir / "mismatched", NAMES)
    script = root / "scripts" / "stage_mods.sh"
    src = script.read_text(encoding="utf-8")
    short = src.replace('  "$WS/7dtd-fps-bots/dist/BotMod"\n', "")
    check("the BotMod SRCS line is present to remove", short != src)
    script.write_text(short, encoding="utf-8")

    proc = run_script(script, cwd=root, env={})
    err = proc.stderr.decode(errors="replace")
    check("mismatched NAMES/SRCS exits 1", proc.returncode == 1)
    check("mismatch names both sides on stderr", "FATAL" in err and "SRCS" in err)
    mods = root / "mods"
    check(
        "the mismatched run staged nothing",
        not mods.exists() or list(mods.iterdir()) == [],
    )

# update_mods.sh: server-side restage from mods-available/ plus one restart.
with tempfile.TemporaryDirectory() as tmp:
    tmpdir = Path(tmp)
    root = tmpdir / "srv"
    scripts = root / "scripts"
    scripts.mkdir(parents=True)
    shutil.copy2(SCRIPTS / "lib-env.sh", scripts / "lib-env.sh")
    shutil.copy2(SCRIPTS / "update_mods.sh", scripts / "update_mods.sh")

    stub_log = root / "restarts.log"
    stub = scripts / "run.sh"
    stub.write_text(
        '#!/usr/bin/env bash\nprintf "%s\\n" "$*" >> "$UPD_STUB_LOG"\n', encoding="utf-8"
    )
    stub.chmod(0o755)

    # mods-available is the newer truth: both enabled mods carry new markers;
    # StaleMod lives only in mods/ (no mods-available counterpart) and must
    # survive untouched.
    mods_available = root / "mods-available"
    mods = root / "mods"
    seeded_mod(mods_available, "EfficientServer", "new-marker")
    seeded_mod(mods_available, "BotMod", "bot-new")
    seeded_mod(mods, "EfficientServer", "old-marker")
    seeded_mod(mods, "BotMod", "bot-old")
    seeded_mod(mods, "StaleMod", "keep-me")
    # Staged but never enabled: update restages what is already enabled in
    # mods/, so a mods-available-only mod must not sneak in.
    seeded_mod(mods_available, "NotEnabled", "not-enabled")
    tmp_litter(mods, "BotMod", dead_pid())

    proc = run_script(scripts / "update_mods.sh", cwd=root, env={"UPD_STUB_LOG": str(stub_log)})
    err = proc.stderr.decode(errors="replace")
    check("update exits 0", proc.returncode == 0)
    if proc.returncode != 0:
        print(err, file=sys.stderr)
    check(
        "restaged mod took the mods-available content",
        (mods / "EfficientServer" / "Config" / "config.json").read_text(encoding="utf-8")
        == "new-marker",
    )
    check(
        "second enabled mod refreshed too",
        (mods / "BotMod" / "Config" / "config.json").read_text(encoding="utf-8") == "bot-new",
    )
    check(
        "unowned mod left alone",
        (mods / "StaleMod" / "Config" / "config.json").read_text(encoding="utf-8") == "keep-me",
    )
    check("restage swept staging litter", litter_gone(mods))
    check(
        "a mod staged but not enabled was not enabled by the update",
        not (mods / "NotEnabled").exists(),
    )
    check(
        "update restarted the container exactly once, with the restart subcommand",
        stub_log.read_text(encoding="utf-8") == "restart\n",
    )

    # A restart that fails leaves the restaged mods on disk and the running
    # container on the old set: the run must say so rather than exit on
    # run.sh's bare status and read as a completed restage.
    stub.write_text("#!/usr/bin/env bash\nprintf 'restart\\n' >> \"$UPD_STUB_LOG\"\nexit 3\n")
    proc = run_script(scripts / "update_mods.sh", cwd=root, env={"UPD_STUB_LOG": str(stub_log)})
    err = proc.stderr.decode(errors="replace")
    check("a failed restart exits nonzero", proc.returncode != 0)
    check(
        "a failed restart names the stale-mods state and the way out",
        "FATAL" in err and "old Mods/" in err and "run.sh start" in err,
    )
    check(
        "the restage still happened before the failed restart",
        (mods / "BotMod" / "Config" / "config.json").read_text(encoding="utf-8") == "bot-new",
    )
    stub.write_text("#!/usr/bin/env bash\nprintf 'restart\\n' >> \"$UPD_STUB_LOG\"\n")
    # The usage scenarios below count restarts from a clean log: the failing
    # restart above is its own scenario, not part of the successful run.
    stub_log.write_text("")
    restarts_before = stub_log.read_text(encoding="utf-8")

    # Same usage contract as stage_mods.sh: help wins over extra words,
    # anything else exits 2 naming the word, and none of it may restage
    # or restart.
    proc = run_script(
        scripts / "update_mods.sh",
        "--help",
        "frobnicate",
        cwd=root,
        env={"UPD_STUB_LOG": str(stub_log)},
    )
    out = proc.stdout + proc.stderr
    check("update --help answers 0 even with an extra word", proc.returncode == 0)
    check("the --help answer carries the usage text", b"usage: update_mods.sh" in proc.stdout)
    proc = run_script(
        scripts / "update_mods.sh",
        "--dry-run",
        cwd=root,
        env={"UPD_STUB_LOG": str(stub_log)},
    )
    err = proc.stderr.decode(errors="replace")
    check("update unknown flag exits 2 naming it", proc.returncode == 2 and "--dry-run" in err)
    check(
        "rejected update invocations restarted nothing more",
        stub_log.read_text(encoding="utf-8") == restarts_before,
    )

# No mods-available/ at all (a tree that predates staging, or one where the
# directory was removed): update must skip the restage instead of erroring,
# leave the enabled mods as they are, and still restart so the entrypoint
# re-syncs Mods/.
with tempfile.TemporaryDirectory() as tmp:
    tmpdir = Path(tmp)
    root = tmpdir / "srv"
    scripts = root / "scripts"
    scripts.mkdir(parents=True)
    shutil.copy2(SCRIPTS / "lib-env.sh", scripts / "lib-env.sh")
    shutil.copy2(SCRIPTS / "update_mods.sh", scripts / "update_mods.sh")
    stub_log = root / "restarts.log"
    stub = scripts / "run.sh"
    stub.write_text('#!/usr/bin/env bash\nprintf "%s\\n" "$*" >> "$UPD_STUB_LOG"\n')
    stub.chmod(0o755)
    mods = root / "mods"
    seeded_mod(mods, "EfficientServer", "untouched")

    proc = run_script(scripts / "update_mods.sh", cwd=root, env={"UPD_STUB_LOG": str(stub_log)})
    check(
        f"update without mods-available exits 0 (stderr: {proc.stderr.decode(errors='replace')!r})",
        proc.returncode == 0,
    )
    check(
        "update without mods-available left the enabled mods alone",
        (mods / "EfficientServer" / "Config" / "config.json").read_text(encoding="utf-8")
        == "untouched",
    )
    check(
        "update without mods-available still restarted once",
        stub_log.read_text(encoding="utf-8") == "restart\n",
    )

# Usage errors are refused before any staging side effect, and the offending
# word is named: a silently ignored argument would read as success while the
# enabled set was rebuilt anyway. Help still wins over extra words, exactly
# like scripts/run.sh.
with tempfile.TemporaryDirectory() as tmp:
    tmpdir = Path(tmp)
    root = make_stage_sandbox(tmpdir / "usage-errors", NAMES)
    script = root / "scripts" / "stage_mods.sh"
    mods = root / "mods"

    proc = run_script(script, "--help", "frobnicate", cwd=root, env={})
    out = proc.stdout + proc.stderr
    check("--help answers 0 even with an extra word", proc.returncode == 0)
    check("the --help answer carries the usage text", b"usage: stage_mods.sh" in proc.stdout)

    proc = run_script(script, "--dry-run", cwd=root, env={})
    err = proc.stderr.decode(errors="replace")
    check(
        "unknown flag exits 2 naming it with usage",
        proc.returncode == 2 and "--dry-run" in err and "usage:" in err,
    )

    # The empty command word plus a stray word must hit the second-word
    # guard instead of falling through the case into a full staging run.
    proc = run_script(script, "", "frobnicate", cwd=root, env={})
    err = proc.stderr.decode(errors="replace")
    check("second word exits 2 naming it", proc.returncode == 2 and "frobnicate" in err)
    check(
        "no rejected invocation staged anything",
        not mods.exists() and not (root / "mods-available").exists(),
    )

exit_status()
print("mod staging contract OK")
