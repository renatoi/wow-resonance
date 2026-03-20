#!/usr/bin/env python3
"""
spell_sounds.py — Walk the WoW DB2 chain to find all sound FileDataIDs for a spell.

Uses wago.tools public CSV API to download datamined DB2 tables.

Usage:
    python spell_sounds.py <SpellID> [SpellID ...]
    python spell_sounds.py --name "Mortal Strike"
    python spell_sounds.py --build mop 12294                # MoP Classic data
    python spell_sounds.py --build cata --name "Lava Burst"  # Cata Classic data
    python spell_sounds.py --lua <SpellID> [SpellID ...]    # output as Lua table
    python spell_sounds.py --generate-mute-data             # generate SpellMuteData.lua
    python spell_sounds.py --generate-mute-data --build mop # from MoP Classic data
    python spell_sounds.py --generate-classic-reference     # generate ClassicSpellSounds.lua
    python spell_sounds.py --list-builds                    # show available builds
    python spell_sounds.py --clear-cache                    # delete cached CSVs

Build aliases:
    retail   Current retail (default, no build param)
    mop      MoP Classic (5.5.3.x)
    cata     Cataclysm Classic (3.80.x)
    classic  Classic Era (1.15.x)
    (or pass a raw version string like 5.5.3.66128)

DB2 chain paths:
  A: SpellID → SpellXSpellVisual → SpellVisualEvent → SpellVisualKitEffect(type=5)
     → SoundKitEntry → FileDataID
  B: SpellID → SpellXSpellVisual → SpellVisual.AnimEventSoundID
     → SoundKitEntry → FileDataID
  C: SpellID → SpellXSpellVisual → SpellVisual.SpellVisualMissileSetID
     → SpellVisualMissile.SoundEntriesID → SoundKitEntry → FileDataID
"""

import argparse
import csv
import re
import sys
import urllib.request
from collections import defaultdict
from pathlib import Path

CACHE_DIR = Path(__file__).parent / ".db2_cache"
WAGO_BASE = "https://wago.tools/db2"

# Friendly build aliases → (wago.tools product, latest known build version)
# Use `--list-builds` to fetch current versions from the API.
BUILD_ALIASES = {
    "retail": ("wow", None),          # None = omit ?build= param (wago default)
    "mop": ("wow_classic", "5.5.3.66128"),
    "cata": ("wow_classic_titan", "3.80.0.66130"),
    "classic": ("wow_classic_era", "1.15.8.66129"),
}

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

# Profession-related DB2 tables
PROFESSION_TABLES = [
    "SkillLine",
    "SkillLineAbility",
]

# Base crafting/gathering/secondary professions by SkillLine ID
# (expansion-specific variants are matched by DisplayName suffix)
PROFESSION_BASE = {
    164: "Blacksmithing", 165: "Leatherworking", 171: "Alchemy",
    182: "Herbalism", 185: "Cooking", 186: "Mining",
    197: "Tailoring", 202: "Engineering", 333: "Enchanting",
    356: "Fishing", 393: "Skinning", 755: "Jewelcrafting",
    773: "Inscription",
}

# Display order in the addon UI
PROFESSION_ORDER = [
    "Alchemy", "Blacksmithing", "Cooking", "Enchanting", "Engineering",
    "Fishing", "Herbalism", "Inscription", "Jewelcrafting",
    "Leatherworking", "Mining", "Skinning", "Tailoring",
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



def download_csv(table_name: str, force: bool = False,
                  build: str | None = None) -> Path:
    """Download a DB2 CSV from wago.tools, caching locally.

    Args:
        table_name: DB2 table name (e.g. "SpellName").
        force: Re-download even if cached.
        build: Game build version string (e.g. "5.5.3.66128").
               None means use wago.tools default (latest retail).
    """
    cache_subdir = CACHE_DIR / (build or "retail")
    cache_subdir.mkdir(parents=True, exist_ok=True)
    path = cache_subdir / f"{table_name}.csv"

    if path.exists() and not force:
        return path

    url = f"{WAGO_BASE}/{table_name}/csv"
    if build:
        url += f"?build={build}"
    print(f"  Downloading {table_name} ({build or 'retail'})...", end=" ", flush=True)
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


def build_vox_data(csv_paths: dict, ske_idx: dict,
                   build: str | None = None) -> dict:
    """Build race/gender vocalization lookup from CreatureSoundData chain."""
    vox_tables = {}
    for table in VOX_TABLES:
        vox_tables[table] = download_csv(table, build=build)

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


def build_weapon_data(ske_idx: dict, build: str | None = None) -> list[int]:
    """Build a flat list of all weapon impact + swing sound FileDataIDs."""
    weapon_tables = {}
    for table in WEAPON_TABLES:
        weapon_tables[table] = download_csv(table, build=build)

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
                       csv_paths: dict, build: str | None = None,
                       max_fid_sharing: int = 100) -> None:
    """Generate SpellMuteData.lua with SpellID→FileDataIDs mapping for all spells.

    max_fid_sharing: exclude FIDs referenced by more than this many spells.
        Generic sounds like precastnaturemagichigh.ogg (4,251 spells) or
        fx_whoosh_small_revamp_*.ogg (~3,400 spells) are not distinctive
        spell sounds — muting them for one spell collaterally silences them
        for every other spell in the game (including Hearthstone).
    """
    ske_idx = indices["SoundKitEntry_by_SoundKitID"]

    # Build vocalization data
    print("Building vocalization data...")
    vox_data = build_vox_data(csv_paths, ske_idx, build=build)

    # Build weapon impact data
    print("Building weapon impact/swing data...")
    weapon_fids = build_weapon_data(ske_idx, build=build)

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

    # Exclude over-shared FIDs (generic cast/precast/whoosh sounds)
    fid_spell_count: dict[int, int] = {}
    for fids in mute_data.values():
        for fid in fids:
            fid_spell_count[fid] = fid_spell_count.get(fid, 0) + 1
    overshared = {fid for fid, c in fid_spell_count.items()
                  if c > max_fid_sharing}
    if overshared:
        filtered_spells = 0
        for spell_id in list(mute_data.keys()):
            original = mute_data[spell_id]
            filtered = [fid for fid in original if fid not in overshared]
            if filtered:
                mute_data[spell_id] = filtered
            else:
                del mute_data[spell_id]
            if len(filtered) != len(original):
                filtered_spells += 1
        print(f"  Excluded {len(overshared)} over-shared FIDs"
              f" (>{max_fid_sharing} spells), touched {filtered_spells} spells")
        count = len(mute_data)

    with open(output_path, "w", encoding="utf-8") as f:
        f.write("-- Auto-generated by tools/spell_sounds.py --generate-mute-data\n")
        f.write(f"-- {count} spells with sound data, "
                f"{len(vox_types)} with vocalization triggers\n\n")

        # Over-shared FIDs that were excluded — addon should unmute these
        # on load to clean up stale MuteSoundFile state from older data.
        if overshared:
            excluded_str = ",".join(str(fid) for fid in sorted(overshared))
            f.write(f'Resonance_ExcludedFIDs = "{excluded_str}"\n\n')

        # Spell mute data (string-packed to avoid ~19 MB table spike at parse)
        f.write("Resonance_SpellMuteData = {\n")
        for spell_id in sorted(mute_data.keys()):
            fids = mute_data[spell_id]
            fid_str = ",".join(str(fid) for fid in fids)
            f.write(f'[{spell_id}]="{fid_str}",\n')
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


