#!/usr/bin/env python3
"""Boot-path tests for entrypoint.sh's config render and admin seed contract.

Methodology: entrypoint.sh only ever executes inside its container image, so
its failure paths were untestable until now. A sandbox gets a patched copy of
entrypoint.sh (hardcoded image paths rewritten to sandbox paths), a steamcmd
stub that just creates the expected server binary, and the real config
templates plus scripts/lib-env.sh. With STEAMCMD_ONLY=1 the run covers every
step up to the exec boundary:

  fresh      render_config + seed_admin_file succeed; serverconfig.xml is
             fully rendered, the minted webadmin credential record matches
             the digest embedded in serveradmin.xml, and no temp files leak
  existing   a later boot with WEBADMIN_PASSWORD set skips the seed with a
             visible warning instead of silently dropping the value
  reseed     deleting serveradmin.xml makes the next boot re-seed under an
             operator password and remove the stale minted record
  bad-tmpl   an unrendered placeholder fatal-exits AND leaves neither the
             half-rendered temp file nor any seeded output behind

Each failed check prints a FAIL line; the process exits nonzero if any failed.
"""

from __future__ import annotations

import base64
import hashlib
import re
import shutil
import stat
import subprocess
import sys
import tempfile
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parent
ROOT = SCRIPTS.parent
ENTRYPOINT = ROOT / "entrypoint.sh"
LIB_ENV = SCRIPTS / "lib-env.sh"
CONFIG = ROOT / "config"

failed_checks: list[str] = []


def check(name: str, cond: bool) -> bool:
    if cond:
        print(f"OK: {name}")
    else:
        print(f"FAIL: {name}", file=sys.stderr)
        failed_checks.append(name)
    return cond


def digest(pw: str) -> str:
    """The exact md5-base64 form the dashboard expects (see lib-env.sh)."""
    return base64.b64encode(hashlib.md5(pw.encode()).digest()).decode()


STEAMCMD_STUB = """#!/bin/sh
shift  # drop +force_install_dir
mkdir -p "$1"
printf '#!/bin/sh\\nexit 0\\n' > "$1/7DaysToDieServer.x86_64"
chmod +x "$1/7DaysToDieServer.x86_64"
"""

# Stalled-download stand-in: creates the expected binary (so the failure is
# attributable to the stall alone), records the attempt, then hangs past any
# sane per-attempt bound.
SLOW_STEAMCMD_STUB = """#!/bin/sh
shift  # drop +force_install_dir
mkdir -p "$1"
printf '#!/bin/sh\\nexit 0\\n' > "$1/7DaysToDieServer.x86_64"
chmod +x "$1/7DaysToDieServer.x86_64"
echo attempt >> "$STEAMCMD_ATTEMPT_MARKER"
# Detached sleep: timeout(1) kills this shell while the child lingers, and a
# sleep still holding the test harness's output pipes would stall read().
sleep 30 >/dev/null 2>&1 </dev/null
"""


def make_sandbox(tmpdir: Path, drift: str | None) -> tuple[Path, Path, Path]:
    """Build sandbox. drift induces the exact template/script drift the
    assert_rendered guards exist for: 'cfg_userdata' drops the USERDATA_DIR
    substitution while the assert list still demands it; 'adm_hash' makes the
    seed sed target a token the template does not carry."""
    root = tmpdir / "srv"
    game = root / "game"
    userdata = root / "userdata"
    conf = root / "conf"
    bindir = root / "bin"
    for d in (game, userdata, conf, bindir):
        d.mkdir(parents=True)

    stub = bindir / "steamcmd"
    stub.write_text(STEAMCMD_STUB)
    stub.chmod(stub.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)

    src = ENTRYPOINT.read_text(encoding="utf-8")
    patched = (
        src.replace("GAME_DIR=/root/7dtd", f"GAME_DIR={game}")
        .replace("USERDATA_DIR=/root/.local/share/7DaysToDie", f"USERDATA_DIR={userdata}")
        .replace("/usr/local/lib/7dtd-lib-env.sh", str(LIB_ENV))
        .replace("/config/serverconfig.tmpl.xml", str(conf / "serverconfig.tmpl.xml"))
        .replace("/config/serveradmin_seed.xml", str(conf / "serveradmin_seed.xml"))
    )
    if drift == "cfg_userdata":
        patched = patched.replace(
            '-e "s|@USERDATA_DIR@|${USERDATA_DIR}|g"',
            "",
            1,
        )
    elif drift == "adm_hash":
        patched = patched.replace(
            '"s|@WEBADMIN_PASSWORD_HASH@|${b64}|g"',
            '"s|@NOPE@|x|g"',
            1,
        )
    ep = root / "entrypoint.sh"
    ep.write_text(patched)
    ep.chmod(ep.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)

    shutil.copy2(CONFIG / "serverconfig.tmpl.xml", conf / "serverconfig.tmpl.xml")
    shutil.copy2(CONFIG / "serveradmin_seed.xml", conf / "serveradmin_seed.xml")
    return root, game, userdata


