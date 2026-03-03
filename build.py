#!/usr/bin/env python3
"""Build script for Resonance WoW addon."""

import os
import re
import shutil
import sys
import zipfile
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
WOW_ADDON_DIR = Path("/mnt/ssd1/games/World of Warcraft/_retail_/Interface/AddOns/Resonance")

# Files and directories to include in the addon
ADDON_INCLUDES = [
    "Resonance.toc",
    "embeds.xml",
    "Core.lua",
    "Options.lua",
    "data",
    "libs",
    "sounds",
]


def get_version():
    toc = (SCRIPT_DIR / "Resonance.toc").read_text()
    match = re.search(r"## Version:\s*(.+)", toc)
    if not match:
        sys.exit("Error: could not find ## Version in Resonance.toc")
    return match.group(1).strip()


def addon_files():
    """Yield (src_path, relative_path) for all addon files."""
    for name in ADDON_INCLUDES:
        src = SCRIPT_DIR / name
        if src.is_file():
            yield src, Path(name)
        elif src.is_dir():
            for child in sorted(src.rglob("*")):
                if child.is_file():
                    yield child, child.relative_to(SCRIPT_DIR)


def deploy():
    """Sync addon files to the WoW AddOns directory."""
    if not WOW_ADDON_DIR.parent.exists():
        sys.exit(f"Error: WoW AddOns directory not found at {WOW_ADDON_DIR.parent}")

    # Collect the set of relative paths we'll write
    expected = set()
    for src, rel in addon_files():
        dest = WOW_ADDON_DIR / rel
        expected.add(rel)
        dest.parent.mkdir(parents=True, exist_ok=True)
        # Only copy if source is newer or different size
        if not dest.exists() or src.stat().st_mtime > dest.stat().st_mtime or src.stat().st_size != dest.stat().st_size:
            shutil.copy2(src, dest)
            print(f"  updated: {rel}")

    # Delete stale files (like rsync --delete)
    if WOW_ADDON_DIR.exists():
        for child in sorted(WOW_ADDON_DIR.rglob("*"), reverse=True):
            rel = child.relative_to(WOW_ADDON_DIR)
            if child.is_file() and rel not in expected:
                child.unlink()
                print(f"  deleted: {rel}")
            elif child.is_dir() and not any(child.iterdir()):
                child.rmdir()
                print(f"  deleted: {rel}/")

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