def parse_class_templates(path: Path) -> dict[str, list[dict]]:
    """Parse ClassTemplates.lua to extract spell entries grouped by class.

    Returns: {"WARRIOR": [{"spellID": 163201, "name": "Execute"}, ...], ...}
    """
    content = path.read_text(encoding="utf-8")
    classes = {}
    current_class = None

    for line in content.splitlines():
        # Match class header: "  WARRIOR = {"
        class_match = re.match(r"\s*(\w+)\s*=\s*\{", line)
        if class_match:
            key = class_match.group(1)
            # Skip non-class keys (Resonance_ClassTemplates itself)
            if key != "Resonance_ClassTemplates":
                current_class = key
                classes[current_class] = []
            continue

        # Closing brace ends current class
        if current_class and re.match(r"\s*\}", line):
            current_class = None
            continue

        if current_class:
            spell_match = re.search(
                r'spellID\s*=\s*(\d+)\s*,\s*name\s*=\s*"([^"]+)"', line
            )
            if spell_match:
                classes[current_class].append({
                    "spellID": int(spell_match.group(1)),
                    "name": spell_match.group(2),
                })

    return classes


def _find_classic_spell(retail_id: int, name: str, indices: dict,
                        name_to_ids: dict[str, list[int]],
                        xsv_index: dict) -> tuple[int, dict]:
    """Look up a spell's classic sounds, trying retail ID first then name.

    Uses the SpellXSpellVisual index to verify a name-matched spell actually
    has visual data (filters out passive/aura/NPC spells that share names).

    Returns (classic_id, results_dict).
    """
    # Try the retail ID directly
    results = find_sounds_for_spell(retail_id, indices)
    if results["all_file_data_ids"]:
        return retail_id, results

    # Fall back to name search — prefer IDs that have SpellXSpellVisual data
    candidates = name_to_ids.get(name.lower(), [])
    # Sort by ID ascending to prefer lower (usually more canonical) spell IDs
    for cid in sorted(candidates):
        if cid not in xsv_index:
            continue
        r = find_sounds_for_spell(cid, indices)
        if r["all_file_data_ids"]:
            return cid, r

    empty = {"all_file_data_ids": set()}
    return retail_id, empty


# Which build to use per class — vanilla classes use Classic Era,
# DK uses Cata Classic (Wrath+), Monk uses MoP Classic
CLASS_BUILD_MAP = {
    "DEATHKNIGHT": "cata",
    "MONK": "mop",
}


def generate_classic_reference(args, output_path: Path) -> None:
    """Generate ClassicSpellSounds.lua by looking up each template spell in
    the appropriate classic-era DB2 data.

    Vanilla classes use Classic Era data, DK uses Cata Classic (has Wrath
    content), and Monk uses MoP Classic. Each class automatically selects
    the right build.

    For each spell in ClassTemplates.lua:
      1. Try the retail spell ID in the build's data
      2. If not found, search by spell name to find the classic-era ID
      3. Write the mapping with all discovered FileDataIDs

    The output is a development reference — sounds should be verified against
    Wowhead Classic before being used in ClassTemplates.lua.
    """
    template_path = Path(__file__).parent.parent / "data" / "ClassTemplates.lua"
    if not template_path.exists():
        print(f"Error: {template_path} not found.")
        sys.exit(1)

    classes = parse_class_templates(template_path)

    # Determine which builds we need
    needed_builds = set()
    for class_key in classes:
        needed_builds.add(CLASS_BUILD_MAP.get(class_key, "classic"))

    # Load indices for each build
    build_data: dict[str, tuple[dict, dict, dict]] = {}  # build -> (indices, name_to_ids, xsv_index)
    for build_alias in sorted(needed_builds):
        print(f"\n--- Loading {build_alias} data ---")
        args.build = build_alias
        indices, csv_paths = load_tables_and_build_indices(args)

        spell_names_csv = load_csv(csv_paths["SpellName"])
        name_to_ids: dict[str, list[int]] = defaultdict(list)
        for row in spell_names_csv:
            sn = row.get("Name_lang", "")
            if sn:
                try:
                    name_to_ids[sn.lower()].append(int(row["ID"]))
                except (ValueError, KeyError):
                    pass

        xsv_index = indices["SpellXSpellVisual_by_SpellID"]
        build_data[build_alias] = (indices, name_to_ids, xsv_index)

    found = 0
    not_found = 0

    with open(output_path, "w", encoding="utf-8") as f:
        f.write("-- Classic spell sound reference table\n")
        f.write("-- Auto-generated by tools/spell_sounds.py "
                "--generate-classic-reference\n")
        f.write("-- Maps spell IDs to their Classic-era sound FIDs via DB2 "
                "chain walking\n")
        f.write("--\n")
        f.write("-- Format: [spellID] = { fid, fid, ... }\n")
        f.write("-- This is a REFERENCE TABLE only -- not loaded by the addon "
                "at runtime\n")
        f.write("-- Sounds should be verified against Wowhead Classic before "
                "use in ClassTemplates\n")
        f.write("--\n")
        f.write("-- To verify a spell's classic sounds:\n")
        f.write("--   1. Go to https://www.wowhead.com/classic/spell=SPELLID "
                "(Sound tab)\n")
        f.write("--   2. Or use https://wago.tools/db2/SoundKitEntry to trace "
                "SoundKit -> FileDataID\n")
        f.write("\nResonance_ClassicSpellSounds = {\n")

        for class_key, spells in classes.items():
            build_alias = CLASS_BUILD_MAP.get(class_key, "classic")
            indices, name_to_ids, xsv_index = build_data[build_alias]

            f.write(f"  {'---' * 25}\n")
            f.write(f"  -- {class_key}")
            if build_alias != "classic":
                f.write(f" (from {build_alias} data)")
            f.write("\n")
            f.write(f"  {'---' * 25}\n")

            for spell in spells:
                retail_id = spell["spellID"]
                name = spell["name"]

                classic_id, results = _find_classic_spell(
                    retail_id, name, indices, name_to_ids, xsv_index
                )

                if results["all_file_data_ids"]:
                    fids = sorted(results["all_file_data_ids"])
                    fid_str = ", ".join(str(fid) for fid in fids)
                    if classic_id != retail_id:
                        # Name-matched to a different spell ID — may be
                        # a false match (different spell with same name)
                        f.write(f"  -- {name} (retail: {retail_id}, "
                                f"name-matched to {classic_id} — verify!)\n")
                    else:
                        f.write(f"  -- {name}\n")
                    f.write(f"  [{classic_id}] = {{ {fid_str} }},\n")
                    found += 1
                else:
                    f.write(f"  -- {name} ({retail_id}): "
                            f"no sounds found\n")
                    not_found += 1

        f.write("}\n")

    print(f"\n  Written to {output_path}")
    print(f"  {found} spells with sounds, {not_found} without")
    if not_found:
        print("  (Spells without sounds are likely retail-only or hero "
              "talent variants)")


