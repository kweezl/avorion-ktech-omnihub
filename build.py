#!/usr/bin/env python3
"""Deploy dev directory to the Avorion mods folder as a clean, publishable copy.

Copies ONLY the deployable mod files (whitelist) into <mods-dir>/<modFolder>, stripping all
development-only files (.git, .idea, .claude, stubs, docs, *.iml, CLAUDE.md, the wiki HTML
dump, etc.) so the result can be uploaded to the Steam Workshop in-game without clutter.

The deploy folder name is read from modinfo.lua's `modFolder` key (a custom meta key the
engine ignores), falling back to the MOD_FOLDER_NAME constant if it is absent.

The destination is wiped for a clean build, but the numeric Steam Workshop "id" that the
engine injects into the deployed modinfo.lua after upload is preserved across rebuilds.

Usage:
    python build.py                 # deploy to <AVORION_MODS_DIR>/<modFolder from modinfo.lua>
    python build.py --dry-run       # show what would happen, touch nothing
    python build.py --mods-dir PATH # override the mods directory
    python build.py --dest PATH     # override the full destination path
    python build.py --name NAME     # override the mod folder name
"""

import argparse
import difflib
import hashlib
import os
import re
import shutil
import sys
from pathlib import Path

# ── Configuration ────────────────────────────────────────────────────────────
# Fallback folder name used only if modinfo.lua declares no `modFolder` key (see
# read_mod_folder). Normally the deploy folder name comes from modinfo.lua.
MOD_FOLDER_NAME = "KTechOmniHub"
WHITELIST = ["modinfo.lua", "modconfig.lua", "data"]  # copied recursively (dirs) / as-is (files)
OPTIONAL_FILES = ["thumb.png", "thumb.jpg"]  # Workshop thumbnail, copied only if present
PRESERVE_MODINFO_KEYS = ["id"]               # steam-injected keys carried across a clean build

# Captures the top-level `id` value (numeric Workshop id or placeholder string) from an
# assignment like:  id = "3315794988"  or  id = "KTechOmniHub".
# The ^\s*id anchor skips dependency entries like `{id = "Avorion", ...}` (a `{` precedes id).
_ID_PATTERN = re.compile(r'(?m)^\s*id\s*=\s*["\']([^"\']*)["\']')

# Matches a top-level `id = "<anything>"` for in-place value replacement, capturing the
# surrounding quote/whitespace so they can be preserved verbatim.
_ID_ASSIGN_PATTERN = re.compile(r'(?m)^(?P<pre>\s*id\s*=\s*["\'])[^"\']*(?P<post>["\'])')

# Captures the deploy folder name from a top-level `modFolder = "..."` assignment in
# modinfo.lua. This is a custom meta key (ignored by the engine) that names the on-disk
# mod directory, kept separate from `id` which Steam overwrites on upload.
_MOD_FOLDER_PATTERN = re.compile(r'(?m)^\s*modFolder\s*=\s*["\']([^"\']*)["\']')


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


def read_id_value(modinfo_path):
    """Return the full top-level `id` value (numeric or placeholder string), or None."""
    if not modinfo_path.is_file():
        return None
    match = _ID_PATTERN.search(modinfo_path.read_text(encoding="utf-8", errors="replace"))
    return match.group(1) if match else None


def read_steam_id(modinfo_path):
    """Return the id only when it's a numeric Steam Workshop id, else None.

    The numeric filter is what keeps a pre-publish placeholder (e.g. id = "KTechOmniHub") from
    being mistaken for a real Workshop id and preserved across rebuilds.
    """
    value = read_id_value(modinfo_path)
    return value if value and value.isdigit() else None


def read_mod_folder(modinfo_path):
    """Return the deploy folder name from modinfo.lua's `modFolder` key, or None if absent."""
    if not modinfo_path.is_file():
        return None
    match = _MOD_FOLDER_PATTERN.search(modinfo_path.read_text(encoding="utf-8", errors="replace"))
    return match.group(1) if match else None


def sha256(path):
    """SHA-256 hex digest of a file's bytes (content only, ignores metadata)."""
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(65536), b""):
            h.update(chunk)
    return h.hexdigest()


def iter_files(root, names):
    """Yield (relative_path, absolute_path) for every file under the given top-level names."""
    for name in names:
        base = root / name
        if base.is_dir():
            for p in sorted(base.rglob("*")):
                if p.is_file():
                    yield p.relative_to(root), p
        elif base.is_file():
            yield Path(name), base


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
        else:
            log(f"  {name}")
            if source.is_dir():
                shutil.copytree(source, target)
            else:
                shutil.copy2(source, target)
        copied.append(name)
    return copied


def reinject_steam_id(dest_modinfo, steam_id, dry_run):
    """Set the deployed modinfo.lua's `id` to steam_id so the Workshop link survives a rebuild.

    Replaces the value of the existing top-level `id = "..."` assignment in place (works for both
    the `meta = { id = "..." }` table form and the flat-global form). The `^\\s*id` anchor skips
    dependency entries like `{id = "Avorion", ...}` because those have a `{` before `id`.
    Falls back to appending a flat global only if no `id` assignment exists at all.
    """
    if dry_run:
        log(f'  would re-inject preserved Steam id: {steam_id}')
        return
    text = dest_modinfo.read_text(encoding="utf-8")
    new_text, n = _ID_ASSIGN_PATTERN.subn(
        lambda m: f'{m.group("pre")}{steam_id}{m.group("post")}', text, count=1)
    if n == 0:
        if not new_text.endswith("\n"):
            new_text += "\n"
        new_text += f'id = "{steam_id}"\n'
    dest_modinfo.write_text(new_text, encoding="utf-8")


