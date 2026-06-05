#!/usr/bin/env python3
"""Deploy avorion-omnihub to the Avorion mods folder as a clean, publishable copy.

Copies ONLY the deployable mod files (whitelist) into <mods-dir>/OmniHub, stripping all
development-only files (.git, .idea, .claude, stubs, docs, *.iml, CLAUDE.md, the wiki HTML
dump, etc.) so the result can be uploaded to the Steam Workshop in-game without clutter.

The destination is wiped for a clean build, but the numeric Steam Workshop "id" that the
engine injects into the deployed modinfo.lua after upload is preserved across rebuilds.

Usage:
    python build.py                 # deploy to <AVORION_MODS_DIR>/OmniHub
    python build.py --dry-run       # show what would happen, touch nothing
    python build.py --mods-dir PATH # override the mods directory
    python build.py --dest PATH     # override the full destination path
    python build.py --name NAME     # override the mod folder name
"""

import argparse
import os
import re
import shutil
import sys
from pathlib import Path

# ── Configuration ────────────────────────────────────────────────────────────
MOD_FOLDER_NAME = "OmniHub"
WHITELIST = ["modinfo.lua", "data"]          # copied recursively (dirs) / as-is (files)
OPTIONAL_FILES = ["thumb.png", "thumb.jpg"]  # Workshop thumbnail, copied only if present
PRESERVE_MODINFO_KEYS = ["id"]               # steam-injected keys carried across a clean build

# Matches a flat-global or table-field assignment like:  id = "3315794988"
_ID_PATTERN = re.compile(r'(?m)^\s*id\s*=\s*["\'](\d+)["\']')


def log(msg=""):
    print(msg)


def resolve_dest(args):
    """Resolve the destination mod folder from args/env/platform defaults."""
    if args.dest:
        return Path(args.dest).expanduser()

    if args.mods_dir:
        mods_dir = Path(args.mods_dir).expanduser()
    elif os.environ.get("AVORION_MODS_DIR"):
        mods_dir = Path(os.environ["AVORION_MODS_DIR"]).expanduser()
    elif sys.platform == "win32":
        mods_dir = Path(os.environ.get("APPDATA", "")) / "Avorion" / "mods"
    else:
        mods_dir = Path.home() / ".local" / "share" / "Avorion" / "mods"

    return mods_dir / args.name


def read_steam_id(modinfo_path):
    """Return the numeric Steam Workshop id declared in a modinfo.lua, or None."""
    if not modinfo_path.is_file():
        return None
    match = _ID_PATTERN.search(modinfo_path.read_text(encoding="utf-8", errors="replace"))
    return match.group(1) if match else None


def copy_whitelist(src, dest, dry_run):
    """Copy whitelisted entries + any present optional files into dest. Returns list of names."""
    copied = []
    for name in WHITELIST + OPTIONAL_FILES:
        source = src / name
        if not source.exists():
            if name in WHITELIST:
                sys.exit(f"ERROR: required '{name}' not found in source {src}")
            continue  # optional file simply absent
        target = dest / name
        if dry_run:
            log(f"  would copy  {name}")
        elif source.is_dir():
            shutil.copytree(source, target)
        else:
            shutil.copy2(source, target)
        copied.append(name)
    return copied


def reinject_steam_id(dest_modinfo, steam_id, dry_run):
    """Append `id = "<steam_id>"` to the deployed modinfo.lua so the Workshop link survives."""
    line = f'id = "{steam_id}"\n'
    if dry_run:
        log(f'  would re-inject preserved Steam id: {steam_id}')
        return
    text = dest_modinfo.read_text(encoding="utf-8")
    if not text.endswith("\n"):
        text += "\n"
    dest_modinfo.write_text(text + line, encoding="utf-8")


def lint_ascii(dest):
    """Warn on any non-ASCII file/folder name (Workshop upload silently fails on those)."""
    warnings = []
    for path in dest.rglob("*"):
        try:
            path.name.encode("ascii")
        except UnicodeEncodeError:
            warnings.append(str(path.relative_to(dest)))
    return warnings


def main():
    parser = argparse.ArgumentParser(description="Deploy avorion-omnihub to the Avorion mods folder.")
    parser.add_argument("--mods-dir", help="Override the Avorion mods directory.")
    parser.add_argument("--dest", help="Override the full destination path (bypasses --mods-dir/--name).")
    parser.add_argument("--name", default=MOD_FOLDER_NAME, help=f"Mod folder name (default: {MOD_FOLDER_NAME}).")
    parser.add_argument("--dry-run", action="store_true", help="Print actions without touching the filesystem.")
    args = parser.parse_args()

    src = Path(__file__).resolve().parent
    src_modinfo = src / "modinfo.lua"
    if not src_modinfo.is_file() or not (src / "data").is_dir():
        sys.exit(f"ERROR: source does not look like the mod root (missing modinfo.lua or data/): {src}")

    dest = resolve_dest(args)

    log(f"Source : {src}")
    log(f"Dest   : {dest}")
    if args.dry_run:
        log("Mode   : DRY RUN (no changes)")
    log()

    # Step 3: capture Steam id from existing deployment before wiping.
    preserved_id = read_steam_id(dest / "modinfo.lua")
    if preserved_id:
        log(f"Preserving Steam id from existing deployment: {preserved_id}")

    # Step 4: clean.
    if dest.exists():
        log(f"Cleaning destination...")
        if not args.dry_run:
            shutil.rmtree(dest)
    if not args.dry_run:
        dest.mkdir(parents=True, exist_ok=True)

    # Step 5: copy whitelist.
    log("Copying files:")
    copied = copy_whitelist(src, dest, args.dry_run)

    # Step 6: re-inject Steam id (source wins if it already carries one).
    source_id = read_steam_id(src_modinfo)
    if source_id:
        log(f"\nSource modinfo already declares Steam id {source_id} — leaving as-is.")
    elif preserved_id:
        log(f"\nRe-injecting preserved Steam id into deployed modinfo.lua:")
        reinject_steam_id(dest / "modinfo.lua", preserved_id, args.dry_run)

    # Step 7: Workshop ASCII lint.
    warnings = [] if args.dry_run else lint_ascii(dest)

    # Step 8: summary.
    log("\n" + "-" * 60)
    log(f"Deployed: {', '.join(copied)}")
    effective_id = source_id or preserved_id
    log(f"Steam id: {effective_id if effective_id else '(none yet — assigned on first Workshop upload)'}")
    if warnings:
        log("\nWARNING: non-ASCII filenames found (Workshop upload will fail):")
        for w in warnings:
            log(f"  ! {w}")
    log("\nDone." if not args.dry_run else "\nDry run complete — no changes made.")


if __name__ == "__main__":
    main()
