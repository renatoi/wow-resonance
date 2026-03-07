#!/usr/bin/env python3
"""Cross-reference ClassTemplates sounds against Wowhead Classic and DB2 data.

For each mismatched spell, fetches Wowhead to find the actual classic sounds,
then recommends the correct replacement."""

import csv
import re
import sys
import time
import urllib.request
from collections import defaultdict
from pathlib import Path

TEMPLATE_FILE = Path("data/ClassTemplates.lua")
CLASSIC_FILE = Path("data/ClassicSpellSounds.lua")
LISTFILE = Path("tools/.db2_cache/retail/listfile.csv")

# Wowhead URLs by era
WOWHEAD_URLS = {
    "classic": "https://www.wowhead.com/classic/spell={sid}",
    "tbc": "https://www.wowhead.com/tbc/spell={sid}",
    "mop": "https://www.wowhead.com/mop-classic/spell={sid}",
}

# Generic/ambient FIDs to deprioritize when picking the "characteristic" sound
GENERIC_SWING_FIDS = {569827, 569828, 569829, 569830, 569831}  # SwingWeaponSpecialWarrior*.ogg
GENERIC_PRECAST = {568938, 568915, 569766, 569767, 569764, 569765, 569424}  # generic cast sounds
GENERIC_CAST = {569777, 569778, 569779, 569780, 569781}  # generic cast variants


def load_listfile(path):
    """Return {fid: filepath}."""
    names = {}
    with open(path) as f:
        for line in f:
            parts = line.strip().split(';', 1)
            if len(parts) == 2:
                try:
                    fid = int(parts[0])
                    names[fid] = parts[1]
                except ValueError:
                    pass
    return names


def parse_templates(path):
    entries = []
    current_class = None
    with open(path) as f:
        for line in f:
            m = re.match(r'\s+(\w+)\s*=\s*\{', line)
            if m:
                current_class = m.group(1)
                continue
            m = re.search(r'spellID\s*=\s*(\d+)\s*,\s*name\s*=\s*"([^"]*)"', line)
            if not m or not current_class:
                continue
            sid = int(m.group(1))
            name = m.group(2)
            sm = re.search(r'sound\s*=\s*(\d+)', line)
            sound = int(sm.group(1)) if sm else None
            table_sounds = []
            tm = re.search(r'sound\s*=\s*\{([^}]+)\}', line)
            if tm:
                for num in re.findall(r'\d+', tm.group(1)):
                    table_sounds.append(int(num))
            has_excl = "muteExclusions" in line
            cm = re.search(r'--\s*(.+)$', line)
            comment = cm.group(1).strip() if cm else ""
            all_sounds = table_sounds if table_sounds else ([sound] if sound else [])
            entries.append((current_class, sid, name, all_sounds, has_excl, comment))
    return entries


def parse_classic_ref(path):
    retail_to_classic = {}
    current_retail = None
    with open(path) as f:
        for line in f:
            line = line.strip()
            if line.startswith("--"):
                rm = re.search(r'retail:\s*(\d+)', line)
                current_retail = int(rm.group(1)) if rm else None
                continue
            m = re.match(r'\[(\d+)\]\s*=\s*\{([^}]*)\}', line)
            if m:
                classic_sid = int(m.group(1))
                fids = set(int(x) for x in re.findall(r'\d+', m.group(2)))
                if current_retail:
                    retail_to_classic[current_retail] = (classic_sid, fids)
                retail_to_classic[classic_sid] = (classic_sid, fids)
    return retail_to_classic


def fetch_wowhead_sounds(sid, era="classic"):
    """Fetch Wowhead and extract sound FIDs + filenames."""
    url = WOWHEAD_URLS[era].format(sid=sid)
    try:
        req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0"})
        with urllib.request.urlopen(req, timeout=10) as resp:
            html = resp.read().decode("utf-8", errors="replace")
        # Extract sound-ids/era/locale/kitid/fid/name.ogg
        sounds = re.findall(r'sound-ids[/\\]+\w+[/\\]+\w+[/\\]+(\d+)[/\\]+(\d+)[/\\]+([^"\\]+\.ogg)', html)
        result = {}
        for kit_id, fid_str, filename in sounds:
            fid = int(fid_str)
            result[fid] = filename
        return result
    except Exception as e:
        return {"_error": str(e)}


