#!/usr/bin/env python3
"""
spell_sounds.py — Walk the WoW DB2 chain to find all sound FileDataIDs for a spell.

Uses wago.tools public CSV API to download datamined DB2 tables.

Usage:
    python spell_sounds.py <SpellID> [SpellID ...]
    python spell_sounds.py --name "Mortal Strike"
    python spell_sounds.py --lua <SpellID> [SpellID ...]   # output as Lua table
    python spell_sounds.py --clear-cache                    # delete cached CSVs

Paths:
  A: SpellID → SpellXSpellVisual → SpellVisualEvent → SpellVisualKitEffect(type=1)
     → SoundKitEntry → FileDataID
  B: SpellID → SpellXSpellVisual → SpellVisual.AnimEventSoundID
     → SoundKitEntry → FileDataID
  C: SpellID → SpellXSpellVisual → SpellVisual.SpellVisualMissileSetID
     → SpellVisualMissile.SoundEntriesID → SoundKitEntry → FileDataID
"""

import argparse
import csv
import sys
import urllib.request
from collections import defaultdict
from pathlib import Path

CACHE_DIR = Path(__file__).parent / ".db2_cache"
WAGO_BASE = "https://wago.tools/db2"

TABLES = [
    "SpellXSpellVisual",
    "SpellVisual",
    "SpellVisualEvent",
    "SpellVisualKitEffect",
    "SpellVisualMissile",
    "SoundKitEntry",
    "SpellName",
    "SpellEffect",
]

# Additional tables for vocalization data
VOX_TABLES = [
    "CreatureSoundData",
    "ChrRaces",
    "ChrRaceXChrModel",
    "ChrModel",
    "CreatureDisplayInfo",
    "CreatureModelData",
]

# Weapon impact/swing sound tables
WEAPON_TABLES = [
    "WeaponImpactSounds",
    "WeaponSwingSounds2",
]

# UnitSoundType enum (EffectType=10 in SpellVisualKitEffect) -> CreatureSoundData column
UNIT_SOUND_TYPE_COLS = {
    1: "SoundExertionID",
    2: "SoundExertionCriticalID",
    3: "SoundInjuryID",
    4: "SoundInjuryCriticalID",
    5: "SoundInjuryCrushingBlowID",
    6: "SoundDeathID",
    7: "SoundStunID",
    8: "SoundStandID",
    9: "SoundFootstepID",
    13: "SoundAlertID",
    14: "SoundFidget_0",
    15: "SoundFidget_1",
    18: "SoundFidget_4",
    19: "CustomAttack_0",
    20: "CustomAttack_1",
    21: "CustomAttack_2",
    24: "LoopSoundID",
    26: "SoundJumpStartID",
    27: "SoundJumpEndID",
    34: "SpellCastDirectedSoundID",
    35: "SubmergeSoundID",
    36: "SubmergedSoundID",
    38: "BattleShoutSoundID",
    39: "BattleShoutCriticalSoundID",
    40: "TauntSoundID",
    # Synthetic keys (101+) for CSD columns not referenced by any UST enum value
    101: "WindupSoundID",
    102: "WindupCriticalSoundID",
    103: "ChargeSoundID",
    104: "SoundAggroID",
    105: "SoundFidget_2",
    106: "SoundFidget_3",
}

# Human-readable names for common vocalization types
UNIT_SOUND_TYPE_NAMES = {
    1: "Exertion",
    2: "ExertionCrit",
    38: "BattleShout",
    39: "BattleShoutCrit",
    34: "SpellCast",
    3: "Injury",
    4: "InjuryCrit",
    6: "Death",
    7: "Stun",
    40: "Taunt",
    101: "Windup",
    102: "WindupCrit",
    103: "Charge",
    104: "Aggro",
    105: "Fidget3",
    106: "Fidget4",
}



def download_csv(table_name: str, force: bool = False) -> Path:
    """Download a DB2 CSV from wago.tools, caching locally."""
    CACHE_DIR.mkdir(parents=True, exist_ok=True)
    path = CACHE_DIR / f"{table_name}.csv"

    if path.exists() and not force:
        return path

    url = f"{WAGO_BASE}/{table_name}/csv"
    print(f"  Downloading {table_name}...", end=" ", flush=True)
    try:
        req = urllib.request.Request(url, headers={"User-Agent": "Resonance-SpellLookup/1.0"})
        with urllib.request.urlopen(req, timeout=120) as resp:
            data = resp.read()
        path.write_bytes(data)
        size_mb = len(data) / (1024 * 1024)
        print(f"OK ({size_mb:.1f} MB)")
    except Exception as e:
        print(f"FAILED: {e}")
        raise
    return path


