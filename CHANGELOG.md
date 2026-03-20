# Changelog

## v1.3.0

### New Features
- **Cast phase triggers:** Choose when spell replacement sounds play — on cast complete, cast bar start (precast), or both with separate sounds for each phase.
- **Sound duration cutoff:** Limit how long a replacement sound plays (in seconds).
- **Sound looping:** Loop a replacement sound continuously or a set number of times.
- **Interrupt alert sound:** Play a custom sound when your spell is interrupted. Uses `C_LossOfControl` school lockout confirmation — fully compatible with Midnight 12.0.1 instanced content (M+, raids, PvP).
- **Ambient sound muting:** Mute ambient sounds by zone with per-zone toggles in a new Ambient tab. Includes a search feature to find and mute individual ambient sounds, with expansion/zone info in results.
- **Per-NPC sound muting:** Mute sounds from specific NPCs.
- **Sound autocomplete:** Autocomplete dropdown when selecting replacement sounds, with a redesigned two-line layout showing expansion/zone and FID info.
- **Rogue Shadowstrike** added to class sound templates.

### UI/UX Improvements
- Options panel reorganized into Settings subcategories with dedicated panels and tab headings.
- Redesigned dropdown rows with per-row variable height and inline mute icon button with visual feedback.
- Improved WCAG contrast and color consistency across the UI.

### Performance
- **LoadOnDemand data split:** Addon split into Resonance (core) + Resonance_Data, deferring large data tables until options are first opened.
- Memory optimizations: table reuse, deferred snapshots, prefix pools, eliminated string concatenation during search.

### Bug Fixes
- Auto-migrate stale creature vox snapshots on addon upgrade.
- Exclude profession sound FIDs from creature vocalization muting.
- Clear stale mute snapshots on startup.
- Use MAX_MUTE_DEPTH unmutes in all clear functions to properly drain refcount.
- Fixed various UI layout issues (editor overlap, duration anchoring, ambient tab positioning, preview button placement).
- Fixed mojibake caused by UTF-8 arrow character in disabled message.

### Tooling
- `/res checkfid <id>` diagnostic command to inspect which muting systems affect a given FileDataID.
- `tools/generate_ambient_data.lua` for generating ambient sound data.

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