def run_entrypoint(root: Path, extra_env: dict[str, str]) -> subprocess.CompletedProcess[bytes]:
    # STEAMCMD_UPDATE=0 skips the install branch (the stub already placed a
    # runnable fake server binary), so the run walks the whole boot path:
    # platform.cfg, render_config, seed_admin_file, sync_mods, exec. The fake
    # server exits 0 immediately, standing in for the exec boundary.
    env = {
        "PATH": f"{root / 'bin'}:/usr/bin:/bin",
        "TELNET_PORT": "8087",
        "STEAMCMD_UPDATE": "0",
        **extra_env,
    }
    return subprocess.run(
        [str(root / "entrypoint.sh")],
        env=env,
        capture_output=True,
        check=False,
        timeout=60,
    )


def no_temp_files(*dirs: Path) -> bool:
    return all(not p.name.endswith(".tmp") for d in dirs for p in d.iterdir())


with tempfile.TemporaryDirectory() as tmp:
    root, game, userdata = make_sandbox(Path(tmp) / "fresh", None)

    # Temp files stranded by a SIGKILLed previous boot (OOM kill, podman
    # kill -9, host power loss) bypass every EXIT trap; the next boot must
    # sweep them up front so a half-rendered credential-bearing file cannot
    # sit beside the real one forever.
    saves = userdata / "Saves"
    saves.mkdir(parents=True)
    (game / ".serverconfig.xml.tmp").write_text("@TELNET_PASSWORD@", encoding="utf-8")
    (saves / ".serveradmin.xml.tmp").write_text("<xml", encoding="utf-8")
    (saves / ".webadmin-password.tmp").write_text("half-written", encoding="utf-8")

    # Fresh boot: everything renders, mints, and cleans up after itself.
    proc = run_entrypoint(root, {})
    out = proc.stdout.decode(errors="replace")
    err = proc.stderr.decode(errors="replace")
    if not check("fresh boot exits 0", proc.returncode == 0):
        print(err, file=sys.stderr)
    else:
        check("fresh boot warns about the public default telnet password", "WARN" in err)
        srv_cfg = (game / "serverconfig.xml").read_text(encoding="utf-8")
        check("serverconfig.xml fully rendered", "@" not in srv_cfg)
        check("serverconfig.xml carries the telnet values", "8087" in srv_cfg)
        check(
            "platform.cfg written",
            (game / "platform.cfg").read_text(encoding="utf-8").startswith("platform=Steam"),
        )
        adm = userdata / "Saves" / "serveradmin.xml"
        record = userdata / "Saves" / ".webadmin-password"
        adm_text = adm.read_text(encoding="utf-8")
        got_pass = re.search(r'pass="([^"]+)"', adm_text)
        check("serveradmin.xml rendered with a digest pass attribute", got_pass is not None)
        minted = record.read_text(encoding="utf-8").rstrip("\n")
        check(
            "credential record matches the seeded digest",
            got_pass is not None and got_pass.group(1) == digest(minted),
        )
        check("no temp files leaked", no_temp_files(game, userdata / "Saves"))
        check(
            "temp files stranded by a killed previous boot were swept",
            not (game / ".serverconfig.xml.tmp").exists()
            and not (saves / ".serveradmin.xml.tmp").exists()
            and not (saves / ".webadmin-password.tmp").exists(),
        )

    # Existing seed + operator password: skip visibly, keep the old record.
    old_record = (userdata / "Saves" / ".webadmin-password").read_bytes()
    proc = run_entrypoint(root, {"WEBADMIN_PASSWORD": "operator-pass-1"})
    out2 = proc.stdout.decode(errors="replace")
    check("second boot exits 0", proc.returncode == 0)
    check(
        "seed skipped with a warning when WEBADMIN_PASSWORD cannot apply",
        "seed skipped" in out2,
    )
    check(
        "existing credential record untouched",
        (userdata / "Saves" / ".webadmin-password").read_bytes() == old_record,
    )

    # Reseed under an operator password: new digest, stale record removed.
    (userdata / "Saves" / "serveradmin.xml").unlink()
    proc = run_entrypoint(root, {"WEBADMIN_PASSWORD": "operator-pass-1"})
    check("reseed exits 0", proc.returncode == 0)
    adm_text = (userdata / "Saves" / "serveradmin.xml").read_text(encoding="utf-8")
    got_pass = re.search(r'pass="([^"]+)"', adm_text)
    check(
        "reseed applied the operator password digest",
        got_pass is not None and got_pass.group(1) == digest("operator-pass-1"),
    )
    record_path = userdata / "Saves" / ".webadmin-password"
    check("reseed removed the stale minted record", not record_path.exists())

    # Drifted serverconfig render (substitution dropped, assert kept): fatal,
    # and the temp file is cleaned up.
    root, game, userdata = make_sandbox(Path(tmp) / "bad-cfg", "cfg_userdata")
    proc = run_entrypoint(root, {"WEBADMIN_PASSWORD": "operator-pass-1"})
    err = proc.stderr.decode(errors="replace")
    check("drifted serverconfig render fatal-exits", proc.returncode != 0)
    check("fatal names the unrendered placeholder", "unrendered placeholder" in err)
    check("render temp file removed on failure", no_temp_files(game))
    check("no serverconfig.xml produced on failure", not (game / "serverconfig.xml").exists())
    seeded = userdata / "Saves" / "serveradmin.xml"
    check("seed never ran after render failure", not seeded.exists())

    # Drifted seed render: fatal, no seed output and no credential record.
    root, game, userdata = make_sandbox(Path(tmp) / "bad-adm", "adm_hash")
    proc = run_entrypoint(root, {})
    err = proc.stderr.decode(errors="replace")
    check("drifted seed render fatal-exits", proc.returncode != 0)
    check("fatal names the unrendered placeholder (seed)", "unrendered placeholder" in err)
    saves = userdata / "Saves"
    check("seed temp files removed on failure", no_temp_files(saves))
    check("no serveradmin.xml produced on failure", not (saves / "serveradmin.xml").exists())
    check("no credential record produced on failure", not (saves / ".webadmin-password").exists())

    # Stalled steamcmd: every attempt must be time-bounded so a hung Steam
    # connection cannot park the boot forever (under --restart unless-stopped
    # a hung entrypoint reads as healthy from the outside). The sandbox shrinks
    # the attempt budget and the retry backoff to keep the scenario fast; the
    # stub hangs past either. Expect: attempt 1 killed at its bound, a real
    # retry (the marker proves it), then the fatal naming the timeout.
    with tempfile.TemporaryDirectory() as slow_tmp:
        tmpdir = Path(slow_tmp)
        root, game, userdata = make_sandbox(tmpdir / "slow-cmd", None)
        ep = root / "entrypoint.sh"
        patched = ep.read_text(encoding="utf-8")
        for old, new in (
            ("max_attempts=3", "max_attempts=2"),
            ("attempt_timeout=3600", "attempt_timeout=1"),
            ("sleep $((attempt * 10))", "sleep 0"),
        ):
            assert old in patched, f"patch anchor missing: {old}"
            patched = patched.replace(old, new, 1)
        ep.write_text(patched, encoding="utf-8")
        stub = root / "bin" / "steamcmd"
        stub.write_text(SLOW_STEAMCMD_STUB)
        stub.chmod(stub.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)

        marker = root / "steamcmd-attempts.log"
        proc = run_entrypoint(
            root,
            {"STEAMCMD_UPDATE": "1", "STEAMCMD_ATTEMPT_MARKER": str(marker)},
        )
        # log() lines ride stdout; the fatal rides stderr.
        out = proc.stdout.decode(errors="replace")
        err = proc.stderr.decode(errors="replace")
        check("stalled steamcmd fatal-exits instead of hanging", proc.returncode != 0)
        attempts = marker.read_text(encoding="utf-8").count("attempt\n") if marker.exists() else 0
        check("a timed-out attempt was retried before giving up", attempts == 2)
        check(
            "fatal names the per-attempt timeout budget",
            "timed out after 2 attempts of 1s each" in err,
        )
        check("per-attempt timeout is visible in the log", "hit the 1s timeout" in out)
        check(
            "boot never reached config render after steamcmd gave up",
            not (game / "serverconfig.xml").exists(),
        )

if failed_checks:
    sys.exit(1)
print("entrypoint boot contract OK")