def load_csv(path: Path) -> list[dict]:
    """Load a CSV into a list of dicts."""
    with open(path, "r", encoding="utf-8") as f:
        return list(csv.DictReader(f))


def build_index(rows: list[dict], key_col: str) -> dict[int, list[dict]]:
    """Build a lookup: int(key_col) → [rows]."""
    idx = defaultdict(list)
    for row in rows:
        val = row.get(key_col, "")
        if val and val != "0":
            try:
                idx[int(val)].append(row)
            except ValueError:
                pass
    return idx


def soundkit_to_fids(sound_kit_id: int, ske_index: dict) -> list[int]:
    """Resolve a SoundKitID to a list of FileDataIDs."""
    fids = []
    for ske in ske_index.get(sound_kit_id, []):
        fid = int(ske["FileDataID"])
        if fid:
            fids.append(fid)
    return fids


def find_sounds_for_spell(spell_id: int, indices: dict, visited: set | None = None) -> dict:
    """Walk the DB2 chain and return all sound info for a spell.

    Also follows triggered sub-spells (SpellEffect type 64) recursively.
    """
    if visited is None:
        visited = set()
    visited.add(spell_id)

    results = {
        "spell_id": spell_id,
        "path_a_sounds": [],  # via SpellVisualKitEffect
        "path_b_sounds": [],  # via AnimEventSoundID
        "path_c_sounds": [],  # via SpellVisualMissile
        "all_file_data_ids": set(),
        "unit_sound_types": set(),  # EffectType=10 UnitSoundType values
        "triggered_spells": [],  # sub-spell IDs from SpellEffect type 64
    }

    ske_idx = indices["SoundKitEntry_by_SoundKitID"]

    # Step 1: SpellID → SpellVisualIDs
    xsv_rows = indices["SpellXSpellVisual_by_SpellID"].get(spell_id, [])

    visual_ids = set()
    for row in xsv_rows:
        vid = int(row["SpellVisualID"])
        if vid:
            visual_ids.add(vid)

    for vid in visual_ids:
        sv_rows = indices["SpellVisual_by_ID"].get(vid, [])
        for sv in sv_rows:
            # Path B: AnimEventSoundID (shortcut)
            anim_sound = int(sv.get("AnimEventSoundID", 0))
            if anim_sound:
                for fid in soundkit_to_fids(anim_sound, ske_idx):
                    results["path_b_sounds"].append({
                        "visual_id": vid,
                        "sound_kit_id": anim_sound,
                        "file_data_id": fid,
                    })
                    results["all_file_data_ids"].add(fid)

            # Path C: Missile sounds
            missile_set_id = int(sv.get("SpellVisualMissileSetID", 0))
            if missile_set_id:
                missile_rows = indices["SpellVisualMissile_by_SetID"].get(missile_set_id, [])
                for missile in missile_rows:
                    snd = int(missile.get("SoundEntriesID", 0))
                    if snd:
                        for fid in soundkit_to_fids(snd, ske_idx):
                            results["path_c_sounds"].append({
                                "visual_id": vid,
                                "missile_set_id": missile_set_id,
                                "sound_kit_id": snd,
                                "file_data_id": fid,
                            })
                            results["all_file_data_ids"].add(fid)

    # Path A: SpellVisual → SpellVisualEvent → SpellVisualKitEffect → SoundKitEntry
    for vid in visual_ids:
        sve_rows = indices["SpellVisualEvent_by_SpellVisualID"].get(vid, [])
        for sve in sve_rows:
            kit_id = int(sve.get("SpellVisualKitID", 0))
            if not kit_id:
                continue

            effect_rows = indices["SpellVisualKitEffect_by_ParentKit"].get(kit_id, [])
            for eff in effect_rows:
                eff_type = eff.get("EffectType")

                if eff_type == "5":  # Sound
                    sound_kit_id = int(eff.get("Effect", 0))
                    if not sound_kit_id:
                        continue

                    for fid in soundkit_to_fids(sound_kit_id, ske_idx):
                        results["path_a_sounds"].append({
                            "visual_id": vid,
                            "event_start": sve.get("StartEvent", "?"),
                            "event_end": sve.get("EndEvent", "?"),
                            "target_type": sve.get("TargetType", "?"),
                            "kit_id": kit_id,
                            "sound_kit_id": sound_kit_id,
                            "file_data_id": fid,
                        })
                        results["all_file_data_ids"].add(fid)

                elif eff_type == "10":  # UnitSoundType (vocalization)
                    ust = int(eff.get("Effect", 0))
                    if ust:
                        results["unit_sound_types"].add(ust)

    # Follow triggered sub-spells (SpellEffect Effect=64 → TriggerSpell)
    spell_effect_rows = indices.get("SpellEffect_by_SpellID", {}).get(spell_id, [])
    for row in spell_effect_rows:
        if row.get("Effect") != "64":
            continue
        trigger_id = int(row.get("EffectTriggerSpell", 0))
        if not trigger_id or trigger_id in visited:
            continue
        results["triggered_spells"].append(trigger_id)
        sub = find_sounds_for_spell(trigger_id, indices, visited)
        results["all_file_data_ids"].update(sub["all_file_data_ids"])
        results["unit_sound_types"].update(sub["unit_sound_types"])

    return results


