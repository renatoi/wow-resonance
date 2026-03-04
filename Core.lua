-- Resonance
-- Goal:
--   1) Keep SFX ON (so you still hear footsteps/world audio)
--   2) Mute specific modern spell sounds by FileDataID
--   3) Play your chosen "old school" sounds on your own casts (UNIT_SPELLCAST_SUCCEEDED)
--   Works with any class/spec.
--
-- Sound file setup:
--   Put extracted sound files (Vanilla/TBC/Wrath) into:
--     Interface\AddOns\Resonance\sounds\vanilla\
--   Named after the spell, e.g.:
--     Mortal Strike.wav
--     Execute.ogg
--     Shield Slam.wav
--   The addon will prefer a file override by spell name (from your local files),
--   over any in-client fallback FileDataID.
--
-- Fallback strategy:
--   - If you do NOT provide a local file override, we can optionally play a SoundKit/FileDataID
--     that exists in the retail client (if you map one).
--   - If neither exists, we play sounds/fallback/generic.wav
--
-- Note on MuteSoundFile:
--   Mutes are not guaranteed to persist after a full client restart, so we re-apply on login.
--   API: MuteSoundFile(fileDataID), UnmuteSoundFile(fileDataID)

Resonance = LibStub("AceAddon-3.0"):NewAddon("Resonance", "AceConsole-3.0", "AceEvent-3.0")

local ADDON_ROOT = "Interface\\AddOns\\Resonance\\"

local db          -- shortcut to self.db.profile, set in OnInitialize
local autoMutedFIDs = {}  -- runtime-only refcounted mute table (not saved)
local voxMutedFIDs = {}   -- runtime-only: FIDs muted by global vox toggle
local weaponMutedFIDs = {} -- runtime-only: FIDs muted by weapon impact toggle

---------------------------------------------------------------------------
-- Defaults (AceDB profile)
---------------------------------------------------------------------------
local defaults = {
  profile = {
    enabled = true,
    debug = false,
    triggerOnOtherPlayers = false,
    soundChannel = "Master",
    mute_file_data_ids = {},
    local_file_overrides_by_spell_name = {},
    spell_to_play_file_data_id = {},
    spell_config = {},
    template_spells = {},  -- { [spellID] = true } tracks which spells came from templates
    muteVocalizations = false,
    muteWeaponImpacts = false,
    minimap = { hide = false },
  },
}

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------
local function msg(s)
  DEFAULT_CHAT_FRAME:AddMessage("|cff00d1ff[Resonance]|r " .. tostring(s))
end

local function getSpellName(spellID)
  if C_Spell and C_Spell.GetSpellName then
    return C_Spell.GetSpellName(spellID)
  end
  local name = GetSpellInfo(spellID)
  return name
end

local function sanitizeFilename(name)
  name = name:gsub("[\\/:*?\"<>|]", "")
  name = name:gsub("%s+$", "")
  return name
end

local function normalizePath(p)
  if not p or p == "" then return nil end
  p = p:gsub("/", "\\")
  if p:lower():match("^interface\\") then return p end
  return ADDON_ROOT .. p
end

local function resolveLocalFileForSpellName(spellName)
  if not spellName or spellName == "" then return nil end

  local mapped = db.local_file_overrides_by_spell_name
              and db.local_file_overrides_by_spell_name[spellName]
  if mapped then
    return normalizePath(mapped)
  end

  local safe = sanitizeFilename(spellName)
  local base = ADDON_ROOT .. "sounds\\vanilla\\"
  return base .. safe .. ".wav", base .. safe .. ".ogg"
end

local function getChannel()
  return db and db.soundChannel or "Master"
end

local function previewSound(value)
  if not value then return false end
  local ch = getChannel()
  if type(value) == "number" then
    return PlaySoundFile(value, ch)
  end
  local path = normalizePath(tostring(value))
  if path then
    return PlaySoundFile(path, ch)
  end
  return false
end

