#!/usr/bin/env python3
"""Boot-path tests for entrypoint.sh's config render and admin seed contract.

Methodology: entrypoint.sh only ever executes inside its container image, so
its failure paths were untestable until now. A sandbox gets a patched copy of
entrypoint.sh (hardcoded image paths rewritten to sandbox paths), a steamcmd
stub that just creates the expected server binary, and the real config
templates plus scripts/lib-env.sh. With STEAMCMD_UPDATE=0 the run walks the
whole boot path (platform.cfg, render_config, seed_admin_file, sync_mods) up to
the exec boundary, where a fake server binary stands in for the game:

  fresh      render_config + seed_admin_file succeed; serverconfig.xml is
             fully rendered, the minted webadmin credential record matches
             the digest embedded in serveradmin.xml, the rendered files are
             owner-only, and no temp files leak
  existing   a later boot with WEBADMIN_PASSWORD set skips the seed with a
             visible warning instead of silently dropping the value
  reseed     deleting serveradmin.xml makes the next boot re-seed under an
             operator password and remove the stale minted record
  bad-tmpl   an unrendered placeholder fatal-exits AND leaves neither the
             half-rendered temp file nor any seeded output behind
  slow-cmd   a steamcmd attempt that hangs past its budget is killed and
             retried, then the boot fatal-exits naming the budget
  sync-mods  the per-boot Mods sync: what /mods no longer stages is swept,
             stock 0_TFP_Harmony survives, hidden /mods entries still reach
             Mods, an edited staged mod propagates, and a mod whose content
             did not change is not rewritten (its inode survives the boot)

Each failed check prints a FAIL line; the process exits nonzero if any failed.
"""

from __future__ import annotations

import base64
import hashlib
import os
import shutil
import stat
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET
from pathlib import Path

from harness import ROOT, SCRIPTS, check, exit_status, resolved_bin_path

ENTRYPOINT = ROOT / "entrypoint.sh"
LIB_ENV = SCRIPTS / "lib-env.sh"
CONFIG = ROOT / "config"


def digest(pw: str) -> str:
    """The exact md5-base64 form the dashboard expects (see lib-env.sh)."""
    return base64.b64encode(hashlib.md5(pw.encode("utf-8")).digest()).decode()


def webadmin_pass(adm_xml: str) -> str | None:
    """The pass attribute of the dashboard's admin user, not any pass= text."""
    users = ET.fromstring(adm_xml).findall("./webusers/user")
    return users[0].get("pass") if len(users) == 1 else None


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
    stub.write_text(STEAMCMD_STUB, encoding="utf-8")
    stub.chmod(stub.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)

    src = ENTRYPOINT.read_text(encoding="utf-8")
    patched = (
        src.replace("GAME_DIR=/root/7dtd", f"GAME_DIR={game}")
        .replace("USERDATA_DIR=/root/.local/share/7DaysToDie", f"USERDATA_DIR={userdata}")
        .replace("/usr/local/lib/7dtd-lib-env.sh", str(LIB_ENV))
        .replace("/config/serverconfig.tmpl.xml", str(conf / "serverconfig.tmpl.xml"))
        .replace("/config/serveradmin_seed.xml", str(conf / "serveradmin_seed.xml"))
    )
    if drift is not None:
        anchor, replacement = {
            "cfg_userdata": ('-e "s|@USERDATA_DIR@|${USERDATA_DIR}|g"', ""),
            "adm_hash": ('"s|@WEBADMIN_PASSWORD_HASH@|${b64}|g"', '"s|@NOPE@|x|g"'),
        }[drift]
        patched = patched.replace(anchor, replacement, 1)
        # A drifted entrypoint must produce a different patch, or the scenario
        # silently degrades into the clean-boot one and passes for the wrong
        # reason.
        assert patched != src, f"drift patch anchor missing: {anchor}"
    ep = root / "entrypoint.sh"
    ep.write_text(patched, encoding="utf-8")
    ep.chmod(ep.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)

    shutil.copy2(CONFIG / "serverconfig.tmpl.xml", conf / "serverconfig.tmpl.xml")
    shutil.copy2(CONFIG / "serveradmin_seed.xml", conf / "serveradmin_seed.xml")
    return root, game, userdata