EVENT_NAMES = {
    "0": "none", "1": "cast_start", "2": "cast_end", "3": "channel_start",
    "4": "channel_end", "5": "precast", "6": "impact", "7": "aura_start",
    "8": "aura_end", "9": "area_trigger", "10": "extra_attack",
    "11": "missile_launch", "12": "missile_impact", "13": "end",
}

TARGET_NAMES = {"1": "caster", "2": "target", "3": "area", "4": "dest"}


def format_results(results: dict, spell_name: str = "") -> str:
    """Format results for display."""
    lines = []
    label = spell_name or str(results["spell_id"])
    lines.append(f"=== SpellID {results['spell_id']}: {label} ===")

    if not results["all_file_data_ids"]:
        lines.append("  No sounds found.")
        return "\n".join(lines)

    if results["path_b_sounds"]:
        lines.append("  AnimEventSoundID:")
        for s in results["path_b_sounds"]:
            lines.append(f"    SoundKit {s['sound_kit_id']} → FileDataID {s['file_data_id']}")

    if results["path_c_sounds"]:
        lines.append("  Missile sounds:")
        seen = set()
        for s in results["path_c_sounds"]:
            key = (s["sound_kit_id"], s["file_data_id"])
            if key in seen:
                continue
            seen.add(key)
            lines.append(f"    MissileSet {s['missile_set_id']} → SoundKit {s['sound_kit_id']} → FileDataID {s['file_data_id']}")

    if results["path_a_sounds"]:
        lines.append("  Visual kit sounds:")
        seen = set()
        for s in results["path_a_sounds"]:
            key = (s["sound_kit_id"], s["file_data_id"])
            if key in seen:
                continue
            seen.add(key)
            evt_s = EVENT_NAMES.get(str(s["event_start"]), str(s["event_start"]))
            evt_e = EVENT_NAMES.get(str(s["event_end"]), str(s["event_end"]))
            tgt = TARGET_NAMES.get(str(s["target_type"]), f"type{s['target_type']}")
            lines.append(f"    Kit {s['kit_id']} ({evt_s}→{evt_e}, {tgt}) → SoundKit {s['sound_kit_id']} → FileDataID {s['file_data_id']}")

    if results.get("triggered_spells"):
        lines.append(f"  Triggered sub-spells: {', '.join(str(s) for s in results['triggered_spells'])}")

    all_fids = sorted(results["all_file_data_ids"])
    lines.append(f"  All FileDataIDs ({len(all_fids)}): {', '.join(str(f) for f in all_fids)}")
    return "\n".join(lines)


def format_lua_mutes(all_results: list[tuple[int, str, dict]]) -> str:
    """Output a Lua snippet to paste into the addon."""
    lines = ["-- Paste into /run or a Lua file to mute these sounds"]
    lines.append("-- Generated by spell_sounds.py")
    lines.append("local mutes = {")

    for spell_id, spell_name, results in all_results:
        if results["all_file_data_ids"]:
            label = spell_name or str(spell_id)
            fids = sorted(results["all_file_data_ids"])
            lines.append(f"  -- {label} (SpellID {spell_id})")
            for fid in fids:
                lines.append(f"  {fid},")

    lines.append("}")
    lines.append("for _, fid in ipairs(mutes) do MuteSoundFile(fid) end")
    lines.append(f"print('Muted ' .. #mutes .. ' sound files.')")
    return "\n".join(lines)


