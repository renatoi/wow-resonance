local Resonance = LibStub("AceAddon-3.0"):GetAddon("Resonance")
local L = Resonance_L

-- Localize Lua built-ins and WoW API functions to avoid per-call
-- _G hash lookups (same rationale as Core.lua).
local type       = type
local tostring   = tostring
local tonumber   = tonumber
local pairs      = pairs
local ipairs     = ipairs
local pcall      = pcall
local wipe       = wipe
local unpack     = unpack
local math       = math
local string     = string
local table      = table
local coroutine  = coroutine

local MuteSoundFile   = MuteSoundFile
local UnmuteSoundFile = UnmuteSoundFile
local PlaySoundFile   = PlaySoundFile
local IsPlayerSpell   = IsPlayerSpell
local C_Timer         = C_Timer

local MAX_MUTE_DEPTH = Resonance.MAX_MUTE_DEPTH

---------------------------------------------------------------------------
-- Sound database search (coroutine-based to avoid frame hitches on large DBs)
---------------------------------------------------------------------------
local SEARCH_BATCH_SIZE = 2000  -- entries per frame before yielding

local activeSearches = {}  -- key -> { co, ticker, callback, id }
local searchGeneration = {}  -- key -> monotonic counter to detect stale results

local function cancelSearch(key)
  local s = activeSearches[key]
  if s then
    if s.ticker then s.ticker:Cancel() end
    activeSearches[key] = nil
  end
end

