-- Resonance project luacheck config
-- WoW API globals are in .luacheckrc_wow (run: python3 tools/update_wow_globals.py)
-- That file contains only a read_globals={...} assignment, extracted
-- from LiangYuxuan/wow-addon-luacheckrc by update_wow_globals.py.

dofile(".luacheckrc_wow")
stds.wow = { read_globals = read_globals or {} }
read_globals = nil

std = "lua51+wow"
max_line_length = false

exclude_files = {
	"Libs/",
	".luacheckrc",
	".luacheckrc_wow",
}

ignore = {
	"11./SLASH_.*",   -- Slash handler globals
	"11./BINDING_.*", -- Keybinding header globals
	"122/StaticPopupDialogs",
	"212/self",       -- Unused argument "self"
	"42.",            -- Shadowing a local variable
	"43.",            -- Shadowing an upvalue
}

-- WoW APIs missing from the auto-generated globals file
read_globals = {
	"bit",
	"C_AddOns",
	"C_Item",
	"C_LossOfControl",
	"C_Spell",
	"C_SpellBook",
	"C_Timer",
	"ChatFontNormal",
	"Enum",
	"GameFontHighlightSmall",
	"GameFontNormal",
	"GetSpellInfo",
	"IsPlayerSpell",
	"MASTER_VOLUME",
	"SOUND_VOLUME",
	"MUSIC_VOLUME",
	"AMBIENCE_VOLUME",
	"DIALOG_VOLUME",
}

-- Addon globals: set in one file, read in others
globals = {
	"Resonance",
	"Resonance_L",
	"ResonanceDB",
	"CastSoundsDB",
	"_",
	-- Data file globals (set in data/*.lua, consumed in Core.lua)
	"Resonance_ClassTemplates",
	"Resonance_ProfessionSoundData",
	"Resonance_ProfessionCategories",
	"Resonance_SpellMuteData",
	"Resonance_SpellVoxTypes",
	"Resonance_VoxTypeNames",
	"Resonance_RaceCSD",
	"Resonance_ExcludedFIDs",
	"Resonance_CharacterSoundPrefixes",
	"Resonance_CharacterSounds",
	"Resonance_ClassicSpellSounds",
	"Resonance_CreatureVoxData",
	"Resonance_CreatureVoxCategories",
	"Resonance_CreatureVoxExcludedFIDs",
	"Resonance_AmbientSoundData",
	"Resonance_NPCSoundIndex",
	"Resonance_NPCToCSD",
	"Resonance_NPCRepCSDs",
	"Resonance_NPCSoundCSD",
	"Resonance_NPCVoiceData",
	"Resonance_NPCSoundL10N",
	"Resonance_VoxFIDs",
	"Resonance_WeaponImpactFIDs",
	"Resonance_AmbientSounds",
	"Resonance_SpellSounds",
	"Resonance_SpellSoundPrefixes",
}
