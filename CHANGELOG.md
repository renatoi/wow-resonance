# Changelog

## v1.3.0

### New Features
- **Alerts tab:** Configure alert sounds for combat events with a dropdown + table UI. Select an event type, pick a sound (with autocomplete search), and manage alerts with enable/disable toggles.
  - **Interrupt alert:** Play a sound when your cast is interrupted by an enemy kick or counterspell. Uses `LOSS_OF_CONTROL_ADDED` + `UNIT_SPELLCAST_INTERRUPTED` dual-direction correlation — fully compatible with Midnight 12.0.1 instanced content.
  - **Loss of Control alert:** Play a sound when you are stunned, feared, silenced, or otherwise lose control of your character.
  - **Death alert:** Play a sound when you die.
- **Custom Sounds tab:** Register your own .ogg/.mp3 sound files and use them throughout the addon. Place files in `Interface/AddOns/Resonance_Sounds/`, register them with a display name, and they appear in all sound search autocomplete dropdowns (highlighted in green).
- **Cast phase triggers:** Choose when spell replacement sounds play — on cast complete, cast bar start (precast), or both with separate sounds for each phase.
- **Sound duration cutoff:** Limit how long a replacement sound plays (in seconds).
- **Sound looping:** Loop a replacement sound continuously or a set number of times.
- **Ambient sound muting:** Mute ambient sounds by zone with per-zone toggles in a new Ambient tab. Includes a search feature to find and mute individual ambient sounds, with expansion/zone info in results.
- **Per-NPC sound muting:** Mute sounds from specific NPCs.
- **Sound autocomplete:** Autocomplete dropdown when selecting replacement sounds, with a redesigned two-line layout showing expansion/zone and FID info.
- **Rogue Shadowstrike** added to class sound templates.

### UI/UX Improvements
- Options panel reorganized into Settings subcategories with dedicated panels and tab headings.
- Redesigned dropdown rows with per-row variable height and inline mute icon button with visual feedback.
- Improved WCAG contrast and color consistency across the UI.
- Sound channel dropdown now uses Blizzard's localized global strings — labels match the game's Sound settings in every language.

### Performance
- **LoadOnDemand data split:** Addon split into Resonance (core) + Resonance_Data, deferring large data tables until options are first opened.
- Memory optimizations: table reuse, deferred snapshots, prefix pools, eliminated string concatenation during search.

### Bug Fixes
- Fix UNIT_MODEL_CHANGED spam: cache race/gender key so vocalization mute refreshes only trigger on actual changes (barbershop, Orb of Deception), not on every model update.
- Auto-migrate stale creature vox snapshots on addon upgrade.
- Exclude profession sound FIDs from creature vocalization muting.
- Clear stale mute snapshots on startup.
- Use MAX_MUTE_DEPTH unmutes in all clear functions to properly drain refcount.
- Fixed various UI layout issues (editor overlap, duration anchoring, ambient tab positioning, preview button placement).
- Fixed mojibake caused by UTF-8 arrow character in disabled message.

### Tooling
- Added luacheck and StyLua linting/formatting with CI workflow.
- Cross-platform dev setup docs in README (macOS, Linux apt/pacman, Windows).
- `/res checkfid <id>` diagnostic command to inspect which muting systems affect a given FileDataID.
- `tools/generate_ambient_data.lua` for generating ambient sound data.

### Localization
- All new keys translated across 9 languages (ptBR, deDE, frFR, esES, itIT, ruRU, koKR, zhCN, zhTW).

## v1.2.0

### New Features
- **Mute-only mode:** Mute all sounds from a spell without selecting a replacement. Enable "Mute only" in the spell editor to silence original sounds with nothing playing in their place.
- **Profession sound muting:** Per-profession checkboxes (Alchemy, Blacksmithing, Cooking, etc.) to mute crafting, gathering, and other profession-related sounds. 13 professions, 168 unique sound files.
- **Shared-sounds disclaimer:** General tab now shows a note explaining that some sounds are shared across multiple spells/effects, so muting for one feature may silence them elsewhere.

### Tooling
- `tools/spell_sounds.py --generate-profession-data` generates `data/ProfessionSoundData.lua` from DB2 SkillLine/SkillLineAbility data.

## v1.1.0

### New Features
- **Classic auto-shot sounds (Hunter):** Replace modern bow and gun auto-shot sounds with classic ones. Automatically detects equipped weapon type (bow/crossbow or gun). Toggle in General options (Hunter only).
- **Disable state:** When "Enable Resonance" is unchecked, all General tab controls are now visually disabled and muting options revert to defaults, making it clear the addon is inactive.
- **Version display:** Minimap tooltip now shows the addon version.

### Bug Fixes
- **Revenge** sound mapping corrected — was playing DecisiveStrike.ogg instead of dedicated warrior_revenge sounds.
- **Bladestorm** sound mapping corrected — was playing WhirlwindShort.ogg instead of dedicated warrior_bladestorm sound.
- **Heart Strike** sound mapping corrected — was playing Blood Strike sounds instead of dedicated deathknight_heartstrike sounds.
- **Addon icon** in the AddOns menu now matches the minimap button icon.

### Creature Vocalization Improvements
- Added fidget (idle roars/growls), alert (pre-aggro), and jump sounds to creature vox muting — previously only combat sounds were covered.
- Narrowed spell FID exclusion to player spells only — NPC abilities no longer incorrectly protect their creature's own vox sounds from being muted.
- Total creature vox coverage increased from ~40K to ~61K sound files (+54%).

## v1.0.0

- Initial release.