def lint_ascii(dest):
    """Warn on any non-ASCII file/folder name (Workshop upload silently fails on those)."""
    warnings = []
    for path in dest.rglob("*"):
        try:
            path.name.encode("ascii")
        except UnicodeEncodeError:
            warnings.append(str(path.relative_to(dest)))
    return warnings


def verify_deploy(src, dest, copied, expected_id):
    """Verify the deployment. Returns a list of detailed error strings (empty == success).

    Checks:
      1. Every copied file's SHA-256 in dest matches source (modinfo.lua handled specially,
         since its `id` may be re-injected). No unexpected extra files exist in dest.
      2. modinfo.lua equals source with `expected_id` applied, and its deployed id == expected_id
         (the Steam-id-preserved guarantee).
    """
    errors = []
    modinfo_rel = Path("modinfo.lua")

    # 1. Checksum every copied file except modinfo.lua.
    src_files = dict(iter_files(src, copied))
    n_checked = 0
    for rel, src_path in src_files.items():
        if rel == modinfo_rel:
            continue
        dest_path = dest / rel
        if not dest_path.is_file():
            errors.append(f"missing in dest: {rel}")
            continue
        s_hash, d_hash = sha256(src_path), sha256(dest_path)
        if s_hash != d_hash:
            errors.append(
                f"checksum mismatch: {rel}\n"
                f"      source sha256: {s_hash}\n"
                f"      dest   sha256: {d_hash}")
        else:
            n_checked += 1

    # Detect unexpected extra files in dest (stale leftovers a clean build should have removed).
    expected_rel = set(src_files.keys())
    for p in sorted(dest.rglob("*")):
        if p.is_file():
            rel = p.relative_to(dest)
            if rel not in expected_rel:
                errors.append(f"unexpected extra file in dest: {rel}")

    # 2. modinfo.lua: content integrity + Steam id preservation.
    src_modinfo, dest_modinfo = src / "modinfo.lua", dest / "modinfo.lua"
    if not dest_modinfo.is_file():
        errors.append("missing in dest: modinfo.lua")
        return errors

    src_text = src_modinfo.read_text(encoding="utf-8")
    dest_text = dest_modinfo.read_text(encoding="utf-8")
    if expected_id:
        expected_text, _ = _ID_ASSIGN_PATTERN.subn(
            lambda m: f'{m.group("pre")}{expected_id}{m.group("post")}', src_text, count=1)
    else:
        expected_text = src_text

    if dest_text != expected_text:
        diff = "".join(difflib.unified_diff(
            expected_text.splitlines(keepends=True), dest_text.splitlines(keepends=True),
            fromfile="expected", tofile="deployed"))
        errors.append("modinfo.lua content differs from expected:\n" +
                      "".join(f"      {ln}" for ln in diff.splitlines(keepends=True)))
    else:
        n_checked += 1

    deployed_id = read_id_value(dest_modinfo)
    if expected_id and deployed_id != expected_id:
        errors.append(
            f"Steam id NOT preserved: expected id = {expected_id!r}, "
            f"deployed id = {deployed_id!r}")

    if not errors:
        log(f"Verification: OK — {n_checked} file(s) checksummed, "
            f"id = {deployed_id!r} preserved.")
    return errors


def main():
    src = Path(__file__).resolve().parent
    src_modinfo = src / "modinfo.lua"
    if not src_modinfo.is_file() or not (src / "data").is_dir():
        sys.exit(f"ERROR: source does not look like the mod root (missing modinfo.lua or data/): {src}")

    # The deploy folder name comes from modinfo.lua's `modFolder` key, falling back to the
    # MOD_FOLDER_NAME constant only if that key is absent. --name still overrides either.
    default_name = read_mod_folder(src_modinfo) or MOD_FOLDER_NAME

    parser = argparse.ArgumentParser(description="Deploy mod to the Avorion mods folder.")
    parser.add_argument("--mods-dir", help="Override the Avorion mods directory.")
    parser.add_argument("--dest", help="Override the full destination path (bypasses --mods-dir/--name).")
    parser.add_argument("--name", default=default_name,
                        help=f"Mod folder name (default from modinfo.lua modFolder: {default_name}).")
    parser.add_argument("--dry-run", action="store_true", help="Print actions without touching the filesystem.")
    args = parser.parse_args()

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

    effective_id = source_id or preserved_id

    # Step 8: verify the deployment (checksums + Steam id preservation).
    if not args.dry_run:
        log()
        errors = verify_deploy(src, dest, copied, effective_id)
        if errors:
            log("\n" + "=" * 60)
            log(f"VERIFICATION FAILED ({len(errors)} problem(s)):")
            for e in errors:
                log(f"  ✘ {e}")
            log("=" * 60)
            sys.exit(1)

    # Step 9: summary.
    log("\n" + "-" * 60)
    log(f"Deployed: {', '.join(copied)}")
    log(f"Steam id: {effective_id if effective_id else '(none yet — assigned on first Workshop upload)'}")
    if warnings:
        log("\nWARNING: non-ASCII filenames found (Workshop upload will fail):")
        for w in warnings:
            log(f"  ! {w}")
    log("\nDone." if not args.dry_run else "\nDry run complete — no changes made.")


if __name__ == "__main__":
    main()
