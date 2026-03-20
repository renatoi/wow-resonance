#!/usr/bin/env python3
"""Download the latest WoW API globals for luacheck.

Source: https://github.com/LiangYuxuan/wow-addon-luacheckrc
(auto-generated daily from Blizzard's interface source)

Usage:
    python tools/update_wow_globals.py
"""

import json
import subprocess
import sys
import urllib.request
from pathlib import Path

REPO = "LiangYuxuan/wow-addon-luacheckrc"
ASSET = "default.luacheckrc"
DEST = Path(__file__).resolve().parent.parent / ".luacheckrc_wow"


def download_with_gh() -> bytes:
    """Try downloading via gh CLI."""
    result = subprocess.run(
        ["gh", "release", "download", "--repo", REPO, "--pattern", ASSET, "-O", "-"],
        capture_output=True,
    )
    if result.returncode == 0:
        return result.stdout
    raise RuntimeError(result.stderr.decode())


def download_with_urllib() -> bytes:
    """Fallback: resolve latest release tag, then download the asset."""
    api_url = f"https://api.github.com/repos/{REPO}/releases/latest"
    with urllib.request.urlopen(api_url) as resp:
        release = json.loads(resp.read())
    for asset in release.get("assets", []):
        if asset["name"] == ASSET:
            with urllib.request.urlopen(asset["browser_download_url"]) as resp:
                return resp.read()
    raise RuntimeError(f"Asset '{ASSET}' not found in latest release")


def main() -> None:
    print(f"Fetching latest WoW API globals from {REPO}...")
    try:
        data = download_with_gh()
    except Exception:
        data = download_with_urllib()

    DEST.write_bytes(data)
    lines = data.count(b"\n")
    print(f"Updated {DEST.name} ({lines} lines)")


if __name__ == "__main__":
    main()
