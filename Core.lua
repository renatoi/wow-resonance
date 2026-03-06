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

local L = Resonance_L
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
    soundChannel = "Master",
    mute_file_data_ids = {},
    local_file_overrides_by_spell_name = {},
    spell_to_play_file_data_id = {},
    spell_config = {},
    preset_spells = {},   -- { [spellID] = presetName } tracks which spells came from presets
    saved_presets = {},   -- { [name] = { spells = {[sid]={sound,muteExclusions}}, mutes = {[fid]=true} } }
    muteVocalizations = "off",
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

local function playOneSoundWithUnmute(snd, dbg)
  local isMuted = type(snd) == "number" and (db.mute_file_data_ids[snd] or autoMutedFIDs[snd] or voxMutedFIDs[snd] or weaponMutedFIDs[snd])
  if dbg then msg(("  Playing: %s (muted: %s)"):format(tostring(snd), tostring(isMuted and true or false))) end
  if isMuted then
    local fid = snd
    -- WoW's MuteSoundFile is refcounted; unmute enough times to fully clear it
    -- (stale mute state can accumulate across reloads when FIDs appear in many spells' mute data)
    for _ = 1, 20 do UnmuteSoundFile(fid) end
    previewSound(fid)
    -- Re-mute after a delay so the sound has time to play, but only if still supposed to be muted
    C_Timer.After(0.5, function()
      if autoMutedFIDs[fid] and autoMutedFIDs[fid] > 0 then
        MuteSoundFile(fid)
      elseif db.mute_file_data_ids[fid] then
        MuteSoundFile(fid)
      elseif weaponMutedFIDs[fid] then
        MuteSoundFile(fid)
      elseif voxMutedFIDs[fid] then
        MuteSoundFile(fid)
      end
    end)
  else
    previewSound(snd)
  end
end

local function playResolvedSound(spellID, spellName)
  local dbg = db.debug

  -- 0) spell_config: unified per-spell configuration
  local cfg = db.spell_config and db.spell_config[spellID]
  if cfg and cfg.sound then
    -- Support single sound, table of sounds, or table with random pool
    local sounds = type(cfg.sound) == "table" and cfg.sound or { cfg.sound }
    if dbg then msg(("  spell_config: %d sound(s), channel: %s"):format(#sounds, getChannel())) end
    for _, snd in ipairs(sounds) do
      playOneSoundWithUnmute(snd, dbg)
    end
    -- Random pool: pick one at random from cfg.sound.random
    if type(cfg.sound) == "table" and cfg.sound.random then
      local pool = cfg.sound.random
      local pick = pool[math.random(1, #pool)]
      if dbg then msg(("  Random pool (%d): picked %s"):format(#pool, tostring(pick))) end
      playOneSoundWithUnmute(pick, dbg)
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

local function getVoxMode()
  local v = db.muteVocalizations
  if v == true then return "mine" end
  if v == false or v == "off" then return "off" end
  return v  -- "mine" or "all"
end

local function muteVoxEntry(voxEntry)
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
  return count
end

local function applyVoxMutes()
  local mode = getVoxMode()
  if mode == "off" then return end
  local count = 0
  if mode == "mine" then
    local voxEntry = getPlayerCSDEntry()
    if voxEntry then
      count = muteVoxEntry(voxEntry)
    end
  elseif mode == "all" then
    if Resonance_VoxFIDs then
      for _, voxEntry in pairs(Resonance_VoxFIDs) do
        count = count + muteVoxEntry(voxEntry)
      end
    end
  end
  if count > 0 then
    local label = mode == "all" and L["all races"] or L["your race/gender"]
    msg(L["Muted %d vocalization sounds (%s)."]:format(count, label))
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
    msg(L["Cleared %d vocalization mutes."]:format(count))
  end
end

local function refreshVoxMutes()
  clearVoxMutes()
  if db.enabled then applyVoxMutes() end
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
    msg(L["Muted %d weapon impact sounds."]:format(count))
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
    msg(L["Cleared %d weapon impact mutes."]:format(count))
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

-- Should we auto-mute for this spell? Only mute FIDs for spells that belong
-- to the player's own class (or custom / saved-preset spells). Spells from
-- other class templates would just silence those sounds for nearby players
-- with no benefit since UNIT_SPELLCAST_SUCCEEDED only fires for "player".
local function shouldAutoMuteSpell(spellID)
  local source = db.preset_spells and db.preset_spells[spellID]
  if not source then return true end                    -- custom spell, always mute
  if not (Resonance_ClassTemplates and Resonance_ClassTemplates[source]) then return true end  -- saved preset (not a class key)
  local _, myClass = UnitClass("player")
  return source == myClass
end

local function rebuildAutoMutes()
  -- Unmute all previously auto-muted FIDs before rebuilding.
  -- MuteSoundFile persists across /reload, so we must explicitly unmute
  -- any FIDs that were muted in the previous session but should no longer
  -- be muted (e.g., FIDs now in muteExclusions after a template update).
  for fid, refcount in pairs(autoMutedFIDs) do
    if refcount > 0 and not db.mute_file_data_ids[fid] and not voxMutedFIDs[fid] and not weaponMutedFIDs[fid] then
      UnmuteSoundFile(fid)
    end
  end
  wipe(autoMutedFIDs)
  for sid, _ in pairs(db.spell_config or {}) do
    if shouldAutoMuteSpell(sid) then
      local fids = Resonance_SpellMuteData and Resonance_SpellMuteData[sid]
      if fids then
        addAutoMuteFIDs(filterExclusions(fids, getExclusions(sid)))
      end
    end
  end
end

local function applyAutoMutesForSpell(spellID)
  if not shouldAutoMuteSpell(spellID) then return end
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
    msg(L["Applied %d sound mutes."]:format(count))
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
    msg(L["Cleared %d sound mutes."]:format(count))
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
-- Export / Import
---------------------------------------------------------------------------
local function encodePresetData(name, spells, mutes)
  local lines = { "V1" }
  if name and name ~= "" then
    lines[#lines + 1] = "N" .. name
  end
  for sid, cfg in pairs(spells or {}) do
    if cfg.sound then
      local val
      if type(cfg.sound) == "table" then
        local parts = {}
        for _, s in ipairs(cfg.sound) do parts[#parts + 1] = tostring(s) end
        -- Append random pool as R<fid>|<fid>|...
        if cfg.sound.random then
          local rParts = {}
          for _, s in ipairs(cfg.sound.random) do rParts[#rParts + 1] = tostring(s) end
          parts[#parts + 1] = "R" .. table.concat(rParts, "|")
        end
        val = table.concat(parts, ",")
      elseif type(cfg.sound) == "number" then
        val = tostring(cfg.sound)
      else
        val = '"' .. tostring(cfg.sound) .. '"'
      end
      lines[#lines + 1] = "S" .. sid .. "=" .. val
    else
      lines[#lines + 1] = "S" .. sid .. "="
    end
    if cfg.muteExclusions then
      local excl = {}
      for fid in pairs(cfg.muteExclusions) do excl[#excl + 1] = tostring(fid) end
      if #excl > 0 then
        lines[#lines + 1] = "X" .. sid .. ":" .. table.concat(excl, ",")
      end
    end
  end
  for fid in pairs(mutes or {}) do
    lines[#lines + 1] = "M" .. fid
  end
  local text = table.concat(lines, "\n")
  return "!Resonance!" .. b64encode(text)
end

local function decodePresetString(str)
  if not str or str == "" then return nil, L["Empty import string."] end
  str = str:match("^%s*(.-)%s*$")
  if str:sub(1, 11) ~= "!Resonance!" then
    return nil, L["Invalid format: missing !Resonance! prefix."]
  end
  local encoded = str:sub(12)
  local ok, decoded = pcall(b64decode, encoded)
  if not ok or not decoded or decoded == "" then
    return nil, L["Failed to decode import string."]
  end
  local lines = {}
  for line in decoded:gmatch("[^\n]+") do
    lines[#lines + 1] = line
  end
  if #lines == 0 or (lines[1] ~= "V1" and lines[1] ~= "V2") then
    return nil, L["Unknown format version."]
  end
  local name = nil
  local spells = {}
  local mutes = {}
  for i = 2, #lines do
    local line = lines[i]
    local tag = line:sub(1, 1)
    if tag == "N" then
      name = line:sub(2)
    elseif tag == "S" then
      local sid, val = line:match("^S(%d+)=(.*)")
      sid = tonumber(sid)
      if sid then
        local sound
        if val and val ~= "" then
          local quoted = val:match('^"(.*)"$')
          if quoted then
            sound = quoted
          elseif val:find(",") then
            -- Multiple comma-separated FIDs, may contain R<fid>|<fid> random pool
            sound = {}
            for part in val:gmatch("[^,]+") do
              local rPool = part:match("^R(.+)$")
              if rPool then
                sound.random = {}
                for fidStr in rPool:gmatch("(%d+)") do
                  sound.random[#sound.random + 1] = tonumber(fidStr)
                end
              else
                local n = tonumber(part)
                if n then sound[#sound + 1] = n end
              end
            end
            if #sound == 1 and not sound.random then sound = sound[1] end
            if #sound == 0 and not sound.random then sound = nil end
          else
            sound = tonumber(val)
          end
        end
        spells[sid] = { sound = sound }
      end
    elseif tag == "X" then
      local sid, fidList = line:match("^X(%d+):(.+)$")
      sid = tonumber(sid)
      if sid and fidList and spells[sid] then
        local exclusions = spells[sid].muteExclusions or {}
        for fidStr in fidList:gmatch("(%d+)") do
          exclusions[tonumber(fidStr)] = true
        end
        spells[sid].muteExclusions = exclusions
      end
    elseif tag == "M" then
      local fid = tonumber(line:sub(2))
      if fid then mutes[fid] = true end
    end
  end
  return name, { spells = spells, mutes = mutes }
end

function Resonance:ExportConfig(name)
  local spells = {}
  for sid, cfg in pairs(db.spell_config or {}) do
    local entry = { sound = cfg.sound }
    if cfg.muteExclusions then
      entry.muteExclusions = {}
      for fid in pairs(cfg.muteExclusions) do
        entry.muteExclusions[fid] = true
      end
    end
    spells[sid] = entry
  end
  local mutes = {}
  for fid, enabled in pairs(db.mute_file_data_ids or {}) do
    if enabled then mutes[fid] = true end
  end
  return encodePresetData(name, spells, mutes)
end

function Resonance:ImportConfig(str)
  local name, result = decodePresetString(str)
  if not name and type(result) == "string" then
    return nil, result
  end
  if not result or type(result) ~= "table" then
    return nil, L["Failed to parse import string."]
  end
  local added, skipped, addedMutes = 0, 0, 0
  for sid, cfg in pairs(result.spells or {}) do
    if db.spell_config[sid] then
      skipped = skipped + 1
    else
      db.spell_config[sid] = { sound = cfg.sound, muteExclusions = cfg.muteExclusions }
      applyAutoMutesForSpell(sid)
      added = added + 1
    end
  end
  for fid in pairs(result.mutes or {}) do
    if not db.mute_file_data_ids[fid] then
      db.mute_file_data_ids[fid] = true
      MuteSoundFile(fid)
      addedMutes = addedMutes + 1
    end
  end
  return added, skipped, addedMutes
end

---------------------------------------------------------------------------
-- Preset management
---------------------------------------------------------------------------
function Resonance:ImportToPreset(str)
  local name, result = decodePresetString(str)
  if not name and type(result) == "string" then
    return nil, result
  end
  if not result or type(result) ~= "table" then
    return nil, L["Failed to parse import string."]
  end
  if not name or name == "" then
    local idx = 1
    repeat
      name = "Imported Preset" .. (idx > 1 and (" " .. idx) or "")
      idx = idx + 1
    until not db.saved_presets[name]
  end
  return name, result
end

function Resonance:SaveCurrentAsPreset(name)
  if not name or name == "" then return false end
  local preset = { spells = {}, mutes = {} }
  for sid, cfg in pairs(db.spell_config or {}) do
    local entry = { sound = cfg.sound }
    if cfg.muteExclusions then
      entry.muteExclusions = {}
      for fid in pairs(cfg.muteExclusions) do
        entry.muteExclusions[fid] = true
      end
    end
    preset.spells[sid] = entry
  end
  for fid, enabled in pairs(db.mute_file_data_ids or {}) do
    if enabled then preset.mutes[fid] = true end
  end
  db.saved_presets[name] = preset
  return true
end

function Resonance:ApplySavedPreset(name)
  local preset = db.saved_presets[name]
  if not preset then return 0, 0, 0 end
  local added, skipped, addedMutes = 0, 0, 0
  for sid, cfg in pairs(preset.spells or {}) do
    if db.spell_config[sid] then
      skipped = skipped + 1
    else
      local newCfg = { sound = cfg.sound }
      if cfg.muteExclusions then
        newCfg.muteExclusions = {}
        for fid in pairs(cfg.muteExclusions) do
          newCfg.muteExclusions[fid] = true
        end
      end
      db.spell_config[sid] = newCfg
      db.preset_spells[sid] = name
      applyAutoMutesForSpell(sid)
      added = added + 1
    end
  end
  for fid in pairs(preset.mutes or {}) do
    if not db.mute_file_data_ids[fid] then
      db.mute_file_data_ids[fid] = true
      MuteSoundFile(fid)
      addedMutes = addedMutes + 1
    end
  end
  return added, skipped, addedMutes
end

function Resonance:DeleteSavedPreset(name)
  if not name then return end
  db.saved_presets[name] = nil
end

function Resonance:ExportPresetData(name, presetData)
  return encodePresetData(name, presetData.spells, presetData.mutes)
end

function Resonance:ClassPresetToData(classKey)
  local template = Resonance_ClassTemplates and Resonance_ClassTemplates[classKey]
  if not template then return nil end
  local data = { spells = {}, mutes = {} }
  for _, entry in ipairs(template) do
    local spell = { sound = entry.sound }
    if entry.muteExclusions then
      spell.muteExclusions = {}
      for _, fid in ipairs(entry.muteExclusions) do
        spell.muteExclusions[fid] = true
      end
    end
    data.spells[entry.spellID] = spell
  end
  return data
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
Resonance.shouldAutoMuteSpell = shouldAutoMuteSpell
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
      local cfg = { sound = entry.sound }
      if entry.muteExclusions then
        cfg.muteExclusions = {}
        for _, fid in ipairs(entry.muteExclusions) do
          cfg.muteExclusions[fid] = true
        end
      end
      db.spell_config[sid] = cfg
      db.preset_spells[sid] = classKey
      applyAutoMutesForSpell(sid)
      added = added + 1
    end
  end
  return added, skipped
end

-- Refresh preset spells to match current template values (runs on load)
-- Updates sound and muteExclusions from template; preserves user's additional unmutes
-- Also auto-adds new template spells for classes the user has already loaded
local function refreshPresetsFromTemplates()
  if not Resonance_ClassTemplates then return end
  local updated, added = 0, 0

  -- Collect which class templates the user has loaded
  local loadedClasses = {}
  for _, source in pairs(db.preset_spells) do
    loadedClasses[source] = true
  end

  -- Update existing preset spells
  for sid, source in pairs(db.preset_spells) do
    local template = Resonance_ClassTemplates[source]
    if template then
      for _, entry in ipairs(template) do
        if entry.spellID == sid then
          local cfg = db.spell_config[sid]
          if cfg then
            -- Update sound and muteExclusions from template (template is source of truth)
            cfg.sound = entry.sound
            if entry.muteExclusions then
              cfg.muteExclusions = {}
              for _, fid in ipairs(entry.muteExclusions) do
                cfg.muteExclusions[fid] = true
              end
            else
              cfg.muteExclusions = nil
            end
            updated = updated + 1
          end
          break
        end
      end
    end
  end

  -- Auto-add new template spells for classes already loaded
  for classKey in pairs(loadedClasses) do
    local template = Resonance_ClassTemplates[classKey]
    if template then
      for _, entry in ipairs(template) do
        local sid = entry.spellID
        if not db.spell_config[sid] then
          local cfg = { sound = entry.sound }
          if entry.muteExclusions then
            cfg.muteExclusions = {}
            for _, fid in ipairs(entry.muteExclusions) do
              cfg.muteExclusions[fid] = true
            end
          end
          db.spell_config[sid] = cfg
          db.preset_spells[sid] = classKey
          added = added + 1
        end
      end
    end
  end

  if updated > 0 or added > 0 then
    rebuildAutoMutes()
    if added > 0 then
      msg(L["%d new template spell(s) auto-added."]:format(added))
    end
  end
end

function Resonance:RemovePresetSpells(presetName)
  local removed = 0
  local toRemove = {}
  for sid, source in pairs(db.preset_spells) do
    if not presetName or source == presetName then
      toRemove[#toRemove + 1] = sid
    end
  end
  for _, sid in ipairs(toRemove) do
    removeAutoMutesForSpell(sid)
    db.spell_config[sid] = nil
    db.preset_spells[sid] = nil
    removed = removed + 1
  end
  return removed
end

---------------------------------------------------------------------------
-- AceConfig options table (General tab)
---------------------------------------------------------------------------
local function getGeneralOptions()
  return {
    type = "group",
    name = L["General"],
    args = {
      enabled = {
        type = "toggle",
        name = L["Enable Resonance"],
        desc = L["Toggle the addon on/off. When disabled, all sound mutes are removed and no custom spell sounds play."],
        order = 1,
        width = "full",
        get = function() return db.enabled end,
        set = function(_, v)
          db.enabled = v
          if v then
            applyMutes()
            if getVoxMode() ~= "off" then applyVoxMutes() end
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
        name = L["Debug mode (print casts to chat)"],
        desc = L["Print spell cast details (name, ID) to chat on each cast. Useful for finding spell IDs to configure."],
        order = 2,
        width = "full",
        get = function() return db.debug end,
        set = function(_, v) db.debug = v end,
      },
      showMinimap = {
        type = "toggle",
        name = L["Show minimap button"],
        desc = L["Show a minimap button. Left-click opens options, right-click toggles addon on/off, drag to reposition."],
        order = 3,
        width = "full",
        get = function() return not db.minimap.hide end,
        set = function(_, v) Resonance.toggleMinimapButton(v) end,
      },
      muteWeaponImpacts = {
        type = "toggle",
        name = L["Mute weapon impact sounds"],
        desc = L["Mute all weapon impact and swing sounds (the melee hit thwack/clang). Applies globally regardless of weapon type."],
        order = 4,
        width = "full",
        get = function() return db.muteWeaponImpacts end,
        set = function(_, v)
          db.muteWeaponImpacts = v
          if v then if db.enabled then applyWeaponMutes() end else clearWeaponMutes() end
        end,
      },
      muteVocalizations = {
        type = "select",
        name = L["Mute character vocalizations"],
        desc = L["Mute combat grunts, shouts, and exertion sounds. 'Mine' mutes your own race/gender, 'All races' mutes every race/gender in the game."],
        order = 5,
        values = {
          off = L["Off"],
          mine = L["Mine"],
          all = L["All races"],
        },
        sorting = { "off", "mine", "all" },
        get = function() return getVoxMode() end,
        set = function(_, v)
          db.muteVocalizations = v
          refreshVoxMutes()
        end,
      },
      soundChannel = {
        type = "select",
        name = L["Replacement sound channel"],
        desc = L["Which audio channel to play replacement spell sounds on. Use 'Master' to always hear them regardless of other volume sliders."],
        order = 6,
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
        if getVoxMode() ~= "off" then applyVoxMutes() end
        if db.muteWeaponImpacts then applyWeaponMutes() end
      else
        clearVoxMutes()
        clearWeaponMutes()
        clearMutes()
      end
      msg(db.enabled and L["Enabled."] or L["Disabled."])
    else
      if Resonance.openOptions then Resonance.openOptions() end
    end
  end,
  OnTooltipShow = function(tt)
    tt:AddLine("Resonance")
    tt:AddLine(L["Left-click: Open options"], 1, 1, 1)
    tt:AddLine(L["Right-click: Toggle on/off"], 1, 1, 1)
    tt:AddLine(L["Drag: Move button"], 0.7, 0.7, 0.7)
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
  local simpleKeys = { "enabled", "debug", "soundChannel" }
  for _, k in ipairs(simpleKeys) do
    if src[k] ~= nil then dest[k] = src[k] end
  end

  local tableKeys = { "mute_file_data_ids", "local_file_overrides_by_spell_name",
                       "spell_to_play_file_data_id", "spell_config", "minimap" }
  for _, k in ipairs(tableKeys) do
    if src[k] then dest[k] = src[k] end
  end

  -- Don't copy auto_muted_fids — it's runtime-only now

  msg(L["Migrated settings from CastSoundsDB. You can disable the old CastSounds addon."])
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
    if getVoxMode() ~= "off" then applyVoxMutes() end
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
  self:RegisterEvent("UNIT_MODEL_CHANGED")
  refreshPresetsFromTemplates()
  rebuildAutoMutes()
  if db.enabled then applyMutes() end
  if getVoxMode() ~= "off" then applyVoxMutes() end
  if db.muteWeaponImpacts then applyWeaponMutes() end
  msg(L["Loaded. Type /res or go to Esc > Options > Addons > Resonance."])
end

---------------------------------------------------------------------------
-- Event handler
---------------------------------------------------------------------------
function Resonance:UNIT_MODEL_CHANGED(_, unit)
  if unit ~= "player" then return end
  -- Player changed appearance (barbershop gender change, etc.) — re-apply vox mutes
  -- Only relevant for "mine" mode; "all" already covers everything
  if getVoxMode() == "mine" then
    refreshVoxMutes()
  end
end

function Resonance:UNIT_SPELLCAST_SUCCEEDED(_, unit, _, spellID)
  if unit ~= "player" then return end
  if not spellID then return end
  if not shouldTriggerForSpell(spellID) then return end

  local spellName = getSpellName(spellID) or ""

  if db.debug then
    msg(("Cast: %s (spellID %d)"):format(spellName ~= "" and spellName or "<?>", spellID))
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
      msg(L["Options panel not loaded."])
    end
    return
  elseif cmd == "on" then
    db.enabled = true
    applyMutes()
    if getVoxMode() ~= "off" then applyVoxMutes() end
    if db.muteWeaponImpacts then applyWeaponMutes() end
    msg(L["Enabled."])
  elseif cmd == "off" then
    db.enabled = false
    clearVoxMutes()
    clearWeaponMutes()
    clearMutes()
    msg(L["Disabled."])
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
      msg(L["Usage: /res muteadd <fileDataID>"])
      return
    end
    db.mute_file_data_ids[fid] = true
    MuteSoundFile(fid)
    msg(L["Muted fileDataID %d."]:format(fid))
  elseif cmd == "mutedel" then
    local fid = tonumber(rest)
    if not fid then
      msg(L["Usage: /res mutedel <fileDataID>"])
      return
    end
    db.mute_file_data_ids[fid] = nil
    if not (autoMutedFIDs[fid] and autoMutedFIDs[fid] > 0) then
      UnmuteSoundFile(fid)
    end
    msg(L["Unmuted fileDataID %d."]:format(fid))
  elseif cmd == "mutelist" then
    msg(L["Muted fileDataIDs:"])
    local n = 0
    for fid, enabled in pairs(db.mute_file_data_ids or {}) do
      if enabled then
        msg(("  %d"):format(fid))
        n = n + 1
      end
    end
    if n == 0 then msg(L["  (none)"]) end
  elseif cmd == "map" then
    local sid, fid = rest:match("^(%d+)%s+(%d+)$")
    sid = sid and tonumber(sid)
    fid = fid and tonumber(fid)
    if not sid or not fid then
      msg(L["Usage: /res map <spellID> <fileDataID>"])
      return
    end
    db.spell_to_play_file_data_id[sid] = fid
    msg(L["Mapped spellID %d -> fileDataID %d."]:format(sid, fid))
  elseif cmd == "unmap" then
    local sid = tonumber(rest)
    if not sid then
      msg(L["Usage: /res unmap <spellID>"])
      return
    end
    db.spell_to_play_file_data_id[sid] = nil
    msg(L["Unmapped spellID %d."]:format(sid))
  elseif cmd == "override" then
    local name, path = rest:match('^"(.-)"%s+(.+)$')
    if not name then
      name, path = rest:match("^(.-)%s+(.+)$")
    end
    if not name or not path then
      msg(L['Usage: /res override "Mortal Strike" sounds/vanilla/Mortal Strike.wav'])
      return
    end
    db.local_file_overrides_by_spell_name[name] = path
    msg(L["Override for '%s' -> %s"]:format(name, path))
  elseif cmd == "clearoverride" then
    local name = rest
    if name and name:sub(1, 1) == '"' then
      name = name:match('^"(.-)"$') or name
    end
    if not name or name == "" then
      msg(L['Usage: /res clearoverride "Mortal Strike"'])
      return
    end
    db.local_file_overrides_by_spell_name[name] = nil
    msg(L["Cleared override for '%s'"]:format(name))
  elseif cmd == "testspell" then
    local sid = tonumber(rest)
    if not sid then
      msg(L["Usage: /res testspell <spellID>"])
      return
    end
    local name = getSpellName(sid) or ""
    msg(L["Testing sound for: %s (spellID %d)"]:format(name ~= "" and name or "<?>", sid))
    playResolvedSound(sid, name)
  elseif cmd == "diag" then
    msg(L["=== Resonance Diagnostics ==="])
    local libs = {
      "LibStub", "CallbackHandler-1.0",
      "AceAddon-3.0", "AceDB-3.0", "AceDBOptions-3.0",
      "AceEvent-3.0", "AceConsole-3.0",
      "AceConfigRegistry-3.0", "AceConfigCmd-3.0",
      "AceConfigDialog-3.0", "AceConfig-3.0",
      "AceGUI-3.0",
      "LibDataBroker-1.1", "LibDBIcon-1.0",
    }
    for _, name in ipairs(libs) do
      if name == "LibStub" then
        local ok = _G.LibStub ~= nil
        msg(("  %s: %s"):format(name, ok and "|cff00ff00OK|r" or "|cffff0000MISSING|r"))
      else
        local lib, minor = LibStub:GetLibrary(name, true)
        if lib then
          msg(("  %s: |cff00ff00v%s|r"):format(name, tostring(minor or "?")))
        else
          msg(("  %s: |cffff0000NOT LOADED|r"):format(name))
        end
      end
    end
    -- Check AceGUI widget types
    local aceGUI = LibStub:GetLibrary("AceGUI-3.0", true)
    if aceGUI then
      local widgets = { "SimpleGroup", "Button", "CheckBox", "Dropdown", "Label", "Slider", "EditBox", "Heading" }
      msg("  AceGUI widgets:")
      for _, wtype in ipairs(widgets) do
        local ok, w = pcall(function() return aceGUI:Create(wtype) end)
        if ok and w then
          aceGUI:Release(w)
          msg(("    %s: |cff00ff00OK|r"):format(wtype))
        else
          msg(("    %s: |cffff0000FAILED|r %s"):format(wtype, ok and "" or tostring(w)))
        end
      end
    end
    msg("  Settings API: " .. (Settings and Settings.RegisterCanvasLayoutCategory and "|cff00ff00OK|r" or "|cffff0000MISSING|r"))
    msg("  Spell mute data: " .. (Resonance_SpellMuteData and ("|cff00ff00" .. tostring(#(Resonance_SpellMuteData or {})) .. " (table)|r") or "|cffff0000NOT LOADED|r"))
    msg("  Vox data: " .. (Resonance_VoxFIDs and "|cff00ff00loaded|r" or "|cffffff00not loaded|r"))
    msg(L["=== End Diagnostics ==="])
  elseif cmd == "sfx" then
    rest = (rest or ""):lower()
    if rest == "off" then
      SetCVar("Sound_EnableSFX", 0)
      msg(L["SFX disabled (you may lose footsteps)."])
    else
      SetCVar("Sound_EnableSFX", 1)
      msg(L["SFX enabled."])
    end
  else
    msg(L["Commands:"])
    msg(L["  /res                     Open settings panel"])
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
