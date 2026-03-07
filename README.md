# Resonance

A World of Warcraft addon that lets you mute or replace spell sounds, character vocalizations, creature vocalizations, and weapon impacts. Works with any class.

## Why?

Repetitive game sounds can be a real problem for players with sensory hypersensitivity or sensory processing disorders. Resonance was built to give you full control over your audio experience -- mute the sounds that bother you, or swap them for something gentler.

## Features

- **Per-spell sound replacement** -- Replace any spell's sound with a different one (Vanilla/TBC/Wrath era sounds, or any FileDataID)
- **Auto-muting** -- When you configure a replacement sound, the original spell sounds are automatically muted
- **Character vocalization muting** -- Silence your own combat grunts, shouts, and exertion sounds (or all player races)
- **Creature vocalization muting** -- Mute monster attack/injury/death sounds by category (Beasts, Demons, Dragons, etc.) or individual creature type (spiders, murlocs, raptors, etc.)
- **Weapon impact muting** -- Mute melee hit and swing sounds
- **Sound browser** -- Search through thousands of available spell and character sounds with preview playback
- **Class presets** -- Built-in sound configurations for every class, auto-updated when templates improve
- **Profile support** -- Save different configurations and switch between them

## Installation

Download the latest `Resonance-x.x.x.zip` from [Releases](https://github.com/renatoi/resonance/releases), extract it into your `World of Warcraft/_retail_/Interface/AddOns/` folder, and restart the game.

## Usage

Open settings from the game menu (**Esc > Options > AddOns > Resonance**) or type:

```
/res            -- Open settings
/res on|off     -- Enable/disable the addon
```

### Settings tabs

| Tab | What it does |
|---|---|
| **General** | Toggle the addon, debug mode, vocalization muting, creature muting, weapon muting, sound channel |
| **Spell Sounds** | Add/edit per-spell sound replacements with search and preview |
| **Muted Sounds** | Manage manually muted FileDataIDs |
| **Presets** | Apply built-in class presets or save/load your own |
| **Profiles** | Create, copy, or reset setting profiles |

### Muting options

**Character vocalizations** -- Combat grunts, shouts, and exertion sounds your character makes when attacking or taking damage. Choose "Mine" to mute only your own race/gender, or "All races" to mute every player race.

**Creature vocalizations** -- Monster attack grunts, injury sounds, death screams, and aggro noises. Blizzard uses ~7,400 creature sound profiles shared across 118,000+ creatures, heavily reusing the same sounds across expansions. You can mute by broad category (e.g. all Beasts) or by specific creature type (e.g. just spiders). See [docs/creature-sound-architecture.md](docs/creature-sound-architecture.md) for technical details.

**Weapon impacts** -- Melee hit thwacks and swing sounds, applied globally regardless of weapon type.

### Slash commands

```
/res debug on|off              -- Print spell casts to chat (useful for finding spell IDs)
/res testspell <spellID>       -- Preview the sound configured for a spell
/res muteadd <fileDataID>      -- Manually mute a specific sound
/res mutedel <fileDataID>      -- Unmute a specific sound
/res mutelist                  -- List all manually muted sounds
/res map <spellID> <fid>       -- Map a spell to a replacement FileDataID
/res unmap <spellID>           -- Remove a spell mapping
/res override "Name" <path>    -- Set a local file override for a spell
/res clearoverride "Name"      -- Clear a local file override
```

## Development

### Project structure

```
Resonance.toc          -- Addon manifest
Core.lua               -- Event handling, sound playback, mute management
Options.lua            -- Settings UI (AceConfig + custom spell editor)
Locales.lua            -- Localization strings (10 languages)
embeds.xml             -- Ace library loader
data/
  SpellSounds.lua      -- Searchable database of spell sound paths + FileDataIDs
  CharacterSounds.lua  -- Searchable database of character/emote sounds
  ClassTemplates.lua   -- Built-in class presets (spells across 11 classes)
  SpellMuteData.lua    -- Auto-generated: spell->FileDataID mute mappings,
                         vocalization data, weapon impact data
  ClassicSpellSounds.lua -- Reference: spellID -> classic-era sound FIDs
                         (not loaded at runtime, used for template development)
docs/
  creature-sound-architecture.md -- Research on WoW's creature sound system
libs/                  -- Embedded Ace3 framework + LibDBIcon + LibDataBroker
sounds/                -- Bundled fallback sound files
tools/
  spell_sounds.py      -- DB2 chain walker + data generation script
  compact_mute_data.py -- Compacts SpellMuteData.lua for smaller file size
build.py               -- Build/deploy script
```

### Sound mute architecture

The addon maintains four independent mute layers, each tracking which FileDataIDs it has muted:

| Layer | Tracking table | Purpose |
|---|---|---|
| Manual mutes | `db.mute_file_data_ids` (saved) | User-added FileDataIDs via `/res muteadd` or the UI |
| Auto-mutes | `autoMutedFIDs` (runtime, refcounted) | Spell sounds muted when a replacement sound is configured |
| Character vox | `voxMutedFIDs` (runtime) | Player race/gender vocalization sounds |
| Weapon impacts | `weaponMutedFIDs` (runtime) | All weapon hit/swing sounds |

When unmuting from one layer, the code checks all other layers before calling `UnmuteSoundFile()` to avoid accidentally unmuting a FID that another layer still wants muted. WoW's `MuteSoundFile` API is refcounted internally, so the addon is careful to call `MuteSoundFile`/`UnmuteSoundFile` symmetrically.

### Classic spell sound reference (`data/ClassicSpellSounds.lua`)

This file maps classic spell IDs to their original Classic/TBC/Wrath-era sound FileDataIDs. It is **not loaded by the addon** -- it exists purely as a development reference when building or updating `ClassTemplates.lua`.

To find the classic sounds for a spell:
1. Look up the spell on [Wowhead Classic](https://www.wowhead.com/classic/spell=SPELLID) (check the Sound tab)
2. Or use [Wago Tools](https://wago.tools/db2/SoundKitEntry) to trace SoundKit -> FileDataID
3. Add the mapping to `ClassicSpellSounds.lua` for future reference
4. Use those FIDs in `ClassTemplates.lua`

### Template auto-update

When a user loads a class template (e.g., Warrior), the addon tracks which class it came from. On subsequent logins, `refreshPresetsFromTemplates()` automatically:
- **Updates** existing preset spells to match the latest template values (sound, muteExclusions)
- **Adds** new spells that were added to the template since the user last loaded it

This means template improvements (new spells, sound fixes) are automatically applied without users needing to re-apply the template.

### Where the data comes from

The `data/` files are generated by `tools/spell_sounds.py`, which walks WoW's datamined DB2 tables (downloaded from [wago.tools](https://wago.tools)) to find every sound FileDataID associated with every spell. It follows several resolution chains:

1. **Spell -> Visual -> Kit Effects -> SoundKit -> FileDataID** (visual kit sounds)
2. **Spell -> Visual -> AnimEventSoundID -> SoundKit -> FileDataID** (animation sounds)
3. **Spell -> Visual -> Missile -> SoundKit -> FileDataID** (missile impact sounds)
4. **Sub-spell discovery** -- Recursively follows triggered sub-spells (SpellEffect type 64)

It also builds:
- **Player vocalization tables** by mapping race/gender -> character model -> CreatureSoundData -> FileDataIDs
- **Weapon impact/swing tables** from WeaponImpactSounds and WeaponSwingSounds2
- **Creature vocalization tables** by walking all CreatureSoundData entries and classifying them by creature archetype using the community listfile

#### Regenerating the data

```bash
cd tools/

# Look up sounds for a specific spell (default: retail data)
python spell_sounds.py 12294                    # by spell ID (Mortal Strike)
python spell_sounds.py --name "Mortal Strike"   # by name

# Target a specific game build
python spell_sounds.py --build mop 12294        # MoP Classic data
python spell_sounds.py --build cata 12294       # Cataclysm Classic data
python spell_sounds.py --build classic 12294    # Classic Era data
python spell_sounds.py --build 5.5.3.66128 12294  # explicit version string

# List available builds from wago.tools
python spell_sounds.py --list-builds

# Regenerate all mute data (takes a while -- downloads ~16 DB2 tables)
python spell_sounds.py --generate-mute-data
python spell_sounds.py --generate-mute-data --build mop  # from MoP Classic data

# Regenerate ClassicSpellSounds.lua reference table from Classic Era DB2 data
# Reads spell IDs from ClassTemplates.lua and looks up their classic-era sounds
python spell_sounds.py --generate-classic-reference

# Force re-download cached DB2 tables
python spell_sounds.py --refresh
python spell_sounds.py --clear-cache
```

Build aliases: `retail` (default), `mop` (MoP Classic 5.5.x), `cata` (Cataclysm Classic 3.80.x), `classic` (Classic Era 1.15.x). Each build's CSV cache is stored separately under `tools/.db2_cache/<version>/`.

The `SpellSounds.lua` and `CharacterSounds.lua` files are sourced from [Leatrix Sounds](https://www.curseforge.com/wow/addons/leatrix-sounds) -- these provide the browsable sound library in the addon's UI.

### Building

```bash
# Deploy to your local WoW AddOns folder for testing
python build.py deploy

# Create a versioned zip for distribution
python build.py package
```

`build.py deploy` syncs only addon-relevant files (not `tools/`, `build.py`, etc.) to the WoW AddOns directory and removes stale files. `build.py package` reads the version from `Resonance.toc` and creates `Resonance-<version>.zip`.