local function searchDB(sourceDB, query, key, callback, prefixPool, l10nTable, extraMatchFn)
  cancelSearch(key)
  if not sourceDB then callback({}); return end
  local terms = {}
  for word in query:lower():gmatch("%S+") do
    terms[#terms + 1] = word
  end
  if #terms == 0 then callback({}); return end

  searchGeneration[key] = (searchGeneration[key] or 0) + 1
  local gen = searchGeneration[key]

  -- Pre-lowercase prefix pool once to avoid per-entry allocation
  local lowerPrefixes
  if prefixPool then
    lowerPrefixes = {}
    for idx, p in ipairs(prefixPool) do
      lowerPrefixes[idx] = p:lower()
    end
  end

  local co = coroutine.create(function()
    local results = {}
    for i, entry in ipairs(sourceDB) do
      if prefixPool then
        -- Prefix-pooled format: "filename#FID#prefixIdx"
        -- Match against filename and prefix separately to avoid
        -- concatenating a full path string for every entry.
        local fn, fidStr, pIdx = entry:match("([^#]+)#([^#]+)#([^#]+)")
        if fn and fidStr and pIdx then
          local lfn = fn:lower()
          local idx = tonumber(pIdx)
          local lprefix = idx and lowerPrefixes[idx] or ""
          local match = true
          for _, t in ipairs(terms) do
            if not lfn:find(t, 1, true) and not lprefix:find(t, 1, true) then
              match = false; break
            end
          end
          if match then
            local prefix = idx and prefixPool[idx] or ""
            results[#results + 1] = { path = prefix .. fn, fileDataID = tonumber(fidStr) }
          end
        end
      else
        local path, fid = entry:match("([^#]+)#([^#]+)")
        if path and fid then
          local lp = path:lower()
          local match = true
          for _, t in ipairs(terms) do
            if not lp:find(t, 1, true) then match = false; break end
          end
          -- For NPC search: also check L10N table if English name didn't match
          if not match and l10nTable then
            local npcID = tonumber(fid)
            local l10n = npcID and l10nTable[npcID]
            if l10n then
              local ll = l10n:lower()
              match = true
              for _, t in ipairs(terms) do
                if not ll:find(t, 1, true) then match = false; break end
              end
            end
          end
          if not match and extraMatchFn then
            match = extraMatchFn(tonumber(fid), terms)
          end
          if match then
            results[#results + 1] = { path = path, fileDataID = tonumber(fid) }
          end
        end
      end
      if i % SEARCH_BATCH_SIZE == 0 then coroutine.yield() end
    end
    return results
  end)

  local ticker
  local function step()
    if searchGeneration[key] ~= gen then
      if ticker then ticker:Cancel() end
      activeSearches[key] = nil
      return
    end
    local ok, results = coroutine.resume(co)
    if not ok then
      activeSearches[key] = nil
      if ticker then ticker:Cancel() end
      if Resonance.db and Resonance.db.profile.debug then
        Resonance.msg("Search error (" .. key .. "): " .. tostring(results))
      end
      callback({})
    elseif coroutine.status(co) == "dead" then
      activeSearches[key] = nil
      if ticker then ticker:Cancel() end
      callback(results or {})
    end
  end

  -- Run the first batch immediately for responsiveness
  step()
  if coroutine.status(co) ~= "dead" then
    ticker = C_Timer.NewTicker(0.01, step)
    activeSearches[key] = { co = co, ticker = ticker, gen = gen }
  end
end

local function hasSpellDB() return Resonance.SpellSounds and #Resonance.SpellSounds > 0 end
local function hasCharDB() return Resonance.CharacterSounds and #Resonance.CharacterSounds > 0 end

local function formatSoundDisplay(path, fid)
  local filename = path:match("([^/\\]+)$") or path
  local parent = path:match("([^/\\]+)[/\\][^/\\]+$")
  if parent then
    return filename .. "  |cff999999" .. parent .. "/|r  |cff808080#" .. fid .. "|r"
  end
  return filename .. "  |cff808080#" .. fid .. "|r"
end

-- Reverse lookup: FID -> path (built lazily, cached)
local fidPathCache
local function lookupFIDPath(fid)
  if not fidPathCache then
    fidPathCache = {}
    local dbs = {
      { Resonance.SpellSounds, Resonance.SpellSoundPrefixes },
      { Resonance.CharacterSounds, Resonance.CharacterSoundPrefixes },
    }
    for _, pair in ipairs(dbs) do
      local entries, prefixes = pair[1], pair[2]
      if entries then
        if prefixes then
          for _, entry in ipairs(entries) do
            local fn, id, pIdx = entry:match("([^#]+)#([^#]+)#([^#]+)")
            if fn and id and pIdx then
              local idx = tonumber(pIdx)
              local prefix = idx and prefixes[idx] or ""
              fidPathCache[tonumber(id)] = prefix .. fn
            end
          end
        else
          for _, entry in ipairs(entries) do
            local path, id = entry:match("([^#]+)#([^#]+)")
            if path and id then fidPathCache[tonumber(id)] = path end
          end
        end
      end
    end
  end
  return fidPathCache[fid]
end

---------------------------------------------------------------------------
-- Race/gender mapping for vocalization search
---------------------------------------------------------------------------
local RACE_SOUND_KEYS = {
  Human = "human", Orc = "orc", Dwarf = "dwarf",
  NightElf = "nightelf", Scourge = "undead", Tauren = "tauren",
  Gnome = "gnome", Troll = "troll", BloodElf = "bloodelf",
  Draenei = "draenei", Worgen = "worgen", Goblin = "goblin",
  Pandaren = "pandaren", Nightborne = "nightborne",
  HighmountainTauren = "highmountain", VoidElf = "void_elf",
  LightforgedDraenei = "lightforged", ZandalariTroll = "zandalari",
  KulTiran = "kul_tiran", MagharOrc = "maghar",
  DarkIronDwarf = "dark_iron", Mechagnome = "mechagnome",
  Vulpera = "vulpera", Dracthyr = "dracthyr", Earthen = "earthen",
}
local GENDER_KEYS = { [2] = "male", [3] = "female" }

local function getPlayerVoxKey()
  local _, engRace = UnitRace("player")
  local gender = UnitSex("player")
  local rk = RACE_SOUND_KEYS[engRace] or engRace:lower()
  local gk = GENDER_KEYS[gender] or "male"
  return rk .. gk
end

---------------------------------------------------------------------------
-- Preview-safe play (temporarily unmutes if needed)
---------------------------------------------------------------------------
local function isFIDMuted(fid)
  local profile = Resonance.db.profile
  if profile.mute_file_data_ids and profile.mute_file_data_ids[fid] then return true end
  if Resonance.autoMutedFIDs and (Resonance.autoMutedFIDs[fid] or 0) > 0 then return true end
  if Resonance.voxMutedFIDs and Resonance.voxMutedFIDs[fid] then return true end
  if Resonance.weaponMutedFIDs and Resonance.weaponMutedFIDs[fid] then return true end
  if Resonance.creatureMutedFIDs and Resonance.creatureMutedFIDs[fid] then return true end
  if Resonance.professionMutedFIDs and Resonance.professionMutedFIDs[fid] then return true end
  if Resonance.fishingMutedFIDs and Resonance.fishingMutedFIDs[fid] then return true end
  if Resonance.npcMutedFIDs and Resonance.npcMutedFIDs[fid] then return true end
  return false
end

local function safePlaySound(value)
  if not value then return nil end
  local fid = tonumber(value)
  local willPlay, handle
  if fid then
    for _ = 1, MAX_MUTE_DEPTH do UnmuteSoundFile(fid) end
    willPlay, handle = PlaySoundFile(fid, "Master")
    -- Re-mute once per active source instead of MAX_MUTE_DEPTH times
    -- to avoid inflating WoW's internal refcount (which would leave
    -- sounds permanently muted after the preview).
    if isFIDMuted(fid) then
      C_Timer.After(0.5, function()
        local p = Resonance.db.profile
        if p.mute_file_data_ids and p.mute_file_data_ids[fid] then MuteSoundFile(fid) end
        if Resonance.autoMutedFIDs and (Resonance.autoMutedFIDs[fid] or 0) > 0 then MuteSoundFile(fid) end
        if Resonance.voxMutedFIDs and Resonance.voxMutedFIDs[fid] then MuteSoundFile(fid) end
        if Resonance.weaponMutedFIDs and Resonance.weaponMutedFIDs[fid] then MuteSoundFile(fid) end
        if Resonance.creatureMutedFIDs and Resonance.creatureMutedFIDs[fid] then MuteSoundFile(fid) end
        if Resonance.professionMutedFIDs and Resonance.professionMutedFIDs[fid] then MuteSoundFile(fid) end
        if Resonance.fishingMutedFIDs and Resonance.fishingMutedFIDs[fid] then MuteSoundFile(fid) end
        if Resonance.npcMutedFIDs and Resonance.npcMutedFIDs[fid] then MuteSoundFile(fid) end
      end)
    end
  else
    willPlay, handle = PlaySoundFile(value, "Master")
  end
  return handle
end

-- Play/Stop toggle state
local activePreviewBtn    -- currently playing button (only one at a time)
local activePreviewHandles = {}
local activePreviewTimer   -- auto-reset timer

local function resetPreviewBtn()
  if activePreviewBtn and activePreviewBtn.icon then
    activePreviewBtn.icon:SetVertexColor(1, 1, 1)
  end
  activePreviewBtn = nil
end

local function stopAllPreviews()
  for _, h in ipairs(activePreviewHandles) do
    StopSound(h, 0)
  end
  wipe(activePreviewHandles)
  if activePreviewTimer then
    activePreviewTimer:Cancel()
    activePreviewTimer = nil
  end
  resetPreviewBtn()
end

-- Wire an icon button as a Play/Stop toggle. getSoundFn() returns the value(s) to play.
local function wirePlayStop(btn, getSoundFn)
  btn:SetScript("OnClick", function()
    if activePreviewBtn == btn then
      -- Already playing: stop
      stopAllPreviews()
      return
    end
    -- Stop any other preview first
    stopAllPreviews()
    -- Play new sound(s)
    local snd = getSoundFn()
    if type(snd) == "table" then
      for _, s in ipairs(snd) do
        local h = safePlaySound(s)
        if h then activePreviewHandles[#activePreviewHandles + 1] = h end
      end
      if snd.random and #snd.random > 0 then
        local pick = snd.random[math.random(1, #snd.random)]
        local h = safePlaySound(pick)
        if h then activePreviewHandles[#activePreviewHandles + 1] = h end
      end
    else
      local h = safePlaySound(snd)
      if h then activePreviewHandles[#activePreviewHandles + 1] = h end
    end
    if #activePreviewHandles > 0 then
      activePreviewBtn = btn
      -- Tint green to indicate playing (distinct from delete/remove icons)
      btn.icon:SetVertexColor(0.3, 1, 0.3)
      -- Auto-reset after sound likely finishes (most spell sounds are 1-3s)
      activePreviewTimer = C_Timer.NewTimer(5, function()
        activePreviewTimer = nil
        wipe(activePreviewHandles)
        resetPreviewBtn()
      end)
    end
  end)
end

---------------------------------------------------------------------------
-- Spell search — async cache of player-known spells
--
-- Building the cache requires ~170k C_Spell.GetSpellName() calls which
-- would freeze the client for several seconds if done synchronously.
-- We use a coroutine that yields every SPELL_CACHE_BATCH entries,
-- spreading the work across frames with a 10ms ticker.
-- The cache starts building proactively on panel OnShow so it's usually
-- ready before the user starts typing.
---------------------------------------------------------------------------
local playerSpellCache       -- nil = not started; table = building or ready
local spellCacheBusy = false -- true while the coroutine is running
local spellCacheTicker       -- C_Timer ticker driving the build coroutine
local spellCacheCallbacks = {} -- functions to call when build finishes
local SPELL_CACHE_BATCH = 5000

local function startBuildPlayerSpellCache(onComplete)
  if playerSpellCache and not spellCacheBusy then
    if onComplete then onComplete() end
    return
  end
  if onComplete then
    spellCacheCallbacks[#spellCacheCallbacks + 1] = onComplete
  end
  if spellCacheBusy then return end

  spellCacheBusy = true
  playerSpellCache = {}
  local seen = {}
  local getName = C_Spell and C_Spell.GetSpellName

  local co = coroutine.create(function()
    -- Primary source: all spells with mute data
    if Resonance.SpellMuteData and getName then
      local count = 0
      for sid in pairs(Resonance.SpellMuteData) do
        if not seen[sid] then
          local ok, name = pcall(getName, sid)
          if ok and name and name ~= "" then
            seen[sid] = true
            playerSpellCache[#playerSpellCache + 1] = { spellID = sid, name = name, known = IsPlayerSpell(sid) }
          end
        end
        count = count + 1
        if count % SPELL_CACHE_BATCH == 0 then coroutine.yield() end
      end
    end

    -- Secondary source: spellbook (catches spells without mute data)
    if C_SpellBook and C_SpellBook.GetNumSpellBookItems and Enum and Enum.SpellBookSpellBank then
      local ok, numSpells = pcall(C_SpellBook.GetNumSpellBookItems, Enum.SpellBookSpellBank.Player)
      if ok and numSpells then
        for i = 1, numSpells do
          local ok2, info = pcall(C_SpellBook.GetSpellBookItemInfo, i, Enum.SpellBookSpellBank.Player)
          if ok2 and info then
            local sid = info.spellID or info.actionID
            if sid and not seen[sid] then
              local name = (getName and getName(sid)) or info.name
              if name and name ~= "" then
                seen[sid] = true
                playerSpellCache[#playerSpellCache + 1] = { spellID = sid, name = name }
              end
            end
          end
        end
      end
    end

    -- Tertiary source: talent-transformed spell overrides (e.g. Raging Blow → Crushing Blow)
    local getOverride = C_Spell and C_Spell.GetOverrideSpell
    if getOverride and getName then
      local base = {}
      for _, entry in ipairs(playerSpellCache) do
        base[#base + 1] = entry.spellID
      end
      for _, sid in ipairs(base) do
        local ok, overrideID = pcall(getOverride, sid)
        if ok and overrideID and overrideID ~= sid and not seen[overrideID] then
          local name = getName(overrideID)
          if name and name ~= "" then
            seen[overrideID] = true
            playerSpellCache[#playerSpellCache + 1] = { spellID = overrideID, name = name }
          end
        end
      end
    end
  end)

  local function step()
    local ok, err = coroutine.resume(co)
    if not ok then
      -- Coroutine errored: log in debug mode and reset the cache so
      -- searchSpells returns nil (triggering the "Loading..." state)
      -- rather than serving partial results.
      if spellCacheTicker then spellCacheTicker:Cancel(); spellCacheTicker = nil end
      spellCacheBusy = false
      playerSpellCache = nil
      if Resonance.db and Resonance.db.profile.debug then
        Resonance.msg("Spell cache error: " .. tostring(err))
      end
      wipe(spellCacheCallbacks)
      return
    end
    if coroutine.status(co) == "dead" then
      if spellCacheTicker then spellCacheTicker:Cancel(); spellCacheTicker = nil end
      spellCacheBusy = false
      local pending = { unpack(spellCacheCallbacks) }
      wipe(spellCacheCallbacks)
      for _, cb in ipairs(pending) do cb() end
    end
  end

  step()
  if spellCacheBusy then
    spellCacheTicker = C_Timer.NewTicker(0.01, step)
  end
end

local function invalidateSpellCache()
  if spellCacheTicker then spellCacheTicker:Cancel(); spellCacheTicker = nil end
  spellCacheBusy = false
  wipe(spellCacheCallbacks)
  playerSpellCache = nil
  fidPathCache = nil
end

local function searchSpells(query)
  if not playerSpellCache or spellCacheBusy then return nil end
  local results = {}
  local terms = {}
  for word in query:lower():gmatch("%S+") do terms[#terms + 1] = word end
  if #terms == 0 then return results end

  for _, entry in ipairs(playerSpellCache) do
    local ln = entry.name:lower()
    local match = true
    for _, t in ipairs(terms) do
      if not ln:find(t, 1, true) then match = false; break end
    end
    if match then
      results[#results + 1] = { spellID = entry.spellID, name = entry.name, known = entry.known,
        display = entry.name, subdisplay = "ID: " .. entry.spellID }
    end
  end

  table.sort(results, function(a, b)
    if a.known ~= b.known then return a.known and true or false end
    return a.name < b.name
  end)
  return results
end

---------------------------------------------------------------------------
-- Debounce
---------------------------------------------------------------------------
local debounceTimers = {}
local function debounce(key, delay, fn)
  if debounceTimers[key] then debounceTimers[key]:Cancel() end
  debounceTimers[key] = C_Timer.NewTimer(delay, function()
    debounceTimers[key] = nil
    fn()
  end)
end

---------------------------------------------------------------------------
-- Constants
---------------------------------------------------------------------------
local SECTION_SPACING = 20
local ROW_HEIGHT = 22
local CONTENT_WIDTH = 580
local AUTOCOMPLETE_ROWS = 8

local CLASS_DISPLAY = LOCALIZED_CLASS_NAMES_MALE or {
  WARRIOR = "Warrior", MAGE = "Mage", ROGUE = "Rogue", PALADIN = "Paladin",
  DRUID = "Druid", WARLOCK = "Warlock", PRIEST = "Priest", SHAMAN = "Shaman",
  HUNTER = "Hunter", DEATHKNIGHT = "Death Knight", MONK = "Monk",
  DEMONHUNTER = "Demon Hunter", EVOKER = "Evoker",
}

-- Display order for class groups in spell list
local CLASS_ORDER = {
  "WARRIOR", "PALADIN", "HUNTER", "ROGUE", "PRIEST",
  "DEATHKNIGHT", "SHAMAN", "MAGE", "WARLOCK", "MONK", "DRUID",
  "DEMONHUNTER", "EVOKER",
}

---------------------------------------------------------------------------
-- Subcategory panel registration
---------------------------------------------------------------------------
local parentCategory
local subcategories = {}  -- name -> { category, panel, built }

local SUB_NAMES = {
  "General", "Spell Sounds", "Muting", "Ambient",
  "Sound Browser", "Presets", "Profiles",
}

local function createSubPanel()
  local p = CreateFrame("Frame")
  p:Hide()
  return p
end

local function registerAllPanels()
  if parentCategory then return end

  -- Main (parent) panel -- shows a brief landing page
  local mainPanel = createSubPanel()
  parentCategory = Settings.RegisterCanvasLayoutCategory(mainPanel, "Resonance")
  Settings.RegisterAddOnCategory(parentCategory)

  -- Landing page content (built once)
  mainPanel:SetScript("OnShow", function(self)
    self:SetScript("OnShow", nil)
    local title = self:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 16, -16)
    title:SetText("Resonance")
    local desc = self:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    desc:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -8)
    desc:SetWidth(500)
    desc:SetJustifyH("LEFT")
    desc:SetText(L["Select a subcategory on the left to configure Resonance."])
  end)

  for _, name in ipairs(SUB_NAMES) do
    local p = createSubPanel()
    local subcat = Settings.RegisterCanvasLayoutSubcategory(parentCategory, p, L[name] or name)
    subcategories[name] = { category = subcat, panel = p, built = false }
  end
end

-- Settings.OpenToCategory calls the protected OpenSettingsPanel(), which is
-- blocked during combat lockdown.  Defer to PLAYER_REGEN_ENABLED so the
-- panel opens automatically once combat ends.
local pendingOpen = false
Resonance.openOptions = function(subcategoryName)
  if not parentCategory then return end
  -- Ensure Resonance_Data (LoadOnDemand) is loaded before showing the UI
  local loaded, reason = Resonance.loadDataAddon()
  if not loaded then
    if reason == "DISABLED" then
      Resonance.msg(L["Resonance Data is disabled. Enable it in the AddOns menu (Esc > AddOns) and /reload to access sound configuration."])
    elseif reason == "MISSING" or reason == "NOT_INSTALLED" then
      Resonance.msg(L["Resonance Data module not found. Reinstall Resonance to restore full functionality."])
    else
      Resonance.msg((L["Could not load Resonance Data: %s"]):format(reason or "unknown"))
    end
  end
  local targetID
  if subcategoryName and subcategories[subcategoryName] then
    targetID = subcategories[subcategoryName].category.ID
  else
    -- Default to General subcategory
    if subcategories["General"] then
      targetID = subcategories["General"].category.ID
    else
      targetID = parentCategory.ID
    end
  end
  if InCombatLockdown() then
    if not pendingOpen then
      pendingOpen = true
      local f = CreateFrame("Frame")
      f:RegisterEvent("PLAYER_REGEN_ENABLED")
      f:SetScript("OnEvent", function(self)
        self:UnregisterEvent("PLAYER_REGEN_ENABLED")
        pendingOpen = false
        if targetID then Settings.OpenToCategory(targetID) end
      end)
    end
    return
  end
  Settings.OpenToCategory(targetID)
end

---------------------------------------------------------------------------
-- Widget helpers
---------------------------------------------------------------------------
local function makeCheckbox(parent, label, anchorTo, offX, offY, getter, setter, tooltip)
  local cb = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
  cb:SetPoint("TOPLEFT", anchorTo, "BOTTOMLEFT", offX or 0, offY or -6)
  local textObj = cb.text or cb.Text
  if textObj then textObj:SetText(label)
  else
    local fs = cb:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    fs:SetPoint("LEFT", cb, "RIGHT", 4, 0)
    fs:SetText(label)
  end
  cb:SetScript("OnShow", function(self) self:SetChecked(getter()) end)
  cb:SetScript("OnClick", function(self) setter(self:GetChecked()) end)
  if tooltip then
    cb:SetScript("OnEnter", function(self)
      GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
      GameTooltip:AddLine(label, 1, 1, 1)
      GameTooltip:AddLine(tooltip, nil, nil, nil, true)
      GameTooltip:Show()
    end)
    cb:SetScript("OnLeave", function() GameTooltip:Hide() end)
  end
  return cb
end

local function makeEditBox(parent, width, anchorTo, offX, offY, placeholder)
  local eb = CreateFrame("EditBox", nil, parent, "InputBoxTemplate")
  eb:SetSize(width, 22)
  eb:SetPoint("TOPLEFT", anchorTo, "BOTTOMLEFT", offX or 6, offY or -4)
  eb:SetAutoFocus(false)
  if placeholder then
    eb.placeholder = eb:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    eb.placeholder:SetPoint("LEFT", 4, 0)
    eb.placeholder:SetText(placeholder)
    local function upd(self)
      if self.placeholder then
        self.placeholder:SetShown(self:GetText() == "" and not self:HasFocus())
      end
    end
    eb:SetScript("OnEditFocusGained", function(self) self.placeholder:Hide() end)
    eb:SetScript("OnEditFocusLost", upd)
    eb:SetScript("OnTextChanged", upd)
    eb:SetScript("OnShow", upd)
  end
  return eb
end

local function wireNumericEditBox(eb, onChange)
  eb:SetScript("OnTextChanged", function(self)
    if self.placeholder then self.placeholder:SetShown(self:GetText() == "" and not self:HasFocus()) end
    local val = tonumber(self:GetText())
    onChange((val and val > 0) and val or nil)
  end)
  eb:SetScript("OnEditFocusGained", function(self) if self.placeholder then self.placeholder:Hide() end end)
  eb:SetScript("OnEditFocusLost", function(self)
    if self.placeholder then self.placeholder:SetShown(self:GetText() == "") end
  end)
  eb:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
  eb:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
end

local function makeIconButton(parent, icon, size, tooltip, onClick)
  local btn = CreateFrame("Button", nil, parent)
  btn:SetSize(size, size)
  local tex = btn:CreateTexture(nil, "ARTWORK")
  tex:SetAllPoints()
  tex:SetTexture(icon)
  btn.icon = tex
  btn:SetHighlightTexture(icon)
  btn:GetHighlightTexture():SetAlpha(0.3)
  if tooltip then
    btn:SetScript("OnEnter", function(self)
      GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
      GameTooltip:AddLine(tooltip, 1, 1, 1)
      GameTooltip:Show()
    end)
    btn:SetScript("OnLeave", function() GameTooltip:Hide() end)
  end
  if onClick then btn:SetScript("OnClick", onClick) end
  btn.SetEnabled = function(self, enabled)
    if enabled then
      self:Enable()
      self.icon:SetDesaturated(false)
      self.icon:SetAlpha(1)
    else
      self:Disable()
      self.icon:SetDesaturated(true)
      self.icon:SetAlpha(0.3)
    end
  end
  return btn
end

-- Shared hidden button for measuring localized text widths
local _measureBtn
local function btnTextWidth(text)
  if not _measureBtn then
    _measureBtn = CreateFrame("Button", nil, UIParent, "UIPanelButtonTemplate")
    _measureBtn:Hide()
  end
  _measureBtn:SetText(text)
  return _measureBtn:GetFontString():GetStringWidth() or 0
end

local function makeButton(parent, text, minWidth, onClick)
  local btn = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
  btn:SetText(text)
  local textW = btn:GetFontString():GetStringWidth() or 0
  btn:SetSize(math.max((minWidth or 0) + 4, textW + 16), 26)
  if onClick then btn:SetScript("OnClick", onClick) end
  return btn
end

local function makeClearButton(editBox, onClear)
  local clr = CreateFrame("Button", nil, editBox:GetParent())
  clr:SetSize(18, 18)
  clr:SetPoint("LEFT", editBox, "RIGHT", 2, 0)
  local nt = clr:CreateTexture(nil, "ARTWORK")
  nt:SetSize(10, 10)
  nt:SetPoint("CENTER")
  nt:SetTexture("Interface\\Buttons\\UI-StopButton")
  clr:SetHighlightTexture("Interface\\Buttons\\UI-StopButton")
  clr:GetHighlightTexture():SetAlpha(0.4)
  clr:Hide()
  clr:SetScript("OnClick", function()
    editBox:SetText("")
    if onClear then onClear() end
  end)
  editBox.clearBtn = clr
  return clr
end

local function makeRadio(parent)
  local rb = CreateFrame("CheckButton", nil, parent)
  rb:SetSize(16, 16)
  rb:SetNormalTexture("Interface\\Buttons\\UI-RadioButton")
  rb:GetNormalTexture():SetTexCoord(0, 0.25, 0, 1)
  rb:SetCheckedTexture("Interface\\Buttons\\UI-RadioButton")
  rb:GetCheckedTexture():SetTexCoord(0.25, 0.5, 0, 1)
  rb:SetHighlightTexture("Interface\\Buttons\\UI-RadioButton")
  rb:GetHighlightTexture():SetTexCoord(0.5, 0.75, 0, 1)
  rb.label = rb:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  rb.label:SetPoint("LEFT", rb, "RIGHT", 4, 0)
  return rb
end

---------------------------------------------------------------------------
-- Autocomplete dropdown component
---------------------------------------------------------------------------
local ROW_HEIGHT_1 = ROW_HEIGHT        -- single-line row
local ROW_HEIGHT_2 = ROW_HEIGHT + 14   -- two-line row (text + 2px gap + subtext)

local function createAutocomplete(searchBox, onPlay, onAction, actionDef, dropdownWidth, extraActions)
  -- actionDef: { label, tooltip, width, icon, altIcons } or string (legacy)
  -- When icon is set, renders a small icon button instead of a text button.
  -- altIcons: optional list of alternate icon paths (swapped via onRowRefresh).
  if type(actionDef) == "string" then actionDef = { label = actionDef } end
  local useIconAction = actionDef.icon ~= nil
  local w = dropdownWidth or CONTENT_WIDTH
  local dd = CreateFrame("Frame", nil, UIParent)
  dd:SetFrameStrata("TOOLTIP")
  dd:SetSize(w, AUTOCOMPLETE_ROWS * ROW_HEIGHT_1 + 18)
  dd:SetPoint("TOPLEFT", searchBox, "BOTTOMLEFT", -2, -2)
  dd:SetClampedToScreen(true)
  dd:Hide()

  local bg = dd:CreateTexture(nil, "BACKGROUND")
  bg:SetAllPoints()
  bg:SetColorTexture(0.05, 0.05, 0.07, 0.97)

  local border = dd:CreateTexture(nil, "BORDER")
  border:SetPoint("TOPLEFT", -1, 1)
  border:SetPoint("BOTTOMRIGHT", 1, -1)
  border:SetColorTexture(0.25, 0.25, 0.30, 0.7)

  dd.scrollOffset = 0
  dd.rows = {}

  -- Custom tooltip that renders above the TOOLTIP-strata dropdown
  local tip = CreateFrame("Frame", nil, dd)
  tip:SetFrameLevel(dd:GetFrameLevel() + 50)
  tip:SetSize(200, 30)
  tip:Hide()
  local tipBg = tip:CreateTexture(nil, "BACKGROUND")
  tipBg:SetAllPoints()
  tipBg:SetColorTexture(0, 0, 0, 0.92)
  local tipBorder = tip:CreateTexture(nil, "BORDER")
  tipBorder:SetPoint("TOPLEFT", -1, 1)
  tipBorder:SetPoint("BOTTOMRIGHT", 1, -1)
  tipBorder:SetColorTexture(0.4, 0.4, 0.45, 0.7)
  local tipText = tip:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  tipText:SetPoint("TOPLEFT", 6, -6)
  tipText:SetPoint("BOTTOMRIGHT", -6, 6)
  tipText:SetTextColor(1, 1, 1, 1)
  tipText:SetWordWrap(true)
  tipText:SetJustifyH("LEFT")

  local function addBtnTooltip(btn, text)
    if not text then return end
    btn:SetScript("OnEnter", function(self)
      tipText:SetText(text)
      local textW = tipText:GetStringWidth()
      tip:SetSize(math.min(textW + 16, 240), tipText:GetStringHeight() + 14)
      tip:ClearAllPoints()
      tip:SetPoint("BOTTOM", self, "TOP", 0, 4)
      tip:Show()
    end)
    btn:SetScript("OnLeave", function() tip:Hide() end)
  end

  -- Measure button text widths to size dynamically for localized labels
  local function measuredBtnW(label, minW)
    local tw = btnTextWidth(label)
    return math.max((minW or 0) + 4, tw + 16)
  end

  local primaryW
  if useIconAction then
    primaryW = 20
  else
    primaryW = measuredBtnW(actionDef.label, actionDef.width or 48)
    if actionDef.altLabels then
      for _, alt in ipairs(actionDef.altLabels) do
        primaryW = math.max(primaryW, measuredBtnW(alt, actionDef.width or 48))
      end
    end
  end
  local btnAreaW = primaryW + 4
  local extraWidths = {}
  for idx, ea in ipairs(extraActions or {}) do
    extraWidths[idx] = measuredBtnW(ea.label, ea.width or 40)
    btnAreaW = btnAreaW + extraWidths[idx] + 2
  end
  local textRightOffset = -(btnAreaW + 28)  -- play button (22) + gaps

  for i = 1, AUTOCOMPLETE_ROWS do
    local row = CreateFrame("Frame", nil, dd)
    row:SetSize(w - 4, ROW_HEIGHT_1)
    row:SetPoint("TOPLEFT", 2, -(i - 1) * ROW_HEIGHT_1 - 2)

    row.stripe = row:CreateTexture(nil, "BACKGROUND")
    row.stripe:SetAllPoints()
    row.stripe:SetColorTexture(1, 1, 1, 0.06)
    row.stripe:Hide()

    row.text = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.text:SetPoint("TOPLEFT", row, "TOPLEFT", 6, -3)
    row.text:SetPoint("RIGHT", row, "RIGHT", textRightOffset, 0)
    row.text:SetJustifyH("LEFT")
    row.text:SetWordWrap(false)

    row.sub = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    row.sub:SetPoint("TOPLEFT", row.text, "BOTTOMLEFT", 0, -2)
    row.sub:SetPoint("RIGHT", row, "RIGHT", textRightOffset, 0)
    row.sub:SetJustifyH("LEFT")
    row.sub:SetWordWrap(false)
    row.sub:SetTextColor(0.5, 0.5, 0.55)
    row.sub:Hide()

    -- Build buttons right-to-left: primary action -> extra actions -> play
    if useIconAction then
      row.actionBtn = makeIconButton(row, actionDef.icon, 20)
      row.actionBtn:SetPoint("RIGHT", row, "RIGHT", -4, 0)
      row.actionBtn:SetScript("OnClick", function() if row.entry then onAction(row.entry) end end)
      row.actionBtn.tooltipText = actionDef.label
      row.actionBtn:SetScript("OnEnter", function(self)
        tipText:SetText(self.tooltipText or "")
        local textW = tipText:GetStringWidth()
        tip:SetSize(math.min(textW + 16, 240), tipText:GetStringHeight() + 14)
        tip:ClearAllPoints()
        tip:SetPoint("BOTTOM", self, "TOP", 0, 4)
        tip:Show()
      end)
      row.actionBtn:SetScript("OnLeave", function() tip:Hide() end)
    else
      row.actionBtn = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
      row.actionBtn:SetSize(primaryW, 22)
      row.actionBtn:SetPoint("RIGHT", row, "RIGHT", -2, 0)
      row.actionBtn:SetText(actionDef.label)
      row.actionBtn:SetScript("OnClick", function() if row.entry then onAction(row.entry) end end)
      addBtnTooltip(row.actionBtn, actionDef.tooltip)
    end

    local prevBtn = row.actionBtn
    row.extraBtns = {}
    for j, ea in ipairs(extraActions or {}) do
      local btn = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
      btn:SetSize(extraWidths[j], 22)
      btn:SetPoint("RIGHT", prevBtn, "LEFT", -2, 0)
      btn:SetText(ea.label)
      local callback = ea.onClick
      btn:SetScript("OnClick", function() if row.entry then callback(row.entry) end end)
      addBtnTooltip(btn, ea.tooltip)
      row.extraBtns[j] = btn
      prevBtn = btn
    end

    row.playBtn = makeIconButton(row, "Interface\\Buttons\\UI-SpellbookIcon-NextPage-Up", 22)
    wirePlayStop(row.playBtn, function()
      if row.entry then return onPlay(row.entry) end
    end)
    row.playBtn:SetPoint("RIGHT", prevBtn, "LEFT", -4, 0)
    -- Use custom tip frame for tooltip (consistent with action button, avoids overlap)
    addBtnTooltip(row.playBtn, L["Play / Stop"])

    row:Hide()
    dd.rows[i] = row
  end

  dd.statusText = dd:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  dd.statusText:SetPoint("BOTTOMLEFT", 4, 2)
  dd.statusText:SetTextColor(0.55, 0.55, 0.55)

  dd.scrollHint = dd:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  dd.scrollHint:SetPoint("BOTTOMRIGHT", -10, 2)
  dd.scrollHint:SetTextColor(0.55, 0.55, 0.55)

  local scrollTrack = dd:CreateTexture(nil, "ARTWORK")
  scrollTrack:SetWidth(4)
  scrollTrack:SetPoint("TOPRIGHT", dd, "TOPRIGHT", -2, -2)
  scrollTrack:SetColorTexture(0.15, 0.15, 0.18, 0.6)
  scrollTrack:Hide()

  local scrollThumb = dd:CreateTexture(nil, "OVERLAY")
  scrollThumb:SetWidth(4)
  scrollThumb:SetColorTexture(0.5, 0.5, 0.55, 0.8)
  scrollThumb:Hide()

  local function refreshRows(self)
    local data = self.data or {}
    local off = self.scrollOffset
    local yOff = 2
    local visibleCount = 0
    for i, row in ipairs(self.rows) do
      local di = off + i
      if di <= #data then
        visibleCount = visibleCount + 1
        row.entry = data[di]
        row.text:SetText(data[di].display or data[di].path or "")
        local sub = data[di].subdisplay
        if sub and sub ~= "" then
          row.sub:SetText(sub)
          row.sub:Show()
          row:SetHeight(ROW_HEIGHT_2)
        else
          row.sub:Hide()
          row:SetHeight(ROW_HEIGHT_1)
        end
        -- Re-anchor text vertically depending on whether sub is shown
        row.text:ClearAllPoints()
        if sub and sub ~= "" then
          row.text:SetPoint("TOPLEFT", row, "TOPLEFT", 6, -3)
        else
          row.text:SetPoint("LEFT", 6, 0)
        end
        row.text:SetPoint("RIGHT", row, "RIGHT", textRightOffset, 0)
        -- Alternating stripe based on data index (not visual position)
        if di % 2 == 0 then row.stripe:Show() else row.stripe:Hide() end
        if self.onRowRefresh then self:onRowRefresh(row, data[di]) end
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", dd, "TOPLEFT", 2, -yOff)
        row:SetSize(w - 4, row:GetHeight())
        row:Show()
        yOff = yOff + row:GetHeight()
      else
        row.entry = nil
        row:Hide()
      end
    end
    local contentH = yOff
    if #data > AUTOCOMPLETE_ROWS then
      self.scrollHint:SetText(L["Showing %d\226\128\147%d of %d"]:format(off + 1, math.min(off + AUTOCOMPLETE_ROWS, #data), #data))
      scrollTrack:ClearAllPoints()
      scrollTrack:SetPoint("TOPRIGHT", dd, "TOPRIGHT", -2, -2)
      scrollTrack:SetPoint("BOTTOMRIGHT", dd, "BOTTOMRIGHT", -2, 16)
      scrollTrack:Show()
      scrollThumb:Show()
      local trackH = contentH - 2
      local thumbH = math.max(16, trackH * AUTOCOMPLETE_ROWS / #data)
      local maxOff = #data - AUTOCOMPLETE_ROWS
      local frac = maxOff > 0 and (off / maxOff) or 0
      scrollThumb:SetHeight(thumbH)
      scrollThumb:ClearAllPoints()
      scrollThumb:SetPoint("TOPRIGHT", scrollTrack, "TOPRIGHT", 0, -((trackH - thumbH) * frac))
    else
      self.scrollHint:SetText("")
      scrollTrack:Hide()
      scrollThumb:Hide()
    end
    dd:SetHeight(contentH + 18)
  end

  function dd:SetData(data, statusMsg)
    self.data = data or {}
    self.scrollOffset = 0
    self.statusText:SetText(statusMsg or "")
    refreshRows(self)
    self:SetShown(#self.data > 0 or (statusMsg and statusMsg ~= ""))
  end

  dd:EnableMouseWheel(true)
  dd:SetScript("OnMouseWheel", function(self, delta)
    local maxOff = math.max(0, #(self.data or {}) - AUTOCOMPLETE_ROWS)
    self.scrollOffset = math.max(0, math.min(maxOff, self.scrollOffset - delta * 3))
    refreshRows(self)
  end)

  return dd
end

---------------------------------------------------------------------------
-- Custom AceGUI widget: EditBox with sound file autocomplete
-- Used by AceConfig "input" options via dialogControl = "Resonance_SoundEditBox"
---------------------------------------------------------------------------
do
  local WidgetType = "Resonance_SoundEditBox"
  local WidgetVersion = 1
  local AceGUI = LibStub("AceGUI-3.0")

  local function SoundEditBox_OnEnterPressed(frame)
    local self = frame.obj
    local value = frame:GetText()
    local cancel = self:Fire("OnEnterPressed", value)
    if not cancel then
      if self.dropdown then self.dropdown:Hide() end
    end
  end

  local function SoundEditBox_OnEscapePressed(frame)
    if frame.obj.dropdown then frame.obj.dropdown:Hide() end
    AceGUI:ClearFocus()
  end

  local function SoundEditBox_OnFocusGained(frame)
    AceGUI:SetFocus(frame.obj)
    local self = frame.obj
    if self.doSearch then self.doSearch() end
  end

  local function SoundEditBox_OnFocusLost(frame)
    local self = frame.obj
    if self.dropdown then
      C_Timer.After(0.2, function()
        if self.editbox and not self.editbox:HasFocus()
           and self.dropdown and not self.dropdown:IsMouseOver() then
          self.dropdown:Hide()
        end
      end)
    end
  end

  local methods = {
    ["OnAcquire"] = function(self)
      self:SetWidth(200)
      self:SetDisabled(false)
      self:SetLabel()
      self:SetText()
      self:SetMaxLetters(0)
    end,

    ["OnRelease"] = function(self)
      self:ClearFocus()
      if self.dropdown then self.dropdown:Hide() end
    end,

    ["SetDisabled"] = function(self, disabled)
      self.disabled = disabled
      if disabled then
        self.editbox:EnableMouse(false)
        self.editbox:ClearFocus()
        self.editbox:SetTextColor(0.5, 0.5, 0.5)
        self.label:SetTextColor(0.5, 0.5, 0.5)
      else
        self.editbox:EnableMouse(true)
        self.editbox:SetTextColor(1, 1, 1)
        self.label:SetTextColor(1, 0.82, 0)
      end
    end,

    ["SetText"] = function(self, text)
      self.lasttext = text or ""
      self.editbox:SetText(text or "")
      self.editbox:SetCursorPosition(0)
    end,

    ["GetText"] = function(self)
      return self.editbox:GetText()
    end,

    ["SetLabel"] = function(self, text)
      if text and text ~= "" then
        self.label:SetText(text)
        self.label:Show()
        self.editbox:SetPoint("TOPLEFT", self.frame, "TOPLEFT", 7, -18)
        self:SetHeight(44)
        self.alignoffset = 30
      else
        self.label:SetText("")
        self.label:Hide()
        self.editbox:SetPoint("TOPLEFT", self.frame, "TOPLEFT", 7, 0)
        self:SetHeight(26)
        self.alignoffset = 12
      end
    end,

    ["SetMaxLetters"] = function(self, num)
      self.editbox:SetMaxLetters(num or 0)
    end,

    ["ClearFocus"] = function(self)
      self.editbox:ClearFocus()
      self.frame:SetScript("OnShow", nil)
    end,

    ["SetFocus"] = function(self)
      self.editbox:SetFocus()
    end,

    ["DisableButton"] = function(self, disabled)
      -- no-op (no OK button in this widget)
    end,

    ["HighlightText"] = function(self, from, to)
      self.editbox:HighlightText(from, to)
    end,
  }

  local function Constructor()
    local num = AceGUI:GetNextWidgetNum(WidgetType)
    local frame = CreateFrame("Frame", nil, UIParent)
    frame:Hide()

    local editbox = CreateFrame("EditBox", "ResonanceSoundEditBox" .. num, frame, "InputBoxTemplate")
    editbox:SetAutoFocus(false)
    editbox:SetFontObject(ChatFontNormal)
    editbox:SetScript("OnEnterPressed", SoundEditBox_OnEnterPressed)
    editbox:SetScript("OnEscapePressed", SoundEditBox_OnEscapePressed)
    editbox:SetScript("OnEditFocusGained", SoundEditBox_OnFocusGained)
    editbox:SetScript("OnEditFocusLost", SoundEditBox_OnFocusLost)
    editbox:SetTextInsets(0, 0, 3, 3)
    editbox:SetMaxLetters(256)
    editbox:SetPoint("BOTTOMLEFT", 6, 0)
    editbox:SetPoint("BOTTOMRIGHT")
    editbox:SetHeight(19)

    local label = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    label:SetPoint("TOPLEFT", 0, -2)
    label:SetPoint("TOPRIGHT", 0, -2)
    label:SetJustifyH("LEFT")
    label:SetHeight(18)

    -- Autocomplete dropdown (reuses the same component as other search boxes)
    local dd
    dd = createAutocomplete(editbox,
      function(e) if e then return e.fileDataID end end,  -- onPlay: return FID
      function(e)                                          -- onAction: select sound
        if e then
          editbox:SetText(tostring(e.fileDataID))
          editbox:ClearFocus()
          SoundEditBox_OnEnterPressed(editbox)
          dd:Hide()
        end
      end,
      { label = L["Use"], width = 36 },
      nil  -- dropdown width will follow editbox
    )

    -- Search function
    local function doSearch()
      if not editbox:HasFocus() then return end
      -- Don't show autocomplete when sound databases aren't loaded
      if not hasSpellDB() then dd:Hide(); return end
      local q = editbox:GetText()
      -- Don't search if input looks like a pure FID or file path
      if tonumber(q) then dd:SetData({}, ""); dd:Hide(); return end
      if q:find("\\") or q:find("/") then dd:SetData({}, ""); dd:Hide(); return end
      if #q < 3 then dd:SetData({}, ""); dd:Hide(); return end
      searchDB(Resonance.SpellSounds, q, "soundWidget" .. num, function(results)
        for _, r in ipairs(results) do
          r.display = formatSoundDisplay(r.path, r.fileDataID)
        end
        dd:SetData(results, #results == 0 and L["No matches."] or L["%d results"]:format(#results))
      end, Resonance.SpellSoundPrefixes)
    end

    editbox:SetScript("OnTextChanged", function(self)
      local value = self:GetText()
      local widget = self.obj
      if tostring(value) ~= tostring(widget.lasttext) then
        widget:Fire("OnTextChanged", value)
        widget.lasttext = value
      end
      debounce("soundWidget" .. num, 0.3, doSearch)
    end)

    local widget = {
      alignoffset = 30,
      editbox     = editbox,
      label       = label,
      frame       = frame,
      dropdown    = dd,
      doSearch    = doSearch,
      type        = WidgetType,
    }
    for method, func in pairs(methods) do
      widget[method] = func
    end
    editbox.obj = widget

    return AceGUI:RegisterAsWidget(widget)
  end

  AceGUI:RegisterWidgetType(WidgetType, Constructor, WidgetVersion)
end

---------------------------------------------------------------------------
-- Panel builders (extracted into functions to stay under Lua 5.1's
-- 200 local-variable limit).  Each receives a shared context table
-- `ctx` and populates it with cross-panel references.
---------------------------------------------------------------------------

-- Show a notice banner inside a scrollable content frame.
-- Returns the banner frame so builders can anchor content below it.
local function showDataUnavailableBanner(contentFrame, reason)
  local banner = CreateFrame("Frame", nil, contentFrame, "BackdropTemplate")
  banner:SetPoint("TOPLEFT", 0, 0)
  banner:SetPoint("RIGHT", contentFrame, "RIGHT", -16, 0)
  banner:SetHeight(48)
  banner:SetBackdrop({
    bgFile = "Interface\\BUTTONS\\WHITE8X8",
    edgeFile = "Interface\\BUTTONS\\WHITE8X8",
    edgeSize = 1,
  })
  banner:SetBackdropColor(0.3, 0.15, 0.05, 0.85)
  banner:SetBackdropBorderColor(0.6, 0.3, 0.1, 0.8)
  -- Warning icon
  local icon = banner:CreateTexture(nil, "OVERLAY")
  icon:SetSize(20, 20)
  icon:SetPoint("LEFT", 10, 0)
  icon:SetAtlas("services-icon-warning")
  local text = banner:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  text:SetPoint("LEFT", icon, "RIGHT", 8, 0)
  text:SetPoint("RIGHT", -12, 0)
  text:SetJustifyH("LEFT")
  text:SetSpacing(3)
  if reason == "DISABLED" then
    text:SetText(L["Resonance Data is disabled. Enable it in the AddOns menu (Esc > AddOns) and /reload to access sound configuration."])
  elseif reason == "MISSING" or reason == "NOT_INSTALLED" then
    text:SetText(L["Resonance Data module not found. Reinstall Resonance to restore full functionality."])
  else
    text:SetText((L["Could not load Resonance Data: %s"]):format(reason or "unknown"))
  end
  -- Adjust height to fit text
  banner:SetScript("OnShow", function(self)
    local h = text:GetStringHeight()
    self:SetHeight(math.max(40, h + 20))
  end)
  return banner
end

-- Forward declarations for the builder functions (defined below).
local buildTab2_SpellSounds
local buildTab3_MutedSounds
local buildTab4_Presets
local buildTab5_Ambient

---------------------------------------------------------------------------
-- Tab 2: Spell Sounds
---------------------------------------------------------------------------
buildTab2_SpellSounds = function(ctx)
  local recalcContentHeight = ctx.recalcContentHeight
  local playerClass = ctx.playerClass
  local profile = Resonance.db.profile

  local spellTab = ctx.spellSoundsContent

  -- Data unavailable banner (anchors content below it)
  local spellBanner
  if not ctx.dataLoaded then
    spellBanner = showDataUnavailableBanner(spellTab, select(2, Resonance.loadDataAddon()))
  end

  -- Tab heading
  local spellTabHdr = spellTab:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
  spellTabHdr:SetPoint("TOPLEFT", spellBanner and spellBanner or spellTab, spellBanner and "BOTTOMLEFT" or "TOPLEFT", 16, spellBanner and -12 or -16)
  spellTabHdr:SetText(L["Spell Sounds"])

  local spellTabDesc = spellTab:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  spellTabDesc:SetPoint("TOPLEFT", spellTabHdr, "BOTTOMLEFT", 0, -6)
  spellTabDesc:SetPoint("RIGHT", spellTab, "RIGHT", -16, 0)
  spellTabDesc:SetJustifyH("LEFT")
  spellTabDesc:SetSpacing(3)
  spellTabDesc:SetText(L["Configure replacement sounds for individual spells. Add spells by ID or name, then assign classic or custom sound files. You can also use your own sound files — place them in Interface/AddOns/Resonance_Sounds/ (create this folder) to keep them safe from addon updates, then enter the full path as the replacement sound."])

  -- Anchor frame positioned after the heading + description
  local spellBtnAnchor = CreateFrame("Frame", nil, spellTab)
  spellBtnAnchor:SetSize(1, 1)
  spellBtnAnchor:SetPoint("TOPLEFT", spellTabDesc, "BOTTOMLEFT", 0, -12)

  local clearAllSpellsBtn = makeButton(spellTab, L["Clear All"], 65, nil)
  clearAllSpellsBtn:SetPoint("TOPRIGHT", spellTabDesc, "BOTTOMRIGHT", 0, -12)

  local clearPresetsBtn = makeButton(spellTab, L["Clear Presets"], 90, nil)
  clearPresetsBtn:SetPoint("RIGHT", clearAllSpellsBtn, "LEFT", -4, 0)

  local addBtn = makeButton(spellTab, L["+ Add Spell"], 80, nil)
  addBtn:SetPoint("RIGHT", clearPresetsBtn, "LEFT", -4, 0)

  -- Table header
  local tableHeader = CreateFrame("Frame", nil, spellTab)
  tableHeader:SetHeight(ROW_HEIGHT)
  tableHeader:SetPoint("TOPLEFT", spellBtnAnchor, "TOPLEFT", 0, -(26 + 6))
  tableHeader:SetPoint("RIGHT", spellTab, "RIGHT", -4, 0)

  local headerBg = tableHeader:CreateTexture(nil, "BACKGROUND")
  headerBg:SetAllPoints()
  headerBg:SetColorTexture(0.15, 0.15, 0.18, 0.6)

  local hdrSpell = tableHeader:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  hdrSpell:SetPoint("LEFT", 4, 0)
  hdrSpell:SetWidth(200)
  hdrSpell:SetJustifyH("LEFT")
  hdrSpell:SetText(L["Spell"])

  local hdrSound = tableHeader:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  hdrSound:SetPoint("LEFT", hdrSpell, "RIGHT", 8, 0)
  hdrSound:SetPoint("RIGHT", tableHeader, "RIGHT", -58, 0)
  hdrSound:SetJustifyH("LEFT")
  hdrSound:SetText(L["Sound"])

  local hdrActions = tableHeader:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  hdrActions:SetPoint("RIGHT", tableHeader, "RIGHT", -2, 0)
  hdrActions:SetJustifyH("RIGHT")
  hdrActions:SetText(L["Actions"])

  local listContainer = CreateFrame("Frame", nil, spellTab)
  listContainer:SetPoint("TOPLEFT", tableHeader, "BOTTOMLEFT", 0, -2)
  listContainer:SetPoint("RIGHT", spellTab, "RIGHT", -4, 0)
  listContainer:SetHeight(ROW_HEIGHT)

  local listEmpty = listContainer:CreateFontString(nil, "OVERLAY", "GameFontDisable")
  listEmpty:SetPoint("TOPLEFT", 4, 0)
  listEmpty:SetText(L["No spells configured. Click '+ Add Spell' to get started."])

  local listRows = {}

  -------------------------------------------------------------------
  -- Editor frame (floating dialog)
  -------------------------------------------------------------------
  local editorFrame = CreateFrame("Frame", "ResonanceEditor", UIParent, "BackdropTemplate")
  editorFrame:SetSize(CONTENT_WIDTH + 20, 460)
  editorFrame:SetPoint("CENTER")
  editorFrame:SetFrameStrata("DIALOG")
  editorFrame:SetMovable(true)
  editorFrame:EnableMouse(true)
  editorFrame:SetClampedToScreen(true)
  editorFrame:Hide()

  editorFrame:SetBackdrop({
    bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
    edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
    tile = true, tileSize = 32, edgeSize = 24,
    insets = { left = 5, right = 5, top = 5, bottom = 5 },
  })
  editorFrame:SetBackdropColor(0.06, 0.06, 0.08, 1)

  local titleBar = CreateFrame("Frame", nil, editorFrame)
  titleBar:SetHeight(28)
  titleBar:SetPoint("TOPLEFT", 6, -6)
  titleBar:SetPoint("TOPRIGHT", -6, -6)
  titleBar:EnableMouse(true)
  titleBar:RegisterForDrag("LeftButton")
  titleBar:SetScript("OnDragStart", function() editorFrame:StartMoving() end)
  titleBar:SetScript("OnDragStop", function() editorFrame:StopMovingOrSizing() end)

  local titleBarBg = titleBar:CreateTexture(nil, "BACKGROUND")
  titleBarBg:SetAllPoints()
  titleBarBg:SetColorTexture(0.12, 0.12, 0.16, 0.8)

  local edTitle = titleBar:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  edTitle:SetPoint("LEFT", 6, 0)

  local edCloseBtn = CreateFrame("Button", nil, titleBar, "UIPanelCloseButton")
  edCloseBtn:SetPoint("TOPRIGHT", editorFrame, "TOPRIGHT", -2, -2)

  tinsert(UISpecialFrames, "ResonanceEditor")

  -- SpellID input
  local edSpellLabel = editorFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  edSpellLabel:SetPoint("TOPLEFT", titleBar, "BOTTOMLEFT", 12, -10)
  edSpellLabel:SetText(L["Spell ID:"])

  local edSpellIDBox = makeEditBox(editorFrame, 100, edSpellLabel, 0, -2, "e.g. 6343")
  edSpellIDBox:SetNumeric(true)

  local edSpellPreview = editorFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  edSpellPreview:SetPoint("LEFT", edSpellIDBox, "RIGHT", 8, 0)

  local editorSound = nil
  local editorDuration = nil   -- optional: stop sound after this many seconds
  local editorLoop = nil       -- optional: loop sound (true or number of iterations)
  local editorTrigger = "cast" -- "cast", "precast", or "precast_and_cast"
  local editorPrecastSound = nil
  local editorPrecastDuration = nil
  local editorExclusions = {}  -- local copy of muteExclusions during editing

  local refreshAutoMuteSection  -- forward declaration
  local edResizeEditor          -- forward declaration
  local autoMuteAnchor          -- forward declaration (used by edSetMuteOnly)

  local function edUpdateSpellPreview()
    local sid = tonumber(edSpellIDBox:GetText())
    if sid and sid > 0 then
      local name = Resonance.getSpellName(sid)
      edSpellPreview:SetText(name and ("|cff00ff00" .. name .. "|r") or "|cffff4444" .. L["Unknown spell"] .. "|r")
    else
      edSpellPreview:SetText("")
    end
    if edSpellIDBox.placeholder then
      edSpellIDBox.placeholder:SetShown(edSpellIDBox:GetText() == "" and not edSpellIDBox:HasFocus())
    end
    -- Update auto-mute section when spell ID changes (new spell mode)
    if refreshAutoMuteSection and edSpellIDBox:IsEnabled() then
      refreshAutoMuteSection(sid)
    end
  end
  edSpellIDBox:SetScript("OnTextChanged", edUpdateSpellPreview)

  -- Spell name search (shown when adding new spell)
  local edSpellSearchLabel = editorFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  edSpellSearchLabel:SetPoint("TOPLEFT", edSpellIDBox, "BOTTOMLEFT", 0, -6)
  edSpellSearchLabel:SetText(L["Search by name:"])

  local edSpellSearchBox = makeEditBox(editorFrame, CONTENT_WIDTH - 60, edSpellSearchLabel, 0, -2, "e.g. Mortal Strike")

  local edSpellSearchDD
  edSpellSearchDD = createAutocomplete(edSpellSearchBox,
    function(e) end,
    function(e)
      if e and e.spellID then
        edSpellIDBox:SetText(tostring(e.spellID))
        edUpdateSpellPreview()
        edSpellSearchDD:Hide()
      end
    end,
    L["Use"], CONTENT_WIDTH
  )
  for _, row in ipairs(edSpellSearchDD.rows) do
    row.playBtn:Hide()
    row.playBtn:SetSize(1, 1)
  end

  local function edDoSpellSearch()
    if not edSpellSearchBox:HasFocus() then return end
    local q = edSpellSearchBox:GetText()
    if #q < 2 then edSpellSearchDD:SetData({}, ""); edSpellSearchDD:Hide(); return end
    local results = searchSpells(q)
    if results == nil then
      -- Cache still building in the background; show status and re-fire when ready
      edSpellSearchDD:SetData({}, L["Loading spell data..."])
      startBuildPlayerSpellCache(function() edDoSpellSearch() end)
      return
    end
    edSpellSearchDD:SetData(results, #results == 0 and L["No matches."] or L["%d results"]:format(#results))
  end

  local edSpellSearchClear = makeClearButton(edSpellSearchBox, function() edSpellSearchDD:Hide() end)

  edSpellSearchBox:SetScript("OnTextChanged", function(self)
    if self.placeholder then self.placeholder:SetShown(self:GetText() == "" and not self:HasFocus()) end
    edSpellSearchClear:SetShown(self:GetText() ~= "")
    debounce("edSpellSearch", 0.3, edDoSpellSearch)
  end)
  edSpellSearchBox:SetScript("OnEditFocusGained", function(self)
    if self.placeholder then self.placeholder:Hide() end
    edDoSpellSearch()
  end)
  edSpellSearchBox:SetScript("OnEditFocusLost", function(self)
    if self.placeholder then self.placeholder:SetShown(self:GetText() == "") end
    C_Timer.After(0.2, function()
      if not edSpellSearchBox:HasFocus() and not edSpellSearchDD:IsMouseOver() then edSpellSearchDD:Hide() end
    end)
  end)
  edSpellSearchBox:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
  edSpellSearchBox:SetScript("OnEscapePressed", function(self) edSpellSearchDD:Hide(); self:ClearFocus() end)

  -- Replacement Sound
  local repAnchor = CreateFrame("Frame", nil, editorFrame)
  repAnchor:SetSize(CONTENT_WIDTH - 20, 1)
  repAnchor:SetPoint("TOPLEFT", edSpellSearchBox, "BOTTOMLEFT", 4, -12)

  local edMuteOnlyCheck = CreateFrame("CheckButton", nil, editorFrame, "UICheckButtonTemplate")
  edMuteOnlyCheck:SetSize(22, 22)
  edMuteOnlyCheck:SetPoint("TOPLEFT", repAnchor, "TOPLEFT", 0, 2)
  edMuteOnlyCheck.text:SetFontObject("GameFontNormal")
  edMuteOnlyCheck.text:SetText(L["Mute only (no replacement sound)"])

  ---------------------------------------------------------------------------
  -- Trigger phase controls
  ---------------------------------------------------------------------------
  local edTriggerLabel = editorFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  edTriggerLabel:SetPoint("TOPLEFT", edMuteOnlyCheck, "BOTTOMLEFT", 0, -6)
  edTriggerLabel:SetText(L["Play sound on:"])

  local edTriggerCast = makeRadio(editorFrame)
  edTriggerCast:SetPoint("TOPLEFT", edTriggerLabel, "BOTTOMLEFT", 0, -2)
  edTriggerCast.label:SetText(L["Cast complete"])

  local edTriggerPrecast = makeRadio(editorFrame)
  edTriggerPrecast:SetPoint("LEFT", edTriggerCast.label, "RIGHT", 12, 0)
  edTriggerPrecast.label:SetText(L["Precast (cast bar start)"])

  local edTriggerBoth = makeRadio(editorFrame)
  edTriggerBoth:SetPoint("LEFT", edTriggerPrecast.label, "RIGHT", 12, 0)
  edTriggerBoth.label:SetText(L["Both"])

  local edPrecastSection  -- forward declaration
  local edRefreshPrecastList  -- forward declaration
  local repHeader             -- forward declaration

  local function edSetTriggerMode(mode)
    editorTrigger = mode
    edTriggerCast:SetChecked(mode == "cast")
    edTriggerPrecast:SetChecked(mode == "precast")
    edTriggerBoth:SetChecked(mode == "precast_and_cast")
    if edPrecastSection then
      edPrecastSection:SetShown(mode == "precast_and_cast")
    end
    -- Re-anchor repHeader below precast section or trigger radios
    if repHeader then
      repHeader:ClearAllPoints()
      if mode == "precast_and_cast" then
        repHeader:SetPoint("TOPLEFT", edPrecastSection, "BOTTOMLEFT", 0, -6)
        repHeader:SetText(L["Cast Complete Sound"])
      else
        repHeader:SetPoint("TOPLEFT", edTriggerCast, "BOTTOMLEFT", 0, -6)
        repHeader:SetText(L["Replacement Sound"])
      end
    end
    if edResizeEditor and editorFrame:IsShown() then edResizeEditor() end
  end
  edTriggerCast:SetScript("OnClick", function() edSetTriggerMode("cast") end)
  edTriggerPrecast:SetScript("OnClick", function() edSetTriggerMode("precast") end)
  edTriggerBoth:SetScript("OnClick", function() edSetTriggerMode("precast_and_cast") end)

  -- Precast sound section (only shown when trigger = "precast_and_cast")
  edPrecastSection = CreateFrame("Frame", nil, editorFrame)
  edPrecastSection:SetPoint("TOPLEFT", edTriggerCast, "BOTTOMLEFT", 0, -6)
  edPrecastSection:SetSize(CONTENT_WIDTH - 20, 56)
  edPrecastSection:Hide()

  local precastHeader = edPrecastSection:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  precastHeader:SetPoint("TOPLEFT", 0, 0)
  precastHeader:SetText(L["Precast Sound"])

  local edPrecastFileBox = makeEditBox(edPrecastSection, CONTENT_WIDTH - 240, edPrecastSection, 0, 0, "FID or path")
  edPrecastFileBox:SetPoint("TOPLEFT", precastHeader, "BOTTOMLEFT", 0, -4)

  local edPrecastPlayBtn = makeIconButton(edPrecastSection, "Interface\\Buttons\\UI-SpellbookIcon-NextPage-Up", 22, L["Play / Stop"])
  wirePlayStop(edPrecastPlayBtn, function()
    local v = edPrecastFileBox:GetText()
    return tonumber(v) or (v ~= "" and v or nil)
  end)
  edPrecastPlayBtn:SetPoint("LEFT", edPrecastFileBox, "RIGHT", 4, 0)

  local edPrecastSetBtn = makeButton(edPrecastSection, L["Set"], 36, function()
    local v = edPrecastFileBox:GetText()
    local snd = tonumber(v) or (v ~= "" and v or nil)
    if snd then editorPrecastSound = snd end
    if edRefreshPrecastList then edRefreshPrecastList() end
  end)
  edPrecastSetBtn:SetPoint("LEFT", edPrecastPlayBtn, "RIGHT", 2, 0)

  local edPrecastClearBtn = makeButton(edPrecastSection, L["Clear"], 42, function()
    editorPrecastSound = nil
    edPrecastFileBox:SetText("")
    if edRefreshPrecastList then edRefreshPrecastList() end
  end)
  edPrecastClearBtn:SetPoint("LEFT", edPrecastSetBtn, "RIGHT", 2, 0)

  local edPrecastDisplay = edPrecastSection:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  edPrecastDisplay:SetPoint("TOPLEFT", edPrecastFileBox, "BOTTOMLEFT", 0, -4)
  edPrecastDisplay:SetJustifyH("LEFT")

  -- Precast duration
  local edPrecastDurLabel = edPrecastSection:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  edPrecastDurLabel:SetPoint("LEFT", edPrecastDisplay, "LEFT", 0, 0)

  local edPrecastDurBox  -- will position after display text

  edRefreshPrecastList = function()
    if editorPrecastSound then
      local display
      if type(editorPrecastSound) == "number" then
        local path = lookupFIDPath(editorPrecastSound)
        display = path and (path:match("([^/\\]+)$") or path) or ("FID:" .. editorPrecastSound)
      else
        display = tostring(editorPrecastSound):match("[^/\\]+$") or tostring(editorPrecastSound)
      end
      edPrecastDisplay:SetText(L["Current: "] .. "|cff00ff00" .. display .. "|r")
    else
      edPrecastDisplay:SetText("|cff888888" .. L["(none)"] .. "|r")
    end
    -- Reposition duration label below the display
    edPrecastDurLabel:ClearAllPoints()
    edPrecastDurLabel:SetPoint("TOPLEFT", edPrecastDisplay, "BOTTOMLEFT", 0, -4)
    edPrecastDurLabel:SetText(L["Stop sound after (seconds):"])
    -- Resize section height
    edPrecastSection:SetHeight(76)
    if edResizeEditor and editorFrame:IsShown() then edResizeEditor() end
  end

  edPrecastDurBox = makeEditBox(edPrecastSection, 60, edPrecastSection, 0, 0, "e.g. 1.5")
  edPrecastDurBox:SetPoint("LEFT", edPrecastDurLabel, "RIGHT", 6, 0)
  wireNumericEditBox(edPrecastDurBox, function(val) editorPrecastDuration = val end)

  repHeader = editorFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  repHeader:SetPoint("TOPLEFT", edTriggerCast, "BOTTOMLEFT", 0, -6)
  repHeader:SetText(L["Replacement Sound"])

  local function formatSoundBrief(snd)
    if type(snd) == "number" then
      local path = lookupFIDPath(snd)
      if path then return (path:match("([^/\\]+)$") or path) end
      return "FID:" .. snd
    end
    return tostring(snd):match("[^/\\]+$") or tostring(snd)
  end

  ---------------------------------------------------------------------------
  -- Sound list helpers (manage editorSound table)
  ---------------------------------------------------------------------------
  local edRefreshSoundList  -- forward declaration
  local edBrowseRadio       -- forward declaration (used by edRefreshSoundList)

  local function edSetSound(snd)
    editorSound = snd
    edRefreshSoundList()
  end

  local function edAddFixedSound(snd)
    if editorSound == nil then
      editorSound = snd
    elseif type(editorSound) ~= "table" then
      editorSound = { editorSound, snd }
    else
      editorSound[#editorSound + 1] = snd
    end
    edRefreshSoundList()
  end

  local function edAddRandomSound(snd)
    if editorSound == nil then
      editorSound = { random = { snd } }
    elseif type(editorSound) ~= "table" then
      editorSound = { editorSound, random = { snd } }
    else
      if not editorSound.random then editorSound.random = {} end
      editorSound.random[#editorSound.random + 1] = snd
    end
    edRefreshSoundList()
  end

  local function edRemoveFixedSound(idx)
    if type(editorSound) ~= "table" then
      -- Single sound, removing it
      editorSound = nil
    else
      table.remove(editorSound, idx)
      if #editorSound == 1 and not editorSound.random then
        editorSound = editorSound[1]
      elseif #editorSound == 0 and editorSound.random and #editorSound.random > 0 then
        -- Keep table form (has random pool but no fixed sounds)
      elseif #editorSound == 0 and (not editorSound.random or #editorSound.random == 0) then
        editorSound = nil
      end
    end
    edRefreshSoundList()
  end

  local function edRemoveRandomSound(idx)
    if type(editorSound) ~= "table" or not editorSound.random then return end
    table.remove(editorSound.random, idx)
    if #editorSound.random == 0 then
      editorSound.random = nil
      if #editorSound == 1 then
        editorSound = editorSound[1]
      elseif #editorSound == 0 then
        editorSound = nil
      end
    end
    edRefreshSoundList()
  end

  ---------------------------------------------------------------------------
  -- Sound list display (individual sound rows with play/remove)
  ---------------------------------------------------------------------------
  local edSoundListFrame = CreateFrame("Frame", nil, editorFrame)
  edSoundListFrame:SetPoint("TOPLEFT", repHeader, "BOTTOMLEFT", 0, -4)
  edSoundListFrame:SetWidth(CONTENT_WIDTH - 20)
  edSoundListFrame:SetHeight(ROW_HEIGHT)

  -- Play All button on the header line
  local edPlayAllBtn = makeIconButton(editorFrame, "Interface\\Buttons\\UI-SpellbookIcon-NextPage-Up", 20, L["Play all sounds / Stop"])
  wirePlayStop(edPlayAllBtn, function() return editorSound end)
  edPlayAllBtn:SetPoint("LEFT", repHeader, "RIGHT", 6, 0)

  -- Clear All button on the header line
  local edClearAllBtn = makeIconButton(editorFrame, "Interface\\Buttons\\UI-StopButton", 16, L["Clear all sounds"],
    function() editorSound = nil; edRefreshSoundList() end)
  edClearAllBtn:SetPoint("LEFT", edPlayAllBtn, "RIGHT", 4, 0)

  local edSoundRows = {}

  edRefreshSoundList = function()
    stopAllPreviews()
    for _, row in ipairs(edSoundRows) do row:Hide() end

    local entries = {}
    if editorSound then
      if type(editorSound) == "table" then
        for i, s in ipairs(editorSound) do
          entries[#entries + 1] = { kind = "fixed", sound = s, idx = i }
        end
        if editorSound.random and #editorSound.random > 0 then
          entries[#entries + 1] = { kind = "header", text = L["Random pool (1 picked per cast):"] }
          for i, s in ipairs(editorSound.random) do
            entries[#entries + 1] = { kind = "random", sound = s, idx = i }
          end
        end
      else
        entries[#entries + 1] = { kind = "fixed", sound = editorSound, idx = 1 }
      end
    end

    if #entries == 0 then
      entries[#entries + 1] = { kind = "empty" }
    end

    local yOff = 0
    for i, entry in ipairs(entries) do
      local row = edSoundRows[i]
      if not row then
        row = CreateFrame("Frame", nil, edSoundListFrame)
        row:SetHeight(ROW_HEIGHT)

        row.text = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.text:SetPoint("LEFT", 4, 0)
        row.text:SetJustifyH("LEFT")
        row.text:SetWordWrap(false)

        row.playBtn = makeIconButton(row, "Interface\\Buttons\\UI-SpellbookIcon-NextPage-Up", 20, L["Play / Stop"])
        row.playBtn:SetPoint("RIGHT", row, "RIGHT", -24, 0)

        row.removeBtn = makeIconButton(row, "Interface\\Buttons\\UI-StopButton", 16, L["Remove sound"])
        row.removeBtn:SetPoint("RIGHT", row, "RIGHT", -2, 0)

        edSoundRows[i] = row
      end

      row:ClearAllPoints()
      row:SetPoint("TOPLEFT", edSoundListFrame, "TOPLEFT", 0, -yOff)
      row:SetPoint("RIGHT", edSoundListFrame, "RIGHT", 0, 0)

      if entry.kind == "header" then
        row.text:SetText("|cffaaaaaa" .. entry.text .. "|r")
        row.text:SetPoint("RIGHT", row, "RIGHT", -4, 0)
        row.playBtn:Hide()
        row.removeBtn:Hide()
      elseif entry.kind == "empty" then
        row.text:SetText("|cff888888" .. L["(none)"] .. "|r")
        row.text:SetPoint("RIGHT", row, "RIGHT", -4, 0)
        row.playBtn:Hide()
        row.removeBtn:Hide()
      else
        local display = formatSoundBrief(entry.sound)
        if entry.kind == "random" then
          display = "  " .. display
        end
        row.text:SetText("|cff00ff00" .. display .. "|r")
        row.text:SetPoint("RIGHT", row.playBtn, "LEFT", -4, 0)
        row.playBtn:Show()
        local snd = entry.sound
        wirePlayStop(row.playBtn, function() return snd end)
        row.removeBtn:Show()
        local eKind, eIdx = entry.kind, entry.idx
        row.removeBtn:SetScript("OnClick", function()
          if eKind == "fixed" then
            edRemoveFixedSound(eIdx)
          else
            edRemoveRandomSound(eIdx)
          end
        end)
      end

      row:Show()
      yOff = yOff + ROW_HEIGHT
    end

    local listH = math.max(ROW_HEIGHT, yOff)
    edSoundListFrame:SetHeight(listH)

    -- Re-anchor browse section below the sound list
    edBrowseRadio:ClearAllPoints()
    edBrowseRadio:SetPoint("TOPLEFT", edSoundListFrame, "BOTTOMLEFT", 0, -6)

    -- Resize editor frame if open
    if editorFrame:IsShown() and edResizeEditor then edResizeEditor() end
  end


  edBrowseRadio = makeRadio(editorFrame)
  edBrowseRadio:SetPoint("TOPLEFT", edSoundListFrame, "BOTTOMLEFT", 0, -6)
  edBrowseRadio.label:SetText(L["Browse"])

  local edFileRadio = makeRadio(editorFrame)
  edFileRadio:SetPoint("LEFT", edBrowseRadio.label, "RIGHT", 12, 0)
  edFileRadio.label:SetText(L["File Path / FID"])

  local edBrowseBox = makeEditBox(editorFrame, CONTENT_WIDTH - 60, edBrowseRadio, 0, -4, L["Search spell sounds..."])
  edBrowseBox:SetPoint("TOPLEFT", edBrowseRadio, "BOTTOMLEFT", 0, -4)

  local edBrowseDD
  edBrowseDD = createAutocomplete(edBrowseBox,
    function(e) if e then return e.fileDataID end end,
    function(e)
      edSetSound(e.fileDataID)
      edBrowseDD:Hide()
    end,
    { label = L["Replace"], width = 52, tooltip = L["Replace all sounds with this one"] },
    CONTENT_WIDTH,
    {
      { label = L["Add"], width = 36, tooltip = L["Add as an additional fixed sound (always plays)"],
        onClick = function(e)
          edAddFixedSound(e.fileDataID)
          edBrowseDD:Hide()
        end },
      { label = L["+Rnd"], width = 38, tooltip = L["Add to the random pool (1 picked at random per cast)"],
        onClick = function(e)
          edAddRandomSound(e.fileDataID)
          edBrowseDD:Hide()
        end },
    }
  )

  local function edDoBrowseSearch()
    if not edBrowseBox:HasFocus() then return end
    local q = edBrowseBox:GetText()
    if #q < 3 then edBrowseDD:SetData({}, ""); edBrowseDD:Hide(); return end
    searchDB(Resonance.SpellSounds, q, "edBrowse", function(results)
      for _, r in ipairs(results) do
        local filename = r.path:match("([^/\\]+)$") or r.path
        local parent = r.path:match("([^/\\]+)[/\\][^/\\]+$")
        r.display = filename
        r.subdisplay = (parent and (parent .. "/  \194\183  ") or "") .. "#" .. r.fileDataID
      end
      edBrowseDD:SetData(results, #results == 0 and L["No matches."] or L["%d results"]:format(#results))
    end, Resonance.SpellSoundPrefixes)
  end

  local edBrowseClear = makeClearButton(edBrowseBox, function() edBrowseDD:Hide() end)

  edBrowseBox:SetScript("OnTextChanged", function(self)
    if self.placeholder then self.placeholder:SetShown(self:GetText() == "" and not self:HasFocus()) end
    edBrowseClear:SetShown(self:GetText() ~= "")
    debounce("edBrowse", 0.3, edDoBrowseSearch)
  end)
  edBrowseBox:SetScript("OnEditFocusGained", function(self)
    if self.placeholder then self.placeholder:Hide() end
    edDoBrowseSearch()
  end)
  edBrowseBox:SetScript("OnEditFocusLost", function(self)
    if self.placeholder then self.placeholder:SetShown(self:GetText() == "") end
    C_Timer.After(0.2, function()
      if not edBrowseBox:HasFocus() and not edBrowseDD:IsMouseOver() then edBrowseDD:Hide() end
    end)
  end)
  edBrowseBox:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
  edBrowseBox:SetScript("OnEscapePressed", function(self) edBrowseDD:Hide(); self:ClearFocus() end)

  local edFileFrame = CreateFrame("Frame", nil, editorFrame)
  edFileFrame:SetPoint("TOPLEFT", edBrowseRadio, "BOTTOMLEFT", 0, -4)
  edFileFrame:SetSize(CONTENT_WIDTH - 20, 50)

  local edFileBox = makeEditBox(edFileFrame, CONTENT_WIDTH - 240, edFileFrame, 0, 0, "path or FID")
  edFileBox:SetPoint("TOPLEFT", edFileFrame, "TOPLEFT", 0, 0)

  local edFilePlayBtn = makeIconButton(edFileFrame, "Interface\\Buttons\\UI-SpellbookIcon-NextPage-Up", 22, L["Play / Stop"])
  wirePlayStop(edFilePlayBtn, function()
    local v = edFileBox:GetText()
    return tonumber(v) or v
  end)
  edFilePlayBtn:SetPoint("LEFT", edFileBox, "RIGHT", 4, 0)

  local function edGetFileValue()
    local v = edFileBox:GetText()
    if v == "" then return nil end
    return tonumber(v) or v
  end

  local function addButtonTooltip(btn, text)
    btn:SetScript("OnEnter", function(self)
      GameTooltip:SetOwner(self, "ANCHOR_TOP")
      GameTooltip:AddLine(text, 1, 1, 1, true)
      GameTooltip:Show()
    end)
    btn:SetScript("OnLeave", function() GameTooltip:Hide() end)
  end

  local edFileReplaceBtn = makeButton(edFileFrame, L["Replace"], 52, function()
    local v = edGetFileValue()
    if v then edSetSound(v) end
  end)
  edFileReplaceBtn:SetPoint("LEFT", edFilePlayBtn, "RIGHT", 2, 0)
  addButtonTooltip(edFileReplaceBtn, L["Replace all sounds with this one"])

  local edFileAddBtn = makeButton(edFileFrame, L["Add"], 36, function()
    local v = edGetFileValue()
    if v then edAddFixedSound(v) end
  end)
  edFileAddBtn:SetPoint("LEFT", edFileReplaceBtn, "RIGHT", 2, 0)
  addButtonTooltip(edFileAddBtn, L["Add as an additional fixed sound (always plays)"])

  local edFileRndBtn = makeButton(edFileFrame, L["+Rnd"], 40, function()
    local v = edGetFileValue()
    if v then edAddRandomSound(v) end
  end)
  edFileRndBtn:SetPoint("LEFT", edFileAddBtn, "RIGHT", 2, 0)
  addButtonTooltip(edFileRndBtn, L["Add to the random pool (1 picked at random per cast)"])

  local edInputAnchor  -- forward-declared; created below duration section
  local function edSetSoundMode(isBrowse)
    edBrowseRadio:SetChecked(isBrowse)
    edFileRadio:SetChecked(not isBrowse)
    edBrowseBox:SetShown(isBrowse)
    if edBrowseBox.clearBtn then edBrowseBox.clearBtn:SetShown(isBrowse and edBrowseBox:GetText() ~= "") end
    edFileFrame:SetShown(not isBrowse)
    if not isBrowse then edBrowseDD:Hide() end
    -- Re-anchor input anchor below the active input area
    if edInputAnchor then
      edInputAnchor:ClearAllPoints()
      if isBrowse then
        edInputAnchor:SetPoint("TOPLEFT", edBrowseBox, "BOTTOMLEFT", 0, -8)
      else
        edInputAnchor:SetPoint("TOPLEFT", edFileFrame, "BOTTOMLEFT", 0, -8)
      end
    end
  end
  edBrowseRadio:SetScript("OnClick", function() edSetSoundMode(true) end)
  edFileRadio:SetScript("OnClick", function() edSetSoundMode(false) end)

  ---------------------------------------------------------------------------
  -- Duration control (stop sound after N seconds)
  ---------------------------------------------------------------------------
  -- Anchor point below the active input area (browse or file-path)
  edInputAnchor = CreateFrame("Frame", nil, editorFrame)
  edInputAnchor:SetSize(CONTENT_WIDTH - 20, 1)
  edInputAnchor:SetPoint("TOPLEFT", edBrowseBox, "BOTTOMLEFT", 0, -8)

  local edDurationFrame = CreateFrame("Frame", nil, editorFrame)
  edDurationFrame:SetSize(CONTENT_WIDTH - 20, 24)
  edDurationFrame:SetPoint("TOPLEFT", edInputAnchor, "TOPLEFT", 0, 0)

  local edDurationLabel = edDurationFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  edDurationLabel:SetPoint("LEFT", edDurationFrame, "LEFT", 0, 0)
  edDurationLabel:SetText(L["Stop sound after (seconds):"])

  local edDurationBox = CreateFrame("EditBox", nil, edDurationFrame, "InputBoxTemplate")
  edDurationBox:SetSize(60, 22)
  edDurationBox:SetPoint("LEFT", edDurationLabel, "RIGHT", 6, 0)
  edDurationBox:SetAutoFocus(false)
  do
    edDurationBox.placeholder = edDurationBox:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    edDurationBox.placeholder:SetPoint("LEFT", 4, 0)
    edDurationBox.placeholder:SetText("e.g. 1.5")
    local function upd(self)
      self.placeholder:SetShown(self:GetText() == "" and not self:HasFocus())
    end
    edDurationBox:SetScript("OnEditFocusGained", function(self) self.placeholder:Hide() end)
    edDurationBox:SetScript("OnEditFocusLost", upd)
    edDurationBox:SetScript("OnTextChanged", upd)
    edDurationBox:SetScript("OnShow", upd)
  end
  wireNumericEditBox(edDurationBox, function(val) editorDuration = val end)

  local edDurationClearBtn = makeButton(edDurationFrame, L["Clear"], 42, function()
    edDurationBox:SetText("")
    editorDuration = nil
  end)
  edDurationClearBtn:SetPoint("LEFT", edDurationBox, "RIGHT", 4, 0)

  local edLoopCheck = CreateFrame("CheckButton", nil, edDurationFrame, "UICheckButtonTemplate")
  edLoopCheck:SetSize(22, 22)
  edLoopCheck:SetPoint("LEFT", edDurationClearBtn, "RIGHT", 8, 0)
  edLoopCheck.text:SetFontObject("GameFontNormalSmall")
  edLoopCheck.text:SetText(L["Loop"])
  edLoopCheck:SetScript("OnClick", function(self)
    editorLoop = self:GetChecked() and true or nil
  end)
  edLoopCheck:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    GameTooltip:AddLine(L["Repeat the sound until the next cast. Requires a duration to be set."], 1, 1, 1, true)
    GameTooltip:Show()
  end)
  edLoopCheck:SetScript("OnLeave", function() GameTooltip:Hide() end)

  local function edSetMuteOnly(muteOnly)
    edMuteOnlyCheck:SetChecked(muteOnly)
    -- Hide/show the trigger and replacement sound sections
    edTriggerLabel:SetShown(not muteOnly)
    edTriggerCast:SetShown(not muteOnly)
    edTriggerPrecast:SetShown(not muteOnly)
    edTriggerBoth:SetShown(not muteOnly)
    edPrecastSection:SetShown(not muteOnly and editorTrigger == "precast_and_cast")
    repHeader:SetShown(not muteOnly)
    edSoundListFrame:SetShown(not muteOnly)
    edPlayAllBtn:SetShown(not muteOnly)
    edClearAllBtn:SetShown(not muteOnly)
    edBrowseRadio:SetShown(not muteOnly)
    edFileRadio:SetShown(not muteOnly)
    edBrowseBox:SetShown(not muteOnly and edBrowseRadio:GetChecked())
    if edBrowseBox.clearBtn then edBrowseBox.clearBtn:SetShown(not muteOnly and edBrowseRadio:GetChecked() and edBrowseBox:GetText() ~= "") end
    edFileFrame:SetShown(not muteOnly and not edBrowseRadio:GetChecked())
    edDurationFrame:SetShown(not muteOnly)
    if muteOnly then edBrowseDD:Hide() end
    -- Re-anchor auto-mute section below the appropriate element
    autoMuteAnchor:ClearAllPoints()
    if muteOnly then
      autoMuteAnchor:SetPoint("TOPLEFT", edMuteOnlyCheck, "BOTTOMLEFT", 0, -12)
    else
      autoMuteAnchor:SetPoint("TOPLEFT", edDurationFrame, "BOTTOMLEFT", 0, -8)
    end
    if edResizeEditor and editorFrame:IsShown() then edResizeEditor() end
  end
  edMuteOnlyCheck:SetScript("OnClick", function(self)
    local checked = self:GetChecked()
    if checked then
      editorSound = false
    else
      editorSound = nil
    end
    edSetMuteOnly(checked)
    edRefreshSoundList()
  end)

  -- Auto-Muted Sounds section
  local AUTO_MUTE_VISIBLE_ROWS = 8
  local AUTO_MUTE_SCROLL_H = AUTO_MUTE_VISIBLE_ROWS * ROW_HEIGHT

  edResizeEditor = function()
    local muteOnly = edMuteOnlyCheck:GetChecked()
    local baseH
    if muteOnly then
      -- No replacement sound section -- just checkbox + auto-mute area
      baseH = 180
    else
      local soundListH = edSoundListFrame:GetHeight()
      local extraSoundH = math.max(0, soundListH - ROW_HEIGHT)
      baseH = 455 + extraSoundH  -- includes trigger radios + duration section
      if editorTrigger == "precast_and_cast" then
        baseH = baseH + (edPrecastSection:GetHeight() or 76) + 6
      end
    end
    local sid = tonumber(edSpellIDBox:GetText())
    local hasMuteData = sid and Resonance.getSpellMuteFIDs(sid)
    if hasMuteData then
      editorFrame:SetHeight(baseH + 30 + AUTO_MUTE_SCROLL_H + 14)
    else
      editorFrame:SetHeight(baseH + 30)
    end
  end

  autoMuteAnchor = CreateFrame("Frame", nil, editorFrame)
  autoMuteAnchor:SetSize(CONTENT_WIDTH - 20, 1)
  autoMuteAnchor:SetPoint("TOPLEFT", edDurationFrame, "BOTTOMLEFT", 0, -8)

  local autoMuteHeader = editorFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  autoMuteHeader:SetPoint("TOPLEFT", autoMuteAnchor, "TOPLEFT", 0, 0)
  autoMuteHeader:SetText(L["Auto-Muted Sounds"])

  local autoMuteInfo = editorFrame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  autoMuteInfo:SetPoint("TOPLEFT", autoMuteHeader, "BOTTOMLEFT", 0, -4)
  autoMuteInfo:SetWidth(CONTENT_WIDTH - 40)
  autoMuteInfo:SetJustifyH("LEFT")
  autoMuteInfo:SetWordWrap(true)

  local autoMuteScroll = CreateFrame("ScrollFrame", "ResonanceAutoMuteScroll", editorFrame, "UIPanelScrollFrameTemplate")
  autoMuteScroll:SetPoint("TOPLEFT", autoMuteInfo, "BOTTOMLEFT", 0, -2)
  autoMuteScroll:SetPoint("BOTTOMRIGHT", editorFrame, "BOTTOMRIGHT", -40, 46)
  autoMuteScroll:SetWidth(CONTENT_WIDTH - 40)

  local autoMuteScrollBar = autoMuteScroll.ScrollBar or _G["ResonanceAutoMuteScrollScrollBar"]

  local autoMuteBg = autoMuteScroll:CreateTexture(nil, "BACKGROUND")
  autoMuteBg:SetAllPoints()
  autoMuteBg:SetColorTexture(0, 0, 0, 0.15)

  local autoMuteContent = CreateFrame("Frame")
  autoMuteScroll:SetScrollChild(autoMuteContent)
  autoMuteContent:SetWidth(CONTENT_WIDTH - 60)
  autoMuteContent:SetHeight(1)

  local autoMuteRows = {}

  refreshAutoMuteSection = function(spellID)
    for _, row in ipairs(autoMuteRows) do row:Hide() end

    if not spellID then
      autoMuteInfo:SetText("|cff888888" .. L["No auto-mute data available."] .. "|r")
      autoMuteScroll:Hide()
      return
    end

    local fids = Resonance.getSpellMuteFIDs(spellID)
    if not fids or #fids == 0 then
      autoMuteInfo:SetText("|cff888888" .. L["No auto-mute data for this spell."] .. "|r")
      autoMuteScroll:Hide()
      return
    end

    local entries = {}
    for _, fid in ipairs(fids) do
      entries[#entries + 1] = { type = "sound", fid = fid }
    end

    autoMuteInfo:SetText(L["%d spell sound(s) — uncheck to keep a sound unmuted:"]:format(#fids))
    autoMuteScroll:Show()

    for i, entry in ipairs(entries) do
      local row = autoMuteRows[i]
      if not row then
        row = CreateFrame("Frame", nil, autoMuteContent)
        row:SetSize(CONTENT_WIDTH - 60, ROW_HEIGHT)
        row:SetPoint("TOPLEFT", 0, -(i - 1) * ROW_HEIGHT)

        row.text = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.text:SetPoint("LEFT", 4, 0)
        row.text:SetPoint("RIGHT", row, "RIGHT", -48, 0)
        row.text:SetJustifyH("LEFT")
        row.text:SetWordWrap(false)

        row.playBtn = makeIconButton(row, "Interface\\Buttons\\UI-SpellbookIcon-NextPage-Up", 22, L["Play / Stop"])
        row.playBtn:SetPoint("RIGHT", row, "RIGHT", -2, 0)

        row.muteBtn = CreateFrame("CheckButton", nil, row, "UICheckButtonTemplate")
        row.muteBtn:SetSize(22, 22)
        row.muteBtn:SetPoint("RIGHT", row.playBtn, "LEFT", -2, 0)
        row.muteBtn:SetHitRectInsets(0, 0, 0, 0)
        row.muteBtn.text:SetText("")
        row.muteBtn:SetScript("OnEnter", function(self)
          GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
          GameTooltip:AddLine(self:GetChecked() and L["Muted (click to unmute)"] or L["Not muted (click to mute)"], 1, 1, 1)
          GameTooltip:Show()
        end)
        row.muteBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

        autoMuteRows[i] = row
      end

      -- Adjust text width to make room for checkbox
      row.text:SetPoint("RIGHT", row, "RIGHT", -72, 0)

      -- Reset stripe
      if not row.stripe then
        row.stripe = row:CreateTexture(nil, "BACKGROUND")
        row.stripe:SetAllPoints()
      end

      local path = lookupFIDPath(entry.fid)
      if path then
        row.text:SetText(formatSoundDisplay(path, entry.fid))
      else
        row.text:SetText("|cffff8800" .. entry.fid .. "|r")
      end
      local entryFid = entry.fid
      wirePlayStop(row.playBtn, function() return entryFid end)
      row.playBtn:Show()

      -- Mute checkbox: checked = muted (not excluded)
      local isExcluded = editorExclusions[entry.fid]
      row.muteBtn:SetChecked(not isExcluded)
      row.muteBtn:SetScript("OnClick", function(self)
        if self:GetChecked() then
          editorExclusions[entry.fid] = nil
        else
          editorExclusions[entry.fid] = true
        end
      end)
      row.muteBtn:Show()

      if i % 2 == 0 then
        row.stripe:SetColorTexture(1, 1, 1, 0.06)
        row.stripe:Show()
      else
        row.stripe:Hide()
      end

      row:Show()
    end

    autoMuteContent:SetHeight(#entries * ROW_HEIGHT)

    -- Only show scrollbar when content overflows
    if autoMuteScrollBar then
      local visibleH = autoMuteScroll:GetHeight()
      if visibleH and #entries * ROW_HEIGHT > visibleH then
        autoMuteScrollBar:Show()
      else
        autoMuteScrollBar:Hide()
        autoMuteScroll:SetVerticalScroll(0)
      end
    end
  end

  -- Save / Cancel
  local edCancelBtn = makeButton(editorFrame, L["Cancel"], 60, nil)
  edCancelBtn:SetPoint("BOTTOMRIGHT", editorFrame, "BOTTOMRIGHT", -18, 16)

  local edSaveBtn = makeButton(editorFrame, L["Save"], 60, nil)
  edSaveBtn:SetPoint("RIGHT", edCancelBtn, "LEFT", -4, 0)

  local refreshList  -- forward declaration

  local function closeEditor()
    editorFrame:Hide()
    edBrowseDD:Hide()
    edSpellSearchDD:Hide()
  end
  edCloseBtn:SetScript("OnClick", closeEditor)

  local function openEditor(spellID)
    profile = Resonance.db.profile
    editorSound = nil
    editorDuration = nil
    editorLoop = nil
    editorTrigger = "cast"
    editorPrecastSound = nil
    editorPrecastDuration = nil
    wipe(editorExclusions)
    edBrowseBox:SetText("")
    edBrowseDD:Hide()
    edSpellSearchBox:SetText("")
    edSpellSearchDD:Hide()
    edFileBox:SetText("")
    edDurationBox:SetText("")
    edLoopCheck:SetChecked(false)
    edPrecastFileBox:SetText("")
    edPrecastDurBox:SetText("")

    local isNew = not spellID
    if spellID then
      edSpellIDBox:SetText(tostring(spellID))
      edSpellIDBox:Disable()
      local cfg = profile.spell_config[spellID]
      if cfg then
        -- Deep-copy sound table so edits don't modify saved config directly
        if type(cfg.sound) == "table" then
          editorSound = {}
          for i, s in ipairs(cfg.sound) do editorSound[i] = s end
          if cfg.sound.random then
            editorSound.random = {}
            for i, s in ipairs(cfg.sound.random) do editorSound.random[i] = s end
          end
        else
          editorSound = cfg.sound
        end
        if cfg.muteExclusions then
          for fid in pairs(cfg.muteExclusions) do editorExclusions[fid] = true end
        end
        if cfg.duration then
          editorDuration = cfg.duration
          edDurationBox:SetText(tostring(cfg.duration))
        end
        if cfg.loop then
          editorLoop = cfg.loop
          edLoopCheck:SetChecked(true)
        end
        if cfg.trigger then
          editorTrigger = cfg.trigger
        end
        if cfg.precastSound then
          editorPrecastSound = cfg.precastSound
          if type(cfg.precastSound) == "number" then
            edPrecastFileBox:SetText(tostring(cfg.precastSound))
          elseif type(cfg.precastSound) == "string" then
            edPrecastFileBox:SetText(cfg.precastSound)
          end
        end
        if cfg.precastDuration then
          editorPrecastDuration = cfg.precastDuration
          edPrecastDurBox:SetText(tostring(cfg.precastDuration))
        end
      end
      local name = Resonance.getSpellName(spellID)
      edTitle:SetText(L["Configure: "] .. (name or "Spell " .. spellID))
    else
      edSpellIDBox:SetText("")
      edSpellIDBox:Enable()
      edTitle:SetText(L["Add New Spell"])
    end

    edSpellSearchLabel:SetShown(isNew)
    edSpellSearchBox:SetShown(isNew)
    if edSpellSearchBox.clearBtn then edSpellSearchBox.clearBtn:SetShown(false) end
    repAnchor:ClearAllPoints()
    if isNew then
      repAnchor:SetPoint("TOPLEFT", edSpellSearchBox, "BOTTOMLEFT", 4, -12)
    else
      repAnchor:SetPoint("TOPLEFT", edSpellIDBox, "BOTTOMLEFT", 4, -12)
    end

    edUpdateSpellPreview()
    edRefreshSoundList()
    edSetSoundMode(hasSpellDB())
    edSetTriggerMode(editorTrigger)
    edRefreshPrecastList()
    edSetMuteOnly(editorSound == false)
    refreshAutoMuteSection(spellID)
    edResizeEditor()

    editorFrame:Show()
  end

  edCancelBtn:SetScript("OnClick", closeEditor)

  edSaveBtn:SetScript("OnClick", function()
    profile = Resonance.db.profile
    local sid = tonumber(edSpellIDBox:GetText())
    if not sid or sid <= 0 then Resonance.msg(L["Enter a valid spell ID."]); return end
    if editorSound == nil then
      Resonance.msg(L["Select a replacement sound or enable 'Mute only'."])
      return
    end
    local isNew = not profile.spell_config[sid]
    -- Build exclusions table (only save if non-empty)
    local exclusions = nil
    for fid in pairs(editorExclusions) do
      if not exclusions then exclusions = {} end
      exclusions[fid] = true
    end
    -- Only save trigger/precast fields if non-default
    local trigger = editorTrigger ~= "cast" and editorTrigger or nil
    local precastSound = (editorTrigger == "precast_and_cast") and editorPrecastSound or nil
    local precastDuration = (editorTrigger == "precast_and_cast") and editorPrecastDuration or nil
    if isNew then
      profile.spell_config[sid] = { sound = editorSound, muteExclusions = exclusions, duration = editorDuration, loop = editorLoop, trigger = trigger, precastSound = precastSound, precastDuration = precastDuration }
      Resonance.applyAutoMutesForSpell(sid)
    else
      -- Remove old mutes (using old exclusions), update config, re-apply with new exclusions
      Resonance.removeAutoMutesForSpell(sid)
      profile.spell_config[sid] = { sound = editorSound, muteExclusions = exclusions, duration = editorDuration, loop = editorLoop, trigger = trigger, precastSound = precastSound, precastDuration = precastDuration }
      Resonance.applyAutoMutesForSpell(sid)
    end
    Resonance.invalidateSpellNameIndex()
    closeEditor()
    refreshList()
  end)

  addBtn:SetScript("OnClick", function() openEditor(nil) end)

  clearPresetsBtn:SetScript("OnClick", function()
    profile = Resonance.db.profile
    local removed = Resonance:RemovePresetSpells()
    closeEditor()
    refreshList()
    Resonance.msg(L["Cleared %d preset spells."]:format(removed))
  end)

  clearAllSpellsBtn:SetScript("OnClick", function()
    profile = Resonance.db.profile
    for sid in pairs(profile.spell_config or {}) do
      Resonance.removeAutoMutesForSpell(sid)
    end
    wipe(profile.spell_config)
    wipe(profile.preset_spells)
    Resonance.invalidateSpellNameIndex()
    closeEditor()
    refreshList()
    Resonance.msg(L["Cleared all spell sound configurations."])
  end)

  -- Spell list rendering
  local listHeaders = {}  -- reusable class header frames
  local collapsedGroups = {}  -- { [groupKey] = true } for collapsed sections
  local collapsedInitialized = false  -- set defaults on first render

  local function getOrCreateHeader(idx)
    if listHeaders[idx] then return listHeaders[idx] end
    local hdr = CreateFrame("Button", nil, listContainer)
    hdr:SetHeight(ROW_HEIGHT)
    local bg = hdr:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(0.2, 0.2, 0.25, 0.5)
    hdr.bg = bg
    hdr.arrow = hdr:CreateTexture(nil, "OVERLAY")
    hdr.arrow:SetSize(16, 16)
    hdr.arrow:SetPoint("LEFT", 4, 0)
    hdr.text = hdr:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    hdr.text:SetPoint("LEFT", hdr.arrow, "RIGHT", 2, 0)
    hdr.text:SetJustifyH("LEFT")
    hdr.count = hdr:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    hdr.count:SetPoint("LEFT", hdr.text, "RIGHT", 6, 0)
    hdr.count:SetTextColor(0.6, 0.6, 0.6)
    -- Highlight on hover
    hdr.highlight = hdr:CreateTexture(nil, "HIGHLIGHT")
    hdr.highlight:SetAllPoints()
    hdr.highlight:SetColorTexture(1, 1, 1, 0.05)
    listHeaders[idx] = hdr
    return hdr
  end

  local function getOrCreateRow(idx)
    if listRows[idx] then return listRows[idx] end
    local row = CreateFrame("Frame", nil, listContainer)
    row:SetHeight(ROW_HEIGHT)
    listRows[idx] = row

    row.nameText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.nameText:SetPoint("LEFT", 4, 0)
    row.nameText:SetWidth(200)
    row.nameText:SetJustifyH("LEFT")
    row.nameText:SetWordWrap(false)

    row.soundText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.soundText:SetPoint("LEFT", row.nameText, "RIGHT", 8, 0)
    row.soundText:SetPoint("RIGHT", row, "RIGHT", -58, 0)
    row.soundText:SetJustifyH("LEFT")
    row.soundText:SetWordWrap(false)

    row.playBtn = makeIconButton(row, "Interface\\Buttons\\UI-SpellbookIcon-NextPage-Up", 22, L["Play / Stop"])
    row.playBtn:SetPoint("RIGHT", row, "RIGHT", -36, 0)

    row.editBtn = makeIconButton(row, "Interface\\WorldMap\\GEAR_64GREY", 20, L["Edit"])
    row.editBtn:SetPoint("RIGHT", row, "RIGHT", -18, 0)

    row.delBtn = makeIconButton(row, "Interface\\Buttons\\UI-StopButton", 18, L["Delete"])
    row.delBtn:SetPoint("RIGHT", row, "RIGHT", -2, 0)

    return row
  end

  refreshList = function()
    profile = Resonance.db.profile
    for _, row in ipairs(listRows) do row:Hide() end
    for _, hdr in ipairs(listHeaders) do hdr:Hide() end

    -- Group spells by source, only showing the player's class and custom spells
    local groups = {}       -- source -> { {spellID, cfg}, ... }
    local groupSet = {}     -- track which sources exist
    for sid, cfg in pairs(profile.spell_config or {}) do
      if cfg.sound ~= nil then
        local source = profile.preset_spells and profile.preset_spells[sid]
        local key = source or "_custom"
        -- Only show player's own class, saved presets, and custom spells
        if key == playerClass or key == "_custom" or not CLASS_DISPLAY[key] then
          if not groups[key] then
            groups[key] = {}
            groupSet[key] = true
          end
          groups[key][#groups[key] + 1] = { spellID = sid, cfg = cfg }
        end
      end
    end

    -- Sort spells within each group by spell name
    for _, spells in pairs(groups) do
      table.sort(spells, function(a, b)
        local na = Resonance.getSpellName(a.spellID) or ""
        local nb = Resonance.getSpellName(b.spellID) or ""
        return na < nb
      end)
    end

    -- Build ordered list of group keys: player's class first, then saved presets, then custom
    local orderedKeys = {}
    if groupSet[playerClass] then
      orderedKeys[#orderedKeys + 1] = playerClass
      groupSet[playerClass] = nil
    end
    local extras = {}
    for key in pairs(groupSet) do
      if key ~= "_custom" then extras[#extras + 1] = key end
    end
    table.sort(extras)
    for _, key in ipairs(extras) do orderedKeys[#orderedKeys + 1] = key end
    if groups["_custom"] then orderedKeys[#orderedKeys + 1] = "_custom" end

    -- Default: everything collapsed
    if not collapsedInitialized and #orderedKeys > 0 then
      for _, key in ipairs(orderedKeys) do
        collapsedGroups[key] = true
      end
      collapsedInitialized = true
    end

    -- Render grouped list
    local yOff = 0
    local rowIdx = 0
    local hdrIdx = 0
    local totalSpells = 0

    for _, key in ipairs(orderedKeys) do
      local spells = groups[key]
      local collapsed = collapsedGroups[key]

      -- Class/group header
      hdrIdx = hdrIdx + 1
      local hdr = getOrCreateHeader(hdrIdx)
      hdr:ClearAllPoints()
      hdr:SetPoint("TOPLEFT", listContainer, "TOPLEFT", 0, -yOff)
      hdr:SetPoint("RIGHT", listContainer, "RIGHT", 0, 0)

      local displayName = CLASS_DISPLAY[key] or (key == "_custom" and L["Custom"] or key)
      local cc = RAID_CLASS_COLORS and RAID_CLASS_COLORS[key]
      if cc then
        hdr.text:SetText(cc:WrapTextInColorCode(displayName))
      else
        hdr.text:SetText(displayName)
      end
      hdr.arrow:SetTexture(collapsed and "Interface\\Buttons\\UI-PlusButton-UP" or "Interface\\Buttons\\UI-MinusButton-UP")
      hdr.count:SetText("(" .. #spells .. ")")
      local hdrKey = key
      hdr:SetScript("OnClick", function()
        collapsedGroups[hdrKey] = not collapsedGroups[hdrKey]
        refreshList()
      end)
      hdr:Show()
      yOff = yOff + ROW_HEIGHT

      -- Spell rows (skip if collapsed)
      if not collapsed then
        for i, entry in ipairs(spells) do
          rowIdx = rowIdx + 1
          totalSpells = totalSpells + 1
          local row = getOrCreateRow(rowIdx)
          row:ClearAllPoints()
          row:SetPoint("TOPLEFT", listContainer, "TOPLEFT", 0, -yOff)
          row:SetPoint("RIGHT", listContainer, "RIGHT", 0, 0)

          if i % 2 == 0 then
            if not row.stripe then
              row.stripe = row:CreateTexture(nil, "BACKGROUND")
              row.stripe:SetAllPoints()
              row.stripe:SetColorTexture(1, 0.82, 0, 0.08)
            end
            row.stripe:Show()
          elseif row.stripe then row.stripe:Hide() end

          local spellName = Resonance.getSpellName(entry.spellID) or "?"
          row.nameText:SetText(spellName .. " |cff888888(" .. entry.spellID .. ")|r")

          local cfg = entry.cfg
          local sound = cfg.sound
          if sound == false then
            row.soundText:SetText("|cffff8800" .. L["Muted (no replacement)"] .. "|r")
            row.playBtn:SetEnabled(false)
          elseif type(sound) == "table" then
            local parts = {}
            for _, s in ipairs(sound) do parts[#parts + 1] = formatSoundBrief(s) end
            if sound.random then
              parts[#parts + 1] = L["+1 random from %d"]:format(#sound.random)
            end
            row.soundText:SetText("|cff00ff00" .. table.concat(parts, ", ") .. "|r")
            row.playBtn:SetEnabled(true)
            local cfgSound = cfg.sound
            wirePlayStop(row.playBtn, function() return cfgSound end)
          elseif type(sound) == "number" then
            local path = lookupFIDPath(sound)
            if path then
              row.soundText:SetText(formatSoundDisplay(path, sound))
            else
              row.soundText:SetText("|cff00ff00FID:" .. sound .. "|r")
            end
            row.playBtn:SetEnabled(true)
            local cfgSound = cfg.sound
            wirePlayStop(row.playBtn, function() return cfgSound end)
          else
            local filename = tostring(sound):match("[^/\\]+$") or tostring(sound)
            row.soundText:SetText("|cff00ff00" .. filename .. "|r")
            row.playBtn:SetEnabled(true)
            local cfgSound = cfg.sound
            wirePlayStop(row.playBtn, function() return cfgSound end)
          end
          -- Append duration and trigger indicators if configured
          local indicators = ""
          if cfg.duration then
            indicators = indicators .. ("%.1fs"):format(cfg.duration)
          end
          if cfg.loop then
            indicators = indicators .. (indicators ~= "" and ", " or "") .. "loop"
          end
          if cfg.trigger == "precast" then
            indicators = indicators .. (indicators ~= "" and ", " or "") .. "precast"
          elseif cfg.trigger == "precast_and_cast" then
            indicators = indicators .. (indicators ~= "" and ", " or "") .. "precast+cast"
          end
          if indicators ~= "" then
            local cur = row.soundText:GetText() or ""
            row.soundText:SetText(cur .. " |cffaaaaaa(" .. indicators .. ")|r")
          end
          row.editBtn:SetScript("OnClick", function() openEditor(entry.spellID) end)
          row.delBtn:SetScript("OnClick", function()
            Resonance.removeAutoMutesForSpell(entry.spellID)
            Resonance.db.profile.spell_config[entry.spellID] = nil
            Resonance.db.profile.preset_spells[entry.spellID] = nil
            Resonance.invalidateSpellNameIndex()
            closeEditor()
            refreshList()
          end)

          row:Show()
          yOff = yOff + ROW_HEIGHT
        end
      else
        totalSpells = totalSpells + #spells
      end
    end

    local totalH = math.max(yOff, ROW_HEIGHT)
    listContainer:SetHeight(totalH)
    listEmpty:SetShown(totalSpells == 0)
    recalcContentHeight(2)
  end

  -- Publish to ctx
  ctx.refreshList = refreshList
  ctx.editorFrame = editorFrame
  ctx.edBrowseDD = edBrowseDD
  ctx.edSpellSearchDD = edSpellSearchDD
  ctx.closeEditor = closeEditor
end

---------------------------------------------------------------------------
-- Tab 3: Muted Sounds
---------------------------------------------------------------------------
buildTab3_MutedSounds = function(ctx)
  local recalcContentHeight = ctx.recalcContentHeight
  local playerClass = ctx.playerClass
  local profile = Resonance.db.profile

  local muteTab = ctx.mutedSoundsContent

  -- Data unavailable banner
  local muteBanner
  if not ctx.dataLoaded then
    muteBanner = showDataUnavailableBanner(muteTab, select(2, Resonance.loadDataAddon()))
  end

  -- Tab heading
  local muteTabHdr = muteTab:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
  muteTabHdr:SetPoint("TOPLEFT", muteBanner and muteBanner or muteTab, muteBanner and "BOTTOMLEFT" or "TOPLEFT", 16, muteBanner and -12 or -16)
  muteTabHdr:SetText(L["Sound Browser"])

  local muteTabDesc = muteTab:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  muteTabDesc:SetPoint("TOPLEFT", muteTabHdr, "BOTTOMLEFT", 0, -6)
  muteTabDesc:SetPoint("RIGHT", muteTab, "RIGHT", -16, 0)
  muteTabDesc:SetJustifyH("LEFT")
  muteTabDesc:SetSpacing(3)
  muteTabDesc:SetText(L["Browse and mute individual sounds by type. Search spell sounds, character vocalizations, NPC sounds, or enter a FileDataID directly."])

  local muteSpellRadio = makeRadio(muteTab)
  muteSpellRadio:SetPoint("TOPLEFT", muteTabDesc, "BOTTOMLEFT", 0, -12)
  muteSpellRadio.label:SetText(L["Spell Sounds"])

  local muteCharRadio = makeRadio(muteTab)
  muteCharRadio:SetPoint("LEFT", muteSpellRadio.label, "RIGHT", 10, 0)
  muteCharRadio.label:SetText(L["Character Sounds"])

  local muteNPCRadio = makeRadio(muteTab)
  muteNPCRadio:SetPoint("LEFT", muteCharRadio.label, "RIGHT", 10, 0)
  muteNPCRadio.label:SetText(L["NPC"])

  local muteFidRadio = makeRadio(muteTab)
  muteFidRadio:SetPoint("LEFT", muteNPCRadio.label, "RIGHT", 10, 0)
  muteFidRadio.label:SetText(L["FID"])

  local muteMode = "spells"

  local muteSearchFrame = CreateFrame("Frame", nil, muteTab)
  muteSearchFrame:SetPoint("TOPLEFT", muteSpellRadio, "BOTTOMLEFT", 0, -4)
  muteSearchFrame:SetSize(CONTENT_WIDTH, 26)

  local muteSearchBox = makeEditBox(muteSearchFrame, CONTENT_WIDTH - 120, muteSearchFrame, 0, 0, L["Search sounds to mute..."])
  muteSearchBox:SetPoint("TOPLEFT", muteSearchFrame, "TOPLEFT", 0, 0)

  local refreshMuteList  -- forward declaration

  local myVoxBtn = makeButton(muteTab, L["My Vox"], 60, function()
    muteCharRadio:Click()
    muteSearchBox:SetText(getPlayerVoxKey())
    muteSearchBox:SetFocus()
  end)
  myVoxBtn:SetPoint("LEFT", muteSearchBox, "RIGHT", 24, 0)

  local muteFidFrame = CreateFrame("Frame", nil, muteTab)
  muteFidFrame:SetPoint("TOPLEFT", muteSpellRadio, "BOTTOMLEFT", 0, -4)
  muteFidFrame:SetSize(CONTENT_WIDTH, 26)
  muteFidFrame:Hide()

  local muteFidBox = makeEditBox(muteFidFrame, 120, muteFidFrame, 0, 0, "FileDataID")
  muteFidBox:SetPoint("TOPLEFT", muteFidFrame, "TOPLEFT", 0, 0)
  muteFidBox:SetNumeric(true)

  local muteFidPlayBtn = makeIconButton(muteFidFrame, "Interface\\Buttons\\UI-SpellbookIcon-NextPage-Up", 22, L["Play / Stop"])
  wirePlayStop(muteFidPlayBtn, function() return tonumber(muteFidBox:GetText()) end)
  muteFidPlayBtn:SetPoint("LEFT", muteFidBox, "RIGHT", 4, 0)

  local muteFidAddBtn = makeButton(muteFidFrame, L["+ Mute"], 52, function()
    local fid = tonumber(muteFidBox:GetText())
    if fid then
      Resonance.db.profile.mute_file_data_ids[fid] = true
      MuteSoundFile(fid)
      muteFidBox:SetText("")
      refreshMuteList()
    end
  end)
  muteFidAddBtn:SetPoint("LEFT", muteFidPlayBtn, "RIGHT", 2, 0)

  -- NPC muting helpers
  local npcNameCache
  local function lookupNPCName(npcID)
    if not npcNameCache then
      npcNameCache = {}
      for _, entry in ipairs(Resonance.NPCSoundIndex or {}) do
        local name, id = entry:match("^(.+)#(-?%d+)$")
        if name and id then
          npcNameCache[tonumber(id)] = name
        end
      end
    end
    return npcNameCache[npcID] or tostring(npcID)
  end

  local function isNPCMuted(npcID)
    return Resonance.db.profile.mutedNPCs and Resonance.db.profile.mutedNPCs[npcID]
  end

  local function getNPCFIDCount(npcID)
    local n = 0
    local NPCSoundCSD = Resonance.NPCSoundCSD
    if NPCSoundCSD then
      local NPCRepCSDs = Resonance.NPCRepCSDs
      local csdList = NPCRepCSDs and NPCRepCSDs[npcID]
      if csdList then
        for cs in csdList:gmatch("%d+") do
          local packed = NPCSoundCSD[tonumber(cs)]
          if packed then
            for _ in packed:gmatch("%d+") do n = n + 1 end
          end
        end
      else
        local NPCToCSD = Resonance.NPCToCSD
        local csd = NPCToCSD and NPCToCSD[npcID]
        local packed = csd and NPCSoundCSD[csd]
        if packed then
          for _ in packed:gmatch("%d+") do n = n + 1 end
        end
      end
    end
    local NPCVoiceData = Resonance.NPCVoiceData
    if NPCVoiceData then
      local vo = NPCVoiceData[npcID]
      if vo then
        for _ in vo:gmatch("%d+") do n = n + 1 end
      end
    end
    return n
  end

  local function muteNPC(npcID)
    local p = Resonance.db.profile
    if not p.mutedNPCs then p.mutedNPCs = {} end
    p.mutedNPCs[npcID] = true
    Resonance.refreshNPCMutes()
    refreshMuteList()
  end

  local function unmuteNPC(npcID)
    local p = Resonance.db.profile
    if p.mutedNPCs then p.mutedNPCs[npcID] = nil end
    Resonance.refreshNPCMutes()
    refreshMuteList()
  end

  local muteDD
  muteDD = createAutocomplete(muteSearchBox,
    function(e) if e then return e.fileDataID end end,
    function(e)
      if e then
        if muteMode == "npc" then
          muteNPC(e.fileDataID)  -- fileDataID is actually npcID in NPC mode
        else
          Resonance.db.profile.mute_file_data_ids[e.fileDataID] = true
          MuteSoundFile(e.fileDataID)
          refreshMuteList()
        end
      end
    end,
    { label = L["+ Mute"], icon = "Interface\\Buttons\\UI-GroupLoot-Pass-Down" }, CONTENT_WIDTH
  )

  function muteDD:onRowRefresh(row, entry)
    if muteMode == "npc" then
      local muted = isNPCMuted(entry.fileDataID)
      row.actionBtn:SetEnabled(not muted)
      row.actionBtn.tooltipText = muted and L["Muted"] or L["+ Mute"]
    else
      local muted = isFIDMuted(entry.fileDataID)
      row.actionBtn:SetEnabled(not muted)
      row.actionBtn.tooltipText = muted and L["Muted"] or L["+ Mute"]
    end
  end

  local function doMuteSearch()
    if not muteSearchBox:HasFocus() then return end
    local q = muteSearchBox:GetText()
    if #q < 3 then muteDD:SetData({}, ""); muteDD:Hide(); return end
    if muteMode == "npc" then
      searchDB(Resonance.NPCSoundIndex, q, "muteSearch", function(results)
        for _, r in ipairs(results) do
          local npcID = r.fileDataID
          local count = getNPCFIDCount(npcID)
          local displayName = r.path
          r.display = displayName
          if isNPCMuted(npcID) then
            r.display = "|cff888888" .. displayName .. "|r"
          end
          r.subdisplay = "NPC " .. npcID .. "  \194\183  " .. count .. " " .. L["sounds"]
        end
        muteDD:SetData(results, #results == 0 and L["No matches."] or L["%d results"]:format(#results))
      end, nil, Resonance.NPCSoundL10N)
    else
      local searchTarget = (muteMode == "character") and Resonance.CharacterSounds or Resonance.SpellSounds
      local prefixPool = (muteMode == "character") and Resonance.CharacterSoundPrefixes or Resonance.SpellSoundPrefixes
      searchDB(searchTarget, q, "muteSearch", function(results)
        for _, r in ipairs(results) do
          local filename = r.path:match("([^/\\]+)$") or r.path
          local parent = r.path:match("([^/\\]+)[/\\][^/\\]+$")
          r.display = filename
          if isFIDMuted(r.fileDataID) then
            r.display = "|cff888888" .. filename .. "|r"
          end
          r.subdisplay = (parent and (parent .. "/  \194\183  ") or "") .. "#" .. r.fileDataID
        end
        muteDD:SetData(results, #results == 0 and L["No matches."] or L["%d results"]:format(#results))
      end, prefixPool)
    end
  end

  local muteSearchClear = makeClearButton(muteSearchBox, function() muteDD:Hide() end)

  muteSearchBox:SetScript("OnTextChanged", function(self)
    if self.placeholder then self.placeholder:SetShown(self:GetText() == "" and not self:HasFocus()) end
    muteSearchClear:SetShown(self:GetText() ~= "")
    debounce("muteSearch", 0.3, doMuteSearch)
  end)
  muteSearchBox:SetScript("OnEditFocusGained", function(self)
    if self.placeholder then self.placeholder:Hide() end
    doMuteSearch()
  end)
  muteSearchBox:SetScript("OnEditFocusLost", function(self)
    if self.placeholder then self.placeholder:SetShown(self:GetText() == "") end
    C_Timer.After(0.2, function()
      if not muteSearchBox:HasFocus() and not muteDD:IsMouseOver() then muteDD:Hide() end
    end)
  end)
  muteSearchBox:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
  muteSearchBox:SetScript("OnEscapePressed", function(self) muteDD:Hide(); self:ClearFocus() end)

  local function setMuteMode(mode)
    muteMode = mode
    muteSpellRadio:SetChecked(mode == "spells")
    muteCharRadio:SetChecked(mode == "character")
    muteNPCRadio:SetChecked(mode == "npc")
    muteFidRadio:SetChecked(mode == "fid")
    muteSearchFrame:SetShown(mode ~= "fid")
    myVoxBtn:SetShown(mode == "character")
    muteFidFrame:SetShown(mode == "fid")
    if mode == "npc" then
      muteSearchBox.placeholder:SetText(L["Search NPC by name..."])
    else
      muteSearchBox.placeholder:SetText(L["Search sounds to mute..."])
    end
    muteDD:Hide()
  end
  muteSpellRadio:SetScript("OnClick", function() setMuteMode("spells") end)
  muteCharRadio:SetScript("OnClick", function() setMuteMode("character") end)
  muteNPCRadio:SetScript("OnClick", function() setMuteMode("npc") end)
  muteFidRadio:SetScript("OnClick", function() setMuteMode("fid") end)

  -- Muted sounds list
  local clearAllBtn = makeButton(muteTab, L["Clear All Manual"], 120, function()
    local p = Resonance.db.profile
    local manualFids = {}
    for fid, enabled in pairs(p.mute_file_data_ids) do
      if enabled then manualFids[#manualFids + 1] = fid end
    end
    wipe(p.mute_file_data_ids)
    for _, fid in ipairs(manualFids) do
      if not isFIDMuted(fid) then
        UnmuteSoundFile(fid)
      end
    end
    refreshMuteList()
  end)

  -- Manual section heading (shown above table header when manual mutes exist)
  local manualSectionHdr = CreateFrame("Frame", nil, muteTab)
  manualSectionHdr:SetHeight(ROW_HEIGHT + 4)
  manualSectionHdr:SetPoint("TOPLEFT", muteSearchFrame, "BOTTOMLEFT", 0, -10)
  manualSectionHdr:SetPoint("RIGHT", muteTab, "RIGHT", -4, 0)
  manualSectionHdr:Hide()

  local manualSectionText = manualSectionHdr:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  manualSectionText:SetPoint("LEFT", 0, 0)
  manualSectionText:SetText(L["Manually muted sounds"])

  -- Table header (matching Spell Sounds tab style)
  local muteTableHeader = CreateFrame("Frame", nil, muteTab)
  muteTableHeader:SetHeight(ROW_HEIGHT)
  muteTableHeader:SetPoint("TOPLEFT", muteSearchFrame, "BOTTOMLEFT", 0, -10)
  muteTableHeader:SetPoint("RIGHT", muteTab, "RIGHT", -4, 0)

  local muteHeaderBg = muteTableHeader:CreateTexture(nil, "BACKGROUND")
  muteHeaderBg:SetAllPoints()
  muteHeaderBg:SetColorTexture(0.15, 0.15, 0.18, 0.6)

  local muteHdrSound = muteTableHeader:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  muteHdrSound:SetPoint("LEFT", 4, 0)
  muteHdrSound:SetPoint("RIGHT", muteTableHeader, "RIGHT", -88, 0)
  muteHdrSound:SetJustifyH("LEFT")
  muteHdrSound:SetText(L["Sound"])

  local muteHdrActions = muteTableHeader:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  muteHdrActions:SetPoint("RIGHT", muteTableHeader, "RIGHT", -2, 0)
  muteHdrActions:SetJustifyH("RIGHT")
  muteHdrActions:SetText(L["Actions"])

  local muteListContainer = CreateFrame("Frame", nil, muteTab)
  muteListContainer:SetPoint("TOPLEFT", muteTableHeader, "BOTTOMLEFT", 0, -2)
  muteListContainer:SetPoint("RIGHT", muteTab, "RIGHT", -4, 0)
  muteListContainer:SetHeight(ROW_HEIGHT)

  local muteListEmpty = muteListContainer:CreateFontString(nil, "OVERLAY", "GameFontDisable")
  muteListEmpty:SetPoint("TOPLEFT", 4, 0)
  muteListEmpty:SetText(L["No sounds muted."])

  local muteListRows = {}
  local muteListHeaders = {}
  local muteCollapsedGroups = {}
  local muteCollapsedInitialized = false

  local function getOrCreateMuteHeader(idx)
    if muteListHeaders[idx] then return muteListHeaders[idx] end
    local hdr = CreateFrame("Button", nil, muteListContainer)
    hdr:SetHeight(ROW_HEIGHT)
    local bg = hdr:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(0.2, 0.2, 0.25, 0.5)
    hdr.bg = bg
    hdr.arrow = hdr:CreateTexture(nil, "OVERLAY")
    hdr.arrow:SetSize(16, 16)
    hdr.arrow:SetPoint("LEFT", 4, 0)
    hdr.text = hdr:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    hdr.text:SetPoint("LEFT", hdr.arrow, "RIGHT", 2, 0)
    hdr.text:SetJustifyH("LEFT")
    hdr.count = hdr:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    hdr.count:SetPoint("LEFT", hdr.text, "RIGHT", 6, 0)
    hdr.count:SetTextColor(0.6, 0.6, 0.6)
    hdr.highlight = hdr:CreateTexture(nil, "HIGHLIGHT")
    hdr.highlight:SetAllPoints()
    hdr.highlight:SetColorTexture(1, 1, 1, 0.05)
    muteListHeaders[idx] = hdr
    return hdr
  end

  local function getOrCreateMuteRow(idx)
    local row = muteListRows[idx]
    if not row then
      row = CreateFrame("Frame", nil, muteListContainer)
      row:SetHeight(ROW_HEIGHT)
      muteListRows[idx] = row
      row.text = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
      row.text:SetPoint("LEFT", 8, 0)
      row.text:SetPoint("RIGHT", row, "RIGHT", -44, 0)
      row.text:SetJustifyH("LEFT")
      row.text:SetWordWrap(false)
      row.playBtn = makeIconButton(row, "Interface\\Buttons\\UI-SpellbookIcon-NextPage-Up", 22, L["Play / Stop"])
      row.playBtn:SetPoint("RIGHT", row, "RIGHT", -20, 0)
      row.removeBtn = makeIconButton(row, "Interface\\Buttons\\UI-StopButton", 18, L["Remove"])
      row.removeBtn:SetPoint("RIGHT", row, "RIGHT", -2, 0)
    end
    return row
  end

  refreshMuteList = function()
    profile = Resonance.db.profile
    for _, row in ipairs(muteListRows) do row:Hide() end
    for _, hdr in ipairs(muteListHeaders) do hdr:Hide() end
    clearAllBtn:Hide()

    -- Collect all muted FIDs, tracking source
    local fidSet = {}
    for fid, enabled in pairs(profile.mute_file_data_ids or {}) do
      if enabled then fidSet[fid] = { source = "manual" } end
    end
    -- Build reverse lookup: FID -> { spellIDs, excluded } (only for current class)
    local autoFidInfo = {}
    for sid in pairs(profile.spell_config or {}) do
      if Resonance.shouldAutoMuteSpell(sid) then
        local fids = Resonance.getSpellMuteFIDs(sid)
        if fids then
          local excl = profile.spell_config[sid].muteExclusions
          for _, fid in ipairs(fids) do
            if not autoFidInfo[fid] then autoFidInfo[fid] = { spellIDs = {}, excluded = true } end
            autoFidInfo[fid].spellIDs[#autoFidInfo[fid].spellIDs + 1] = sid
            if not (excl and excl[fid]) then
              autoFidInfo[fid].excluded = false
            end
          end
        end
      end
    end
    for fid, info in pairs(autoFidInfo) do
      if fidSet[fid] then
        fidSet[fid].source = info.excluded and fidSet[fid].source or "both"
      else
        fidSet[fid] = { source = info.excluded and "auto_excluded" or "auto" }
      end
      fidSet[fid].spellIDs = info.spellIDs
      fidSet[fid].excluded = info.excluded
    end

    -- Split into manual and auto entries
    local manualEntries = {}
    local autoEntries = {}
    for fid, info in pairs(fidSet) do
      local path = lookupFIDPath(fid)
      local sortKey = path and path:lower() or tostring(fid)
      local entry = { fid = fid, source = info.source, spellIDs = info.spellIDs, excluded = info.excluded, sortKey = sortKey }
      if info.source == "manual" then
        manualEntries[#manualEntries + 1] = entry
      else
        autoEntries[#autoEntries + 1] = entry
      end
    end
    table.sort(manualEntries, function(a, b) return a.sortKey < b.sortKey end)

    -- Group auto entries by class (from preset_spells), then by spell within each class
    -- Structure: classKey -> spellID -> { entries }
    local classSpellFids = {}  -- classKey -> spellID -> { entries }
    local assignedFids = {}

    for _, entry in ipairs(autoEntries) do
      if entry.spellIDs then
        -- Find the primary spell (first by preset class, then by name)
        local bestSid, bestClass
        for _, sid in ipairs(entry.spellIDs) do
          local cls = profile.preset_spells and profile.preset_spells[sid]
          if cls then
            bestSid = sid
            bestClass = cls
            break
          end
        end
        if not bestSid then
          bestSid = entry.spellIDs[1]
          bestClass = "_custom"
        end
        if not classSpellFids[bestClass] then classSpellFids[bestClass] = {} end
        if not classSpellFids[bestClass][bestSid] then classSpellFids[bestClass][bestSid] = {} end
        local group = classSpellFids[bestClass][bestSid]
        group[#group + 1] = entry
        assignedFids[entry.fid] = true
      end
    end

    -- Sort entries within each spell group
    for _, spellMap in pairs(classSpellFids) do
      for _, entries in pairs(spellMap) do
        table.sort(entries, function(a, b) return a.sortKey < b.sortKey end)
      end
    end

    -- Build ordered class keys: player's class first, then CLASS_ORDER, then extras, then _custom
    local orderedClassKeys = {}
    local classKeySet = {}
    for key in pairs(classSpellFids) do classKeySet[key] = true end

    if classKeySet[playerClass] then
      orderedClassKeys[#orderedClassKeys + 1] = playerClass
      classKeySet[playerClass] = nil
    end
    for _, cls in ipairs(CLASS_ORDER) do
      if classKeySet[cls] then
        orderedClassKeys[#orderedClassKeys + 1] = cls
        classKeySet[cls] = nil
      end
    end
    local extras = {}
    for key in pairs(classKeySet) do
      if key ~= "_custom" then extras[#extras + 1] = key end
    end
    table.sort(extras)
    for _, key in ipairs(extras) do orderedClassKeys[#orderedClassKeys + 1] = key end
    if classSpellFids["_custom"] then orderedClassKeys[#orderedClassKeys + 1] = "_custom" end

    -- Count FIDs per class
    local classCount = {}
    for cls, spellMap in pairs(classSpellFids) do
      local n = 0
      for _, entries in pairs(spellMap) do n = n + #entries end
      classCount[cls] = n
    end

    -- Default: everything collapsed
    if not muteCollapsedInitialized and #orderedClassKeys > 0 then
      for _, key in ipairs(orderedClassKeys) do
        muteCollapsedGroups[key] = true
      end
      muteCollapsedInitialized = true
    end

    -- Render
    local yOff = 0
    local rowIdx = 0
    local hdrIdx = 0
    local soundRowIdx = 0

    -- Manual mutes section
    if #manualEntries > 0 then
      -- Show section heading above table header, with Clear All button on the right
      manualSectionHdr:Show()
      clearAllBtn:SetParent(manualSectionHdr)
      clearAllBtn:ClearAllPoints()
      clearAllBtn:SetPoint("RIGHT", manualSectionHdr, "RIGHT", 0, 0)
      clearAllBtn:Show()
      muteTableHeader:ClearAllPoints()
      muteTableHeader:SetPoint("TOPLEFT", manualSectionHdr, "BOTTOMLEFT", 0, -2)
      muteTableHeader:SetPoint("RIGHT", muteTab, "RIGHT", -4, 0)

      for _, entry in ipairs(manualEntries) do
        soundRowIdx = soundRowIdx + 1
        rowIdx = rowIdx + 1
        local row = getOrCreateMuteRow(rowIdx)
        row:SetHeight(ROW_HEIGHT)
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", muteListContainer, "TOPLEFT", 0, -yOff)
        row:SetPoint("RIGHT", muteListContainer, "RIGHT", 0, 0)

        local fid = entry.fid
        row.text:SetFontObject(GameFontHighlightSmall)
        local path = lookupFIDPath(fid)
        local display
        if path then
          display = formatSoundDisplay(path, fid)
        else
          display = "|cffff8800" .. fid .. "|r"
        end
        row.text:SetText(display)
        row.text:SetPoint("LEFT", 8, 0)
        row.text:SetPoint("RIGHT", row, "RIGHT", -44, 0)

        row.playBtn:Show()
        local f = fid
        wirePlayStop(row.playBtn, function() return f end)
        if row.muteToggle then row.muteToggle:Hide() end
        row.removeBtn:Show()
        row.removeBtn:SetEnabled(true)
        row.removeBtn:SetScript("OnEnter", function(self)
          GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
          GameTooltip:AddLine(L["Unmute"], 1, 1, 1)
          GameTooltip:Show()
        end)
        row.removeBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
        row.removeBtn:SetScript("OnClick", function()
          profile.mute_file_data_ids[fid] = nil
          if not isFIDMuted(fid) then
            UnmuteSoundFile(fid)
          end
          refreshMuteList()
        end)

        if not row.stripe then
          row.stripe = row:CreateTexture(nil, "BACKGROUND")
          row.stripe:SetAllPoints()
          row.stripe:SetColorTexture(1, 1, 1, 0.06)
        end
        row.stripe:SetShown(soundRowIdx % 2 == 0)

        row:Show()
        yOff = yOff + ROW_HEIGHT
      end
    else
      manualSectionHdr:Hide()
      clearAllBtn:Hide()
      muteTableHeader:ClearAllPoints()
      muteTableHeader:SetPoint("TOPLEFT", muteSearchFrame, "BOTTOMLEFT", 0, -10)
      muteTableHeader:SetPoint("RIGHT", muteTab, "RIGHT", -4, 0)
    end

    -- Auto-muted class groups
    if #orderedClassKeys > 0 then
      rowIdx = rowIdx + 1
      local autoLabel = getOrCreateMuteRow(rowIdx)
      autoLabel:SetHeight(ROW_HEIGHT + 4)
      autoLabel:ClearAllPoints()
      autoLabel:SetPoint("TOPLEFT", muteListContainer, "TOPLEFT", 0, -yOff)
      autoLabel:SetPoint("RIGHT", muteListContainer, "RIGHT", 0, 0)
      autoLabel.text:SetFontObject(GameFontNormal)
      autoLabel.text:SetPoint("LEFT", 0, 0)
      autoLabel.text:SetPoint("RIGHT", autoLabel, "RIGHT", -4, 0)
      autoLabel.text:SetText(L["Auto-muted from spell configurations"])
      autoLabel.playBtn:Hide()
      autoLabel.removeBtn:Hide()
      if autoLabel.muteToggle then autoLabel.muteToggle:Hide() end
      if autoLabel.stripe then autoLabel.stripe:Hide() end
      autoLabel:Show()
      yOff = yOff + ROW_HEIGHT + 4
    end

    for _, classKey in ipairs(orderedClassKeys) do
      local spellMap = classSpellFids[classKey]
      local collapsed = muteCollapsedGroups[classKey]

      -- Class header
      hdrIdx = hdrIdx + 1
      local hdr = getOrCreateMuteHeader(hdrIdx)
      hdr:ClearAllPoints()
      hdr:SetPoint("TOPLEFT", muteListContainer, "TOPLEFT", 0, -yOff)
      hdr:SetPoint("RIGHT", muteListContainer, "RIGHT", 0, 0)

      local displayName = CLASS_DISPLAY[classKey] or (classKey == "_custom" and L["Custom"] or classKey)
      local cc = RAID_CLASS_COLORS and RAID_CLASS_COLORS[classKey]
      if cc then
        hdr.text:SetText(cc:WrapTextInColorCode(displayName))
      else
        hdr.text:SetText(displayName)
      end
      hdr.arrow:SetTexture(collapsed and "Interface\\Buttons\\UI-PlusButton-UP" or "Interface\\Buttons\\UI-MinusButton-UP")
      hdr.count:SetText("(" .. (classCount[classKey] or 0) .. ")")
      local hdrKey = classKey
      hdr:SetScript("OnClick", function()
        muteCollapsedGroups[hdrKey] = not muteCollapsedGroups[hdrKey]
        refreshMuteList()
      end)
      hdr:Show()
      yOff = yOff + ROW_HEIGHT

      if not collapsed then
        -- Sort spells within class by name
        local sortedSpells = {}
        for sid in pairs(spellMap) do
          sortedSpells[#sortedSpells + 1] = { sid = sid, name = Resonance.getSpellName(sid) or tostring(sid) }
        end
        table.sort(sortedSpells, function(a, b) return a.name < b.name end)

        for _, spellInfo in ipairs(sortedSpells) do
          local entries = spellMap[spellInfo.sid]

          -- Spell sub-header
          rowIdx = rowIdx + 1
          local spellRow = getOrCreateMuteRow(rowIdx)
          spellRow:SetHeight(ROW_HEIGHT)
          spellRow:ClearAllPoints()
          spellRow:SetPoint("TOPLEFT", muteListContainer, "TOPLEFT", 0, -yOff)
          spellRow:SetPoint("RIGHT", muteListContainer, "RIGHT", 0, 0)
          spellRow.text:SetFontObject(GameFontHighlightSmall)
          spellRow.text:SetPoint("LEFT", 8, 0)
          spellRow.text:SetPoint("RIGHT", spellRow, "RIGHT", -4, 0)
          spellRow.text:SetText("|cff66aaff" .. spellInfo.name .. "|r  |cff888888(" .. spellInfo.sid .. ")|r")
          spellRow.playBtn:Hide()
          spellRow.removeBtn:Hide()
          if spellRow.muteToggle then spellRow.muteToggle:Hide() end
          if spellRow.stripe then spellRow.stripe:Hide() end
          spellRow:Show()
          yOff = yOff + ROW_HEIGHT

          -- Sound entries for this spell
          for _, entry in ipairs(entries) do
            soundRowIdx = soundRowIdx + 1
            rowIdx = rowIdx + 1
            local row = getOrCreateMuteRow(rowIdx)
            row:SetHeight(ROW_HEIGHT)
            row:ClearAllPoints()
            row:SetPoint("TOPLEFT", muteListContainer, "TOPLEFT", 0, -yOff)
            row:SetPoint("RIGHT", muteListContainer, "RIGHT", 0, 0)

            row.text:SetFontObject(GameFontHighlightSmall)
            local fid = entry.fid
            local display
            local path = lookupFIDPath(fid)
            if path then
              display = formatSoundDisplay(path, fid)
            else
              display = "|cffff8800" .. fid .. "|r"
            end
            if entry.excluded then
              display = "|cff888888[unmuted]|r " .. display
            end
            row.text:SetText(display)
            row.text:SetPoint("LEFT", 16, 0)
            row.text:SetPoint("RIGHT", row, "RIGHT", -114, 0)

            row.playBtn:Show()
            local f = fid
            wirePlayStop(row.playBtn, function() return f end)

            if not row.muteToggle then
              local mtMinW = math.max(btnTextWidth(L["Mute"]), btnTextWidth(L["Unmute"])) + 12
              row.muteToggle = makeButton(row, L["Unmute"], math.max(60, mtMinW), nil)
              row.muteToggle:SetPoint("RIGHT", row.playBtn, "LEFT", -4, 0)
            end

            row.removeBtn:Hide()
            row.muteToggle:Show()
            row.muteToggle:SetText(entry.excluded and L["Mute"] or L["Unmute"])
            row.muteToggle:SetScript("OnClick", function()
              profile = Resonance.db.profile
              if entry.excluded then
                -- Re-mute: remove this FID from exclusions only for the
                -- spells that actually reference it (avoids cross-preset
                -- side effects from iterating all spell_config entries).
                if entry.spellIDs then
                  for _, sid in ipairs(entry.spellIDs) do
                    local cfg = profile.spell_config[sid]
                    if cfg and cfg.muteExclusions then
                      cfg.muteExclusions[fid] = nil
                    end
                  end
                end
                Resonance.rebuildAutoMutes()
                MuteSoundFile(fid)
                Resonance.msg(L["Re-muted FID %d"]:format(fid))
              else
                -- Unmute: add this FID to exclusions only for the spells
                -- that reference it.
                if entry.spellIDs then
                  for _, sid in ipairs(entry.spellIDs) do
                    local cfg = profile.spell_config[sid]
                    if cfg then
                      if not cfg.muteExclusions then
                        cfg.muteExclusions = {}
                      end
                      cfg.muteExclusions[fid] = true
                    end
                  end
                end
                Resonance.rebuildAutoMutes()
                if not isFIDMuted(fid) then
                  UnmuteSoundFile(fid)
                end
                Resonance.msg(L["Unmuted FID %d"]:format(fid))
              end
              refreshMuteList()
            end)

            -- Striping
            if not row.stripe then
              row.stripe = row:CreateTexture(nil, "BACKGROUND")
              row.stripe:SetAllPoints()
              row.stripe:SetColorTexture(1, 1, 1, 0.06)
            end
            row.stripe:SetShown(soundRowIdx % 2 == 0)

            row:Show()
            yOff = yOff + ROW_HEIGHT
          end
        end
      end
    end

    -- Muted NPCs section
    local mutedNPCs = profile.mutedNPCs
    local npcEntries = {}
    if mutedNPCs and Resonance.NPCToCSD then
      for npcID in pairs(mutedNPCs) do
        local name = lookupNPCName(npcID)
        npcEntries[#npcEntries + 1] = { npcID = npcID, name = name, count = getNPCFIDCount(npcID) }
      end
      table.sort(npcEntries, function(a, b) return a.name:lower() < b.name:lower() end)
    end

    if #npcEntries > 0 then
      -- NPC section header
      rowIdx = rowIdx + 1
      local npcLabel = getOrCreateMuteRow(rowIdx)
      npcLabel:SetHeight(ROW_HEIGHT + 4)
      npcLabel:ClearAllPoints()
      npcLabel:SetPoint("TOPLEFT", muteListContainer, "TOPLEFT", 0, -yOff)
      npcLabel:SetPoint("RIGHT", muteListContainer, "RIGHT", 0, 0)
      npcLabel.text:SetFontObject(GameFontNormal)
      npcLabel.text:SetPoint("LEFT", 0, 0)
      npcLabel.text:SetPoint("RIGHT", npcLabel, "RIGHT", -4, 0)
      npcLabel.text:SetText(L["Muted NPCs"])
      npcLabel.playBtn:Hide()
      npcLabel.removeBtn:Hide()
      if npcLabel.muteToggle then npcLabel.muteToggle:Hide() end
      if npcLabel.stripe then npcLabel.stripe:Hide() end
      npcLabel:Show()
      yOff = yOff + ROW_HEIGHT + 4

      for ni, npcEntry in ipairs(npcEntries) do
        rowIdx = rowIdx + 1
        local row = getOrCreateMuteRow(rowIdx)
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", muteListContainer, "TOPLEFT", 8, -yOff)
        row:SetPoint("RIGHT", muteListContainer, "RIGHT", 0, 0)
        row.text:SetFontObject(GameFontHighlightSmall)
        row.text:SetText(npcEntry.name .. " |cff888888(NPC " .. npcEntry.npcID .. ", " .. npcEntry.count .. " " .. L["sounds"] .. ")|r")
        row.playBtn:Hide()
        row.removeBtn:Show()
        row.removeBtn:SetEnabled(true)
        if row.muteToggle then row.muteToggle:Hide() end
        local capturedNpcID = npcEntry.npcID
        row.removeBtn:SetScript("OnEnter", function(self)
          GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
          GameTooltip:AddLine(L["Unmute"], 1, 1, 1)
          GameTooltip:Show()
        end)
        row.removeBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
        row.removeBtn:SetScript("OnClick", function()
          unmuteNPC(capturedNpcID)
        end)
        if not row.stripe then
          row.stripe = row:CreateTexture(nil, "BACKGROUND")
          row.stripe:SetAllPoints()
          row.stripe:SetColorTexture(1, 1, 1, 0.06)
        end
        row.stripe:SetShown(ni % 2 == 0)
        row:Show()
        yOff = yOff + ROW_HEIGHT
      end
    end

    for i = rowIdx + 1, #muteListRows do muteListRows[i]:Hide() end
    for i = hdrIdx + 1, #muteListHeaders do muteListHeaders[i]:Hide() end
    local totalH = math.max(yOff, ROW_HEIGHT)
    muteListContainer:SetHeight(totalH)
    muteListEmpty:SetShown(yOff == 0)
    recalcContentHeight(5)
  end

  setMuteMode("spells")

  -- Publish to ctx
  ctx.refreshMuteList = refreshMuteList
  ctx.muteDD = muteDD
end

---------------------------------------------------------------------------
-- Tab 4: Presets
---------------------------------------------------------------------------
buildTab4_Presets = function(ctx)
  local recalcContentHeight = ctx.recalcContentHeight
  local playerClass = ctx.playerClass
  local profile = Resonance.db.profile

  local presetTab = ctx.presetsContent

  -- Export/Import dialog (shared by Presets tab)
  local eiFrame = CreateFrame("Frame", "ResonanceExportImport", UIParent, "BackdropTemplate")
  eiFrame:SetSize(480, 260)
  eiFrame:SetPoint("CENTER")
  eiFrame:SetFrameStrata("DIALOG")
  eiFrame:SetMovable(true)
  eiFrame:EnableMouse(true)
  eiFrame:SetClampedToScreen(true)
  eiFrame:Hide()

  eiFrame:SetBackdrop({
    bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
    edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
    tile = true, tileSize = 32, edgeSize = 24,
    insets = { left = 5, right = 5, top = 5, bottom = 5 },
  })
  eiFrame:SetBackdropColor(0.06, 0.06, 0.08, 1)

  local eiTitleBar = CreateFrame("Frame", nil, eiFrame)
  eiTitleBar:SetHeight(28)
  eiTitleBar:SetPoint("TOPLEFT", 6, -6)
  eiTitleBar:SetPoint("TOPRIGHT", -6, -6)
  eiTitleBar:EnableMouse(true)
  eiTitleBar:RegisterForDrag("LeftButton")
  eiTitleBar:SetScript("OnDragStart", function() eiFrame:StartMoving() end)
  eiTitleBar:SetScript("OnDragStop", function() eiFrame:StopMovingOrSizing() end)

  local eiTitleBg = eiTitleBar:CreateTexture(nil, "BACKGROUND")
  eiTitleBg:SetAllPoints()
  eiTitleBg:SetColorTexture(0.12, 0.12, 0.16, 0.8)

  local eiTitle = eiTitleBar:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  eiTitle:SetPoint("LEFT", 6, 0)

  local eiCloseBtn = CreateFrame("Button", nil, eiFrame, "UIPanelCloseButton")
  eiCloseBtn:SetPoint("TOPRIGHT", eiFrame, "TOPRIGHT", -2, -2)

  tinsert(UISpecialFrames, "ResonanceExportImport")

  local eiScrollFrame = CreateFrame("ScrollFrame", "ResonanceEIScroll", eiFrame, "UIPanelScrollFrameTemplate")
  eiScrollFrame:SetPoint("TOPLEFT", eiTitleBar, "BOTTOMLEFT", 10, -8)
  eiScrollFrame:SetPoint("BOTTOMRIGHT", eiFrame, "BOTTOMRIGHT", -34, 50)

  local eiEditBox = CreateFrame("EditBox", nil, eiScrollFrame)
  eiEditBox:SetMultiLine(true)
  eiEditBox:SetAutoFocus(false)
  eiEditBox:SetFontObject(ChatFontNormal)
  eiEditBox:SetWidth(eiScrollFrame:GetWidth() or 420)
  eiEditBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
  eiScrollFrame:SetScrollChild(eiEditBox)

  local eiStatus = eiFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  eiStatus:SetPoint("BOTTOMLEFT", eiFrame, "BOTTOMLEFT", 16, 18)
  eiStatus:SetWidth(300)
  eiStatus:SetJustifyH("LEFT")

  local eiMinW = math.max(btnTextWidth(L["Close"]), btnTextWidth(L["Import"])) + 12
  local eiActionBtn = makeButton(eiFrame, L["Close"], math.max(80, eiMinW), nil)
  eiActionBtn:SetPoint("BOTTOMRIGHT", eiFrame, "BOTTOMRIGHT", -16, 14)

  local eiMode = "export"

  local refreshPresetList  -- forward declaration

  eiActionBtn:SetScript("OnClick", function()
    if eiMode == "export" then
      eiFrame:Hide()
    else
      -- Import as preset
      local text = eiEditBox:GetText()
      local name, result = Resonance:ImportToPreset(text)
      if not name then
        eiStatus:SetText("|cffff4444" .. (result or "Import failed.") .. "|r")
      else
        -- Handle name conflicts
        local baseName = name
        local idx = 2
        while Resonance.db.profile.saved_presets[name] do
          name = baseName .. " " .. idx
          idx = idx + 1
        end
        Resonance.db.profile.saved_presets[name] = result
        local sc = 0
        for _ in pairs(result.spells or {}) do sc = sc + 1 end
        local mc = 0
        for _ in pairs(result.mutes or {}) do mc = mc + 1 end
        eiStatus:SetText("|cff00ff00" .. L["Imported preset '%s': %d spells, %d mutes."]:format(name, sc, mc) .. "|r")
        if refreshPresetList then refreshPresetList() end
      end
    end
  end)

  -- Presets tab layout
  local presetBanner
  if not ctx.dataLoaded then
    presetBanner = showDataUnavailableBanner(presetTab, select(2, Resonance.loadDataAddon()))
  end

  local presetTabHdr = presetTab:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
  presetTabHdr:SetPoint("TOPLEFT", presetBanner and presetBanner or presetTab, presetBanner and "BOTTOMLEFT" or "TOPLEFT", 16, presetBanner and -12 or -16)
  presetTabHdr:SetText(L["Presets"])

  local presetDesc = presetTab:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  presetDesc:SetPoint("TOPLEFT", presetTabHdr, "BOTTOMLEFT", 0, -6)
  presetDesc:SetWidth(CONTENT_WIDTH)
  presetDesc:SetJustifyH("LEFT")
  presetDesc:SetSpacing(3)
  presetDesc:SetText(L["Load built-in class presets or your own saved configurations. Each preset contains spell sound settings and manual mutes."])

  local presetSaveBtn = makeButton(presetTab, L["Save Current Config"], 130, nil)
  presetSaveBtn:SetPoint("TOPLEFT", presetDesc, "BOTTOMLEFT", 0, -12)

  local presetImportBtn = makeButton(presetTab, L["Import"], 54, nil)
  presetImportBtn:SetPoint("LEFT", presetSaveBtn, "RIGHT", 6, 0)

  local presetExportProfileBtn = makeButton(presetTab, L["Export Full Profile"], 130, nil)
  presetExportProfileBtn:SetPoint("LEFT", presetImportBtn, "RIGHT", 6, 0)

  -- Inline save name input (hidden by default)
  local presetSaveFrame = CreateFrame("Frame", nil, presetTab)
  presetSaveFrame:SetPoint("TOPLEFT", presetSaveBtn, "BOTTOMLEFT", 0, -6)
  presetSaveFrame:SetPoint("RIGHT", presetTab, "RIGHT", -16, 0)
  presetSaveFrame:SetHeight(26)
  presetSaveFrame:Hide()

  local presetSaveNameLabel = presetSaveFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  presetSaveNameLabel:SetPoint("LEFT", 0, 0)
  presetSaveNameLabel:SetText(L["Name:"])

  local presetSaveNameBox = makeEditBox(presetSaveFrame, 200, presetSaveNameLabel, 0, 0, L["Preset name..."])
  presetSaveNameBox:ClearAllPoints()
  presetSaveNameBox:SetPoint("LEFT", presetSaveNameLabel, "RIGHT", 6, 0)

  local presetSaveConfirmBtn = makeButton(presetSaveFrame, L["Save"], 50, nil)
  presetSaveConfirmBtn:SetPoint("LEFT", presetSaveNameBox, "RIGHT", 4, 0)

  local presetSaveCancelBtn = makeButton(presetSaveFrame, L["Cancel"], 50, nil)
  presetSaveCancelBtn:SetPoint("LEFT", presetSaveConfirmBtn, "RIGHT", 4, 0)

  -- List anchor (adjusts when save frame is shown)
  local presetListAnchor = CreateFrame("Frame", nil, presetTab)
  presetListAnchor:SetSize(1, 1)
  presetListAnchor:SetPoint("TOPLEFT", presetSaveBtn, "BOTTOMLEFT", 0, -10)

  -- Table header
  local presetTableHeader = CreateFrame("Frame", nil, presetTab)
  presetTableHeader:SetHeight(ROW_HEIGHT)
  presetTableHeader:SetPoint("TOPLEFT", presetListAnchor, "BOTTOMLEFT", 0, 0)
  presetTableHeader:SetPoint("RIGHT", presetTab, "RIGHT", -16, 0)

  local presetHeaderBg = presetTableHeader:CreateTexture(nil, "BACKGROUND")
  presetHeaderBg:SetAllPoints()
  presetHeaderBg:SetColorTexture(0.15, 0.15, 0.18, 0.6)

  local presetHdrName = presetTableHeader:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  presetHdrName:SetPoint("LEFT", 4, 0)
  presetHdrName:SetWidth(180)
  presetHdrName:SetJustifyH("LEFT")
  presetHdrName:SetText(L["Preset"])

  local presetHdrInfo = presetTableHeader:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  presetHdrInfo:SetPoint("LEFT", presetHdrName, "RIGHT", 8, 0)
  presetHdrInfo:SetWidth(140)
  presetHdrInfo:SetJustifyH("LEFT")
  presetHdrInfo:SetText(L["Contents"])

  local presetHdrActions = presetTableHeader:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  presetHdrActions:SetPoint("RIGHT", presetTableHeader, "RIGHT", -2, 0)
  presetHdrActions:SetJustifyH("RIGHT")
  presetHdrActions:SetText(L["Actions"])

  -- Preset list container
  local presetListContainer = CreateFrame("Frame", nil, presetTab)
  presetListContainer:SetPoint("TOPLEFT", presetTableHeader, "BOTTOMLEFT", 0, -2)
  presetListContainer:SetPoint("RIGHT", presetTab, "RIGHT", -16, 0)
  presetListContainer:SetHeight(ROW_HEIGHT)

  local presetListEmpty = presetListContainer:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  presetListEmpty:SetPoint("TOPLEFT", 4, 0)
  presetListEmpty:SetText(L["No presets available."])

  local presetListRows = {}

  -- Remove All Preset Spells button
  local presetRemoveAllBtn = makeButton(presetTab, L["Remove All Preset Spells"], 170, nil)
  presetRemoveAllBtn:SetPoint("TOPLEFT", presetListContainer, "BOTTOMLEFT", 0, -8)
  presetRemoveAllBtn:Hide()

  -- Preset list rendering
  refreshPresetList = function()
    profile = Resonance.db.profile
    for _, row in ipairs(presetListRows) do row:Hide() end

    local presets = {}

    -- Helper to build a class preset entry
    local function makeClassPresetEntry(classKey)
      local tpl = Resonance.ClassTemplates[classKey]
      local spellCount = #tpl
      local activeCount = 0
      for _, entry in ipairs(tpl) do
        if profile.preset_spells[entry.spellID] == classKey then
          activeCount = activeCount + 1
        end
      end
      return {
        name = CLASS_DISPLAY[classKey] or classKey,
        key = classKey,
        source = "class",
        spellCount = spellCount,
        muteCount = 0,
        activeCount = activeCount,
      }
    end

    -- Player's class preset first
    if Resonance.ClassTemplates and Resonance.ClassTemplates[playerClass] then
      presets[#presets + 1] = makeClassPresetEntry(playerClass)
    end

    -- Saved presets
    local savedNames = {}
    for name in pairs(profile.saved_presets or {}) do
      savedNames[#savedNames + 1] = name
    end
    table.sort(savedNames)
    for _, name in ipairs(savedNames) do
      local preset = profile.saved_presets[name]
      local spellCount = 0
      for _ in pairs(preset.spells or {}) do spellCount = spellCount + 1 end
      local muteCount = 0
      for _ in pairs(preset.mutes or {}) do muteCount = muteCount + 1 end
      local activeCount = 0
      for _, source in pairs(profile.preset_spells) do
        if source == name then activeCount = activeCount + 1 end
      end
      presets[#presets + 1] = {
        name = name,
        key = name,
        source = "saved",
        spellCount = spellCount,
        muteCount = muteCount,
        activeCount = activeCount,
      }
    end

    -- Other class presets (de-emphasized, for alt setup)
    if Resonance.ClassTemplates then
      local otherClasses = {}
      for classKey in pairs(Resonance.ClassTemplates) do
        if classKey ~= playerClass then
          otherClasses[#otherClasses + 1] = classKey
        end
      end
      table.sort(otherClasses, function(a, b)
        return (CLASS_DISPLAY[a] or a) < (CLASS_DISPLAY[b] or b)
      end)
      for _, classKey in ipairs(otherClasses) do
        presets[#presets + 1] = makeClassPresetEntry(classKey)
      end
    end

    -- Check if any preset spells are active (for Remove All button)
    local hasActivePresetSpells = false
    for _ in pairs(profile.preset_spells) do
      hasActivePresetSpells = true
      break
    end

    for idx, preset in ipairs(presets) do
      local row = presetListRows[idx]
      if not row then
        row = CreateFrame("Frame", nil, presetListContainer)
        row:SetHeight(ROW_HEIGHT)
        presetListRows[idx] = row

        row.nameText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.nameText:SetPoint("LEFT", 4, 0)
        row.nameText:SetWidth(180)
        row.nameText:SetJustifyH("LEFT")
        row.nameText:SetWordWrap(false)

        row.infoBtn = CreateFrame("Button", nil, row)
        row.infoBtn:SetPoint("LEFT", row.nameText, "RIGHT", 8, 0)
        row.infoBtn:SetSize(140, ROW_HEIGHT)
        row.infoBtn:SetHighlightTexture("Interface\\BUTTONS\\WHITE8X8")
        row.infoBtn:GetHighlightTexture():SetAlpha(0.1)
        row.infoBtn:SetScript("OnEnter", function(self)
          if self.spellList and #self.spellList > 0 then
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:AddLine(self.presetName or "Preset", 1, 0.82, 0)
            GameTooltip:AddLine(" ")
            for _, spellInfo in ipairs(self.spellList) do
              GameTooltip:AddLine(spellInfo, 1, 1, 1)
            end
            GameTooltip:Show()
          end
        end)
        row.infoBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

        row.infoText = row.infoBtn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.infoText:SetPoint("LEFT", 0, 0)
        row.infoText:SetWidth(140)
        row.infoText:SetJustifyH("LEFT")
        row.infoText:SetWordWrap(false)

        row.applyBtn = makeButton(row, L["Apply"], 50, nil)
        row.removeBtn = makeButton(row, L["Remove"], 65, nil)
        row.exportBtn = makeButton(row, L["Export"], 50, nil)
        row.deleteBtn = makeIconButton(row, "Interface\\Buttons\\UI-StopButton", 18, L["Delete preset"])
      end

      row:SetPoint("TOPLEFT", presetListContainer, "TOPLEFT", 0, -(idx - 1) * ROW_HEIGHT)
      row:SetPoint("RIGHT", presetListContainer, "RIGHT", 0, 0)

      -- Stripe
      if idx % 2 == 0 then
        if not row.stripe then
          row.stripe = row:CreateTexture(nil, "BACKGROUND")
          row.stripe:SetAllPoints()
          row.stripe:SetColorTexture(1, 1, 1, 0.06)
        end
        row.stripe:Show()
      elseif row.stripe then row.stripe:Hide() end

      -- Name (de-emphasize other classes)
      local nameDisplay = preset.name
      if preset.source == "class" then
        if preset.key == playerClass then
          nameDisplay = nameDisplay .. "  |cff888888" .. L["(Your Class)"] .. "|r"
        else
          nameDisplay = "|cff888888" .. nameDisplay .. "  " .. L["(Other Class)"] .. "|r"
        end
      end
      row.nameText:SetText(nameDisplay)

      -- Info
      local info
      if preset.muteCount > 0 then
        info = L["%d spells, %d mutes."]:format(preset.spellCount, preset.muteCount)
      else
        info = L["%d spells"]:format(preset.spellCount)
      end
      if preset.activeCount > 0 then
        info = info .. "  |cff00ff00" .. L["(%d active)"]:format(preset.activeCount) .. "|r"
      end
      row.infoText:SetText(info)

      -- Build spell list for tooltip preview
      local spellList = {}
      if preset.source == "class" then
        local tpl = Resonance.ClassTemplates[preset.key]
        if tpl then
          for _, tplEntry in ipairs(tpl) do
            local sname = Resonance.getSpellName(tplEntry.spellID) or tplEntry.name
            local active = profile.preset_spells[tplEntry.spellID] == preset.key
            local prefix = active and "|cff00ff00" or "|cffcccccc"
            spellList[#spellList + 1] = prefix .. sname .. "|r  |cff888888(" .. tplEntry.spellID .. ")|r"
          end
        end
      else
        local presetData = profile.saved_presets[preset.key]
        if presetData and presetData.spells then
          local sortedSids = {}
          for sid in pairs(presetData.spells) do
            sortedSids[#sortedSids + 1] = sid
          end
          table.sort(sortedSids)
          for _, sid in ipairs(sortedSids) do
            local sname = Resonance.getSpellName(sid) or tostring(sid)
            local active = profile.preset_spells[sid] == preset.key
            local prefix = active and "|cff00ff00" or "|cffcccccc"
            spellList[#spellList + 1] = prefix .. sname .. "|r  |cff888888(" .. sid .. ")|r"
          end
        end
      end
      row.infoBtn.spellList = spellList
      row.infoBtn.presetName = preset.name

      -- Position buttons from right to left
      local rightEdge = -2

      -- Delete button (only for saved presets)
      if preset.source == "saved" then
        row.deleteBtn:ClearAllPoints()
        row.deleteBtn:SetPoint("RIGHT", row, "RIGHT", rightEdge, 0)
        row.deleteBtn:Show()
        row.deleteBtn:SetScript("OnClick", function()
          Resonance:DeleteSavedPreset(preset.key)
          Resonance:RemovePresetSpells(preset.key)
          Resonance.msg(L["Deleted preset '%s'."]:format(preset.name))
          refreshPresetList()
          if ctx.refreshList then ctx.refreshList() end
        end)
        rightEdge = rightEdge - (row.deleteBtn:GetWidth() + 4)
      else
        row.deleteBtn:Hide()
      end

      -- Export button
      row.exportBtn:ClearAllPoints()
      row.exportBtn:SetPoint("RIGHT", row, "RIGHT", rightEdge, 0)
      row.exportBtn:Show()
      row.exportBtn:SetScript("OnClick", function()
        local data
        if preset.source == "class" then
          data = Resonance:ClassPresetToData(preset.key)
        else
          data = profile.saved_presets[preset.key]
        end
        if data then
          eiMode = "export"
          eiTitle:SetText(L["Export Preset: "] .. preset.name)
          local exportStr = Resonance:ExportPresetData(preset.name, data)
          eiEditBox:SetText(exportStr)
          eiActionBtn:SetText(L["Close"])
          local sc = 0
          for _ in pairs(data.spells or {}) do sc = sc + 1 end
          local mc = 0
          for _ in pairs(data.mutes or {}) do mc = mc + 1 end
          eiStatus:SetText(L["%d spells, %d mutes."]:format(sc, mc))
          eiFrame:Show()
          eiEditBox:SetFocus()
          eiEditBox:HighlightText()
        end
      end)
      rightEdge = rightEdge - (row.exportBtn:GetWidth() + 4)

      -- Remove button (only if preset has active spells)
      if preset.activeCount > 0 then
        row.removeBtn:ClearAllPoints()
        row.removeBtn:SetPoint("RIGHT", row, "RIGHT", rightEdge, 0)
        row.removeBtn:SetText(L["Remove"])
        row.removeBtn:Show()
        row.removeBtn:SetScript("OnClick", function()
          local removed = Resonance:RemovePresetSpells(preset.key)
          Resonance.msg(L["Removed %d preset spells from '%s'."]:format(removed, preset.name))
          refreshPresetList()
          if ctx.refreshList then ctx.refreshList() end
        end)
        rightEdge = rightEdge - (row.removeBtn:GetWidth() + 4)
      else
        row.removeBtn:Hide()
      end

      -- Apply button (hide if all spells from this preset are already active)
      if preset.activeCount < preset.spellCount then
        row.applyBtn:ClearAllPoints()
        row.applyBtn:SetPoint("RIGHT", row, "RIGHT", rightEdge, 0)
        row.applyBtn:Show()
        row.applyBtn:SetScript("OnClick", function()
          if preset.source == "class" then
            local added, skipped = Resonance:ApplyClassTemplate(preset.key)
            Resonance.msg(L["Preset '%s' applied: %d spells added, %d skipped."]:format(preset.name, added, skipped))
          else
            local added, skipped, addedMutes = Resonance:ApplySavedPreset(preset.key)
            Resonance.msg(L["Preset '%s' applied: %d spells, %d mutes added (%d skipped)."]:format(preset.name, added, addedMutes, skipped))
          end
          refreshPresetList()
          if ctx.refreshList then ctx.refreshList() end
        end)
      else
        row.applyBtn:Hide()
      end

      row:Show()
    end

    -- Hide extra rows
    for i = #presets + 1, #presetListRows do presetListRows[i]:Hide() end

    local listH = math.max(#presets * ROW_HEIGHT, ROW_HEIGHT)
    presetListContainer:SetHeight(listH)
    presetListEmpty:SetShown(#presets == 0)

    -- Remove All button
    presetRemoveAllBtn:SetShown(hasActivePresetSpells)

    recalcContentHeight(6)
  end

  -- Save Current Config button
  presetSaveBtn:SetScript("OnClick", function()
    if presetSaveFrame:IsShown() then
      presetSaveFrame:Hide()
      presetListAnchor:ClearAllPoints()
      presetListAnchor:SetPoint("TOPLEFT", presetSaveBtn, "BOTTOMLEFT", 0, -10)
    else
      presetSaveFrame:Show()
      presetSaveNameBox:SetText("")
      presetSaveNameBox:SetFocus()
      presetListAnchor:ClearAllPoints()
      presetListAnchor:SetPoint("TOPLEFT", presetSaveFrame, "BOTTOMLEFT", 0, -6)
    end
    recalcContentHeight(6)
  end)

  presetSaveConfirmBtn:SetScript("OnClick", function()
    local name = presetSaveNameBox:GetText()
    if name == "" then Resonance.msg(L["Enter a preset name."]); return end
    if Resonance.db.profile.saved_presets[name] then
      Resonance.msg(L["Preset '%s' already exists. Choose a different name."]:format(name))
      return
    end
    Resonance:SaveCurrentAsPreset(name)
    Resonance.msg(L["Saved current config as preset '%s'."]:format(name))
    presetSaveFrame:Hide()
    presetListAnchor:ClearAllPoints()
    presetListAnchor:SetPoint("TOPLEFT", presetSaveBtn, "BOTTOMLEFT", 0, -10)
    refreshPresetList()
  end)

  presetSaveCancelBtn:SetScript("OnClick", function()
    presetSaveFrame:Hide()
    presetListAnchor:ClearAllPoints()
    presetListAnchor:SetPoint("TOPLEFT", presetSaveBtn, "BOTTOMLEFT", 0, -10)
    recalcContentHeight(6)
  end)

  presetSaveNameBox:SetScript("OnEnterPressed", function() presetSaveConfirmBtn:Click() end)
  presetSaveNameBox:SetScript("OnEscapePressed", function() presetSaveCancelBtn:Click() end)

  -- Import button
  presetImportBtn:SetScript("OnClick", function()
    eiMode = "import"
    eiTitle:SetText(L["Import Preset"])
    eiEditBox:SetText("")
    eiActionBtn:SetText(L["Import"])
    eiStatus:SetText(L["Paste a preset string below."])
    eiFrame:Show()
    eiEditBox:SetFocus()
  end)

  -- Export Full Profile button
  presetExportProfileBtn:SetScript("OnClick", function()
    eiMode = "export"
    eiTitle:SetText(L["Export Full Profile"])
    local exportStr = Resonance:ExportConfig("Full Profile")
    eiEditBox:SetText(exportStr)
    eiActionBtn:SetText(L["Close"])
    local sc = 0
    for _ in pairs(profile.spell_config or {}) do sc = sc + 1 end
    local mc = 0
    for fid, enabled in pairs(profile.mute_file_data_ids or {}) do
      if enabled then mc = mc + 1 end
    end
    eiStatus:SetText(L["%d spells, %d manual mutes (all classes)."]:format(sc, mc))
    eiFrame:Show()
    eiEditBox:SetFocus()
    eiEditBox:HighlightText()
  end)

  -- Remove All Preset Spells button
  presetRemoveAllBtn:SetScript("OnClick", function()
    local removed = Resonance:RemovePresetSpells()
    Resonance.msg(L["Removed %d preset spells."]:format(removed))
    refreshPresetList()
    if ctx.refreshList then ctx.refreshList() end
  end)

  -- Publish to ctx
  ctx.refreshPresetList = refreshPresetList
end

---------------------------------------------------------------------------
-- Tab 5: Ambient Sounds
---------------------------------------------------------------------------
buildTab5_Ambient = function(ctx)
  local recalcContentHeight = ctx.recalcContentHeight

  ctx.refreshAmbientTab = (function()
    local ambTab = ctx.ambientContent
    local ASD = Resonance.AmbientSoundData

    -- Data unavailable banner
    local ambBanner
    if not ctx.dataLoaded then
      ambBanner = showDataUnavailableBanner(ambTab, select(2, Resonance.loadDataAddon()))
    end

    if not ASD then
      local noData = ambTab:CreateFontString(nil, "OVERLAY", "GameFontDisable")
      noData:SetPoint("TOPLEFT", ambBanner and ambBanner or ambTab, ambBanner and "BOTTOMLEFT" or "TOPLEFT", 16, ambBanner and -12 or -16)
      noData:SetText(L["No ambient sound data available."])
      return function() end
    end

    local hdr = ambTab:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    hdr:SetPoint("TOPLEFT", ambBanner and ambBanner or ambTab, ambBanner and "BOTTOMLEFT" or "TOPLEFT", 16, ambBanner and -12 or -16)
    hdr:SetText(L["Ambient"])

    local desc = ambTab:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    desc:SetPoint("TOPLEFT", hdr, "BOTTOMLEFT", 0, -6)
    desc:SetPoint("RIGHT", ambTab, "RIGHT", -16, 0)
    desc:SetJustifyH("LEFT")
    desc:SetSpacing(3)
    desc:SetText(L["Mute environmental/ambient sounds for specific zones. Useful for silencing annoying drones, beams, or oppressive ambient audio."])

    -- Search box for individual ambient sounds
    local doAmbSearch  -- forward declaration
    local ambSearchLabel = ambTab:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    ambSearchLabel:SetPoint("TOPLEFT", desc, "BOTTOMLEFT", 0, -12)
    ambSearchLabel:SetText(L["Search individual sounds:"])

    local ambSearchBox = makeEditBox(ambTab, CONTENT_WIDTH - 60, ambSearchLabel, 0, -4, L["e.g. silvermoon, maw, beam, wind..."])
    ambSearchBox:SetPoint("TOPLEFT", ambSearchLabel, "BOTTOMLEFT", 0, -4)

    local ambSearchDD
    ambSearchDD = createAutocomplete(ambSearchBox,
      function(e) if e then return e.fileDataID end end,
      function(e)
        if e then
          local p = Resonance.db.profile
          local fid = e.fileDataID
          if p.mute_file_data_ids[fid] then
            p.mute_file_data_ids[fid] = nil
            UnmuteSoundFile(fid)
            Resonance.msg(L["Unmuted FID %d"]:format(fid))
          else
            p.mute_file_data_ids[fid] = true
            MuteSoundFile(fid)
            Resonance.msg(L["Re-muted FID %d"]:format(fid))
          end
          -- Refresh dropdown in-place (doAmbSearch has a focus guard that
          -- would skip the refresh when clicking the button steals focus)
          if ambSearchDD.data then
            for _, r in ipairs(ambSearchDD.data) do
              local f = r.fileDataID
              local filename = r.path:match("([^/\\]+)$") or r.path
              if p.mute_file_data_ids[f] then
                r.display = "|cff888888" .. filename .. "|r"
              else
                r.display = filename
              end
            end
            ambSearchDD:SetData(ambSearchDD.data, ambSearchDD.statusText:GetText())
          end
        end
      end,
      { label = L["Mute"], icon = "Interface\\Buttons\\UI-GroupLoot-Pass-Down" }, CONTENT_WIDTH
    )
    ctx.allDropdowns[#ctx.allDropdowns + 1] = ambSearchDD

    function ambSearchDD:onRowRefresh(row, entry)
      local muted = Resonance.db.profile.mute_file_data_ids[entry.fileDataID]
      row.actionBtn.tooltipText = muted and L["Unmute"] or L["Mute"]
      -- Visual feedback: red + reduced alpha when muted, bright when not
      if muted then
        row.actionBtn.icon:SetVertexColor(1, 0.3, 0.3)
        row.actionBtn.icon:SetAlpha(0.6)
      else
        row.actionBtn.icon:SetVertexColor(0.8, 0.8, 0.8)
        row.actionBtn.icon:SetAlpha(1)
      end
    end

    -- Build FID → "Expansion > Zone" lookup lazily (cached).
    -- Used for both search matching and display labels.
    local ambFIDZone = {}  -- fid (number) → "Expansion > Zone"
    -- Pre-lowercased zone+expansion search strings per FID (built once)
    local ambFIDZoneSearch  -- fid (number) → lowercased "Exp > Zone LocalExp LocalZone"
    local function ensureAmbFIDZone()
      if ambFIDZoneSearch then return end
      ambFIDZoneSearch = {}
      if ASD then
        for exp, zones in pairs(ASD) do
          for zone, packed in pairs(zones) do
            local label = exp .. " > " .. zone
            local localExp = L[exp] or ""
            local localZone = L[zone] or ""
            local searchStr = label
            if localExp ~= exp and localExp ~= "" then searchStr = searchStr .. " " .. localExp end
            if localZone ~= zone and localZone ~= "" then searchStr = searchStr .. " " .. localZone end
            local lowerSearch = searchStr:lower()
            for s in packed:gmatch("%d+") do
              local fid = tonumber(s)
              ambFIDZone[fid] = label
              ambFIDZoneSearch[fid] = lowerSearch
            end
          end
        end
      end
    end

    doAmbSearch = function()
      if not ambSearchBox:HasFocus() then return end
      local q = ambSearchBox:GetText()
      if #q < 3 then ambSearchDD:SetData({}, ""); ambSearchDD:Hide(); return end
      ensureAmbFIDZone()
      searchDB(Resonance.AmbientSounds, q, "ambSearch", function(results)
        for _, r in ipairs(results) do
          local fid = r.fileDataID
          local zoneLabel = ambFIDZone[fid]
          local filename = r.path:match("([^/\\]+)$") or r.path
          local parent = r.path:match("([^/\\]+)[/\\][^/\\]+$")
          r.display = filename
          if Resonance.db.profile.mute_file_data_ids[fid] then
            r.display = "|cff888888" .. filename .. "|r"
          end
          local parts = {}
          if zoneLabel then parts[#parts + 1] = "|cff66aacc" .. zoneLabel .. "|r" end
          if parent then parts[#parts + 1] = "|cff888888" .. parent .. "/|r" end
          parts[#parts + 1] = "|cff777777#" .. fid .. "|r"
          r.subdisplay = table.concat(parts, "  \194\183  ")
        end
        ambSearchDD:SetData(results, #results == 0 and L["No matches."] or L["%d results"]:format(#results))
      end, nil, nil, function(fid, terms)
        -- Match zone/expansion metadata without concatenating into the path
        local zs = ambFIDZoneSearch[fid]
        if not zs then return false end
        for _, t in ipairs(terms) do
          if not zs:find(t, 1, true) then return false end
        end
        return true
      end)
    end

    local ambSearchClear = makeClearButton(ambSearchBox, function() ambSearchDD:Hide() end)

    ambSearchBox:SetScript("OnTextChanged", function(self)
      if self.placeholder then self.placeholder:SetShown(self:GetText() == "" and not self:HasFocus()) end
      ambSearchClear:SetShown(self:GetText() ~= "")
      debounce("ambSearch", 0.3, doAmbSearch)
    end)
    ambSearchBox:SetScript("OnEditFocusGained", function(self)
      if self.placeholder then self.placeholder:Hide() end
      doAmbSearch()
    end)
    ambSearchBox:SetScript("OnEditFocusLost", function(self)
      if self.placeholder then self.placeholder:SetShown(self:GetText() == "") end
      C_Timer.After(0.2, function()
        if not ambSearchBox:HasFocus() and not ambSearchDD:IsMouseOver() then ambSearchDD:Hide() end
      end)
    end)
    ambSearchBox:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    ambSearchBox:SetScript("OnEscapePressed", function(self) ambSearchDD:Hide(); self:ClearFocus() end)

    -- Zone-based bulk muting
    local zoneHeader = ambTab:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    zoneHeader:SetPoint("TOPLEFT", ambSearchBox, "BOTTOMLEFT", 0, -16)
    zoneHeader:SetText(L["Mute by zone:"])

    local EXP_ORDER = { "Midnight", "The War Within", "Dragonflight", "Shadowlands", "Battle for Azeroth", "Legion", "General" }
    local allRows = {}
    local expanded = {}

    local function countFIDs(packed)
      local n = 0
      for _ in packed:gmatch("%d+") do n = n + 1 end
      return n
    end

    local ZONE_COL_WIDTH = math.floor((CONTENT_WIDTH - 40) / 2)
    local function buildZoneRow(parent, anchor, isFirst, zone, key, fidCount)
      local row = CreateFrame("Frame", nil, parent)
      row:SetSize(ZONE_COL_WIDTH, ROW_HEIGHT)
      local cb = CreateFrame("CheckButton", nil, row, "UICheckButtonTemplate")
      cb:SetPoint("LEFT", 0, 0)
      local t = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
      t:SetPoint("LEFT", cb, "RIGHT", 4, 0)
      t:SetText(zone)
      local b = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
      b:SetPoint("LEFT", t, "RIGHT", 6, 0)
      b:SetText("|cff888888(" .. fidCount .. ")|r")
      cb:SetScript("OnClick", function(self)
        local p = Resonance.db.profile
        if not p.muteAmbientSounds then p.muteAmbientSounds = {} end
        p.muteAmbientSounds[key] = self:GetChecked() or nil
        Resonance.refreshAmbientMutes()
      end)
      row.cb = cb
      row.key = key
      return row
    end

    local expHeaders = {}  -- { ehdr, zoneRows[] } per expansion
    local function relayoutExpansions()
      local yOff = -8
      for _, entry in ipairs(expHeaders) do
        entry.ehdr:ClearAllPoints()
        entry.ehdr:SetPoint("TOPLEFT", zoneHeader, "BOTTOMLEFT", 0, yOff)
        entry.ehdr:SetPoint("RIGHT", ambTab, "RIGHT", -16, 0)
        yOff = yOff - (ROW_HEIGHT + 4) - 2
        if expanded[entry.exp] then
          -- Column-major layout: first half left, second half right
          -- A | C
          -- B | D
          local n = #entry.zoneRows
          local half = math.ceil(n / 2)
          local startY = yOff
          for idx, row in ipairs(entry.zoneRows) do
            row:ClearAllPoints()
            local col, rowInCol
            if idx <= half then
              col = 0
              rowInCol = idx - 1
            else
              col = 1
              rowInCol = idx - half - 1
            end
            local xOff = 20 + col * ZONE_COL_WIDTH
            local rowY = startY - rowInCol * (ROW_HEIGHT + 2)
            row:SetPoint("TOPLEFT", zoneHeader, "BOTTOMLEFT", xOff, rowY)
          end
          yOff = startY - half * (ROW_HEIGHT + 2)
        end
      end
      recalcContentHeight(4)
    end

    for _, exp in ipairs(EXP_ORDER) do
      local data = ASD[exp]
      if data then
        local ehdr = CreateFrame("Button", nil, ambTab)
        ehdr:SetHeight(ROW_HEIGHT + 4)
        ehdr:SetPoint("RIGHT", ambTab, "RIGHT", -16, 0)
        local bg = ehdr:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints()
        bg:SetColorTexture(0.18, 0.18, 0.18, 0.8)
        local arrow = ehdr:CreateTexture(nil, "OVERLAY")
        arrow:SetSize(16, 16)
        arrow:SetPoint("LEFT", 8, 0)
        arrow:SetTexture("Interface\\Buttons\\UI-PlusButton-UP")
        local title = ehdr:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        title:SetPoint("LEFT", arrow, "RIGHT", 4, 0)
        title:SetText(L[exp] or exp)

        local zc, fc = 0, 0
        for _, packed in pairs(data) do zc = zc + 1; fc = fc + countFIDs(packed) end
        local info = ehdr:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        info:SetPoint("LEFT", title, "RIGHT", 8, 0)
        info:SetText("(" .. L["%d zones, %d sounds"]:format(zc, fc) .. ")")

        local sorted = {}
        for z in pairs(data) do sorted[#sorted + 1] = z end
        table.sort(sorted)

        local zoneRows = {}
        for _, z in ipairs(sorted) do
          local row = buildZoneRow(ambTab, ehdr, false, z, exp .. "|" .. z, countFIDs(data[z]))
          row:Hide()
          zoneRows[#zoneRows + 1] = row
          allRows[#allRows + 1] = row
        end

        expanded[exp] = false
        ehdr:SetScript("OnClick", function()
          expanded[exp] = not expanded[exp]
          arrow:SetTexture(expanded[exp] and "Interface\\Buttons\\UI-MinusButton-UP" or "Interface\\Buttons\\UI-PlusButton-UP")
          for _, r in ipairs(zoneRows) do r:SetShown(expanded[exp]) end
          relayoutExpansions()
        end)
        ehdr:SetScript("OnEnter", function() bg:SetColorTexture(0.25, 0.25, 0.25, 0.8) end)
        ehdr:SetScript("OnLeave", function() bg:SetColorTexture(0.18, 0.18, 0.18, 0.8) end)

        expHeaders[#expHeaders + 1] = { exp = exp, ehdr = ehdr, zoneRows = zoneRows }
      end
    end
    relayoutExpansions()

    return function()
      local p = Resonance.db.profile
      for _, row in ipairs(allRows) do
        row.cb:SetChecked(p.muteAmbientSounds and p.muteAmbientSounds[row.key] or false)
      end
      recalcContentHeight(4)
    end
  end)()
end


---------------------------------------------------------------------------
-- Subcategory panel infrastructure
---------------------------------------------------------------------------

-- Shared context table used by all builder functions.  Elevated to module
-- scope so that cross-panel references (refreshList, allDropdowns, etc.)
-- survive across subcategory show/hide cycles.
local ctx

-- Create a scroll frame inside a panel and return both the scroll frame
-- and its content child.  This mirrors the old per-tab scroll setup.
local function createScrollableContent(parentPanel)
  local sf = CreateFrame("ScrollFrame", nil, parentPanel, "UIPanelScrollFrameTemplate")
  sf:SetPoint("TOPLEFT", parentPanel, "TOPLEFT", 8, -8)
  sf:SetPoint("BOTTOMRIGHT", parentPanel, "BOTTOMRIGHT", -24, 8)

  -- Auto-hide scrollbar when content fits
  local scrollbarParts = {}
  for j = 1, sf:GetNumChildren() do
    local child = select(j, sf:GetChildren())
    if child:IsObjectType("Slider") then
      scrollbarParts[#scrollbarParts + 1] = child
      for k = 1, child:GetNumChildren() do
        local sub = select(k, child:GetChildren())
        scrollbarParts[#scrollbarParts + 1] = sub
      end
      break
    end
  end
  sf.scrollbarParts = scrollbarParts
  for _, part in ipairs(scrollbarParts) do part:Hide() end

  local function updateScrollbar(self)
    local yRange = self:GetVerticalScrollRange()
    local show = yRange and yRange > 0
    for _, part in ipairs(self.scrollbarParts) do
      part:SetShown(show)
    end
    if not show then self:SetVerticalScroll(0) end
  end
  sf:HookScript("OnScrollRangeChanged", updateScrollbar)
  sf:HookScript("OnShow", updateScrollbar)

  local c = CreateFrame("Frame")
  sf:SetScrollChild(c)
  c:SetWidth(CONTENT_WIDTH + 40)
  c:SetHeight(1)
  sf:HookScript("OnSizeChanged", function(self, w)
    if w and w > 0 then c:SetWidth(w) end
  end)

  return sf, c
end

-- Dynamically resize scroll child to fit actual content.
-- Accepts either a numeric tabIndex (legacy compat -- indexes into
-- ctx.contentFrames) or a content frame directly.
local function recalcContentHeight(contentOrIndex)
  C_Timer.After(0, function()
    local content
    if type(contentOrIndex) == "number" then
      local entry = ctx and ctx.contentFrames and ctx.contentFrames[contentOrIndex]
      content = entry
    else
      content = contentOrIndex
    end
    if not content then return end
    local top = content:GetTop()
    if not top then return end
    local lowestBottom = top
    for i = 1, content:GetNumChildren() do
      local child = select(i, content:GetChildren())
      if child:IsShown() then
        local bottom = child:GetBottom()
        if bottom and bottom < lowestBottom then
          lowestBottom = bottom
        end
      end
    end
    content:SetHeight(math.max(top - lowestBottom + 20, 1))
  end)
end

-- Helper to embed an AceConfig table into a subcategory panel
local function buildAceConfigPanel(parentFrame, aceConfigName, title, description)
  local aceGUI = LibStub("AceGUI-3.0")
  local AceConfigDialog = LibStub("AceConfigDialog-3.0")

  local yOffset = -16
  if title then
    local hdr = parentFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    hdr:SetPoint("TOPLEFT", 16, -16)
    hdr:SetText(title)
    yOffset = -16
    if description then
      local desc = parentFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
      desc:SetPoint("TOPLEFT", hdr, "BOTTOMLEFT", 0, -6)
      desc:SetPoint("RIGHT", parentFrame, "RIGHT", -16, 0)
      desc:SetJustifyH("LEFT")
      desc:SetSpacing(3)
      desc:SetText(description)
      -- Defer measuring until the font string has been laid out
      parentFrame:SetScript("OnShow", function(self)
        local descH = desc:GetStringHeight() or 14
        local hdrH = hdr:GetStringHeight() or 16
        local aceContainer = self._aceContainer
        if aceContainer then
          aceContainer:ClearAllPoints()
          aceContainer:SetPoint("TOPLEFT", 16, -(16 + hdrH + 6 + descH + 12))
          aceContainer:SetPoint("TOPRIGHT", -16, 0)
        end
      end)
      yOffset = -(16 + 16 + 6 + 14 + 12)  -- approximate; OnShow refines it
    else
      yOffset = -(16 + 16 + 12)
    end
  end

  local aceContainer = CreateFrame("Frame", nil, parentFrame)
  aceContainer:SetPoint("TOPLEFT", 16, yOffset)
  aceContainer:SetPoint("TOPRIGHT", -16, 0)
  aceContainer:SetHeight(400)
  parentFrame._aceContainer = aceContainer

  local container = aceGUI:Create("SimpleGroup")
  container:SetLayout("Fill")
  container.frame:SetParent(parentFrame)
  container.frame:SetAllPoints(aceContainer)
  container.frame:Show()

  AceConfigDialog:Open(aceConfigName, container)
  return container
end

-- Build the content for a specific subcategory panel.
-- Called on first OnShow of each panel; `built` flag prevents re-entry.
local function buildSubcategoryContent(name, panel)
  local entry = subcategories[name]
  if not entry or entry.built then return end
  entry.built = true

  local dataLoaded, dataReason = Resonance.loadDataAddon()
  ctx.dataLoaded = dataLoaded

  -- AceConfig-based panels
  if name == "General" or name == "Muting" or name == "Profiles" then
    local aceKey = ({
      ["General"]  = "Resonance_General",
      ["Muting"]   = "Resonance_Muting",
      ["Profiles"] = "Resonance_Profiles",
    })[name]
    local aceTitle = ({
      ["General"]  = L["General"],
      ["Muting"]   = L["Muting"],
      ["Profiles"] = L["Profiles"],
    })[name]
    local aceDesc = ({
      ["General"]  = L["Toggle features, configure the interrupt alert sound, and choose the replacement sound channel."],
      ["Muting"]   = L["Configure which categories of game sounds to mute: weapon impacts, vocalizations, creature sounds, and profession audio."],
      ["Profiles"] = L["Manage saved profiles. Copy settings between characters or switch configurations."],
    })[name]
    buildAceConfigPanel(panel, aceKey, aceTitle, aceDesc)
    return
  end

  -- Custom UI panels need scrollable content areas
  if name == "Spell Sounds" then
    local sf, content = createScrollableContent(panel)
    ctx.spellSoundsContent = content
    ctx.contentFrames[2] = content
    buildTab2_SpellSounds(ctx)
    -- Wire editor frame dropdown cleanup
    if ctx.editorFrame then
      ctx.editorFrame:HookScript("OnHide", function()
        if ctx.edBrowseDD then ctx.edBrowseDD:Hide() end
        if ctx.edSpellSearchDD then ctx.edSpellSearchDD:Hide() end
      end)
    end
    -- Register dropdowns for click-catcher management
    if ctx.edBrowseDD then ctx.allDropdowns[#ctx.allDropdowns + 1] = ctx.edBrowseDD end
    if ctx.edSpellSearchDD then ctx.allDropdowns[#ctx.allDropdowns + 1] = ctx.edSpellSearchDD end
    return
  end

  if name == "Sound Browser" then
    local sf, content = createScrollableContent(panel)
    ctx.mutedSoundsContent = content
    ctx.contentFrames[5] = content
    buildTab3_MutedSounds(ctx)
    -- Register mute dropdown for click-catcher management
    if ctx.muteDD then ctx.allDropdowns[#ctx.allDropdowns + 1] = ctx.muteDD end
    return
  end

  if name == "Ambient" then
    local sf, content = createScrollableContent(panel)
    ctx.ambientContent = content
    ctx.contentFrames[4] = content
    buildTab5_Ambient(ctx)
    return
  end

  if name == "Presets" then
    local sf, content = createScrollableContent(panel)
    ctx.presetsContent = content
    ctx.contentFrames[6] = content
    buildTab4_Presets(ctx)
    return
  end
end

---------------------------------------------------------------------------
-- SetupOptions (called from Core.lua OnInitialize)
---------------------------------------------------------------------------
function Resonance:SetupOptions()
  registerAllPanels()

  local _, playerClass = UnitClass("player")

  -- Initialize shared context (elevated to module scope)
  ctx = {
    playerClass    = playerClass,
    allDropdowns   = {},
    recalcContentHeight = recalcContentHeight,
    contentFrames  = {},  -- numeric index -> content frame (legacy compat)
  }

  -- Wire OnShow handlers for each subcategory panel to build on first show
  for name, entry in pairs(subcategories) do
    local panelFrame = entry.panel
    panelFrame:SetScript("OnShow", function(self)
      if entry.built then
        -- Re-trigger refresh callbacks on subsequent shows
        if name == "Spell Sounds" then
          invalidateSpellCache()
          startBuildPlayerSpellCache()
          if ctx.refreshList then ctx.refreshList() end
        elseif name == "Sound Browser" then
          if ctx.refreshMuteList then ctx.refreshMuteList() end
        elseif name == "Ambient" then
          if ctx.refreshAmbientTab then ctx.refreshAmbientTab() end
        elseif name == "Presets" then
          if ctx.refreshPresetList then ctx.refreshPresetList() end
        end
        return
      end
      local ok, err = pcall(buildSubcategoryContent, name, self)
      if not ok then
        local errStr = tostring(err)
        local errLabel = self:CreateFontString(nil, "OVERLAY", "GameFontRed")
        errLabel:SetPoint("CENTER", 0, 0)
        errLabel:SetWidth(500)
        errLabel:SetText(L["Resonance options failed to load:\n\n"] .. errStr)
        Resonance.msg("|cffff4444" .. L["Options UI error: "] .. errStr .. "|r")
        Resonance.msg("|cffff4444" .. L["Type /res diag for library diagnostics."] .. "|r")
      end
    end)
  end

  -- Free spell cache memory when leaving Spell Sounds panel
  if subcategories["Spell Sounds"] then
    subcategories["Spell Sounds"].panel:HookScript("OnHide", function()
      invalidateSpellCache()
    end)
  end

  -- Dropdown management: hide dropdowns when custom panels hide
  for _, sname in ipairs({"Spell Sounds", "Sound Browser", "Ambient"}) do
    if subcategories[sname] then
      subcategories[sname].panel:HookScript("OnHide", function()
        if ctx and ctx.allDropdowns then
          for _, dd in ipairs(ctx.allDropdowns) do dd:Hide() end
        end
      end)
    end
  end

  -- Click catcher to close dropdowns when clicking outside
  local clickCatcher = CreateFrame("Button", nil, UIParent)
  clickCatcher:SetAllPoints()
  clickCatcher:SetFrameStrata("FULLSCREEN_DIALOG")
  clickCatcher:SetFrameLevel(0)
  clickCatcher:Hide()
  clickCatcher:RegisterForClicks("AnyUp")
  clickCatcher:SetScript("OnClick", function()
    if ctx and ctx.allDropdowns then
      for _, dd in ipairs(ctx.allDropdowns) do dd:Hide() end
    end
    clickCatcher:Hide()
  end)

  -- Wire click catcher to all dropdowns that get registered.
  -- Since dropdowns are created lazily when panels build, we hook
  -- into the allDropdowns table via a metatable that auto-wires new entries.
  local realDropdowns = ctx.allDropdowns
  local ddMeta = {}
  ddMeta.__newindex = function(t, k, dd)
    rawset(t, k, dd)
    if dd and type(dd) == "table" and dd.HookScript then
      dd:HookScript("OnShow", function() clickCatcher:Show() end)
      dd:HookScript("OnHide", function()
        local anyVisible = false
        for _, d in ipairs(realDropdowns) do
          if d:IsShown() then anyVisible = true; break end
        end
        if not anyVisible then clickCatcher:Hide() end
      end)
    end
  end
  setmetatable(realDropdowns, ddMeta)
end

-- Refresh any currently-visible custom panel (called from Core.lua on profile change)
Resonance.refreshVisibleOptionPanels = function()
  if not ctx then return end
  for name, entry in pairs(subcategories) do
    if entry.built and entry.panel:IsVisible() then
      if name == "Spell Sounds" and ctx.refreshList then ctx.refreshList() end
      if name == "Sound Browser" and ctx.refreshMuteList then ctx.refreshMuteList() end
      if name == "Presets" and ctx.refreshPresetList then ctx.refreshPresetList() end
      if name == "Ambient" and ctx.refreshAmbientTab then ctx.refreshAmbientTab() end
    end
  end
end