local function playResolvedSound(spellID, spellName)
  local dbg = db.debug

  -- 0) spell_config: unified per-spell configuration
  local cfg = db.spell_config and db.spell_config[spellID]
  if cfg and cfg.sound then
    -- Temporarily unmute the replacement sound in case it's also in the mute list (manual or auto)
    local isMuted = type(cfg.sound) == "number" and (db.mute_file_data_ids[cfg.sound] or autoMutedFIDs[cfg.sound] or voxMutedFIDs[cfg.sound] or weaponMutedFIDs[cfg.sound])
    if dbg then msg(("  spell_config sound: %s (type: %s, muted: %s, channel: %s)"):format(tostring(cfg.sound), type(cfg.sound), tostring(isMuted and true or false), getChannel())) end
    if isMuted then
      local fid = cfg.sound
      -- WoW's MuteSoundFile is refcounted; unmute enough times to fully clear it
      for _ = 1, 5 do UnmuteSoundFile(fid) end
      local ok = previewSound(fid)
      if dbg then msg(("  PlaySoundFile result: %s"):format(tostring(ok))) end
      -- Re-mute once after a delay (applyMutes only uses count=1 per FID; reload normalizes)
      C_Timer.After(0.2, function() MuteSoundFile(fid) end)
    else
      local ok = previewSound(cfg.sound)
      if dbg then msg(("  PlaySoundFile result: %s"):format(tostring(ok))) end
    end
    -- User explicitly configured this sound; don't fall through
    -- (PlaySoundFile may return nil for valid FileDataIDs)
    return true
  elseif dbg then
    msg("  No spell_config sound for this spell.")
  end

  -- 1) Prefer local extracted "vanilla" file by spell name
  local ch = getChannel()
  local wav, ogg = resolveLocalFileForSpellName(spellName)
  if wav then
    local ok = PlaySoundFile(wav, ch)
    if ok then return true end
  end
  if ogg then
    local ok = PlaySoundFile(ogg, ch)
    if ok then return true end
  end

  -- 2) Fallback to an in-client FileDataID mapping (user-provided)
  local fid = db.spell_to_play_file_data_id
          and db.spell_to_play_file_data_id[spellID]
  if fid then
    local ok = PlaySoundFile(fid, ch)
    if ok then return true end
  end

  return false
end

local function shouldTriggerForSpell(spellID)
  if not db.enabled then return false end
  if not spellID then return false end

  -- Always trigger for spells explicitly configured by the user
  if db.spell_config and db.spell_config[spellID] then
    return true
  end

  -- Trigger for spells in the player's spellbook
  return IsPlayerSpell(spellID)
end

---------------------------------------------------------------------------
-- Global vocalization mute
---------------------------------------------------------------------------
local function getPlayerCSDEntry()
  if not Resonance_RaceCSD or not Resonance_VoxFIDs then return nil end
  local raceID = select(3, UnitRace("player"))
  local sex = (UnitSex("player") == 3) and "1" or "0"
  local csdID = Resonance_RaceCSD[tostring(raceID) .. ":" .. sex]
  if not csdID then return nil end
  return Resonance_VoxFIDs[csdID]
end

local function applyVoxMutes()
  local voxEntry = getPlayerCSDEntry()
  if not voxEntry then return end
  local count = 0
  for _, fids in pairs(voxEntry) do
    for _, fid in ipairs(fids) do
      if not voxMutedFIDs[fid] then
        voxMutedFIDs[fid] = true
        MuteSoundFile(fid)
        count = count + 1
      end
    end
  end
  if count > 0 then
    msg(("Muted %d vocalization sounds."):format(count))
  end
end

local function clearVoxMutes()
  local count = 0
  for fid in pairs(voxMutedFIDs) do
    -- Don't unmute if also held by manual mutes, auto-mutes, or weapon mutes
    if not db.mute_file_data_ids[fid]
       and not (autoMutedFIDs[fid] and autoMutedFIDs[fid] > 0)
       and not weaponMutedFIDs[fid] then
      UnmuteSoundFile(fid)
    end
    count = count + 1
  end
  wipe(voxMutedFIDs)
  if count > 0 then
    msg(("Cleared %d vocalization mutes."):format(count))
  end
end

---------------------------------------------------------------------------
-- Global weapon impact mute
---------------------------------------------------------------------------
local function applyWeaponMutes()
  if not Resonance_WeaponImpactFIDs then return end
  local count = 0
  for _, fid in ipairs(Resonance_WeaponImpactFIDs) do
    if not weaponMutedFIDs[fid] then
      weaponMutedFIDs[fid] = true
      MuteSoundFile(fid)
      count = count + 1
    end
  end
  if count > 0 then
    msg(("Muted %d weapon impact sounds."):format(count))
  end