def run_entrypoint(root: Path, extra_env: dict[str, str]) -> subprocess.CompletedProcess[bytes]:
    # STEAMCMD_UPDATE=0 skips the install branch (the stub already placed a
    # runnable fake server binary), so the run walks the whole boot path:
    # platform.cfg, render_config, seed_admin_file, sync_mods, exec. The fake
    # server exits 0 immediately, standing in for the exec boundary.
    #
    # The public default telnet password is opt-in, so these runs take the
    # opt-in to reach the render/seed path at all; the refusal itself is
    # covered by its own case below.
    env = {
        # The tools the boot path shells out to, resolved from the running
        # host: /usr/bin:/bin is not where coreutils lives on NixOS, a
        # brew-only prefix, or a slim test image, and a missing diff alone
        # would silently change which sync_tree branch runs.
        "PATH": ":".join(
            (
                str(root / "bin"),
                resolved_bin_path(
                    "bash",
                    "sed",
                    "grep",
                    "od",
                    "tr",
                    "base64",
                    "md5sum",
                    "timeout",
                    "diff",
                    "cp",
                    "mv",
                    "rm",
                    "mkdir",
                    "head",
                    "chmod",
                    "cat",
                    "cut",
                ),
            )
        ),
        "TELNET_PORT": "8087",
        "STEAMCMD_UPDATE": "0",
        "ALLOW_PUBLIC_DEFAULT_TELNET_PASSWORD": "1",
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
    # Every staging name either path uses carries ".tmp" (".serverconfig.xml.tmp",
    # ".<mod>.tmp.$$", ".<mod>.tmp.retired.$$"): a suffix-only test passes on a
    # Mods dir littered with exactly the artifacts it claims to exclude.
    return all(".tmp" not in p.name for d in dirs for p in d.iterdir())


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
        # sync_mods emits its own WARN on the same stream, so the bare "WARN"
        # would pass even if this boot never fell back to the public default.
        check(
            "fresh boot warns about the public default telnet password",
            "WARN: TELNET_PASSWORD unset" in err and "public lab default" in err,
        )
        srv_cfg = (game / "serverconfig.xml").read_text(encoding="utf-8")
        check("serverconfig.xml fully rendered", "@" not in srv_cfg)
        # Read the properties the entrypoint actually owns, not a substring of
        # a stock template that happens to mention the same digits.
        props = {
            p.get("name"): p.get("value")
            for p in ET.fromstring(srv_cfg).iter("property")
            if p.get("name") is not None
        }
        check(
            "serverconfig.xml carries the rendered telnet values",
            props.get("TelnetPort") == "8087" and props.get("TelnetPassword") == "retest",
        )
        check(
            "serverconfig.xml points Saves at the rendered userdata dir",
            props.get("UserDataFolder") == str(userdata),
        )
        # All three lines, not just the first: the LAN/Local joins are the
        # reason the file exists, and startswith would pass on the header alone.
        check(
            "platform.cfg written",
            (game / "platform.cfg").read_text(encoding="utf-8")
            == "platform=Steam\ncrossplatform=None\nserverplatforms=Steam,LAN,Local,\n",
        )
        adm = userdata / "Saves" / "serveradmin.xml"
        record = userdata / "Saves" / ".webadmin-password"
        adm_text = adm.read_text(encoding="utf-8")
        got_pass = webadmin_pass(adm_text)
        check("serveradmin.xml rendered with a digest pass attribute", got_pass is not None)
        minted = record.read_text(encoding="utf-8").rstrip("\n")
        check(
            "credential record matches the seeded digest",
            got_pass is not None and got_pass == digest(minted),
        )
        check("no temp files leaked", no_temp_files(game, userdata / "Saves"))
        # Both rendered files carry credentials (telnet password, dashboard
        # digest); render_config/seed_admin_file set umask 077 so they are not
        # world-readable in the host's data/ tree.
        modes = {
            p: stat.S_IMODE(p.stat().st_mode) for p in (game / "serverconfig.xml", adm, record)
        }
        check(
            f"rendered credential files are owner-only (modes: {modes})",
            all(mode == 0o600 for mode in modes.values()),
        )
    # Existing seed + operator password: skip visibly, keep the old record.
    # Stranding the two Saves temps again here is the load-bearing half of
    # the sweep check: this boot writes neither one (the seed returns early
    # and no password is minted), so only the up-front sweep can remove them.
    # The first boot's copy is vacuous, since its own render and seed write
    # and rename those same names.
    (saves / ".serveradmin.xml.tmp").write_text("<xml", encoding="utf-8")
    (saves / ".webadmin-password.tmp").write_text("half-written", encoding="utf-8")
    old_adm = (userdata / "Saves" / "serveradmin.xml").read_bytes()
    old_record = (userdata / "Saves" / ".webadmin-password").read_bytes()
    proc = run_entrypoint(root, {"WEBADMIN_PASSWORD": "operator-pass-1"})
    out2 = proc.stdout.decode(errors="replace")
    err2 = proc.stderr.decode(errors="replace")
    check("second boot exits 0", proc.returncode == 0)
    # The warning rides stderr, not the boot's stdout progress stream (same
    # rule as every other WARN in these scripts).
    check(
        "seed skipped with a warning when WEBADMIN_PASSWORD cannot apply",
        "seed skipped" in err2 and "seed skipped" not in out2,
    )
    check(
        "existing credential record untouched",
        (userdata / "Saves" / ".webadmin-password").read_bytes() == old_record,
    )
    check(
        "existing seeded serveradmin.xml untouched",
        (userdata / "Saves" / "serveradmin.xml").read_bytes() == old_adm,
    )
    check(
        "temp files stranded by a killed previous boot were swept",
        not (game / ".serverconfig.xml.tmp").exists()
        and not (saves / ".serveradmin.xml.tmp").exists()
        and not (saves / ".webadmin-password.tmp").exists(),
    )

    # Reseed under an operator password: new digest, stale record removed.
    (userdata / "Saves" / "serveradmin.xml").unlink()
    proc = run_entrypoint(root, {"WEBADMIN_PASSWORD": "operator-pass-1"})
    check("reseed exits 0", proc.returncode == 0)
    adm_text = (userdata / "Saves" / "serveradmin.xml").read_text(encoding="utf-8")
    got_pass = webadmin_pass(adm_text)
    check(
        "reseed applied the operator password digest",
        got_pass == digest("operator-pass-1"),
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
    # retry (the marker proves it), then the fatal naming the timeout. The
    # per-attempt bound is 3s, not 1s: the stub records its attempt before it
    # hangs, and a bound short enough to be mistaken for a fast machine lands
    # the kill before that record exists, which reads as a missing retry.
    with tempfile.TemporaryDirectory() as slow_tmp:
        tmpdir = Path(slow_tmp)
        root, game, userdata = make_sandbox(tmpdir / "slow-cmd", None)
        ep = root / "entrypoint.sh"
        patched = ep.read_text(encoding="utf-8")
        for old, new in (
            ("max_attempts=3", "max_attempts=2"),
            ("attempt_timeout=3600", "attempt_timeout=3"),
            ("sleep $((attempt * 10))", "sleep 0"),
        ):
            assert old in patched, f"patch anchor missing: {old}"
            patched = patched.replace(old, new, 1)
        ep.write_text(patched, encoding="utf-8")
        stub = root / "bin" / "steamcmd"
        stub.write_text(SLOW_STEAMCMD_STUB, encoding="utf-8")
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
            "timed out after 2 attempts of 3s each" in err,
        )
        check("per-attempt timeout is visible in the log", "hit the 3s timeout" in out)
        check(
            "boot never reached config render after steamcmd gave up",
            not (game / "serverconfig.xml").exists(),
        )

    # The quadlet path pins no TELNET_PASSWORD, so the entrypoint is the last
    # place the public lab default can be refused: a set telnet password makes
    # the game listen on every interface, and the default ships in this repo.
    with tempfile.TemporaryDirectory() as no_default:
        nd_root, nd_game, _ = make_sandbox(Path(no_default) / "nodefault", None)
        nd_env = {"ALLOW_PUBLIC_DEFAULT_TELNET_PASSWORD": "0"}
        proc = run_entrypoint(nd_root, nd_env)
        nd_err = proc.stderr.decode(errors="replace")
        check("boot without a telnet password exits nonzero", proc.returncode != 0)
        check("the refusal names the missing value", "TELNET_PASSWORD unset" in nd_err)
        check(
            "the refusal points at the opt-in escape hatch",
            "ALLOW_PUBLIC_DEFAULT_TELNET_PASSWORD=1" in nd_err,
        )
        check(
            "the refused boot rendered no credential-bearing config",
            not (nd_game / "serverconfig.xml").exists(),
        )

# sync_mods: the per-boot Mods sync. The cases above run with /mods absent,
# so they never enter the copy loop; this one points /mods at a sandbox and
# truncates the entrypoint after sync_mods so each run is one boot's sync and
# nothing else. The performance contract is pinned here alongside the
# behavior: a mod whose content did not change keeps its inode, so the boot
# proved it skipped the rewrite instead of deleting and copying it back.
with tempfile.TemporaryDirectory() as tmp:
    root, game, _userdata = make_sandbox(Path(tmp) / "sync-mods", None)
    mods = root / "mods"
    mods.mkdir()
    game_mods = game / "Mods"
    (game_mods / "0_TFP_Harmony").mkdir(parents=True)
    (game_mods / "0_TFP_Harmony" / "0_TFP_Harmony.dll").write_text("stock", encoding="utf-8")
    # A mod the host no longer stages must be swept on the next boot.
    (game_mods / "OldMod").mkdir()
    (game_mods / "OldMod" / "old.dll").write_text("stale", encoding="utf-8")

    for mod_name, mod_marker in (("EfficientServer", "cfg"), ("BotMod", "bot")):
        mod_conf = mods / mod_name / "Config"
        mod_conf.mkdir(parents=True)
        (mod_conf / "config.json").write_text(mod_marker, encoding="utf-8")
    # The old `cp -a /mods/.` carried hidden entries through; keep that.
    (mods / ".hidden").write_text("h", encoding="utf-8")

    ep = root / "entrypoint.sh"
    patched = ep.read_text(encoding="utf-8").replace("/mods", str(mods))
    # Replace the boot body (mkdir onward, ending at the exec) with the one
    # call under test.
    body_at = patched.index('mkdir -p "$GAME_DIR" "$USERDATA_DIR/Logs"')
    ep.write_text(patched[:body_at] + "sync_mods\n", encoding="utf-8")

    first = run_entrypoint(root, {})
    check("sync-only boot exits 0", first.returncode == 0)
    if first.returncode != 0:
        print(first.stderr.decode(errors="replace"), file=sys.stderr)
    check("unstaged mod swept from the game's Mods", not (game_mods / "OldMod").exists())
    check("stock 0_TFP_Harmony kept", (game_mods / "0_TFP_Harmony" / "0_TFP_Harmony.dll").exists())
    check(
        "staged mods copied into the game's Mods",
        (game_mods / "EfficientServer" / "Config" / "config.json").read_text(encoding="utf-8")
        == "cfg",
    )
    check("hidden /mods entry still propagated", (game_mods / ".hidden").exists())
    check("sync left no staging litter in Mods", no_temp_files(game_mods))

    bot_cfg = game_mods / "BotMod" / "Config" / "config.json"
    inode = bot_cfg.stat().st_ino
    second = run_entrypoint(root, {})
    check("second sync-only boot exits 0", second.returncode == 0)
    check(
        "an unchanged mod is not rewritten on the next boot (inode kept)",
        bot_cfg.stat().st_ino == inode,
    )

    # The skip must not be a blind no-op: a mod edited under /mods (the
    # /api/perf toggle writes the EfficientServer config there) has to land.
    (mods / "BotMod" / "Config" / "config.json").write_text("toggled", encoding="utf-8")
    run_entrypoint(root, {})
    check(
        "an edited staged mod still propagates",
        (game_mods / "BotMod" / "Config" / "config.json").read_text(encoding="utf-8") == "toggled",
    )

    shutil.rmtree(mods / "EfficientServer")
    run_entrypoint(root, {})
    check("a mod dropped from /mods is swept", not (game_mods / "EfficientServer").exists())
    check(
        "stock 0_TFP_Harmony survives the sweep",
        (game_mods / "0_TFP_Harmony" / "0_TFP_Harmony.dll").exists(),
    )

    # A boot killed between sync_tree's cp and its rename strands its staging
    # sibling (and, on a failed install, the retired one) in the game's Mods
    # dir, which is host state that outlives the container and a directory the
    # game scans for mods. The next boot must reclaim a dead owner's entries
    # and must not touch a live owner's.
    stranded = game_mods / ".BotMod.tmp.999999"
    stranded.mkdir()
    (stranded / "BotMod.dll").write_text("half-copied", encoding="utf-8")
    retired = game_mods / ".BotMod.tmp.retired.999999"
    retired.mkdir()
    (retired / "BotMod.dll").write_text("previous", encoding="utf-8")
    # This process is alive, so its PID must shield an in-flight entry the
    # way it does for the host staging scripts.
    in_flight = game_mods / f".BotMod.tmp.{os.getpid()}"
    in_flight.mkdir()
    sweep_boot = run_entrypoint(root, {})
    check("boot over stranded staging litter exits 0", sweep_boot.returncode == 0)
    check(
        "a staging copy stranded by a killed boot is reclaimed",
        not stranded.exists(),
    )
    check(
        "a staging tree retired by a failed install is reclaimed",
        not retired.exists(),
    )
    check(
        "a live owner's staging entry survives the sweep",
        in_flight.exists(),
    )
    check(
        "no dead owner's staging entry is left in the game's Mods",
        sorted(p.name for p in game_mods.glob(".*.tmp.*")) == [in_flight.name],
    )
    check("the sweep left no temp litter", no_temp_files(game_mods))

exit_status()
print("entrypoint boot contract OK")