def resolve_spell_name(name: str, spell_name_index: dict[str, list[dict]]) -> list[tuple[int, str]]:
    """Look up SpellID(s) by name."""
    matches = []
    name_lower = name.lower()
    for sname, rows in spell_name_index.items():
        if sname.lower() == name_lower:
            for row in rows:
                sid = int(row["ID"])
                matches.append((sid, sname))
    return matches


def build_vox_data(csv_paths: dict, ske_idx: dict) -> dict:
    """Build race/gender vocalization lookup from CreatureSoundData chain."""
    vox_tables = {}
    for table in VOX_TABLES:
        vox_tables[table] = download_csv(table)

    # ChrRaces: ID -> ClientPrefix
    race_names = {}
    for row in load_csv(vox_tables["ChrRaces"]):
        race_names[row["ID"]] = row.get("ClientPrefix", "") or row.get("Name_lang", "")

    # ChrRaceXChrModel: (RaceID, Sex) -> ChrModelID
    rxm = {}
    for row in load_csv(vox_tables["ChrRaceXChrModel"]):
        rxm[(row.get("ChrRacesID", ""), row.get("Sex", ""))] = row.get("ChrModelID", "")

    # ChrModel: ID -> DisplayID
    model_display = {}
    for row in load_csv(vox_tables["ChrModel"]):
        model_display[row["ID"]] = row.get("DisplayID", "")

    # CreatureDisplayInfo: ID -> SoundID, ModelID
    cdi = {}
    for row in load_csv(vox_tables["CreatureDisplayInfo"]):
        cdi[row["ID"]] = (row.get("SoundID", "0"), row.get("ModelID", "0"))

    # CreatureModelData: ID -> SoundID
    cmd_sound = {}
    for row in load_csv(vox_tables["CreatureModelData"]):
        cmd_sound[row["ID"]] = row.get("SoundID", "0")

    # CreatureSoundData: ID -> {column -> SoundKitID}
    csd_data = {}
    for row in load_csv(vox_tables["CreatureSoundData"]):
        csd_data[row["ID"]] = row

    # Resolve: (race_id, sex) -> CSD ID
    race_csd = {}
    for (race_id, sex), chr_model_id in rxm.items():
        display_id = model_display.get(chr_model_id, "")
        if not display_id:
            continue
        di = cdi.get(display_id, ("0", "0"))
        sound_id = di[0]
        if sound_id == "0":
            model_id = di[1]
            sound_id = cmd_sound.get(model_id, "0")
        if sound_id != "0":
            race_csd[(race_id, sex)] = sound_id

    # For each (race_id, sex) + UnitSoundType, resolve to FileDataIDs
    # Return: {csd_id: {ust_col: [fids]}}
    vox_fids = {}
    for csd_id, row in csd_data.items():
        vox_entry = {}
        for ust, col in UNIT_SOUND_TYPE_COLS.items():
            sk = int(row.get(col, 0))
            if sk:
                fids = soundkit_to_fids(sk, ske_idx)
                if fids:
                    vox_entry[ust] = sorted(fids)
        if vox_entry:
            vox_fids[int(csd_id)] = vox_entry

    return {
        "race_csd": race_csd,
        "vox_fids": vox_fids,
        "race_names": race_names,
    }


def build_weapon_data(ske_idx: dict) -> list[int]:
    """Build a flat list of all weapon impact + swing sound FileDataIDs."""
    weapon_tables = {}
    for table in WEAPON_TABLES:
        weapon_tables[table] = download_csv(table)

    all_fids = set()

    # WeaponImpactSounds: collect all SoundKit IDs from impact columns
    impact_rows = load_csv(weapon_tables["WeaponImpactSounds"])
    impact_prefixes = [
        "ImpactSoundID_",
        "CritImpactSoundID_",
        "PierceImpactSoundID_",
        "PierceCritImpactSoundID_",
    ]
    for row in impact_rows:
        for prefix in impact_prefixes:
            for i in range(11):  # 0-10
                col = f"{prefix}{i}"
                sk = int(row.get(col, 0))
                if sk:
                    for fid in soundkit_to_fids(sk, ske_idx):
                        all_fids.add(fid)

    # WeaponSwingSounds2: collect all SoundID values
    swing_rows = load_csv(weapon_tables["WeaponSwingSounds2"])
    for row in swing_rows:
        sk = int(row.get("SoundID", 0))
        if sk:
            for fid in soundkit_to_fids(sk, ske_idx):
                all_fids.add(fid)

    return sorted(all_fids)