def classify_fid(fid, filename):
    """Classify a FID as impact/cast/precast/swing/ambient."""
    fn = filename.lower()
    if fid in GENERIC_SWING_FIDS or "swingweapon" in fn:
        return "swing"
    if fid in GENERIC_PRECAST:
        return "generic-cast"
    if fid in GENERIC_CAST:
        return "generic-cast"
    if "precast" in fn:
        return "precast"
    if "impact" in fn or "target" in fn or "hit" in fn:
        return "impact"
    if "cast" in fn:
        return "cast"
    if "loop" in fn or "state" in fn or "channel" in fn:
        return "loop"
    if "area" in fn or "base" in fn:
        return "area"
    return "other"


def pick_best_sound(fids_with_names):
    """Pick the most characteristic sound from a set of (fid, name) pairs."""
    classified = []
    for fid, name in fids_with_names:
        cat = classify_fid(fid, name)
        classified.append((cat, fid, name))

    # Priority: impact > cast > other > area > precast > loop > generic-cast > swing
    priority = {"impact": 0, "cast": 1, "other": 2, "area": 3, "precast": 4, "loop": 5, "generic-cast": 6, "swing": 7}
    classified.sort(key=lambda x: priority.get(x[0], 99))
    return classified


def main():
    listfile = load_listfile(LISTFILE)
    templates = parse_templates(TEMPLATE_FILE)
    retail_to_classic = parse_classic_ref(CLASSIC_FILE)

    # Find mismatches
    mismatches = []
    for cls, sid, name, sounds, has_excl, comment in templates:
        if not sounds:
            continue
        ref = retail_to_classic.get(sid)
        if not ref:
            continue
        classic_sid, classic_fids = ref
        if all(s in classic_fids for s in sounds):
            continue
        mismatches.append((cls, sid, name, sounds, classic_sid, classic_fids, has_excl, comment))

    print(f"Found {len(mismatches)} mismatches to verify")
    print()

    # Process each mismatch
    for i, (cls, sid, name, tmpl_sounds, classic_sid, classic_fids, has_excl, comment) in enumerate(mismatches):
        print(f"--- [{i+1}/{len(mismatches)}] {cls} / {name} (spell {sid}) ---")
        print(f"  Template sound: {tmpl_sounds} ({comment})")

        # Show classic DB2 FIDs with filenames
        print(f"  Classic DB2 ({classic_sid}):")
        classic_with_names = []
        for fid in sorted(classic_fids):
            fn = listfile.get(fid, "???")
            fn_short = fn.split("/")[-1] if "/" in fn else fn
            cat = classify_fid(fid, fn_short)
            classic_with_names.append((fid, fn_short))
            print(f"    {fid}: {fn_short} [{cat}]")

        # Fetch from Wowhead (try classic first, then appropriate era)
        lookup_sid = classic_sid if classic_sid != sid else sid

        # Determine which Wowhead era to use based on class
        if cls == "MONK":
            era = "mop"
        elif cls == "DEATHKNIGHT":
            era = "tbc"  # DK added in Wrath, try TBC-era wowhead (which covers Wrath)
        else:
            era = "classic"

        wh_sounds = fetch_wowhead_sounds(lookup_sid, era)
        if "_error" in wh_sounds:
            # Try the retail spell ID on classic
            wh_sounds = fetch_wowhead_sounds(sid, era)

        if "_error" not in wh_sounds and wh_sounds:
            print(f"  Wowhead ({era}, spell {lookup_sid}):")
            for fid in sorted(wh_sounds):
                fn = wh_sounds[fid]
                cat = classify_fid(fid, fn)
                marker = " <-- IN DB2" if fid in classic_fids else ""
                print(f"    {fid}: {fn} [{cat}]{marker}")
        elif "_error" in wh_sounds:
            print(f"  Wowhead: ERROR - {wh_sounds['_error']}")
        else:
            print(f"  Wowhead: no sounds found")

        # Recommend best sound from classic data
        ranked = pick_best_sound(classic_with_names)
        if ranked:
            best_cat, best_fid, best_name = ranked[0]
            tmpl_fid_name = listfile.get(tmpl_sounds[0], "???").split("/")[-1]
            print(f"  CURRENT:     {tmpl_sounds[0]} ({tmpl_fid_name})")
            print(f"  RECOMMENDED: {best_fid} ({best_name}) [{best_cat}]")
            if best_fid == tmpl_sounds[0]:
                print(f"  -> ALREADY CORRECT")
            elif best_fid in (tmpl_sounds[0],):
                print(f"  -> KEEP (same)")
            else:
                print(f"  -> CHANGE NEEDED")

        print()

        # Rate limit Wowhead requests
        time.sleep(0.3)


if __name__ == "__main__":
    main()