# Creature archetype -> category classification.
# Keywords matched against the creature type folder name from the listfile
# (e.g. "sound/creature/bearv2/" -> type "bearv2" -> matches "bear" -> "Beast").
# Order matters: first match wins.
CREATURE_CATEGORY_KEYWORDS: dict[str, list[str]] = {
    "Beast": [
        # Canines / felines / large mammals
        "wolf", "bear", "boar", "cat", "tiger", "lion", "horse", "stag",
        "hyena", "coyote", "mastiff", "dog", "corgi", "saberworg",
        "sabertooth", "manasaber", "flamesaber", "nightsaber", "manakitty",
        "felinefamiliar", "warpchaser", "ox", "yak", "cow", "sheep", "ram",
        "pig", "deer", "moose", "kodo", "elekk", "mammoth", "rhino",
        "clefthoof", "talbuk", "camel", "alpaca", "gorilla", "monkey",
        "hippo", "giraffe", "ferret", "sloth", "otter", "riverotter",
        "walrus", "orca", "porcupine", "redpanda", "pangolin",
        # Birds
        "bird", "hawk", "eagle", "owl", "crane", "parrot", "raven",
        "seagull", "toucan", "peacock", "falcon", "stormcrow", "duck",
        "chicken", "turkey", "woodpecker", "spiritdarter", "dragonhawk",
        # Reptiles / amphibians
        "raptor", "serpent", "snake", "turtle", "crocolisk", "basilisk",
        "saurolisk", "devilsaur", "pterrordax", "pterodactyl", "pterrodax",
        "direhorn", "brutosaur", "falcosaur", "battlesaur", "thunderlizard",
        "diemetradon", "trex", "compy", "saurid", "crawg", "frog", "toad",
        # Insects / arachnids
        "spider", "scorpion", "beetle", "wasp", "bee", "giantbee", "fly",
        "firefly", "moth", "tarantula", "silithid", "silkworm", "larva",
        "ravager", "roach", "cricket",
        # Aquatic
        "crab", "worm", "eel", "monstrouseel", "shark", "ray", "stingray",
        "manaray", "nether_ray", "pufferfish", "grouper", "frenzy",
        "threshadon", "krakken", "leviathan", "lobstrok", "makrura",
        "deepstrider", "waterstrider", "dolphin", "goldfish",
        "eyeballjellyfish",
        # Winged / hybrid beasts
        "bat", "gryphon", "hippogryph", "wyvern", "chimera", "hydra",
        "phoenix", "sporebat", "aetherwyrm",
        # Misc beasts
        "snail", "rabbit", "squirrel", "rat", "beaver", "raccoon",
        "armadillo", "skunk", "tallstrider", "riverwallow", "mushan",
        "protoram", "fogcreature", "saberon", "goren", "slime", "ooze",
        "ringworm", "lavaworm", "crystalline", "wolpertinger", "moonkin",
        "swampbeast", "deepflayer", "quilen", "bonetusk", "trilobite",
        "lasher", "verming", "shoveltusk", "magnataur", "yeti",
        "progenitorwombat", "progenitorwasp", "progenitorjellyfish",
        "protodrake", "protodragon", "skeletalraptor", "siberiantiger",
        "skeletonhorse", "draenorwolf", "warp_stalker", "ranishu",
        "golden_grazer", "kakapo", "goat", "blindcaveskipper",
        "kareshstrider", "kareshroamer", "kaliri",
        # Midnight (12.0) creatures identified via CDI model paths
        "grovecrawler", "thornmaw", "devilsaptor", "saptor",
        "resinrhino", "potatoad", "capybara", "lynx", "potadpole",
        "blistercreep", "lightbloomsaptor", "hexeagle", "gianteagle",
        "mawexpansion", "tripod", "hedgehog",
        "panther", "seal", "brontosaur",
    ],
    "Dragonkin": [
        "dragon", "drake", "whelp", "drakonid", "dragonspawn", "dragonkin",
        "deathwing", "dracthyr", "djaradin", "greatwyrm",
    ],
    "Demon": [
        "demon", "imp", "felhound", "felguard", "doomguard", "infernal",
        "succubus", "voidwalker", "void", "eredar", "moarg", "observer",
        "felbat", "wrathguard", "shivarra", "pitlord", "pit_lord",
        "darkhound", "terrorguard", "jailer", "felstalker", "felbeast",
        "felhunter", "beholder", "dreadlord", "fellord", "felreaver",
        "helcannon", "hellhound",
        "satyr", "incubus", "felsaber", "felelf", "argusfiend", "antaen",
        "wyrmtongue", "felorc", "doomlord", "urzul", "shivan",
        "fel_broken",
        # Midnight (12.0) void creatures identified via CDI model paths
        "voidwraith", "voidjellyfish", "voidcaller", "voidbroken",
        "darknaaru", "naaru", "dimensius",
    ],
    "Undead": [
        "skeleton", "zombie", "ghost", "lich", "banshee", "wraith",
        "spectre", "abomination", "geist", "mummy", "undead", "forsaken",
        "death_knight", "maldraxxus", "fleshgiant", "fleshbeast",
        "boneguard", "cryptfiend", "nerubian", "ghoul", "val'kyr",
        "valkier", "skeletonmage",
        "gargoyle", "wight", "frostwyrm", "wickerman", "wickerbeast",
        "decomposer", "deathknight", "cryptlord",
        # Midnight (12.0) creatures identified via CDI model paths
        "headlesshorseman",
    ],
    "Elemental": [
        "elemental", "revenantearth", "revenantwater", "revenantfire",
        "revenantair", "unbndairelem", "lava", "magma", "bog_beast",
        "treant", "ancient", "wisp", "deepholm_golem", "deathelemental",
        "botani", "ent",
        "djinn", "stonetrog", "firespirit", "waterspirit", "earthspirit",
        "airspirit", "geode", "crystalfury", "seagiant", "mountaingiant",
        "mawgiant", "fungalgiant", "sporecreature", "crystalportal",
        "bogbeast", "stonewatcher",
        "shamedium", "shasmall", "shaoffear", "shaofanger",
        "sporeling", "groundflower", "blossom", "spriggan",
        # Midnight (12.0) creatures identified via CDI model paths
        "lightblooment", "kelpelemental",
    ],
    "Humanoid": [
        "vrykul", "mogu", "saurok", "hozen", "kobold", "gnoll", "murloc",
        "furbolg", "ettin", "ogre", "centaur", "harpy", "quilboar",
        "forsworn", "aspirant", "kyrian", "venthyr", "vampire", "broker",
        "dredger", "earthen", "arathi", "gilnean", "sethrak", "tuskarr",
        "titan", "gilgoblin", "pygmy", "trogg", "forest_troll", "ice_troll",
        "mantid", "klaxxi", "aqir", "naga", "ethereal", "arakkoa",
        "nightborne", "zandalari", "kultiran", "kul_tiran", "magnaron",
        "ogron", "gronn", "withered", "legionnaire", "tortollan",
        "shadowguard", "prince_renathal", "amanitroll",
        "goblin", "vulpera", "jinyu", "grummle", "tolvir", "wolvar",
        "hobgoblin", "drogbar", "yaungol", "pandaren", "nightfallen",
        "worgen", "oracle", "frostnymph", "highborne", "kvaldir",
        "paleorc", "troll", "gnome", "irondwarf", "drust", "faun",
        "ankoan", "kthir", "brownie", "podling", "genesaur", "steward",
        "fungarian", "dervishian", "hordepeon", "skrog",
        "mawguard", "mawshade", "mawnecromancer", "blood_troll",
        "dire_troll", "diretroll", "lightforged", "troglodyte",
        "grell", "keeperofthegrove", "dryad", "lostone",
        "faceless", "nzoth", "devourer",
        "facelessone", "heraldofnzoth", "devourersmall", "devourerflier",
        "kobyss", "berserker", "rutaani", "stalker", "maw_shade",
        # Midnight (12.0) creatures identified via CDI model paths
        "orderofnight", "skardyn", "amanibrute",
    ],
    "Mechanical": [
        "mech", "robot", "golem", "construct", "harvest", "shredder",
        "gyrocopter", "tank", "turret", "progenitorbot",
        "clockwork", "gnomebot", "gnomepounder", "meatwagon", "cookbot",
        "mobilealert", "ironjuggernaut", "goblinbomb",
        # Midnight (12.0) creatures identified via CDI model paths
        "sapper", "healraydrone", "mechadevilsaur", "crowdpummeler",
        "flyingmachineboss", "gorillabossmech", "automaton",
    ],
}

# Ordered display list for UI
CREATURE_CATEGORY_ORDER = [
    "Beast", "Dragonkin", "Humanoid", "Demon",
    "Undead", "Elemental", "Mechanical",
]


def classify_creature_type(creature_type: str) -> str | None:
    """Classify a creature type folder name into a category.

    Returns the category name, or None if unclassified.
    """
    name = creature_type.lower()
    for category, keywords in CREATURE_CATEGORY_KEYWORDS.items():
        for kw in keywords:
            if kw in name:
                return category
    return None


