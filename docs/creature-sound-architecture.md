# Creature Sound Architecture in WoW

Research notes on how World of Warcraft organizes creature/monster sounds internally, and how Resonance can leverage this for a "mute monster vocalizations" feature.

## DB2 resolution chain

Monster vocalizations follow the same chain the addon already walks for player vocalizations:

```
Creature
  -> CreatureDisplayInfo.SoundID -> CreatureSoundData
  -> (fallback) CreatureDisplayInfo.ModelID -> CreatureModelData.SoundID -> CreatureSoundData
```

Each `CreatureSoundData` (CSD) entry contains SoundKit IDs for ~16 vocalization types:

| Column | Description | Coverage |
|---|---|---|
| SoundExertionID | Attack grunts | 60.7% of CSDs |
| SoundExertionCriticalID | Critical attack grunts | 39.2% |
| SoundInjuryID | Taking damage | 77.8% |
| SoundInjuryCriticalID | Taking critical damage | 62.2% |
| SoundDeathID | Death sounds | 54.5% |
| SoundAggroID | Aggro/pull sounds | 57.7% |
| BattleShoutSoundID | Battle shouts | 22.9% |
| CustomAttack_0/1/2 | Special attack sounds | ~1% |
| WindupSoundID | Windup sounds | 2.7% |
| ChargeSoundID | Charge sounds | 2.6% |
| TauntSoundID | Taunt sounds | 0.7% |

Each SoundKit resolves to 2-6 FileDataIDs (random variants the engine picks from).

## Key numbers

| Metric | Count |
|---|---|
| Total CreatureSoundData entries | 7,397 |
| Total CreatureDisplayInfo entries | 118,493 |
| Unique CSD IDs referenced by CDIs | 6,521 |
| Total unique vocalization FIDs across all CSDs | ~73,000 |
| FIDs per CSD | avg 27, median 27, max 128 |

## Massive sound reuse

The single most important finding: **Blizzard reuses creature sounds extensively.**

The top 20 most-referenced CSD entries are all **player race vocalizations** (Human Male, Human Female, Orc Male, etc.) applied to thousands of humanoid NPCs. CSD 49 (Human Male) alone is used by 5,882 creature display entries.

### Reuse distribution

How many CreatureDisplayInfo entries share the same CSD:

| Sharing | CSD entries |
|---|---|
| 1 (unique) | 2,564 |
| 2-5 | 1,996 |
| 6-20 | 1,217 |
| 21-100 | 617 |
| 101-500 | 101 |
| 500+ | 26 |

## Cross-expansion reuse

This was the key question: when a new expansion comes out, do creatures get new sounds or reuse old ones?

Data based on estimating CSD/CDI eras by FileDataID ranges:

| Creatures from | Same-expansion sounds | Reused from older |
|---|---|---|
| Classic/TBC | 64.8% | 35.2% |
| WotLK/Cata | 11.9% | 88.1% (mostly Classic sounds) |
| MoP/WoD | 19.2% | 80.8% |
| Legion | 32.3% | 67.7% |
| BfA/Shadowlands | 31.5% | 68.5% |
| Dragonflight | 76.6% | 23.4% (unusually original) |
| The War Within | 46.6% | 53.4% |

**Typical expansions reuse 50-70% of creature sounds from older content.** Dragonflight was an anomaly with 76.6% new sounds because it introduced many new creature families (centaur v2, drakonids v2, etc.).

This means **muting by expansion is a poor organizational model** -- a player who hates spider screeches would need to mute every expansion separately, and the sounds are often identical across expansions anyway.

## Two populations of creature sounds

The ~5,700 unique creature sound folders in the game files split into two distinct groups:

| Category | Types | FIDs | Description |
|---|---|---|---|
| Named NPCs (1-2 CSDs) | 1,755 | ~51,700 | Boss-specific sounds (Zovaal, Alleria, etc.) -- each used by only 1-2 creatures |
| Archetypes (3+ CSDs) | 581 | ~18,700 | Reusable creature families (bear, spider, drakonid, etc.) -- shared across many creatures |

Named NPCs account for 75% of FIDs but have low impact (you encounter each boss infrequently). Archetypes are the high-value targets.

## Natural categories

Creature archetypes group naturally into super-categories:

