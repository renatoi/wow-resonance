-- Resonance project luacheck config
-- WoW API globals are in .luacheckrc_wow (run: python3 tools/update_wow_globals.py)

-- Load WoW API globals into a custom standard
local wow_rg = {}
local wow_chunk = loadfile(".luacheckrc_wow")
if wow_chunk then
	-- Lua 5.4: use load with custom env to capture read_globals
	local env = {}
	setmetatable(env, { __index = _ENV })
	if debug and debug.setupvalue then
		debug.setupvalue(wow_chunk, 1, env)
	end
	pcall(wow_chunk)
	wow_rg = env.read_globals or {}
end

stds.wow = { read_globals = wow_rg }

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