def download_listfile(build: str | None = None) -> Path:
    """Download the community listfile (FileDataID -> file path mapping)."""
    cache_subdir = CACHE_DIR / (build or "retail")
    cache_subdir.mkdir(parents=True, exist_ok=True)
    path = cache_subdir / "listfile.csv"
    if path.exists():
        return path
    print("  Downloading community listfile...", end=" ", flush=True)
    url = ("https://github.com/wowdev/wow-listfile/releases/"
           "latest/download/community-listfile.csv")
    req = urllib.request.Request(url, headers={"User-Agent": "Resonance/1.0"})
    with urllib.request.urlopen(req, timeout=120) as resp:
        data = resp.read()
    path.write_bytes(data)
    size_mb = len(data) / (1024 * 1024)
    print(f"OK ({size_mb:.1f} MB)")
    return path


def build_fid_to_creature_type(listfile_path: Path) -> dict[int, str]:
    """Parse the listfile to map FileDataID -> creature type folder name."""
    mapping = {}
    with open(listfile_path, "r", encoding="utf-8", errors="replace") as f:
        for line in f:
            parts = line.strip().split(";", 1)
            if len(parts) != 2:
                continue
            path = parts[1].lower()
            if not path.startswith("sound/creature/"):
                continue
            try:
                fid = int(parts[0])
                creature_type = path.split("/")[2]
                mapping[fid] = creature_type
            except (ValueError, IndexError):
                pass
    return mapping


# All sound columns in CreatureSoundData (comprehensive, for NPC muting)
ALL_CSD_SOUND_COLS = [
    "SoundExertionID", "SoundExertionCriticalID",
    "SoundInjuryID", "SoundInjuryCriticalID", "SoundInjuryCrushingBlowID",
    "SoundDeathID", "SoundStunID", "SoundStandID", "SoundFootstepID",
    "SoundAlertID", "SoundAggroID",
    "SoundFidget_0", "SoundFidget_1", "SoundFidget_2", "SoundFidget_3",
    "SoundFidget_4",
    "CustomAttack_0", "CustomAttack_1", "CustomAttack_2",
    "LoopSoundID",
    "SoundJumpStartID", "SoundJumpEndID",
    "SpellCastDirectedSoundID",
    "SubmergeSoundID", "SubmergedSoundID",
    "BattleShoutSoundID", "BattleShoutCriticalSoundID",
    "TauntSoundID",
    "WindupSoundID", "WindupCriticalSoundID",
    "ChargeSoundID",
]

# Vocalization columns to collect from CreatureSoundData
CREATURE_VOX_COLS = [
    "SoundExertionID", "SoundExertionCriticalID",
    "SoundInjuryID", "SoundInjuryCriticalID",
    "SoundDeathID", "SoundAggroID",
    "CustomAttack_0", "CustomAttack_1", "CustomAttack_2",
    "BattleShoutSoundID", "BattleShoutCriticalSoundID",
    "WindupSoundID", "WindupCriticalSoundID",
    "ChargeSoundID", "TauntSoundID",
    "SoundAlertID",
    "SoundFidget_0", "SoundFidget_1", "SoundFidget_2", "SoundFidget_3",
    "SoundJumpStartID", "SoundJumpEndID",
]


def _build_model_name_index(
    cdi_rows: list[dict], cmd_by_id: dict[int, dict],
    fid_to_path: dict[int, str],
) -> dict[int, str]:
    """Build CSD ID -> model creature name index from CDI -> CMD -> listfile.

    When a CSD's sound folder name is numeric/unclassifiable, we can often
    identify the creature by tracing CDI.SoundID -> CDI.ModelID ->
    CMD.FileDataID -> listfile path (e.g. creature/voidwraith/voidwraith.m2).
    """
    csd_to_models: dict[int, dict[str, int]] = {}
    for cdi in cdi_rows:
        csd_id = int(cdi.get("SoundID", 0))
        if not csd_id:
            continue
        model_id = int(cdi.get("ModelID", 0))
        cmd = cmd_by_id.get(model_id)
        if not cmd:
            continue
        model_fid = int(cmd.get("FileDataID", 0))
        path = fid_to_path.get(model_fid, "")
        # Extract creature name from model path like "creature/voidwraith/..."
        parts = path.lower().split("/")
        if len(parts) >= 3 and parts[0] == "creature":
            name = parts[1]
            votes = csd_to_models.setdefault(csd_id, {})
            votes[name] = votes.get(name, 0) + 1

    # Pick the most-voted model name for each CSD
    result: dict[int, str] = {}
    for csd_id, votes in csd_to_models.items():
        result[csd_id] = max(votes, key=votes.get)
    return result