| Category | CSDs | FIDs | Examples |
|---|---|---|---|
| Beast | ~1,300 | ~7,800 | bear, wolf, spider, raptor, crab, bat, boar |
| Humanoid | ~930 | ~11,500 | vrykul, mogu, gnoll, saurok, kobold, murloc, ogre |
| Dragon | ~160 | ~1,100 | drake, drakonid, dragonspawn, whelp |
| Demon | ~180 | ~1,600 | imp, felhound, doomguard, eredar, felbat |
| Undead | ~160 | ~1,100 | skeleton, ghost, lich, geist, banshee |
| Elemental | ~240 | ~900 | fire/water/earth elemental, lasher, treant |
| Mechanical | ~140 | ~900 | golem, construct, shredder, robot |
| Other/Boss-specific | ~2,800 | ~45,000 | named NPCs + unclassified archetypes |

## Top creature archetypes by FID count

The creature types that would need the most MuteSoundFile calls:

| Archetype | CSDs | FIDs |
|---|---|---|
| drakonid2 | 17 | 293 |
| kyrianmaw | 7 | 285 |
| centaur2_female | 16 | 190 |
| broker | 9 | 137 |
| mawjailerarmored | 1 | 128 |
| centaur2_brute | 4 | 127 |
| maldraxxusmutant | 3 | 124 |
| aspirantmale | 4 | 124 |
| kyrianmale | 3 | 120 |
| dredgerbrute | 4 | 116 |

Most archetypes have 30-80 FIDs. A single archetype mute is nearly instantaneous.

## Performance implications

| Scope | MuteSoundFile calls | Login impact |
|---|---|---|
| Single archetype (e.g. "spiders") | ~30-60 | Instant |
| One category (e.g. "Beasts") | ~7,800 | ~0.5s |
| All archetypes | ~18,700 | ~1-2s |
| All including named NPCs | ~70,000 | Needs frame-staggering (~3-5s) |

Runtime (in-combat) cost is **zero** regardless of scope -- `MuteSoundFile` is fire-and-forget, the engine skips muted FIDs with no per-frame overhead.

## Recommended architecture

### Data generation (spell_sounds.py)

New flag: `--generate-creature-mute-data`

1. Walk all `CreatureSoundData` entries (not just player races)
2. For each CSD, resolve all vocalization SoundKits to FileDataIDs
3. Classify each CSD into an archetype name using the listfile path (`sound/creature/<archetype>/...`)
4. Group archetypes into super-categories
5. Emit a Lua data file (~300-500 KB estimated)

### Data format

```lua
-- Archetype -> {FID, FID, ...}
Resonance_CreatureVoxData = {
    ["bear"] = {567001, 567002, 567003, ...},
    ["spider"] = {568100, 568101, ...},
    ...
}

-- Archetype -> category for UI grouping
Resonance_CreatureVoxCategories = {
    ["bear"] = "Beast",
    ["spider"] = "Beast",
    ["drakonid"] = "Dragon",
    ...
}
```

### Addon side (Core.lua)

A new mute layer (`creatureMutedFIDs`) parallel to the existing `voxMutedFIDs` and `weaponMutedFIDs`. The pattern is already established:

- `applyCreatureVoxMutes()` / `clearCreatureVoxMutes()`
- Saved variable: `muteCreatureVox` = `"off"` | `"all"` | category name | list of archetype names
- Overlap-safe with existing mute layers (same refcount/guard pattern)

### UI (Options.lua)

```
Creature Sounds
  [dropdown] Scope: Off / All / By Category / By Creature Type
  [category checkboxes if "By Category"]
  [searchable archetype list if "By Creature Type"]
```

### Frame-staggering for large mute sets

For "all" mode (~18K+ FIDs), stagger MuteSoundFile calls across frames:

```lua
local MUTE_BATCH_SIZE = 5000
local function applyMutesBatched(fidList, callback)
    local i = 1
    local function batch()
        local limit = math.min(i + MUTE_BATCH_SIZE - 1, #fidList)
        for j = i, limit do
            MuteSoundFile(fidList[j])
        end
        i = limit + 1
        if i <= #fidList then
            C_Timer.After(0, batch)
        elseif callback then
            callback()
        end
    end
    batch()
end
```

## File path conventions

Blizzard organizes creature sounds under `sound/creature/<type>/`:

- `sound/creature/bear/` -- generic bear sounds
- `sound/creature/bearv2/` -- updated bear sounds
- `sound/creature/spider/` -- spider sounds
- `sound/creature/alleria_windrunner/` -- NPC-specific
- `sound/creature/6181820/` -- numeric ID (NPC-specific, no name)

The `<type>` folder name serves as the archetype identifier. Variants within a type (e.g., `bearv2`, `drakonid2`) use suffixed names. Named NPCs and numeric-ID folders are typically 1-2 CSD entries each.