end

local function clearWeaponMutes()
  local count = 0
  for fid in pairs(weaponMutedFIDs) do
    -- Don't unmute if also held by manual mutes, auto-mutes, or vox mutes
    if not db.mute_file_data_ids[fid]
       and not (autoMutedFIDs[fid] and autoMutedFIDs[fid] > 0)
       and not voxMutedFIDs[fid] then
      UnmuteSoundFile(fid)
    end
    count = count + 1
  end
  wipe(weaponMutedFIDs)
  if count > 0 then
    msg(("Cleared %d weapon impact mutes."):format(count))
  end
end

---------------------------------------------------------------------------
-- Auto-mute management (runtime refcounts in autoMutedFIDs)
---------------------------------------------------------------------------
local function addAutoMuteFIDs(fids)
  if not fids then return end
  for _, fid in ipairs(fids) do
    autoMutedFIDs[fid] = (autoMutedFIDs[fid] or 0) + 1
  end
end

local function removeAutoMuteFIDs(fids)
  if not fids then return end
  for _, fid in ipairs(fids) do
    local count = (autoMutedFIDs[fid] or 0) - 1
    if count <= 0 then
      autoMutedFIDs[fid] = nil
      if not db.mute_file_data_ids[fid] and not voxMutedFIDs[fid] and not weaponMutedFIDs[fid] then
        UnmuteSoundFile(fid)
      end
    else
      autoMutedFIDs[fid] = count
    end
  end
end

local function getExclusions(spellID)
  local cfg = db.spell_config and db.spell_config[spellID]
  return cfg and cfg.muteExclusions
end