def generate_creature_vox_data(ske_idx: dict, output_path: Path,
                               build: str | None = None,
                               exclude_fids: set[int] | None = None) -> None:
    """Generate CreatureVoxData.lua with category -> FileDataID mappings.

    exclude_fids: FIDs to omit (typically SpellMuteData FIDs so creature
        vox muting doesn't collaterally silence player spell sounds that
        reuse creature audio, e.g. druid bear-form abilities).
    """
    # Load creature sound tables
    csd_rows = load_csv(download_csv("CreatureSoundData", build=build))
    print(f"  {len(csd_rows)} CreatureSoundData entries")

    # Download listfile for creature type classification
    listfile_path = download_listfile(build)
    fid_to_type = build_fid_to_creature_type(listfile_path)
    print(f"  {len(fid_to_type)} FIDs mapped to creature types")

    # Build CDI model-name fallback index for CSDs with unclassifiable
    # sound folder names (numeric IDs in the community listfile)
    cdi_rows = load_csv(download_csv("CreatureDisplayInfo", build=build))
    cmd_rows = load_csv(download_csv("CreatureModelData", build=build))
    cmd_by_id: dict[int, dict] = {int(r["ID"]): r for r in cmd_rows}
    fid_to_path: dict[int, str] = {}
    with open(listfile_path, "r", encoding="utf-8", errors="replace") as f:
        for line in f:
            parts = line.strip().split(";", 1)
            if len(parts) == 2:
                try:
                    fid_to_path[int(parts[0])] = parts[1]
                except ValueError:
                    pass
    csd_model_names = _build_model_name_index(cdi_rows, cmd_by_id, fid_to_path)
    print(f"  {len(csd_model_names)} CSDs linked to model names via CDI")

    # For each CSD, determine creature type and collect vocalization FIDs
    category_fids: dict[str, set[int]] = {cat: set() for cat in CREATURE_CATEGORY_ORDER}
    unclassified_types: set[str] = set()
    classified_csds = 0
    model_fallback_csds = 0

    for row in csd_rows:
        csd_id = int(row["ID"])
        # Collect all vocalization FIDs for this CSD
        csd_fids: list[int] = []
        for col in CREATURE_VOX_COLS:
            sk = int(row.get(col, 0))
            if sk:
                for entry in ske_idx.get(sk, []):
                    csd_fids.append(int(entry["FileDataID"]))

        if not csd_fids:
            continue

        # Determine creature type from the sound file paths
        type_votes: dict[str, int] = {}
        for fid in csd_fids:
            ct = fid_to_type.get(fid)
            if ct:
                type_votes[ct] = type_votes.get(ct, 0) + 1

        if not type_votes:
            # No sound path at all — try model name fallback
            model_name = csd_model_names.get(csd_id)
            if model_name:
                category = classify_creature_type(model_name)
                if category:
                    category_fids[category].update(csd_fids)
                    classified_csds += 1
                    model_fallback_csds += 1
                else:
                    unclassified_types.add(f"(model:{model_name})")
            continue

        creature_type = max(type_votes, key=type_votes.get)
        # Skip player character vocalizations (handled by player vox mutes)
        if ("playerexertions" in creature_type or "character/" in creature_type
                or creature_type.startswith("pc")
                or creature_type.startswith("genericdh")
                or "druid" in creature_type and "haranir" in creature_type):
            continue

        category = classify_creature_type(creature_type)
        if not category:
            # Sound folder name unclassifiable — try two fallbacks:
            # 1) CDI model name (CSD -> CDI.SoundID -> CMD -> model path)
            model_name = csd_model_names.get(csd_id)
            if model_name:
                category = classify_creature_type(model_name)
            # 2) Numeric folder = model FileDataID (look up in listfile)
            if not category and creature_type.isdigit():
                model_path = fid_to_path.get(int(creature_type), "")
                parts = model_path.lower().split("/")
                if len(parts) >= 3 and parts[0] == "creature":
                    category = classify_creature_type(parts[1])
            if category:
                model_fallback_csds += 1

        if category:
            category_fids[category].update(csd_fids)
            classified_csds += 1
        else:
            unclassified_types.add(creature_type)

    print(f"  {classified_csds} CSDs classified into categories"
          f" ({model_fallback_csds} via model fallback)")
    print(f"  {len(unclassified_types)} unclassified creature types (skipped)")

    # Remove FIDs that are also used by player spells — MuteSoundFile is
    # global, so creature vox muting would collaterally silence druid
    # bear-form abilities, hunter pet attacks, etc.
    actually_excluded: set[int] = set()
    if exclude_fids:
        for cat in CREATURE_CATEGORY_ORDER:
            overlap = category_fids[cat] & exclude_fids
            actually_excluded |= overlap
            category_fids[cat] -= exclude_fids
        print(f"  Excluded {len(actually_excluded)} FIDs shared with SpellMuteData")

    # Write output
    total_fids = 0
    with open(output_path, "w", encoding="utf-8") as f:
        f.write("-- Auto-generated by tools/spell_sounds.py "
                "--generate-creature-vox-data\n")
        f.write("-- Creature vocalization FileDataIDs grouped by category\n\n")

        # FIDs removed from creature vox to avoid collateral spell muting —
        # addon unconditionally unmutes these on startup to clear stale state
        if actually_excluded:
            excl_str = ",".join(str(fid) for fid in sorted(actually_excluded))
            f.write(f'Resonance_CreatureVoxExcludedFIDs = "{excl_str}"\n\n')

        f.write("-- Ordered category list for UI display\n")
        f.write("Resonance_CreatureVoxCategories = {\n")
        for cat in CREATURE_CATEGORY_ORDER:
            fids = sorted(category_fids[cat])
            total_fids += len(fids)
            f.write(f'  "{cat}",\n')
        f.write("}\n\n")

        f.write("-- Category -> comma-separated FileDataIDs (string-packed)\n")
        f.write("Resonance_CreatureVoxData = {\n")
        for cat in CREATURE_CATEGORY_ORDER:
            fids = sorted(category_fids[cat])
            fid_str = ",".join(str(fid) for fid in fids)
            f.write(f'["{cat}"]="{fid_str}",\n')
        f.write("}\n")

    size_kb = output_path.stat().st_size / 1024
    print(f"  Written to {output_path} ({size_kb:.0f} KB, "
          f"{total_fids} FIDs across {len(CREATURE_CATEGORY_ORDER)} categories)")


