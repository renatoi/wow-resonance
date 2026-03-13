# Changelog

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