def generate_mute_data(indices: dict, xsv_index: dict, output_path: Path,
                       csv_paths: dict) -> None:
    """Generate SpellMuteData.lua with SpellID→FileDataIDs mapping for all spells."""
    ske_idx = indices["SoundKitEntry_by_SoundKitID"]

    # Build vocalization data
    print("Building vocalization data...")
    vox_data = build_vox_data(csv_paths, ske_idx)

    # Build weapon impact data
    print("Building weapon impact/swing data...")
    weapon_fids = build_weapon_data(ske_idx)

    print("Generating mute data for all spells...")
    spell_ids = sorted(xsv_index.keys())
    print(f"  {len(spell_ids)} spells with visual data")

    mute_data = {}    # spellID -> sorted list of FIDs
    vox_types = {}    # spellID -> sorted list of UnitSoundType values
    count = 0
    for spell_id in spell_ids:
        results = find_sounds_for_spell(spell_id, indices)

        fids = sorted(results["all_file_data_ids"])
        if fids:
            mute_data[spell_id] = fids
            count += 1

        if results["unit_sound_types"]:
            vox_types[spell_id] = sorted(results["unit_sound_types"])

    print(f"  {count} spells have sound data")
    print(f"  {len(vox_types)} spells have vocalization triggers")

    with open(output_path, "w", encoding="utf-8") as f:
        f.write("-- Auto-generated by tools/spell_sounds.py --generate-mute-data\n")
        f.write(f"-- {count} spells with sound data, "
                f"{len(vox_types)} with vocalization triggers\n\n")

        # Spell mute data
        f.write("Resonance_SpellMuteData = {\n")
        for spell_id in sorted(mute_data.keys()):
            fids = mute_data[spell_id]
            fid_str = ",".join(str(fid) for fid in fids)
            f.write(f"[{spell_id}]={{{fid_str}}},\n")
        f.write("}\n\n")

        # Spell vocalization types: SpellID -> {UnitSoundType, ...}
        f.write("-- SpellID -> {UnitSoundType values}\n")
        f.write("Resonance_SpellVoxTypes = {\n")
        for spell_id in sorted(vox_types.keys()):
            usts = vox_types[spell_id]
            ust_str = ",".join(str(u) for u in usts)
            f.write(f"[{spell_id}]={{{ust_str}}},\n")
        f.write("}\n\n")

        # UnitSoundType names
        f.write("-- UnitSoundType enum -> display name\n")
        f.write("Resonance_VoxTypeNames = {\n")
        for ust in sorted(UNIT_SOUND_TYPE_NAMES.keys()):
            f.write(f'[{ust}]="{UNIT_SOUND_TYPE_NAMES[ust]}",\n')
        f.write("}\n\n")

        # Race/gender -> CSD ID mapping
        f.write("-- {raceID, sex} -> CreatureSoundData ID\n")
        f.write("Resonance_RaceCSD = {\n")
        for (race_id, sex), csd_id in sorted(vox_data["race_csd"].items()):
            f.write(f'["{race_id}:{sex}"]={csd_id},\n')
        f.write("}\n\n")

        # CSD ID -> {UnitSoundType -> {FileDataIDs}}
        # Only include CSDs that are used by player races; include ALL vox types
        player_csds = set(int(v) for v in vox_data["race_csd"].values())
        f.write("-- CreatureSoundData ID -> {UnitSoundType -> {FileDataIDs}}\n")
        f.write("Resonance_VoxFIDs = {\n")
        for csd_id in sorted(player_csds):
            vox_entry = vox_data["vox_fids"].get(csd_id, {})
            if not vox_entry:
                continue
            parts = []
            for ust in sorted(vox_entry.keys()):
                fids = vox_entry[ust]
                fid_str = ",".join(str(fid) for fid in fids)
                parts.append(f"[{ust}]={{{fid_str}}}")
            if parts:
                f.write(f"[{csd_id}]={{{','.join(parts)}}},\n")
        f.write("}\n\n")

        # Weapon impact + swing FileDataIDs (flat array)
        f.write(f"-- {len(weapon_fids)} weapon impact/swing FileDataIDs\n")
        f.write("Resonance_WeaponImpactFIDs = {")
        f.write(",".join(str(fid) for fid in weapon_fids))
        f.write("}\n")

    size_mb = output_path.stat().st_size / (1024 * 1024)
    print(f"  Written to {output_path} ({size_mb:.1f} MB)")