def generate_npc_data(ske_idx: dict, output_path: Path,
                      build: str | None = None) -> None:
    """Generate NPCSoundData.lua with per-NPC sound FileDataID mappings.

    Walks Creature → CreatureDisplayInfo → CreatureSoundData → SoundKitEntry
    to build a searchable NPC-name index and NPC-ID → packed-FID lookup.

    Uses CSD-indexed storage: many NPCs share the same CreatureSoundData
    entry, so FIDs are stored per-CSD and NPCs point to their CSD ID.
    """
    # Load tables — download Creature for each locale to get localized names
    NPC_LOCALES = ["enUS", "ptBR", "deDE", "frFR", "esES", "itIT",
                   "ruRU", "koKR", "zhCN", "zhTW"]
    creature_rows = load_csv(download_csv("Creature", force=False, build=build))
    print(f"  {len(creature_rows)} Creature entries")

    # Build npcID → localized names from each locale
    npc_locale_names: dict[int, dict[str, str]] = {}  # npcID → {locale → name}
    for locale in NPC_LOCALES:
        if locale == "enUS":
            # Already have English from the main download
            for row in creature_rows:
                try:
                    npc_id = int(row["ID"])
                    name = row.get("Name_lang", "").strip()
                    if name:
                        npc_locale_names.setdefault(npc_id, {})["enUS"] = name
                except (ValueError, KeyError):
                    pass
            continue
        # Download locale-specific Creature CSV
        cache_subdir = CACHE_DIR / (build or "retail")
        locale_path = cache_subdir / f"Creature_{locale}.csv"
        if not locale_path.exists():
            url = f"{WAGO_BASE}/Creature/csv?locale={locale}"
            if build:
                url += f"&build={build}"
            print(f"  Downloading Creature ({locale})...", end=" ", flush=True)
            try:
                req = urllib.request.Request(url, headers={
                    "User-Agent": "Resonance-SpellLookup/1.0"})
                with urllib.request.urlopen(req, timeout=120) as resp:
                    data = resp.read()
                locale_path.write_bytes(data)
                size_mb = len(data) / (1024 * 1024)
                print(f"OK ({size_mb:.1f} MB)")
            except Exception as e:
                print(f"FAILED: {e} (skipping {locale})")
                continue
        for row in load_csv(locale_path):
            try:
                npc_id = int(row["ID"])
                name = row.get("Name_lang", "").strip()
                if name:
                    npc_locale_names.setdefault(npc_id, {})[locale] = name
            except (ValueError, KeyError):
                pass
    locale_count = sum(1 for names in npc_locale_names.values()
                       if len(names) > 1)
    print(f"  {locale_count} NPCs have multi-locale names")

    cdi_rows = load_csv(download_csv("CreatureDisplayInfo", force=False, build=build))
    print(f"  {len(cdi_rows)} CreatureDisplayInfo entries")

    cmd_rows = load_csv(download_csv("CreatureModelData", force=False, build=build))
    csd_rows = load_csv(download_csv("CreatureSoundData", force=False, build=build))
    print(f"  {len(csd_rows)} CreatureSoundData entries")

    # Build indices
    cdi_by_id: dict[int, dict] = {}
    for row in cdi_rows:
        try:
            cdi_by_id[int(row["ID"])] = row
        except (ValueError, KeyError):
            pass

    cmd_sound: dict[int, int] = {}
    for row in cmd_rows:
        try:
            sid = int(row.get("SoundID", 0))
            if sid:
                cmd_sound[int(row["ID"])] = sid
        except (ValueError, KeyError):
            pass

    csd_by_id: dict[int, dict] = {}
    for row in csd_rows:
        try:
            csd_by_id[int(row["ID"])] = row
        except (ValueError, KeyError):
            pass

    # Pre-compute CSD → FIDs for all CSDs with sound data
    csd_fids: dict[int, list[int]] = {}
    for csd_id, row in csd_by_id.items():
        fids: list[int] = []
        seen: set[int] = set()
        for col in ALL_CSD_SOUND_COLS:
            sk = int(row.get(col, 0))
            if sk:
                for entry in ske_idx.get(sk, []):
                    fid = int(entry["FileDataID"])
                    if fid and fid not in seen:
                        fids.append(fid)
                        seen.add(fid)
        if fids:
            csd_fids[csd_id] = sorted(fids)

    print(f"  {len(csd_fids)} CSDs with sound data")

    # Resolve Creature → CSD via DisplayID → CDI → CSD chain
    npc_csd: dict[int, int] = {}  # npcID → csdID
    npc_names: dict[int, str] = {}  # npcID → English name

    for row in creature_rows:
        try:
            npc_id = int(row["ID"])
        except (ValueError, KeyError):
            continue

        name = row.get("Name_lang", "").strip()
        if not name:
            continue

        # Try each display variant (DisplayID_0 through DisplayID_3)
        resolved_csd = None
        for i in range(4):
            display_id_str = row.get(f"DisplayID_{i}", "0")
            try:
                display_id = int(display_id_str)
            except ValueError:
                continue
            if not display_id:
                continue

            cdi = cdi_by_id.get(display_id)
            if not cdi:
                continue

            # CDI.SoundID → CSD
            sound_id = int(cdi.get("SoundID", 0))
            if not sound_id:
                # Fallback: CDI.ModelID → CMD.SoundID
                model_id = int(cdi.get("ModelID", 0))
                if model_id:
                    sound_id = cmd_sound.get(model_id, 0)

            if sound_id and sound_id in csd_fids:
                resolved_csd = sound_id
                break

        if resolved_csd:
            npc_csd[npc_id] = resolved_csd
            npc_names[npc_id] = name

    print(f"  {len(npc_csd)} NPCs resolved to CSDs with sounds")

    # Build VO (voice-over) FID index from the community listfile.
    # Creature dialogue files live at sound/creature/{folder}/*.ogg and are
    # NOT in CreatureSoundData.  We match folders to NPC names to merge
    # dialogue FIDs with the CSD combat sounds.
    listfile_path = download_listfile(build)
    vo_folder_fids: dict[str, list[int]] = {}  # folder_name -> [fids]
    with open(listfile_path, "r", encoding="utf-8", errors="replace") as lf:
        for line in lf:
            parts = line.strip().split(";", 1)
            if len(parts) != 2:
                continue
            try:
                fid = int(parts[0])
            except ValueError:
                continue
            path = parts[1].lower()
            if not path.startswith("sound/creature/") or not path.endswith(".ogg"):
                continue
            segments = path.split("/")
            if len(segments) < 4:
                continue
            folder = segments[2]  # e.g. "valeera_sanguinar", "brann"
            # Skip player character VO and generic test files
            if folder.startswith("vo_pc") or folder == "vo_soundtest_01.ogg":
                continue
            vo_folder_fids.setdefault(folder, []).append(fid)

    print(f"  {len(vo_folder_fids)} creature VO folders in listfile "
          f"({sum(len(v) for v in vo_folder_fids.values())} files)")

    # Match VO folders to NPC names.  Strategy:
    #   1. Build normalized name -> npc_ids index
    #   2. For each VO folder, try exact match, then first-word match
    npc_name_index: dict[str, list[int]] = {}  # normalized_name -> [npc_ids]
    for npc_id, name in npc_names.items():
        key = name.lower().replace(" ", "_").replace("'", "").replace("-", "_")
        npc_name_index.setdefault(key, []).append(npc_id)

    # Also index first word for short-name folders like "brann" -> "Brann Bronzebeard"
    first_word_index: dict[str, list[int]] = {}
    for npc_id, name in npc_names.items():
        first = name.split()[0].lower().replace("'", "")
        first_word_index.setdefault(first, []).append(npc_id)

    # Merge VO FIDs into npc_vo dict: npc_id -> set(fids)
    npc_vo: dict[int, set[int]] = {}
    vo_matched = 0
    # Also track VO-only NPCs (have VO files but no CSD data)
    vo_only_names: dict[str, list[int]] = {}  # folder_name -> [fids]
    for folder, fids in vo_folder_fids.items():
        matched_ids = npc_name_index.get(folder)
        if not matched_ids:
            # Try first-word match only if unambiguous
            candidates = first_word_index.get(folder)
            if candidates and len(set(npc_names[nid] for nid in candidates)) == 1:
                matched_ids = candidates
        if matched_ids:
            vo_matched += 1
            for npc_id in matched_ids:
                npc_vo.setdefault(npc_id, set()).update(fids)
        else:
            # VO folder with no CSD match — store for VO-only entries
            if len(fids) >= 5:  # skip tiny folders (sound effects, not dialogue)
                vo_only_names[folder] = fids

    print(f"  {vo_matched} VO folders matched to NPCs, "
          f"{len(vo_only_names)} unmatched VO-only folders (>=5 files)")

    # Filter junk NPCs: quest credit triggers, invisible bunnies, placeholders, etc.
    JUNK_PATTERNS = re.compile(
        r"credit|killcredit|tracking|trigger|invis|placeholder|bunny|stalker"
        r"|generic .* target|test ?npc|^\d{2,}\s|^\(.*(bunny|trigger|invis)",
        re.IGNORECASE)
    pre_filter = len(npc_csd)
    junk_ids = {nid for nid, name in npc_names.items() if JUNK_PATTERNS.search(name)}
    for nid in junk_ids:
        npc_csd.pop(nid, None)
    print(f"  Filtered {len(junk_ids)} junk NPCs "
          f"({pre_filter} → {len(npc_csd)})")

    # Deduplicate by NAME only: merge all CSDs and VO FIDs for the same
    # display name into one entry.  Users want "Anduin Wrynn" once, not
    # separate entries per story phase / CSD variant.
    name_groups: dict[str, list[int]] = {}
    for npc_id in npc_csd:
        name_groups.setdefault(npc_names[npc_id], []).append(npc_id)

    dedup_entries: list[dict] = []
    all_npc_ids: dict[int, int] = {}  # every npc_id → its CSD
    rep_vo_fids: dict[int, set[int]] = {}  # rep_npc_id → merged VO FIDs
    rep_csds: dict[int, set[int]] = {}  # rep_npc_id → all CSD IDs

    for name, npc_ids in name_groups.items():
        rep_id = min(npc_ids)
        csds: set[int] = set()
        merged_vo: set[int] = set()
        for nid in npc_ids:
            csd = npc_csd[nid]
            csds.add(csd)
            all_npc_ids[nid] = csd
            if nid in npc_vo:
                merged_vo |= npc_vo[nid]
        dedup_entries.append({"name": name, "rep_id": rep_id,
                              "all_ids": sorted(npc_ids)})
        rep_csds[rep_id] = csds
        if merged_vo:
            rep_vo_fids[rep_id] = merged_vo

    dedup_entries.sort(key=lambda e: e["name"].lower())

    # Add VO-only entries (creatures with VO files but no CSD match)
    vo_only_entries: list[dict] = []
    vo_only_id_counter = -1
    for folder, fids in sorted(vo_only_names.items()):
        pretty = folder.replace("_", " ").title()
        vo_only_entries.append({"name": pretty, "folder": folder,
                                "id": vo_only_id_counter, "fids": fids})
        vo_only_id_counter -= 1

    # Count unique CSDs actually referenced by NPCs
    used_csds = set(all_npc_ids.values())
    vo_npc_count = len(rep_vo_fids)
    vo_fid_count = sum(len(fids) for fids in rep_vo_fids.values())
    print(f"  {len(used_csds)} unique CSDs used")
    print(f"  {len(dedup_entries)} unique NPC names "
          f"(deduped from {len(npc_csd)} NPC IDs)")
    print(f"  {vo_npc_count} NPCs have VO dialogue data ({vo_fid_count} FIDs)")
    print(f"  {len(vo_only_entries)} VO-only creatures (no CSD match)")

    # Write output
    total_csd_fids = sum(len(csd_fids[csd]) for csd in used_csds)
    with open(output_path, "w", encoding="utf-8") as f:
        f.write("-- Auto-generated by tools/spell_sounds.py "
                "--generate-npc-data\n")
        f.write(f"-- {len(dedup_entries)} unique NPCs (from {len(npc_csd)} "
                f"creature entries), {len(used_csds)} CSD profiles, "
                f"{total_csd_fids} CSD FIDs\n"
                f"-- + {vo_npc_count} NPCs with voice-over dialogue "
                f"({vo_fid_count} VO FIDs from listfile)\n\n")

        # Searchable index: "EnglishName#npcID" (English only, compact)
        # Locale names split into separate Resonance_NPCSoundL10N table
        f.write("-- Searchable NPC list: \"EnglishName#npcID\" format\n")
        f.write("Resonance_NPCSoundIndex = {\n")
        l10n_entries: dict[int, str] = {}  # rep_id -> "alt1|alt2|..."
        for entry in dedup_entries:
            rep_id = entry["rep_id"]
            en_name = entry["name"]
            safe_en = en_name.replace("\\", "\\\\").replace('"', '\\"')
            f.write(f'"{safe_en}#{rep_id}",\n')
            # Collect unique non-English names for L10N table
            alt_names = []
            seen = {en_name.lower()}
            for nid in entry["all_ids"]:
                locale_data = npc_locale_names.get(nid, {})
                for loc in NPC_LOCALES:
                    lname = locale_data.get(loc, "")
                    if lname and lname.lower() not in seen:
                        alt_names.append(lname)
                        seen.add(lname.lower())
            if alt_names:
                l10n_entries[rep_id] = "|".join(alt_names)
        f.write("}\n\n")

        # Locale names table: npcID -> "locName1|locName2|..."
        f.write(f"-- {len(l10n_entries)} NPCs with non-English locale names\n")
        f.write("Resonance_NPCSoundL10N = {\n")
        for rep_id in sorted(l10n_entries.keys()):
            safe = l10n_entries[rep_id].replace("\\", "\\\\").replace('"', '\\"')
            f.write(f'[{rep_id}]="{safe}",\n')
        f.write("}\n\n")

        # NPC ID → CSD ID mapping (ALL NPC IDs, not just representatives,
        # so muting works regardless of which ID the user encounters)
        f.write("-- NPC ID -> CreatureSoundData ID (all creature variants)\n")
        f.write("Resonance_NPCToCSD = {\n")
        for npc_id in sorted(all_npc_ids.keys()):
            f.write(f"[{npc_id}]={all_npc_ids[npc_id]},\n")
        f.write("}\n\n")

        # Representative NPC ID → all CSD IDs (for name-deduped NPCs
        # that have multiple sound profiles across story phases)
        f.write("-- Representative NPC ID -> all CSD IDs for this name\n")
        f.write("Resonance_NPCRepCSDs = {\n")
        for entry in dedup_entries:
            csds = sorted(rep_csds.get(entry["rep_id"], set()))
            if len(csds) > 1:
                csd_str = ",".join(str(c) for c in csds)
                f.write(f'[{entry["rep_id"]}]="{csd_str}",\n')
        f.write("}\n\n")

        # CSD ID → packed FIDs (only include CSDs referenced by NPCs)
        f.write("-- CreatureSoundData ID -> comma-separated FileDataIDs\n")
        f.write("Resonance_NPCSoundCSD = {\n")
        for csd_id in sorted(used_csds):
            fid_str = ",".join(str(fid) for fid in csd_fids[csd_id])
            f.write(f'[{csd_id}]="{fid_str}",\n')
        f.write("}\n\n")

        # VO FIDs per representative NPC ID (dialogue from listfile,
        # separate from CSD combat sounds)
        f.write("-- NPC representative ID -> comma-separated voice-over FileDataIDs\n")
        f.write("Resonance_NPCVoiceData = {\n")
        for npc_id in sorted(rep_vo_fids.keys()):
            fids = sorted(rep_vo_fids[npc_id])
            fid_str = ",".join(str(fid) for fid in fids)
            f.write(f'[{npc_id}]="{fid_str}",\n')
        f.write("}\n")

    size_kb = output_path.stat().st_size / 1024
    print(f"  Written to {output_path} ({size_kb:.0f} KB)")


