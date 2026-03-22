#!/usr/bin/env python3
"""Build script for Resonance WoW addon."""

import os
import re
import shutil
import sys
import zipfile
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
WOW_ADDONS_DIR = Path("/mnt/ssd1/games/World of Warcraft/_retail_/Interface/AddOns")
WOW_ADDON_DIR = WOW_ADDONS_DIR / "Resonance"
WOW_DATA_DIR = WOW_ADDONS_DIR / "Resonance_Data"

# Files and directories to include in the main addon (Resonance/)
ADDON_INCLUDES = [
    "Resonance.toc",
    "embeds.xml",
    "Locales.lua",
    "Core.lua",
    "Options.lua",
    "data",
    "libs",
    "sounds",
]

# Files and directories to include in the data addon (Resonance_Data/)
DATA_INCLUDES = [
    "Resonance_Data/Resonance_Data.toc",
    "Resonance_Data/data",
]


def get_version():
    toc = (SCRIPT_DIR / "Resonance.toc").read_text()
    match = re.search(r"## Version:\s*(.+)", toc)
    if not match:
        sys.exit("Error: could not find ## Version in Resonance.toc")
    return match.group(1).strip()


def iter_includes(includes):
    """Yield (src_path, relative_path_from_SCRIPT_DIR) for a list of includes."""
    for name in includes:
        src = SCRIPT_DIR / name
        if src.is_file():
            yield src, Path(name)
        elif src.is_dir():
            for child in sorted(src.rglob("*")):
                if child.is_file():
                    yield child, child.relative_to(SCRIPT_DIR)


def sync_folder(includes, dest_dir, strip_prefix=None):
    """Sync files from includes list to dest_dir, removing stale files."""
    same_dir = dest_dir.resolve() == SCRIPT_DIR.resolve()
    if same_dir:
        print(f"  ({dest_dir.name}: source and dest are the same — skipping stale cleanup)")

    expected = set()
    for src, rel in iter_includes(includes):
        # Strip prefix for sub-addons (e.g. Resonance_Data/ -> data/)
        out_rel = rel.relative_to(strip_prefix) if strip_prefix else rel
        dest = dest_dir / out_rel
        expected.add(out_rel)
        dest.parent.mkdir(parents=True, exist_ok=True)
        if not same_dir and (not dest.exists() or src.stat().st_mtime > dest.stat().st_mtime or src.stat().st_size != dest.stat().st_size):
            shutil.copy2(src, dest)
            print(f"  updated: {dest_dir.name}/{out_rel}")

    if not same_dir and dest_dir.exists():
        for child in sorted(dest_dir.rglob("*"), reverse=True):
            rel = child.relative_to(dest_dir)
            if child.is_file() and rel not in expected:
                child.unlink()
                print(f"  deleted: {dest_dir.name}/{rel}")
            elif child.is_dir() and not any(child.iterdir()):
                child.rmdir()
                print(f"  deleted: {dest_dir.name}/{rel}/")


def deploy():
    """Sync addon files to the WoW AddOns directory."""
    if not WOW_ADDONS_DIR.exists():
        sys.exit(f"Error: WoW AddOns directory not found at {WOW_ADDONS_DIR}")

    print("Deploying Resonance...")
    sync_folder(ADDON_INCLUDES, WOW_ADDON_DIR)
    print("Deploying Resonance_Data...")
    sync_folder(DATA_INCLUDES, WOW_DATA_DIR, strip_prefix=Path("Resonance_Data"))
    print("Deploy complete.")


def package():
    """Create a versioned zip for distribution."""
    version = get_version()
    zipname = SCRIPT_DIR / f"Resonance-{version}.zip"

    with zipfile.ZipFile(zipname, "w", zipfile.ZIP_DEFLATED) as zf:
        for src, rel in addon_files():
            arcname = Path("Resonance") / rel
            zf.write(src, arcname)

    print(f"Created {zipname.name}")


def main():
    os.chdir(SCRIPT_DIR)
    if len(sys.argv) < 2 or sys.argv[1] not in ("deploy", "package"):
        print("Usage: python build.py {deploy|package}")
        sys.exit(1)

    {"deploy": deploy, "package": package}[sys.argv[1]]()


if __name__ == "__main__":
    main()