def load_tables_and_build_indices(args) -> tuple[dict, list]:
    """Download/load CSVs and build indices. Returns (indices, xsv_rows)."""
    print("Loading DB2 tables...")
    csv_paths = {}
    for table in TABLES:
        csv_paths[table] = download_csv(table, force=args.refresh)

    print("Building indices...")
    xsv = load_csv(csv_paths["SpellXSpellVisual"])
    sv = load_csv(csv_paths["SpellVisual"])
    sve = load_csv(csv_paths["SpellVisualEvent"])
    svke = load_csv(csv_paths["SpellVisualKitEffect"])
    svm = load_csv(csv_paths["SpellVisualMissile"])
    ske = load_csv(csv_paths["SoundKitEntry"])
    se = load_csv(csv_paths["SpellEffect"])

    indices = {
        "SpellXSpellVisual_by_SpellID": build_index(xsv, "SpellID"),
        "SpellVisual_by_ID": build_index(sv, "ID"),
        "SpellVisualEvent_by_SpellVisualID": build_index(sve, "SpellVisualID"),
        "SpellVisualKitEffect_by_ParentKit": build_index(svke, "ParentSpellVisualKitID"),
        "SpellVisualMissile_by_SetID": build_index(svm, "SpellVisualMissileSetID"),
        "SoundKitEntry_by_SoundKitID": build_index(ske, "SoundKitID"),
        "SpellEffect_by_SpellID": build_index(se, "SpellID"),
    }

    return indices, csv_paths


def main():
    parser = argparse.ArgumentParser(description="Look up sound FileDataIDs for WoW spells")
    parser.add_argument("spell_ids", nargs="*", type=int, help="SpellID(s) to look up")
    parser.add_argument("--name", "-n", type=str, help="Look up by spell name instead of ID")
    parser.add_argument("--lua", action="store_true", help="Output as Lua mute snippet")
    parser.add_argument("--generate-mute-data", action="store_true",
                        help="Generate SpellMuteData.lua with all SpellID→FileDataID mappings")
    parser.add_argument("--clear-cache", action="store_true", help="Delete cached CSV files")
    parser.add_argument("--refresh", action="store_true", help="Re-download CSVs")
    args = parser.parse_args()

    if args.clear_cache:
        if CACHE_DIR.exists():
            import shutil
            shutil.rmtree(CACHE_DIR)
            print("Cache cleared.")
        else:
            print("No cache to clear.")
        return

    if args.generate_mute_data:
        indices, csv_paths = load_tables_and_build_indices(args)
        output_path = Path(__file__).parent.parent / "data" / "SpellMuteData.lua"
        generate_mute_data(indices, indices["SpellXSpellVisual_by_SpellID"],
                           output_path, csv_paths)
        return

    if not args.spell_ids and not args.name:
        parser.print_help()
        sys.exit(1)

    indices, csv_paths = load_tables_and_build_indices(args)

    # Resolve spell names if needed
    spell_lookups = []  # list of (spell_id, name)

    if args.name:
        spell_names = load_csv(csv_paths["SpellName"])
        name_index = defaultdict(list)
        for row in spell_names:
            n = row.get("Name_lang", "")
            if n:
                name_index[n].append(row)

        matches = resolve_spell_name(args.name, name_index)
        if not matches:
            print(f"No spells found with name '{args.name}'.")
            sys.exit(1)

        print(f"Found {len(matches)} spell(s) named '{args.name}':")
        for sid, sname in matches:
            print(f"  SpellID {sid}: {sname}")
        spell_lookups = matches
    else:
        # Try to resolve names for the IDs
        spell_names = load_csv(csv_paths["SpellName"])
        id_to_name = {}
        for row in spell_names:
            try:
                id_to_name[int(row["ID"])] = row.get("Name_lang", "")
            except (ValueError, KeyError):
                pass
        spell_lookups = [(sid, id_to_name.get(sid, "")) for sid in args.spell_ids]

    # Look up sounds
    print()
    all_results = []
    for spell_id, spell_name in spell_lookups:
        results = find_sounds_for_spell(spell_id, indices)
        all_results.append((spell_id, spell_name, results))

        if not args.lua:
            print(format_results(results, spell_name))
            print()

    if args.lua:
        print(format_lua_mutes(all_results))


if __name__ == "__main__":
    main()