def generate_profession_data(indices: dict, output_path: Path,
                             build: str | None = None) -> None:
    """Generate ProfessionSoundData.lua with per-profession sound FIDs.

    Walks SkillLine → SkillLineAbility → SpellXSpellVisual → DB2 chain
    to find all unique sound FileDataIDs for each profession.
    """
    # Download profession tables
    sl_path = download_csv("SkillLine", force=False, build=build)
    sla_path = download_csv("SkillLineAbility", force=False, build=build)
    sl_rows = load_csv(sl_path)
    sla_rows = load_csv(sla_path)

    # Map SkillLine IDs to base profession names
    # Category 11 = primary professions, 9 = secondary, 12 = secondary sub
    prof_skill_ids: dict[int, str] = {}
    base_names = set(PROFESSION_BASE.values())
    for row in sl_rows:
        cat = row.get("CategoryID", "")
        sl_id = int(row["ID"])
        name = row.get("DisplayName_lang", "")
        if cat in ("11", "9", "12"):
            # Match base profession ID directly
            if sl_id in PROFESSION_BASE:
                prof_skill_ids[sl_id] = PROFESSION_BASE[sl_id]
            else:
                # Expansion-specific: "Legion Blacksmithing" -> "Blacksmithing"
                for base_name in base_names:
                    if name.endswith(base_name):
                        prof_skill_ids[sl_id] = base_name
                        break

    print(f"  {len(prof_skill_ids)} profession SkillLine IDs mapped")

    # Map spell IDs to professions via SkillLineAbility
    spell_to_prof: dict[int, str] = {}
    for row in sla_rows:
        sl_id = int(row.get("SkillLine", 0))
        if sl_id in prof_skill_ids:
            spell_id = int(row.get("Spell", 0))
            if spell_id:
                spell_to_prof[spell_id] = prof_skill_ids[sl_id]

    print(f"  {len(spell_to_prof)} profession spells found")

    # Walk the DB2 chain for each profession spell to find sound FIDs
    xsv_idx = indices["SpellXSpellVisual_by_SpellID"]
    prof_fids: dict[str, set[int]] = {name: set() for name in PROFESSION_ORDER}
    spells_with_sounds = 0

    for spell_id, prof_name in spell_to_prof.items():
        if spell_id not in xsv_idx:
            continue
        results = find_sounds_for_spell(spell_id, indices)
        fids = results["all_file_data_ids"]
        if fids and prof_name in prof_fids:
            prof_fids[prof_name] |= fids
            spells_with_sounds += 1

    print(f"  {spells_with_sounds} profession spells have sound data")

    # Write output (same format as CreatureVoxData)
    total_fids = 0
    with open(output_path, "w", encoding="utf-8") as f:
        f.write("-- Auto-generated by tools/spell_sounds.py "
                "--generate-profession-data\n")
        f.write("-- Profession sound FileDataIDs grouped by profession\n\n")

        f.write("-- Ordered profession list for UI display\n")
        f.write("Resonance_ProfessionCategories = {\n")
        for prof in PROFESSION_ORDER:
            f.write(f'  "{prof}",\n')
        f.write("}\n\n")

        f.write("-- Profession -> comma-separated FileDataIDs (string-packed)\n")
        f.write("Resonance_ProfessionSoundData = {\n")
        for prof in PROFESSION_ORDER:
            fids = sorted(prof_fids.get(prof, set()))
            total_fids += len(fids)
            fid_str = ",".join(str(fid) for fid in fids)
            f.write(f'["{prof}"]="{fid_str}",\n')
        f.write("}\n")

    size_kb = output_path.stat().st_size / 1024
    print(f"  Written to {output_path} ({size_kb:.0f} KB, "
          f"{total_fids} FIDs across {len(PROFESSION_ORDER)} professions)")
    for prof in PROFESSION_ORDER:
        n = len(prof_fids.get(prof, set()))
        if n:
            print(f"    {prof}: {n} FIDs")


