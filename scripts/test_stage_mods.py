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
  update      restage copies mods-available content over every mod already
              enabled in mods/ (marker propagates), leaves a mod that has
              no mods-available counterpart alone, sweeps litter, and
              restarts exactly once

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


# stage_mods.sh's SRCS array, keyed the way the script enables them.
SIBLING_OF = {
    "EfficientServer": "7dtd-server-optimizer",
    "7dtd-server-apm-bridge": "7dtd-server-apm",
    "BotMod": "7dtd-fps-bots",
}
NAMES = list(SIBLING_OF)

WS_LINE = 'WS="$(cd "$ROOT/.." && pwd)"'


def fake_dist(ws: Path, name: str, marker: str) -> Path:
    """Create <ws>/<sibling>/dist/<name> with one marker file inside."""
    dist = ws / SIBLING_OF[name] / "dist"
    (dist / name / "Config").mkdir(parents=True)
    (dist / name / "Config" / "config.json").write_text(marker)
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
        env={"PATH": "/usr/bin:/bin", **env},
        capture_output=True,
        check=False,
        timeout=60,
    )


def tmp_litter(directory: Path, owner: str) -> None:
    """A leftover staging entry as a killed cp would strand it."""
    directory.mkdir(parents=True, exist_ok=True)
    litter = directory / f".{owner}.tmp.999"
    litter.mkdir()
    (litter / "half-written").write_text("junk")


def litter_gone(*dirs: Path) -> bool:
    return not any(entry.name.startswith(".") for d in dirs for entry in d.iterdir())


def seeded_mod(base: Path, name: str, marker: str) -> None:
    mod = base / name / "Config"
    mod.mkdir(parents=True)
    (mod / "config.json").write_text(marker)


with tempfile.TemporaryDirectory() as tmp:
    tmpdir = Path(tmp)
    root = make_stage_sandbox(tmpdir / "full", NAMES)
    mods = root / "mods"
    mods_available = root / "mods-available"

    # A stale hand-enabled mod and stranded staging entries must not survive.
    seeded_mod(mods, "OldMod", "stale")
    tmp_litter(mods, "EfficientServer")
    tmp_litter(mods_available, "BotMod")

    proc = run_script(root / "scripts" / "stage_mods.sh", cwd=root, env={})
    err = proc.stderr.decode(errors="replace")
    check("stage with all dists exits 0", proc.returncode == 0)
    if proc.returncode != 0:
        print(err, file=sys.stderr)
    check(
        "mods carries exactly the owned NAMES set",
        sorted(p.name for p in mods.iterdir()) == sorted(NAMES),
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

# update_mods.sh: server-side restage from mods-available/ plus one restart.
with tempfile.TemporaryDirectory() as tmp:
    tmpdir = Path(tmp)
    root = tmpdir / "srv"
    scripts = root / "scripts"
    scripts.mkdir(parents=True)
    shutil.copy2(SCRIPTS / "update_mods.sh", scripts / "update_mods.sh")

    stub_log = root / "restarts.log"
    stub = scripts / "run.sh"
    stub.write_text("#!/usr/bin/env bash\nprintf 'restart\\n' >> \"$UPD_STUB_LOG\"\n")
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
    tmp_litter(mods, "BotMod")

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
        "update restarted the container exactly once",
        stub_log.read_text(encoding="utf-8") == "restart\n",
    )

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
        not mods.exists() or list(mods.iterdir()) == [],
    )

if failed_checks:
    sys.exit(1)
print("mod staging contract OK")