local function filterExclusions(fids, exclusions)
  if not exclusions then return fids end
  local filtered = {}
  for _, fid in ipairs(fids) do
    if not exclusions[fid] then
      filtered[#filtered + 1] = fid
    end
  end
  return filtered
end

local function rebuildAutoMutes()
  wipe(autoMutedFIDs)
  for sid, _ in pairs(db.spell_config or {}) do
    local fids = Resonance_SpellMuteData and Resonance_SpellMuteData[sid]
    if fids then
      addAutoMuteFIDs(filterExclusions(fids, getExclusions(sid)))
    end
  end
end

local function applyAutoMutesForSpell(spellID)
  local fids = Resonance_SpellMuteData and Resonance_SpellMuteData[spellID]
  if not fids then return end
  fids = filterExclusions(fids, getExclusions(spellID))
  -- Only call MuteSoundFile for FIDs not already muted (avoid inflating WoW's internal refcount)
  local newFIDs = {}
  for _, fid in ipairs(fids) do
    if not autoMutedFIDs[fid] or autoMutedFIDs[fid] <= 0 then
      if not db.mute_file_data_ids[fid] then
        newFIDs[#newFIDs + 1] = fid
      end
    end
  end
  addAutoMuteFIDs(fids)
  if db.enabled then
    for _, fid in ipairs(newFIDs) do MuteSoundFile(fid) end
  end
end

local function removeAutoMutesForSpell(spellID)
  local fids = Resonance_SpellMuteData and Resonance_SpellMuteData[spellID]
  if not fids then return end
  removeAutoMuteFIDs(filterExclusions(fids, getExclusions(spellID)))
end

local function applyMutes()
  local count = 0
  for fid, enabled in pairs(db.mute_file_data_ids or {}) do
    if enabled then
      MuteSoundFile(fid)
      count = count + 1
    end
  end
  for fid, refcount in pairs(autoMutedFIDs) do
    if refcount > 0 and not db.mute_file_data_ids[fid] then
      MuteSoundFile(fid)
      count = count + 1
    end
  end
  if count > 0 then
    msg(("Applied %d sound mutes."):format(count))
  end
end

local function clearMutes()
  local count = 0
  for fid, enabled in pairs(db.mute_file_data_ids or {}) do
    if enabled and not voxMutedFIDs[fid] and not weaponMutedFIDs[fid] then
      UnmuteSoundFile(fid)
      count = count + 1
    end
  end
  for fid, refcount in pairs(autoMutedFIDs) do
    if refcount > 0 and not db.mute_file_data_ids[fid] and not voxMutedFIDs[fid] and not weaponMutedFIDs[fid] then
      UnmuteSoundFile(fid)
      count = count + 1
    end
  end
  if count > 0 then
    msg(("Cleared %d sound mutes."):format(count))
  end
end

---------------------------------------------------------------------------
-- Base64 encode/decode
---------------------------------------------------------------------------
local b64chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local b64lookup = {}
for i = 1, 64 do b64lookup[b64chars:byte(i)] = i - 1 end

local function b64encode(data)
  local out = {}
  for i = 1, #data, 3 do
    local a, b, c = data:byte(i, i + 2)
    b = b or 0; c = c or 0
    local n = a * 65536 + b * 256 + c
    local remaining = #data - i + 1
    out[#out + 1] = b64chars:sub(bit.rshift(n, 18) + 1, bit.rshift(n, 18) + 1)
    out[#out + 1] = b64chars:sub(bit.band(bit.rshift(n, 12), 63) + 1, bit.band(bit.rshift(n, 12), 63) + 1)
    out[#out + 1] = remaining > 1 and b64chars:sub(bit.band(bit.rshift(n, 6), 63) + 1, bit.band(bit.rshift(n, 6), 63) + 1) or "="
    out[#out + 1] = remaining > 2 and b64chars:sub(bit.band(n, 63) + 1, bit.band(n, 63) + 1) or "="
  end
  return table.concat(out)
end

local function b64decode(data)
  data = data:gsub("[^A-Za-z0-9+/=]", "")
  local out = {}
  for i = 1, #data, 4 do
    local a = b64lookup[data:byte(i)] or 0
    local b = b64lookup[data:byte(i + 1)] or 0
    local c = b64lookup[data:byte(i + 2)] or 0
    local d = b64lookup[data:byte(i + 3)] or 0
    local n = a * 262144 + b * 4096 + c * 64 + d
    out[#out + 1] = string.char(bit.band(bit.rshift(n, 16), 255))
    if data:sub(i + 2, i + 2) ~= "=" then out[#out + 1] = string.char(bit.band(bit.rshift(n, 8), 255)) end
    if data:sub(i + 3, i + 3) ~= "=" then out[#out + 1] = string.char(bit.band(n, 255)) end
  end
  return table.concat(out)
end

---------------------------------------------------------------------------
-- Export / Import config
---------------------------------------------------------------------------
function Resonance:ExportConfig()
  local lines = { "V1" }
  -- Spell config entries
  for sid, cfg in pairs(db.spell_config or {}) do
    if cfg.sound then
      local val
      if type(cfg.sound) == "number" then
        val = tostring(cfg.sound)
      else
        val = '"' .. tostring(cfg.sound) .. '"'
      end
      lines[#lines + 1] = "S" .. sid .. "=" .. val
    else
      -- Mute-only entry (no replacement sound)
      lines[#lines + 1] = "S" .. sid .. "="
    end
    -- Export mute exclusions if any
    if cfg.muteExclusions then
      local excl = {}
      for fid in pairs(cfg.muteExclusions) do excl[#excl + 1] = tostring(fid) end
      if #excl > 0 then
        lines[#lines + 1] = "X" .. sid .. ":" .. table.concat(excl, ",")
      end
    end
  end
  -- Manual mute entries
  for fid, enabled in pairs(db.mute_file_data_ids or {}) do
    if enabled then
      lines[#lines + 1] = "M" .. fid
    end
  end
  local text = table.concat(lines, "\n")
  return "!Resonance!" .. b64encode(text)
end

function Resonance:ImportConfig(str)
  if not str or str == "" then return nil, "Empty import string." end
  -- Strip whitespace
  str = str:match("^%s*(.-)%s*$")
  -- Validate prefix
  if str:sub(1, 11) ~= "!Resonance!" then
    return nil, "Invalid format: missing !Resonance! prefix."
  end
  local encoded = str:sub(12)
  local ok, decoded = pcall(b64decode, encoded)
  if not ok or not decoded or decoded == "" then
    return nil, "Failed to decode import string."
  end
  -- Parse lines
  local lines = {}
  for line in decoded:gmatch("[^\n]+") do
    lines[#lines + 1] = line
  end
  if #lines == 0 or lines[1] ~= "V1" then
    return nil, "Unknown format version."
  end
  local added, skipped, addedMutes = 0, 0, 0
  for i = 2, #lines do
    local line = lines[i]
    local tag = line:sub(1, 1)
    if tag == "S" then
      local sid, val = line:match("^S(%d+)=(.*)")
      sid = tonumber(sid)
      if sid then
        if db.spell_config[sid] then
          skipped = skipped + 1
        else
          local sound
          if val and val ~= "" then
            local quoted = val:match('^"(.*)"$')
            if quoted then
              sound = quoted
            else
              sound = tonumber(val)
            end
          end
          db.spell_config[sid] = { sound = sound }
          applyAutoMutesForSpell(sid)
          added = added + 1
        end
      end
    elseif tag == "X" then
      local sid, fidList = line:match("^X(%d+):(.+)$")
      sid = tonumber(sid)
      if sid and fidList and db.spell_config[sid] then
        local exclusions = db.spell_config[sid].muteExclusions or {}
        for fidStr in fidList:gmatch("(%d+)") do
          exclusions[tonumber(fidStr)] = true
        end
        db.spell_config[sid].muteExclusions = exclusions
      end
    elseif tag == "M" then
      local fid = tonumber(line:sub(2))
      if fid then
        if not db.mute_file_data_ids[fid] then
          db.mute_file_data_ids[fid] = true
          MuteSoundFile(fid)
          addedMutes = addedMutes + 1
        end
      end
    end
  end
  return added, skipped, addedMutes
end

---------------------------------------------------------------------------
-- Public API (for Options.lua)
---------------------------------------------------------------------------
Resonance.ADDON_ROOT = ADDON_ROOT
Resonance.msg = msg
Resonance.getSpellName = getSpellName
Resonance.normalizePath = normalizePath
Resonance.previewSound = previewSound
Resonance.applyMutes = applyMutes
Resonance.clearMutes = clearMutes
Resonance.applyAutoMutesForSpell = applyAutoMutesForSpell
Resonance.removeAutoMutesForSpell = removeAutoMutesForSpell
Resonance.rebuildAutoMutes = rebuildAutoMutes
Resonance.autoMutedFIDs = autoMutedFIDs
Resonance.voxMutedFIDs = voxMutedFIDs
Resonance.weaponMutedFIDs = weaponMutedFIDs

function Resonance:ApplyClassTemplate(classKey)
  local template = Resonance_ClassTemplates and Resonance_ClassTemplates[classKey]
  if not template then return 0, 0 end
  local added, skipped = 0, 0
  for _, entry in ipairs(template) do
    local sid = entry.spellID
    if db.spell_config[sid] then
      skipped = skipped + 1
    else
      db.spell_config[sid] = { sound = entry.sound }
      db.template_spells[sid] = true
      applyAutoMutesForSpell(sid)
      added = added + 1
    end
  end
  return added, skipped
end

function Resonance:RemoveTemplateSpells()
  local removed = 0
  for sid in pairs(db.template_spells) do
    removeAutoMutesForSpell(sid)
    db.spell_config[sid] = nil
    removed = removed + 1
  end
  wipe(db.template_spells)
  return removed
end

---------------------------------------------------------------------------
-- AceConfig options table (General tab)
---------------------------------------------------------------------------
local function getGeneralOptions()
  return {
    type = "group",
    name = "General",
    args = {
      enabled = {
        type = "toggle",
        name = "Enable Resonance",
        desc = "Toggle the addon on/off. When disabled, all sound mutes are removed and no custom spell sounds play.",
        order = 1,
        width = "full",
        get = function() return db.enabled end,
        set = function(_, v)
          db.enabled = v
          if v then
            applyMutes()
            if db.muteVocalizations then applyVoxMutes() end
            if db.muteWeaponImpacts then applyWeaponMutes() end
          else
            clearVoxMutes()
            clearWeaponMutes()
            clearMutes()
          end
        end,
      },
      debug = {
        type = "toggle",
        name = "Debug mode (print casts to chat)",
        desc = "Print spell cast details (name, ID) to chat on each cast. Useful for finding spell IDs to configure.",
        order = 2,
        width = "full",
        get = function() return db.debug end,
        set = function(_, v) db.debug = v end,
      },
      triggerOnOtherPlayers = {
        type = "toggle",
        name = "Trigger on other players' spells",
        desc = "Also play custom sounds when other players cast spells (party, raid, nearby). Uses your spell configurations and spellbook.",
        order = 3,
        width = "full",
        get = function() return db.triggerOnOtherPlayers end,
        set = function(_, v) db.triggerOnOtherPlayers = v end,
      },
      showMinimap = {
        type = "toggle",
        name = "Show minimap button",
        desc = "Show a minimap button. Left-click opens options, right-click toggles addon on/off, drag to reposition.",
        order = 4,
        width = "full",
        get = function() return not db.minimap.hide end,
        set = function(_, v) Resonance.toggleMinimapButton(v) end,
      },
      muteVocalizations = {
        type = "toggle",
        name = "Mute character vocalizations",
        desc = "Mute all character vocalization sounds (grunts, shouts, etc.) for your race/gender. Applies globally, not per-spell.",
        order = 5,
        width = "full",
        get = function() return db.muteVocalizations end,
        set = function(_, v)
          db.muteVocalizations = v
          if v then if db.enabled then applyVoxMutes() end else clearVoxMutes() end
        end,
      },
      muteWeaponImpacts = {
        type = "toggle",
        name = "Mute weapon impact sounds",
        desc = "Mute all weapon impact and swing sounds (the melee hit thwack/clang). Applies globally regardless of weapon type.",
        order = 6,
        width = "full",
        get = function() return db.muteWeaponImpacts end,
        set = function(_, v)
          db.muteWeaponImpacts = v
          if v then if db.enabled then applyWeaponMutes() end else clearWeaponMutes() end
        end,
      },
      soundChannel = {
        type = "select",
        name = "Sound Channel",
        desc = "Which audio channel to play replacement sounds on.",
        order = 7,
        values = {
          Master = "Master",
          SFX = "SFX",
          Music = "Music",
          Ambience = "Ambience",
          Dialog = "Dialog",
        },
        sorting = { "Master", "SFX", "Music", "Ambience", "Dialog" },
        get = function() return db.soundChannel end,
        set = function(_, v) db.soundChannel = v end,
      },
    },
  }
end

---------------------------------------------------------------------------
-- Minimap button (LibDBIcon)
---------------------------------------------------------------------------
local LDB = LibStub("LibDataBroker-1.1")
local LDBIcon = LibStub("LibDBIcon-1.0")

local ldbObj = LDB:NewDataObject("Resonance", {
  type = "launcher",
  icon = 6383545,
  OnClick = function(_, button)
    if button == "RightButton" then
      db.enabled = not db.enabled
      if db.enabled then
        applyMutes()
        if db.muteVocalizations then applyVoxMutes() end
        if db.muteWeaponImpacts then applyWeaponMutes() end
      else
        clearVoxMutes()
        clearWeaponMutes()
        clearMutes()
      end
      msg(db.enabled and "Enabled." or "Disabled.")
    else
      if Resonance.openOptions then Resonance.openOptions() end
    end
  end,
  OnTooltipShow = function(tt)
    tt:AddLine("Resonance")
    tt:AddLine("Left-click: Open options", 1, 1, 1)
    tt:AddLine("Right-click: Toggle on/off", 1, 1, 1)
    tt:AddLine("Drag: Move button", 0.7, 0.7, 0.7)
  end,
})

Resonance.toggleMinimapButton = function(show)
  db.minimap.hide = not show
  if show then
    LDBIcon:Show("Resonance")
  else
    LDBIcon:Hide("Resonance")
  end
end

---------------------------------------------------------------------------
-- Migration from CastSoundsDB
---------------------------------------------------------------------------
local function migrateFromCastSounds()
  if not CastSoundsDB then return end

  -- Build AceDB-compatible structure
  if not ResonanceDB then ResonanceDB = {} end
  if not ResonanceDB.profiles then ResonanceDB.profiles = {} end
  if not ResonanceDB.profiles["Default"] then ResonanceDB.profiles["Default"] = {} end

  local dest = ResonanceDB.profiles["Default"]
  local src = CastSoundsDB

  -- Copy known keys
  local simpleKeys = { "enabled", "debug", "triggerOnOtherPlayers", "soundChannel" }
  for _, k in ipairs(simpleKeys) do
    if src[k] ~= nil then dest[k] = src[k] end
  end

  local tableKeys = { "mute_file_data_ids", "local_file_overrides_by_spell_name",
                       "spell_to_play_file_data_id", "spell_config", "minimap" }
  for _, k in ipairs(tableKeys) do
    if src[k] then dest[k] = src[k] end
  end

  -- Don't copy auto_muted_fids — it's runtime-only now

  msg("Migrated settings from CastSoundsDB. You can disable the old CastSounds addon.")
  CastSoundsDB = nil
end

---------------------------------------------------------------------------
-- AceAddon lifecycle
---------------------------------------------------------------------------
function Resonance:OnInitialize()
  -- Migrate old saved variables before AceDB:New
  migrateFromCastSounds()

  -- Create AceDB
  self.db = LibStub("AceDB-3.0"):New("ResonanceDB", defaults, true)
  db = self.db.profile

  -- Profile change callbacks
  local function onProfileChanged()
    clearWeaponMutes()
    clearVoxMutes()
    clearMutes()
    db = self.db.profile
    wipe(autoMutedFIDs)
    rebuildAutoMutes()
    if db.enabled then applyMutes() end
    if db.muteVocalizations then applyVoxMutes() end
    if db.muteWeaponImpacts then applyWeaponMutes() end
  end
  self.db.RegisterCallback(self, "OnProfileChanged", onProfileChanged)
  self.db.RegisterCallback(self, "OnProfileCopied", onProfileChanged)
  self.db.RegisterCallback(self, "OnProfileReset", onProfileChanged)

  -- Register AceConfig
  LibStub("AceConfig-3.0"):RegisterOptionsTable("Resonance_General", getGeneralOptions)
  LibStub("AceConfig-3.0"):RegisterOptionsTable("Resonance_Profiles",
    LibStub("AceDBOptions-3.0"):GetOptionsTable(self.db))

  -- Slash commands
  self:RegisterChatCommand("res", "ChatCommand")
  self:RegisterChatCommand("resonance", "ChatCommand")

  -- Minimap button
  LDBIcon:Register("Resonance", ldbObj, db.minimap)

  -- Options panel (deferred to Options.lua)
  if self.SetupOptions then self:SetupOptions() end
end

function Resonance:OnEnable()
  self:RegisterEvent("UNIT_SPELLCAST_SUCCEEDED")
  rebuildAutoMutes()
  if db.enabled then applyMutes() end
  if db.muteVocalizations then applyVoxMutes() end
  if db.muteWeaponImpacts then applyWeaponMutes() end
  msg("Loaded. Type /res or go to Esc > Options > Addons > Resonance.")
end

---------------------------------------------------------------------------
-- Event handler
---------------------------------------------------------------------------
function Resonance:UNIT_SPELLCAST_SUCCEEDED(_, unit, _, spellID)
  if unit ~= "player" and not db.triggerOnOtherPlayers then return end
  if not spellID then return end
  if not shouldTriggerForSpell(spellID) then return end

  local spellName = getSpellName(spellID) or ""

  if db.debug then
    local src = unit == "player" and "" or (" [%s]"):format(unit)
    msg(("Cast: %s (spellID %d)%s"):format(spellName ~= "" and spellName or "<?>", spellID, src))
  end

  playResolvedSound(spellID, spellName)
end

---------------------------------------------------------------------------
-- Slash command handler
---------------------------------------------------------------------------
function Resonance:ChatCommand(input)
  input = input or ""
  local cmd, rest = input:match("^(%S+)%s*(.-)$")
  cmd = cmd and cmd:lower() or ""

  if cmd == "options" or cmd == "config" or cmd == "settings" or cmd == "" then
    if Resonance.openOptions then
      Resonance.openOptions()
    else
      msg("Options panel not loaded.")
    end
    return
  elseif cmd == "on" then
    db.enabled = true
    applyMutes()
    if db.muteVocalizations then applyVoxMutes() end
    if db.muteWeaponImpacts then applyWeaponMutes() end
    msg("Enabled.")
  elseif cmd == "off" then
    db.enabled = false
    clearVoxMutes()
    clearWeaponMutes()
    clearMutes()
    msg("Disabled.")
  elseif cmd == "debug" then
    rest = (rest or ""):lower()
    db.debug = (rest == "on" or rest == "1" or rest == "true")
    msg("Debug " .. (db.debug and "ON" or "OFF") .. ".")
  elseif cmd == "applymutes" then
    applyMutes()
  elseif cmd == "clearmutes" then
    clearMutes()
  elseif cmd == "muteadd" then
    local fid = tonumber(rest)
    if not fid then
      msg("Usage: /res muteadd <fileDataID>")
      return
    end
    db.mute_file_data_ids[fid] = true
    MuteSoundFile(fid)
    msg(("Muted fileDataID %d."):format(fid))
  elseif cmd == "mutedel" then
    local fid = tonumber(rest)
    if not fid then
      msg("Usage: /res mutedel <fileDataID>")
      return
    end
    db.mute_file_data_ids[fid] = nil
    if not (autoMutedFIDs[fid] and autoMutedFIDs[fid] > 0) then
      UnmuteSoundFile(fid)
    end
    msg(("Unmuted fileDataID %d."):format(fid))
  elseif cmd == "mutelist" then
    msg("Muted fileDataIDs:")
    local n = 0
    for fid, enabled in pairs(db.mute_file_data_ids or {}) do
      if enabled then
        msg(("  %d"):format(fid))
        n = n + 1
      end
    end
    if n == 0 then msg("  (none)") end
  elseif cmd == "map" then
    local sid, fid = rest:match("^(%d+)%s+(%d+)$")
    sid = sid and tonumber(sid)
    fid = fid and tonumber(fid)
    if not sid or not fid then
      msg("Usage: /res map <spellID> <fileDataID>")
      return
    end
    db.spell_to_play_file_data_id[sid] = fid
    msg(("Mapped spellID %d -> fileDataID %d."):format(sid, fid))
  elseif cmd == "unmap" then
    local sid = tonumber(rest)
    if not sid then
      msg("Usage: /res unmap <spellID>")
      return
    end
    db.spell_to_play_file_data_id[sid] = nil
    msg(("Unmapped spellID %d."):format(sid))
  elseif cmd == "override" then
    local name, path = rest:match('^"(.-)"%s+(.+)$')
    if not name then
      name, path = rest:match("^(.-)%s+(.+)$")
    end
    if not name or not path then
      msg('Usage: /res override "Mortal Strike" sounds/vanilla/Mortal Strike.wav')
      return
    end
    db.local_file_overrides_by_spell_name[name] = path
    msg(("Override for '%s' -> %s"):format(name, path))
  elseif cmd == "clearoverride" then
    local name = rest
    if name and name:sub(1, 1) == '"' then
      name = name:match('^"(.-)"$') or name
    end
    if not name or name == "" then
      msg('Usage: /res clearoverride "Mortal Strike"')
      return
    end
    db.local_file_overrides_by_spell_name[name] = nil
    msg(("Cleared override for '%s'"):format(name))
  elseif cmd == "testspell" then
    local sid = tonumber(rest)
    if not sid then
      msg("Usage: /res testspell <spellID>")
      return
    end
    local name = getSpellName(sid) or ""
    msg(("Testing sound for: %s (spellID %d)"):format(name ~= "" and name or "<?>", sid))
    playResolvedSound(sid, name)
  elseif cmd == "sfx" then
    rest = (rest or ""):lower()
    if rest == "off" then
      SetCVar("Sound_EnableSFX", 0)
      msg("SFX disabled (you may lose footsteps).")
    else
      SetCVar("Sound_EnableSFX", 1)
      msg("SFX enabled.")
    end
  else
    msg("Commands:")
    msg("  /res                     Open settings panel")
    msg("  /res on|off")
    msg("  /res debug on|off")
    msg("  /res testspell <spellID>")
    msg("  /res muteadd <fileDataID>   /res mutedel <fileDataID>   /res mutelist")
    msg("  /res map <spellID> <fileDataID>   /res unmap <spellID>")
    msg('  /res override "Spell Name" <path>   /res clearoverride "Spell Name"')
    msg("  /res applymutes  /res clearmutes")
    msg("  /res sfx on|off")
  end
end