def resolve_build(raw: str | None) -> str | None:
    """Resolve a build alias or version string to a wago.tools build version.

    Returns None for retail (no ?build= needed), or a version string like
    "5.5.3.66128" for specific builds.
    """
    if raw is None:
        return None
    alias = raw.lower()
    if alias in BUILD_ALIASES:
        _, version = BUILD_ALIASES[alias]
        return version
    # Assume it's a raw version string (e.g. "5.5.3.66128")
    return raw


def load_tables_and_build_indices(args) -> tuple[dict, list]:
    """Download/load CSVs and build indices. Returns (indices, csv_paths)."""
    build = resolve_build(getattr(args, "build", None))
    build_label = build or "retail"
    print(f"Loading DB2 tables ({build_label})...")
    csv_paths = {}
    for table in TABLES:
        csv_paths[table] = download_csv(table, force=args.refresh, build=build)

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


def list_builds():
    """Fetch and display available builds from wago.tools."""
    print("Fetching available builds from wago.tools...")
    url = "https://wago.tools/api/builds"
    req = urllib.request.Request(url, headers={"User-Agent": "Resonance-SpellLookup/1.0"})
    import json
    with urllib.request.urlopen(req, timeout=30) as resp:
        data = json.loads(resp.read())

    print("\nKnown aliases:")
    for alias, (product, version) in sorted(BUILD_ALIASES.items()):
        print(f"  {alias:10s} → {product} ({version or 'latest'})")

    print("\nAll products (latest 3 builds each):")
    for product in sorted(data.keys()):
        versions = [b.get("version", "?") for b in data[product][:3]]
        print(f"  {product}: {', '.join(versions)}")


def main():
    parser = argparse.ArgumentParser(
        description="Look up sound FileDataIDs for WoW spells",
        epilog="Build aliases: " + ", ".join(
            f"{k} ({v[0]})" for k, v in sorted(BUILD_ALIASES.items())
        ),
    )
    parser.add_argument("spell_ids", nargs="*", type=int, help="SpellID(s) to look up")
    parser.add_argument("--name", "-n", type=str, help="Look up by spell name instead of ID")
    parser.add_argument("--build", "-b", type=str, default=None,
                        help="Game build to target: alias (retail, mop, cata, classic) "
                             "or version string (e.g. 5.5.3.66128). Default: retail")
    parser.add_argument("--lua", action="store_true", help="Output as Lua mute snippet")
    parser.add_argument("--generate-mute-data", action="store_true",
                        help="Generate SpellMuteData.lua with all SpellID→FileDataID mappings")
    parser.add_argument("--max-fid-sharing", type=int, default=100,
                        help="Exclude FIDs shared by more than N spells (default: 100). "
                             "Generic cast/precast sounds shared across thousands of spells "
                             "cause collateral muting (e.g. hearthstone silence)")
    parser.add_argument("--generate-creature-vox-data", action="store_true",
                        help="Generate CreatureVoxData.lua with creature vocalization FIDs")
    parser.add_argument("--generate-profession-data", action="store_true",
                        help="Generate ProfessionSoundData.lua with per-profession sound FIDs")
    parser.add_argument("--generate-npc-data", action="store_true",
                        help="Generate NPCSoundData.lua with NPC name→sound FileDataID mappings")
    parser.add_argument("--generate-classic-reference", action="store_true",
                        help="Generate ClassicSpellSounds.lua from Classic Era DB2 data")
    parser.add_argument("--list-builds", action="store_true",
                        help="List available builds from wago.tools")
    parser.add_argument("--clear-cache", action="store_true", help="Delete cached CSV files")
    parser.add_argument("--refresh", action="store_true", help="Re-download CSVs")
    args = parser.parse_args()

    if args.list_builds:
        list_builds()
        return

    if args.clear_cache:
        if CACHE_DIR.exists():
            import shutil
            shutil.rmtree(CACHE_DIR)
            print("Cache cleared.")
        else:
            print("No cache to clear.")
        return

    if args.generate_mute_data:
        build = resolve_build(args.build)
        indices, csv_paths = load_tables_and_build_indices(args)
        output_path = Path(__file__).parent.parent / "data" / "SpellMuteData.lua"
        generate_mute_data(indices, indices["SpellXSpellVisual_by_SpellID"],
                           output_path, csv_paths, build=build,
                           max_fid_sharing=args.max_fid_sharing)
        return

    if args.generate_creature_vox_data:
        build = resolve_build(args.build)
        # Only need SoundKitEntry for this generation
        ske_path = download_csv("SoundKitEntry", force=args.refresh, build=build)
        ske_rows = load_csv(ske_path)
        ske_idx = build_index(ske_rows, "SoundKitID")
        output_path = Path(__file__).parent.parent / "data" / "CreatureVoxData.lua"
        # Only exclude creature vox FIDs that overlap with player spells in
        # ClassTemplates.  The old approach excluded ALL SpellMuteData FIDs,
        # which removed creature sounds shared with NPC-only abilities (e.g.
        # a berserker's own "Noxious Breath" reusing its vox audio).
        templates_path = Path(__file__).parent.parent / "data" / "ClassTemplates.lua"
        mute_data_path = Path(__file__).parent.parent / "data" / "SpellMuteData.lua"
        player_spell_ids: set[str] = set()
        if templates_path.exists():
            with open(templates_path, "r", encoding="utf-8") as tf:
                for m in re.finditer(r"spellID\s*=\s*(\d+)", tf.read()):
                    player_spell_ids.add(m.group(1))
            print(f"  Loaded {len(player_spell_ids)} player spell IDs from ClassTemplates")
        spell_fids: set[int] = set()
        if mute_data_path.exists() and player_spell_ids:
            with open(mute_data_path, "r", encoding="utf-8") as mf:
                for line in mf:
                    m = re.match(r'\s*\[(\d+)\]\s*=\s*"([\d,]+)"', line)
                    if m and m.group(1) in player_spell_ids:
                        for fid_s in m.group(2).split(","):
                            spell_fids.add(int(fid_s))
            print(f"  Loaded {len(spell_fids)} spell FIDs to exclude from creature vox")
        # Also exclude profession sound FIDs — these are often shared with
        # creature vox data (e.g. mining pick sounds classified as humanoid
        # combat audio) and muting creature vox should never silence professions.
        prof_data_path = Path(__file__).parent.parent / "data" / "ProfessionSoundData.lua"
        if prof_data_path.exists():
            with open(prof_data_path, "r", encoding="utf-8") as pf:
                for m in re.finditer(r'"([\d,]+)"', pf.read()):
                    for fid_s in m.group(1).split(","):
                        spell_fids.add(int(fid_s))
            print(f"  Total FIDs to exclude (spells + professions): {len(spell_fids)}")
        generate_creature_vox_data(ske_idx, output_path, build=build,
                                   exclude_fids=spell_fids or None)
        return

    if args.generate_profession_data:
        build = resolve_build(args.build)
        indices, csv_paths = load_tables_and_build_indices(args)
        output_path = Path(__file__).parent.parent / "data" / "ProfessionSoundData.lua"
        generate_profession_data(indices, output_path, build=build)
        return

    if args.generate_npc_data:
        build = resolve_build(args.build)
        ske_path = download_csv("SoundKitEntry", force=args.refresh, build=build)
        ske_rows = load_csv(ske_path)
        ske_idx = build_index(ske_rows, "SoundKitID")
        output_path = Path(__file__).parent.parent / "data" / "NPCSoundData.lua"
        generate_npc_data(ske_idx, output_path, build=build)
        return

    if args.generate_classic_reference:
        output_path = Path(__file__).parent.parent / "data" / "ClassicSpellSounds.lua"
        generate_classic_reference(args, output_path)
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
