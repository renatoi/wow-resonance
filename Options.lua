local Resonance = LibStub("AceAddon-3.0"):GetAddon("Resonance")

---------------------------------------------------------------------------
-- Sound database search
---------------------------------------------------------------------------
local function searchDB(db, query)
  if not db then return {} end
  local results = {}
  local terms = {}
  for word in query:lower():gmatch("%S+") do
    terms[#terms + 1] = word
  end
  if #terms == 0 then return results end
  for _, entry in ipairs(db) do
    local path, fid = entry:match("([^#]+)#([^#]+)")
    if path and fid then
      local lp = path:lower()
      local match = true
      for _, t in ipairs(terms) do
        if not lp:find(t, 1, true) then match = false; break end
      end
      if match then
        results[#results + 1] = { path = path, fileDataID = tonumber(fid) }
      end
    end
  end
  return results
end

local function hasSpellDB() return Resonance_SpellSounds and #Resonance_SpellSounds > 0 end
local function hasCharDB() return Resonance_CharacterSounds and #Resonance_CharacterSounds > 0 end

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
    for _, db in ipairs({ Resonance_SpellSounds, Resonance_CharacterSounds }) do
      if db then
        for _, entry in ipairs(db) do
          local path, id = entry:match("([^#]+)#([^#]+)")
          if path and id then fidPathCache[tonumber(id)] = path end
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
  return false
end

local function safePlaySound(value)
  if not value then return end
  local fid = tonumber(value)
  if fid and isFIDMuted(fid) then
    UnmuteSoundFile(fid)
    PlaySoundFile(fid, "Master")
    MuteSoundFile(fid)
  else
    PlaySoundFile(fid or value, "Master")
  end
end

---------------------------------------------------------------------------
-- Spell search — lazy cache of player-known spells
---------------------------------------------------------------------------
local playerSpellCache  -- built once, then reused

local function buildPlayerSpellCache()
  if playerSpellCache then return end
  playerSpellCache = {}
  local seen = {}
  local getName = C_Spell and C_Spell.GetSpellName

  -- Primary source: all spells with mute data (includes talent overrides, procs, etc.)
  if Resonance_SpellMuteData and getName then
    for sid in pairs(Resonance_SpellMuteData) do
      if not seen[sid] then
        local ok, name = pcall(getName, sid)
        if ok and name and name ~= "" then
          seen[sid] = true
          playerSpellCache[#playerSpellCache + 1] = { spellID = sid, name = name, known = IsPlayerSpell(sid) }
        end
      end
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
end

local function invalidateSpellCache()
  playerSpellCache = nil
end

local function searchSpells(query)
  buildPlayerSpellCache()
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
        display = entry.name .. "  |cff808080(ID: " .. entry.spellID .. ")|r" }
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

local CLASS_DISPLAY = {
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
-- Panel registration
---------------------------------------------------------------------------
local panel = CreateFrame("Frame")
panel:Hide()

local category
local function registerPanel()
  if category then return end
  category = Settings.RegisterCanvasLayoutCategory(panel, "Resonance")
  Settings.RegisterAddOnCategory(category)
end

Resonance.openOptions = function()
  if category then Settings.OpenToCategory(category.ID) end
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

local function makeButton(parent, text, width, onClick)
  local btn = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
  btn:SetSize(width + 4, 26)
  btn:SetText(text)
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
local NUM_WIDTH = 24

local function createAutocomplete(searchBox, onPlay, onAction, actionLabel, dropdownWidth)
  local w = dropdownWidth or CONTENT_WIDTH
  local dd = CreateFrame("Frame", nil, UIParent)
  dd:SetFrameStrata("TOOLTIP")
  dd:SetSize(w, AUTOCOMPLETE_ROWS * ROW_HEIGHT + 18)
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

  for i = 1, AUTOCOMPLETE_ROWS do
    local row = CreateFrame("Frame", nil, dd)
    row:SetSize(w - 4, ROW_HEIGHT)
    row:SetPoint("TOPLEFT", 2, -(i - 1) * ROW_HEIGHT - 2)

    if i % 2 == 0 then
      local stripe = row:CreateTexture(nil, "BACKGROUND")
      stripe:SetAllPoints()
      stripe:SetColorTexture(1, 1, 1, 0.04)
    end

    row.num = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    row.num:SetPoint("LEFT", 2, 0)
    row.num:SetWidth(NUM_WIDTH)
    row.num:SetJustifyH("RIGHT")

    row.text = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.text:SetPoint("LEFT", NUM_WIDTH + 6, 0)
    row.text:SetPoint("RIGHT", row, "RIGHT", -114, 0)
    row.text:SetJustifyH("LEFT")
    row.text:SetWordWrap(false)

    row.playBtn = makeIconButton(row, "Interface\\Buttons\\UI-SpellbookIcon-NextPage-Up", 22, "Play sound",
      function() if row.entry then onPlay(row.entry) end end)
    row.playBtn:SetPoint("RIGHT", row, "RIGHT", -58, 0)

    row.actionBtn = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
    row.actionBtn:SetSize(52, 22)
    row.actionBtn:SetPoint("RIGHT", row, "RIGHT", -2, 0)
    row.actionBtn:SetText(actionLabel)
    row.actionBtn:SetScript("OnClick", function() if row.entry then onAction(row.entry) end end)

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
  scrollTrack:SetPoint("BOTTOMRIGHT", dd, "BOTTOMRIGHT", -2, 16)
  scrollTrack:SetColorTexture(0.15, 0.15, 0.18, 0.6)
  scrollTrack:Hide()

  local scrollThumb = dd:CreateTexture(nil, "OVERLAY")
  scrollThumb:SetWidth(4)
  scrollThumb:SetColorTexture(0.5, 0.5, 0.55, 0.8)
  scrollThumb:Hide()

  local function refreshRows(self)
    local data = self.data or {}
    local off = self.scrollOffset
    for i, row in ipairs(self.rows) do
      local di = off + i
      if di <= #data then
        row.entry = data[di]
        row.num:SetText("|cff888888" .. di .. "|r")
        row.text:SetText(data[di].display or data[di].path or "")
        if self.onRowRefresh then self:onRowRefresh(row, data[di]) end
        row:Show()
      else
        row.entry = nil
        row:Hide()
      end
    end
    if #data > AUTOCOMPLETE_ROWS then
      self.scrollHint:SetText(("Showing %d\226\128\147%d of %d"):format(off + 1, math.min(off + AUTOCOMPLETE_ROWS, #data), #data))
      scrollTrack:Show()
      scrollThumb:Show()
      local trackH = AUTOCOMPLETE_ROWS * ROW_HEIGHT
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
-- Build layout
---------------------------------------------------------------------------
local built = false

local function buildLayout()
  if built then return end
  built = true

  local profile = Resonance.db.profile

  local refreshList
  local refreshMuteList
  local refreshPresetList
  local allDropdowns = {}

  -------------------------------------------------------------------
  -- Tab system
  -------------------------------------------------------------------
  local TAB_NAMES = { "General", "Spell Sounds", "Muted Sounds", "Presets", "Profiles" }
  local TAB_HEIGHT = 28
  local TAB_OVERLAP = 4
  local CONTENT_BG = { 0.1, 0.1, 0.1, 0.7 }
  local tabFrames = {}
  local tabButtons = {}

  local tabBackdrop = {
    bgFile   = "Interface\\BUTTONS\\WHITE8X8",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    edgeSize = 14,
    insets   = { left = 3, right = 3, top = 3, bottom = 3 },
  }

  -- Content container with border
  local contentBox = CreateFrame("Frame", nil, panel, "BackdropTemplate")
  contentBox:SetPoint("TOPLEFT", panel, "TOPLEFT", 4, -(TAB_HEIGHT + 8 - TAB_OVERLAP))
  contentBox:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -4, 4)
  contentBox:SetBackdrop({
    bgFile   = "Interface\\BUTTONS\\WHITE8X8",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    edgeSize = 14,
    insets   = { left = 3, right = 3, top = 3, bottom = 3 },
  })
  contentBox:SetBackdropColor(CONTENT_BG[1], CONTENT_BG[2], CONTENT_BG[3], CONTENT_BG[4])
  contentBox:SetBackdropBorderColor(0.45, 0.45, 0.45, 1)

  for i, name in ipairs(TAB_NAMES) do
    local btn = CreateFrame("Button", "ResonanceTab" .. i, panel, "BackdropTemplate")
    btn:SetHeight(TAB_HEIGHT)
    btn:SetBackdrop(tabBackdrop)
    btn:SetFrameLevel(contentBox:GetFrameLevel() + 1)

    btn.text = btn:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    btn.text:SetPoint("CENTER", 0, 1)
    btn.text:SetText(name)
    btn:SetWidth(btn.text:GetStringWidth() + 26)

    -- Mask that hides the bottom border of the tab
    btn.bottomMask = btn:CreateTexture(nil, "OVERLAY")
    btn.bottomMask:SetPoint("BOTTOMLEFT", 3, -TAB_OVERLAP)
    btn.bottomMask:SetPoint("BOTTOMRIGHT", -3, -TAB_OVERLAP)
    btn.bottomMask:SetHeight(TAB_OVERLAP + 8)

    if i == 1 then
      btn:SetPoint("TOPLEFT", panel, "TOPLEFT", 8, -8)
    else
      btn:SetPoint("LEFT", tabButtons[i - 1], "RIGHT", 4, 0)
    end
    tabButtons[i] = btn

    local sf = CreateFrame("ScrollFrame", nil, contentBox, "UIPanelScrollFrameTemplate")
    sf:SetPoint("TOPLEFT", contentBox, "TOPLEFT", 8, -8)
    sf:SetPoint("BOTTOMRIGHT", contentBox, "BOTTOMRIGHT", -24, 8)
    sf:Hide()

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
    -- Hide scrollbar initially
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
    -- Dynamically match scroll child width to scroll frame
    sf:HookScript("OnSizeChanged", function(self, w)
      if w and w > 0 then c:SetWidth(w) end
    end)
    tabFrames[i] = { scroll = sf, content = c }
  end

  -- Dynamically resize scroll child to fit actual content
  local function recalcContentHeight(tabIndex)
    C_Timer.After(0, function()
      local content = tabFrames[tabIndex].content
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

  local function selectTab(id)
    for i, tf in ipairs(tabFrames) do
      tf.scroll:SetShown(i == id)
    end
    for i, btn in ipairs(tabButtons) do
      if i == id then
        btn:SetBackdropColor(CONTENT_BG[1], CONTENT_BG[2], CONTENT_BG[3], 1)
        btn:SetBackdropBorderColor(0.45, 0.45, 0.45, 1)
        btn:SetFrameLevel(contentBox:GetFrameLevel() + 2)
        btn.text:SetFontObject("GameFontHighlight")
        btn.bottomMask:SetColorTexture(CONTENT_BG[1], CONTENT_BG[2], CONTENT_BG[3], 1)
      else
        btn:SetBackdropColor(0.06, 0.06, 0.06, 1)
        btn:SetBackdropBorderColor(0.35, 0.35, 0.35, 1)
        btn:SetFrameLevel(contentBox:GetFrameLevel() - 1)
        btn.text:SetFontObject("GameFontNormal")
        btn.bottomMask:SetColorTexture(0.06, 0.06, 0.06, 1)
      end
    end
    for _, dd in ipairs(allDropdowns) do dd:Hide() end
    if id == 1 then recalcContentHeight(1) end
    if id == 2 and refreshList then refreshList() end
    if id == 3 and refreshMuteList then refreshMuteList() end
    if id == 4 and refreshPresetList then refreshPresetList() end
  end

  for i, btn in ipairs(tabButtons) do
    btn:SetScript("OnClick", function() selectTab(i) end)
  end

  -------------------------------------------------------------------
  -- Tab 1: General (AceConfig embedded)
  -------------------------------------------------------------------
  local gen = tabFrames[1].content

  local aceContainer = CreateFrame("Frame", nil, gen)
  aceContainer:SetPoint("TOPLEFT", 16, -16)
  aceContainer:SetPoint("TOPRIGHT", -16, 0)
  aceContainer:SetHeight(300)

  local AceConfigDialog = LibStub("AceConfigDialog-3.0")
  -- AceConfigDialog:Open uses a container widget; we embed into our tab
  -- We use a simple group with inline=true approach
  local aceGUI = LibStub("AceGUI-3.0")

  local function buildAceGeneralTab()
    -- Create an AceGUI container and embed in our frame
    local container = aceGUI:Create("SimpleGroup")
    container:SetLayout("Fill")
    container.frame:SetParent(gen)
    container.frame:SetAllPoints(aceContainer)
    container.frame:Show()

    AceConfigDialog:Open("Resonance_General", container)
  end

  -- Build on first show
  aceContainer:SetScript("OnShow", function(self)
    self:SetScript("OnShow", nil)
    buildAceGeneralTab()
  end)

  -------------------------------------------------------------------
  -- Tab 2: Spell Sounds
  -------------------------------------------------------------------
  local spellTab = tabFrames[2].content

  local secHeader = spellTab:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
  secHeader:SetPoint("TOPLEFT", 16, -16)
  secHeader:SetText("Spell Sounds")

  local clearAllSpellsBtn = makeButton(spellTab, "Clear All", 65, nil)
  clearAllSpellsBtn:SetPoint("RIGHT", spellTab, "RIGHT", -16, 0)
  clearAllSpellsBtn:SetPoint("TOP", secHeader, "TOP", 0, 4)

  local clearPresetsBtn = makeButton(spellTab, "Clear Presets", 90, nil)
  clearPresetsBtn:SetPoint("RIGHT", clearAllSpellsBtn, "LEFT", -4, 0)

  local addBtn = makeButton(spellTab, "+ Add Spell", 80, nil)
  addBtn:SetPoint("RIGHT", clearPresetsBtn, "LEFT", -4, 0)

  -- Table header
  local tableHeader = CreateFrame("Frame", nil, spellTab)
  tableHeader:SetHeight(ROW_HEIGHT)
  tableHeader:SetPoint("TOPLEFT", secHeader, "BOTTOMLEFT", 0, -6)
  tableHeader:SetPoint("RIGHT", spellTab, "RIGHT", -4, 0)

  local headerBg = tableHeader:CreateTexture(nil, "BACKGROUND")
  headerBg:SetAllPoints()
  headerBg:SetColorTexture(0.15, 0.15, 0.18, 0.6)

  local hdrSpell = tableHeader:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  hdrSpell:SetPoint("LEFT", 4, 0)
  hdrSpell:SetWidth(200)
  hdrSpell:SetJustifyH("LEFT")
  hdrSpell:SetText("Spell")

  local hdrSound = tableHeader:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  hdrSound:SetPoint("LEFT", hdrSpell, "RIGHT", 8, 0)
  hdrSound:SetPoint("RIGHT", tableHeader, "RIGHT", -58, 0)
  hdrSound:SetJustifyH("LEFT")
  hdrSound:SetText("Sound")

  local hdrActions = tableHeader:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  hdrActions:SetPoint("RIGHT", tableHeader, "RIGHT", -2, 0)
  hdrActions:SetJustifyH("RIGHT")
  hdrActions:SetText("Actions")

  local listContainer = CreateFrame("Frame", nil, spellTab)
  listContainer:SetPoint("TOPLEFT", tableHeader, "BOTTOMLEFT", 0, -2)
  listContainer:SetPoint("RIGHT", spellTab, "RIGHT", -4, 0)
  listContainer:SetHeight(ROW_HEIGHT)

  local listEmpty = listContainer:CreateFontString(nil, "OVERLAY", "GameFontDisable")
  listEmpty:SetPoint("TOPLEFT", 4, 0)
  listEmpty:SetText("No spells configured. Click '+ Add Spell' to get started.")

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
  edSpellLabel:SetText("Spell ID:")

  local edSpellIDBox = makeEditBox(editorFrame, 100, edSpellLabel, 0, -2, "e.g. 6343")
  edSpellIDBox:SetNumeric(true)

  local edSpellPreview = editorFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  edSpellPreview:SetPoint("LEFT", edSpellIDBox, "RIGHT", 8, 0)

  local editorSound = nil
  local editorExclusions = {}  -- local copy of muteExclusions during editing

  local refreshAutoMuteSection  -- forward declaration

  local function edUpdateSpellPreview()
    local sid = tonumber(edSpellIDBox:GetText())
    if sid and sid > 0 then
      local name = Resonance.getSpellName(sid)
      edSpellPreview:SetText(name and ("|cff00ff00" .. name .. "|r") or "|cffff4444Unknown spell|r")
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
  edSpellSearchLabel:SetText("Search by name:")

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
    "Use", CONTENT_WIDTH
  )
  for _, row in ipairs(edSpellSearchDD.rows) do
    row.playBtn:Hide()
    row.playBtn:SetSize(1, 1)
    row.text:SetPoint("RIGHT", row, "RIGHT", -58, 0)
  end

  local function edDoSpellSearch()
    if not edSpellSearchBox:HasFocus() then return end
    local q = edSpellSearchBox:GetText()
    if #q < 2 then edSpellSearchDD:SetData({}, ""); edSpellSearchDD:Hide(); return end
    local results = searchSpells(q)
    edSpellSearchDD:SetData(results, #results == 0 and "No matches." or #results .. " results")
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

  local repHeader = editorFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  repHeader:SetPoint("TOPLEFT", repAnchor, "TOPLEFT", 0, 0)
  repHeader:SetText("Replacement Sound")

  local edCurrentLabel = editorFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  edCurrentLabel:SetPoint("TOPLEFT", repHeader, "BOTTOMLEFT", 0, -6)

  local function edUpdateCurrentSound()
    if editorSound then
      local display
      if type(editorSound) == "number" then display = "FID:" .. editorSound
      else display = tostring(editorSound):match("[^/\\]+$") or tostring(editorSound) end
      edCurrentLabel:SetText("Current: |cff00ff00" .. display .. "|r")
    else
      edCurrentLabel:SetText("Current: |cff888888none|r")
    end
  end

  local edPlayCurBtn = makeIconButton(editorFrame, "Interface\\Buttons\\UI-SpellbookIcon-NextPage-Up", 22, "Play current sound",
    function() if editorSound then safePlaySound(editorSound) end end)
  edPlayCurBtn:SetPoint("LEFT", edCurrentLabel, "RIGHT", 6, 0)

  local edClearSndBtn = makeIconButton(editorFrame, "Interface\\Buttons\\UI-StopButton", 18, "Clear sound",
    function() editorSound = nil; edUpdateCurrentSound() end)
  edClearSndBtn:SetPoint("LEFT", edPlayCurBtn, "RIGHT", 4, 0)

  local edBrowseRadio = makeRadio(editorFrame)
  edBrowseRadio:SetPoint("TOPLEFT", edCurrentLabel, "BOTTOMLEFT", 0, -8)
  edBrowseRadio.label:SetText("Browse")

  local edFileRadio = makeRadio(editorFrame)
  edFileRadio:SetPoint("LEFT", edBrowseRadio.label, "RIGHT", 12, 0)
  edFileRadio.label:SetText("File Path / FID")

  local edBrowseBox = makeEditBox(editorFrame, CONTENT_WIDTH - 60, edBrowseRadio, 0, -4, "Search spell sounds...")
  edBrowseBox:SetPoint("TOPLEFT", edBrowseRadio, "BOTTOMLEFT", 0, -4)

  local edBrowseDD
  edBrowseDD = createAutocomplete(edBrowseBox,
    function(e) if e then safePlaySound(e.fileDataID) end end,
    function(e)
      editorSound = e.fileDataID
      edUpdateCurrentSound()
      edBrowseDD:Hide()
    end,
    "Use", CONTENT_WIDTH
  )

  local function edDoBrowseSearch()
    if not edBrowseBox:HasFocus() then return end
    local q = edBrowseBox:GetText()
    if #q < 3 then edBrowseDD:SetData({}, ""); edBrowseDD:Hide(); return end
    local results = searchDB(Resonance_SpellSounds, q)
    for _, r in ipairs(results) do
      r.display = formatSoundDisplay(r.path, r.fileDataID)
    end
    edBrowseDD:SetData(results, #results == 0 and "No matches." or #results .. " results")
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

  local edFileBox = makeEditBox(edFileFrame, CONTENT_WIDTH - 140, edFileFrame, 0, 0, "path or FID")
  edFileBox:SetPoint("TOPLEFT", edFileFrame, "TOPLEFT", 0, 0)

  local edFilePlayBtn = makeIconButton(edFileFrame, "Interface\\Buttons\\UI-SpellbookIcon-NextPage-Up", 22, "Play sound",
    function() local v = edFileBox:GetText(); Resonance.previewSound(tonumber(v) or v) end)
  edFilePlayBtn:SetPoint("LEFT", edFileBox, "RIGHT", 4, 0)

  local edFileUseBtn = makeButton(edFileFrame, "Use", 36, function()
    local v = edFileBox:GetText()
    if v ~= "" then editorSound = tonumber(v) or v; edUpdateCurrentSound() end
  end)
  edFileUseBtn:SetPoint("LEFT", edFilePlayBtn, "RIGHT", 2, 0)

  local function edSetSoundMode(isBrowse)
    edBrowseRadio:SetChecked(isBrowse)
    edFileRadio:SetChecked(not isBrowse)
    edBrowseBox:SetShown(isBrowse)
    if edBrowseBox.clearBtn then edBrowseBox.clearBtn:SetShown(isBrowse and edBrowseBox:GetText() ~= "") end
    edFileFrame:SetShown(not isBrowse)
    if not isBrowse then edBrowseDD:Hide() end
  end
  edBrowseRadio:SetScript("OnClick", function() edSetSoundMode(true) end)
  edFileRadio:SetScript("OnClick", function() edSetSoundMode(false) end)

  -- Auto-Muted Sounds section
  local AUTO_MUTE_VISIBLE_ROWS = 8
  local AUTO_MUTE_SCROLL_H = AUTO_MUTE_VISIBLE_ROWS * ROW_HEIGHT

  local autoMuteAnchor = CreateFrame("Frame", nil, editorFrame)
  autoMuteAnchor:SetSize(CONTENT_WIDTH - 20, 1)
  autoMuteAnchor:SetPoint("TOPLEFT", edBrowseBox, "BOTTOMLEFT", 0, -12)

  local autoMuteHeader = editorFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  autoMuteHeader:SetPoint("TOPLEFT", autoMuteAnchor, "TOPLEFT", 0, 0)
  autoMuteHeader:SetText("Auto-Muted Sounds")

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
      autoMuteInfo:SetText("|cff888888No auto-mute data available.|r")
      autoMuteScroll:Hide()
      return
    end

    local fids = Resonance_SpellMuteData and Resonance_SpellMuteData[spellID]
    if not fids or #fids == 0 then
      autoMuteInfo:SetText("|cff888888No auto-mute data for this spell.|r")
      autoMuteScroll:Hide()
      return
    end

    local entries = {}
    for _, fid in ipairs(fids) do
      entries[#entries + 1] = { type = "sound", fid = fid }
    end

    autoMuteInfo:SetText(#fids .. " spell sound(s) — uncheck to keep a sound unmuted:")
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

        row.playBtn = makeIconButton(row, "Interface\\Buttons\\UI-SpellbookIcon-NextPage-Up", 22, "Play sound")
        row.playBtn:SetPoint("RIGHT", row, "RIGHT", -2, 0)

        row.muteBtn = CreateFrame("CheckButton", nil, row, "UICheckButtonTemplate")
        row.muteBtn:SetSize(22, 22)
        row.muteBtn:SetPoint("RIGHT", row.playBtn, "LEFT", -2, 0)
        row.muteBtn:SetHitRectInsets(0, 0, 0, 0)
        row.muteBtn.text:SetText("")
        row.muteBtn:SetScript("OnEnter", function(self)
          GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
          GameTooltip:AddLine(self:GetChecked() and "Muted (click to unmute)" or "Not muted (click to mute)", 1, 1, 1)
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
      row.playBtn:SetScript("OnClick", function() safePlaySound(entry.fid) end)
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
        row.stripe:SetColorTexture(1, 1, 1, 0.04)
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
  local edCancelBtn = makeButton(editorFrame, "Cancel", 60, nil)
  edCancelBtn:SetPoint("BOTTOMRIGHT", editorFrame, "BOTTOMRIGHT", -18, 16)

  local edSaveBtn = makeButton(editorFrame, "Save", 60, nil)
  edSaveBtn:SetPoint("RIGHT", edCancelBtn, "LEFT", -4, 0)

  local function closeEditor()
    editorFrame:Hide()
    edBrowseDD:Hide()
    edSpellSearchDD:Hide()
  end
  edCloseBtn:SetScript("OnClick", closeEditor)

  local function openEditor(spellID)
    profile = Resonance.db.profile
    editorSound = nil
    wipe(editorExclusions)
    edBrowseBox:SetText("")
    edBrowseDD:Hide()
    edSpellSearchBox:SetText("")
    edSpellSearchDD:Hide()
    edFileBox:SetText("")

    local isNew = not spellID
    if spellID then
      edSpellIDBox:SetText(tostring(spellID))
      edSpellIDBox:Disable()
      local cfg = profile.spell_config[spellID]
      if cfg then
        editorSound = cfg.sound
        if cfg.muteExclusions then
          for fid in pairs(cfg.muteExclusions) do editorExclusions[fid] = true end
        end
      end
      local name = Resonance.getSpellName(spellID)
      edTitle:SetText("Configure: " .. (name or "Spell " .. spellID))
    else
      edSpellIDBox:SetText("")
      edSpellIDBox:Enable()
      edTitle:SetText("Add New Spell")
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
    edUpdateCurrentSound()
    edSetSoundMode(hasSpellDB())
    refreshAutoMuteSection(spellID)

    -- Resize editor: base + auto-mute section (header/info + scroll area + spacing)
    local baseH = 360
    local hasMuteData = spellID and Resonance_SpellMuteData and Resonance_SpellMuteData[spellID]
    if hasMuteData then
      editorFrame:SetHeight(baseH + 30 + AUTO_MUTE_SCROLL_H + 14)
    else
      editorFrame:SetHeight(baseH + 30)
    end

    editorFrame:Show()
  end

  edCancelBtn:SetScript("OnClick", closeEditor)

  edSaveBtn:SetScript("OnClick", function()
    profile = Resonance.db.profile
    local sid = tonumber(edSpellIDBox:GetText())
    if not sid or sid <= 0 then Resonance.msg("Enter a valid spell ID."); return end
    local isNew = not profile.spell_config[sid]
    -- Build exclusions table (only save if non-empty)
    local exclusions = nil
    for fid in pairs(editorExclusions) do
      if not exclusions then exclusions = {} end
      exclusions[fid] = true
    end
    if isNew then
      profile.spell_config[sid] = { sound = editorSound, muteExclusions = exclusions }
      Resonance.applyAutoMutesForSpell(sid)
    else
      -- Remove old mutes (using old exclusions), update config, re-apply with new exclusions
      Resonance.removeAutoMutesForSpell(sid)
      profile.spell_config[sid] = { sound = editorSound, muteExclusions = exclusions }
      Resonance.applyAutoMutesForSpell(sid)
    end
    closeEditor()
    refreshList()
  end)

  addBtn:SetScript("OnClick", function() openEditor(nil) end)

  clearPresetsBtn:SetScript("OnClick", function()
    profile = Resonance.db.profile
    local removed = Resonance:RemovePresetSpells()
    closeEditor()
    refreshList()
    Resonance.msg(("Cleared %d preset spells."):format(removed))
  end)

  clearAllSpellsBtn:SetScript("OnClick", function()
    profile = Resonance.db.profile
    for sid in pairs(profile.spell_config or {}) do
      Resonance.removeAutoMutesForSpell(sid)
    end
    wipe(profile.spell_config)
    wipe(profile.preset_spells)
    closeEditor()
    refreshList()
    Resonance.msg("Cleared all spell sound configurations.")
  end)

  -- Spell list rendering
  local listHeaders = {}  -- reusable class header frames
  local collapsedGroups = {}  -- { [groupKey] = true } for collapsed sections
  local collapsedInitialized = false  -- set defaults on first render
  local _, playerClass = UnitClass("player")

  local function getOrCreateHeader(idx)
    if listHeaders[idx] then return listHeaders[idx] end
    local hdr = CreateFrame("Button", nil, listContainer)
    hdr:SetHeight(ROW_HEIGHT)
    local bg = hdr:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(0.2, 0.2, 0.25, 0.5)
    hdr.bg = bg
    hdr.arrow = hdr:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    hdr.arrow:SetPoint("LEFT", 4, 0)
    hdr.arrow:SetWidth(14)
    hdr.arrow:SetJustifyH("LEFT")
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

    row.playBtn = makeIconButton(row, "Interface\\Buttons\\UI-SpellbookIcon-NextPage-Up", 22, "Play sound")
    row.playBtn:SetPoint("RIGHT", row, "RIGHT", -36, 0)

    row.editBtn = makeIconButton(row, "Interface\\WorldMap\\GEAR_64GREY", 20, "Edit")
    row.editBtn:SetPoint("RIGHT", row, "RIGHT", -18, 0)

    row.delBtn = makeIconButton(row, "Interface\\Buttons\\UI-StopButton", 18, "Delete")
    row.delBtn:SetPoint("RIGHT", row, "RIGHT", -2, 0)

    return row
  end

  refreshList = function()
    profile = Resonance.db.profile
    for _, row in ipairs(listRows) do row:Hide() end
    for _, hdr in ipairs(listHeaders) do hdr:Hide() end

    -- Group spells by source, only including those with a sound
    local groups = {}       -- source -> { {spellID, cfg}, ... }
    local groupSet = {}     -- track which sources exist
    for sid, cfg in pairs(profile.spell_config or {}) do
      if cfg.sound ~= nil then
        local source = profile.preset_spells and profile.preset_spells[sid]
        local key = source or "_custom"
        if not groups[key] then
          groups[key] = {}
          groupSet[key] = true
        end
        groups[key][#groups[key] + 1] = { spellID = sid, cfg = cfg }
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

    -- Build ordered list of group keys: player's class first, then class order, then saved presets, then custom
    local orderedKeys = {}
    if groupSet[playerClass] then
      orderedKeys[#orderedKeys + 1] = playerClass
      groupSet[playerClass] = nil
    end
    for _, cls in ipairs(CLASS_ORDER) do
      if groupSet[cls] then
        orderedKeys[#orderedKeys + 1] = cls
        groupSet[cls] = nil
      end
    end
    local extras = {}
    for key in pairs(groupSet) do
      if key ~= "_custom" then extras[#extras + 1] = key end
    end
    table.sort(extras)
    for _, key in ipairs(extras) do orderedKeys[#orderedKeys + 1] = key end
    if groups["_custom"] then orderedKeys[#orderedKeys + 1] = "_custom" end

    -- Default: player's class and custom expanded, everything else collapsed
    if not collapsedInitialized and #orderedKeys > 0 then
      for _, key in ipairs(orderedKeys) do
        if key ~= playerClass and key ~= "_custom" then
          collapsedGroups[key] = true
        end
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

      local displayName = CLASS_DISPLAY[key] or (key == "_custom" and "Custom" or key)
      local cc = RAID_CLASS_COLORS and RAID_CLASS_COLORS[key]
      if cc then
        hdr.text:SetText(cc:WrapTextInColorCode(displayName))
      else
        hdr.text:SetText(displayName)
      end
      hdr.arrow:SetText(collapsed and "|cffaaaaaa+|r" or "|cffaaaaaa-|r")
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
          if type(sound) == "number" then
            local path = lookupFIDPath(sound)
            if path then
              row.soundText:SetText(formatSoundDisplay(path, sound))
            else
              row.soundText:SetText("|cff00ff00FID:" .. sound .. "|r")
            end
          else
            local filename = tostring(sound):match("[^/\\]+$") or tostring(sound)
            row.soundText:SetText("|cff00ff00" .. filename .. "|r")
          end

          row.playBtn:SetEnabled(true)
          row.playBtn:SetScript("OnClick", function() safePlaySound(cfg.sound) end)
          row.editBtn:SetScript("OnClick", function() openEditor(entry.spellID) end)
          row.delBtn:SetScript("OnClick", function()
            Resonance.removeAutoMutesForSpell(entry.spellID)
            Resonance.db.profile.spell_config[entry.spellID] = nil
            Resonance.db.profile.preset_spells[entry.spellID] = nil
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

  -------------------------------------------------------------------
  -- Tab 3: Muted Sounds
  -------------------------------------------------------------------
  local muteTab = tabFrames[3].content

  local muteSecHeader = muteTab:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
  muteSecHeader:SetPoint("TOPLEFT", 16, -16)
  muteSecHeader:SetText("Muted Sounds")

  local muteSpellRadio = makeRadio(muteTab)
  muteSpellRadio:SetPoint("TOPLEFT", muteSecHeader, "BOTTOMLEFT", 0, -6)
  muteSpellRadio.label:SetText("Spell Sounds")

  local muteCharRadio = makeRadio(muteTab)
  muteCharRadio:SetPoint("LEFT", muteSpellRadio.label, "RIGHT", 10, 0)
  muteCharRadio.label:SetText("Character Sounds")

  local muteFidRadio = makeRadio(muteTab)
  muteFidRadio:SetPoint("LEFT", muteCharRadio.label, "RIGHT", 10, 0)
  muteFidRadio.label:SetText("FID")

  local muteMode = "spells"

  local muteSearchFrame = CreateFrame("Frame", nil, muteTab)
  muteSearchFrame:SetPoint("TOPLEFT", muteSpellRadio, "BOTTOMLEFT", 0, -4)
  muteSearchFrame:SetSize(CONTENT_WIDTH, 26)

  local muteSearchBox = makeEditBox(muteSearchFrame, CONTENT_WIDTH - 120, muteSearchFrame, 0, 0, "Search sounds to mute...")
  muteSearchBox:SetPoint("TOPLEFT", muteSearchFrame, "TOPLEFT", 0, 0)

  local myVoxBtn = makeButton(muteTab, "My Vox", 60, function()
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

  local muteFidPlayBtn = makeIconButton(muteFidFrame, "Interface\\Buttons\\UI-SpellbookIcon-NextPage-Up", 22, "Play sound",
    function() local fid = tonumber(muteFidBox:GetText()); if fid then safePlaySound(fid) end end)
  muteFidPlayBtn:SetPoint("LEFT", muteFidBox, "RIGHT", 4, 0)

  local muteFidAddBtn = makeButton(muteFidFrame, "+ Mute", 52, function()
    local fid = tonumber(muteFidBox:GetText())
    if fid then
      Resonance.db.profile.mute_file_data_ids[fid] = true
      MuteSoundFile(fid)
      muteFidBox:SetText("")
      refreshMuteList()
    end
  end)
  muteFidAddBtn:SetPoint("LEFT", muteFidPlayBtn, "RIGHT", 2, 0)

  local muteDD
  muteDD = createAutocomplete(muteSearchBox,
    function(e) if e then safePlaySound(e.fileDataID) end end,
    function(e)
      if e then
        Resonance.db.profile.mute_file_data_ids[e.fileDataID] = true
        MuteSoundFile(e.fileDataID)
        refreshMuteList()
      end
    end,
    "+ Mute", CONTENT_WIDTH
  )

  function muteDD:onRowRefresh(row, entry)
    local muted = isFIDMuted(entry.fileDataID)
    row.actionBtn:SetEnabled(not muted)
    if muted then
      row.actionBtn:SetText("Muted")
    else
      row.actionBtn:SetText("+ Mute")
    end
  end

  local function doMuteSearch()
    if not muteSearchBox:HasFocus() then return end
    local q = muteSearchBox:GetText()
    if #q < 3 then muteDD:SetData({}, ""); muteDD:Hide(); return end
    local searchTarget = (muteMode == "character") and Resonance_CharacterSounds or Resonance_SpellSounds
    local results = searchDB(searchTarget, q)
    for _, r in ipairs(results) do
      local display = formatSoundDisplay(r.path, r.fileDataID)
      if isFIDMuted(r.fileDataID) then
        display = "|cff666666[muted]|r " .. display
      end
      r.display = display
    end
    muteDD:SetData(results, #results == 0 and "No matches." or #results .. " results")
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
    muteFidRadio:SetChecked(mode == "fid")
    muteSearchFrame:SetShown(mode ~= "fid")
    myVoxBtn:SetShown(mode == "character")
    muteFidFrame:SetShown(mode == "fid")
    muteDD:Hide()
  end
  muteSpellRadio:SetScript("OnClick", function() setMuteMode("spells") end)
  muteCharRadio:SetScript("OnClick", function() setMuteMode("character") end)
  muteFidRadio:SetScript("OnClick", function() setMuteMode("fid") end)

  -- Muted sounds list
  local clearAllBtn = makeButton(muteTab, "Clear All Manual", 120, function()
    local p = Resonance.db.profile
    for fid, enabled in pairs(p.mute_file_data_ids) do
      if enabled and not (Resonance.autoMutedFIDs[fid] and Resonance.autoMutedFIDs[fid] > 0) then
        UnmuteSoundFile(fid)
      end
    end
    wipe(p.mute_file_data_ids)
    refreshMuteList()
  end)

  local muteListContainer = CreateFrame("Frame", nil, muteTab)
  muteListContainer:SetPoint("TOPLEFT", muteSearchFrame, "BOTTOMLEFT", 0, -10)
  muteListContainer:SetPoint("RIGHT", muteTab, "RIGHT", -4, 0)
  muteListContainer:SetHeight(ROW_HEIGHT)

  local muteListEmpty = muteListContainer:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  muteListEmpty:SetPoint("TOPLEFT", 4, 0)
  muteListEmpty:SetText("|cff888888No sounds muted.|r")

  local muteListRows = {}

  refreshMuteList = function()
    profile = Resonance.db.profile
    for _, row in ipairs(muteListRows) do row:Hide() end
    clearAllBtn:Hide()

    -- Collect all muted FIDs, tracking source
    local fidSet = {}
    for fid, enabled in pairs(profile.mute_file_data_ids or {}) do
      if enabled then fidSet[fid] = { source = "manual" } end
    end
    -- Build reverse lookup: FID -> { spells, excluded }
    local autoFidInfo = {}
    for sid in pairs(profile.spell_config or {}) do
      local fids = Resonance_SpellMuteData and Resonance_SpellMuteData[sid]
      if fids then
        local excl = profile.spell_config[sid].muteExclusions
        for _, fid in ipairs(fids) do
          if not autoFidInfo[fid] then autoFidInfo[fid] = { spells = {}, excluded = true } end
          local name = Resonance.getSpellName(sid) or tostring(sid)
          autoFidInfo[fid].spells[#autoFidInfo[fid].spells + 1] = name
          if not (excl and excl[fid]) then
            autoFidInfo[fid].excluded = false
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
      fidSet[fid].spells = info.spells
      fidSet[fid].excluded = info.excluded
    end

    -- Split into manual-only and auto (includes "both", "auto", "auto_excluded")
    local manualEntries = {}
    local autoEntries = {}
    for fid, info in pairs(fidSet) do
      local path = lookupFIDPath(fid)
      local sortKey = path and path:lower() or tostring(fid)
      local entry = { fid = fid, source = info.source, spells = info.spells, excluded = info.excluded, sortKey = sortKey }
      if info.source == "manual" then
        manualEntries[#manualEntries + 1] = entry
      else
        autoEntries[#autoEntries + 1] = entry
      end
    end
    table.sort(manualEntries, function(a, b) return a.sortKey < b.sortKey end)

    -- Group auto entries by primary spell (first alphabetically)
    local spellNameSet = {}
    for _, entry in ipairs(autoEntries) do
      if entry.spells then
        for _, name in ipairs(entry.spells) do spellNameSet[name] = true end
      end
    end
    local sortedSpellNames = {}
    for name in pairs(spellNameSet) do sortedSpellNames[#sortedSpellNames + 1] = name end
    table.sort(sortedSpellNames)

    local spellGroups = {}
    for _, name in ipairs(sortedSpellNames) do spellGroups[name] = {} end
    local assignedFids = {}
    for _, spellName in ipairs(sortedSpellNames) do
      for _, entry in ipairs(autoEntries) do
        if not assignedFids[entry.fid] and entry.spells then
          for _, name in ipairs(entry.spells) do
            if name == spellName then
              spellGroups[spellName][#spellGroups[spellName] + 1] = entry
              assignedFids[entry.fid] = true
              break
            end
          end
        end
      end
      table.sort(spellGroups[spellName], function(a, b) return a.sortKey < b.sortKey end)
    end

    -- Build flat display list with headers
    local displayItems = {}
    displayItems[#displayItems + 1] = { type = "header", text = "Manually muted sounds:", showClearAll = true }
    if #manualEntries == 0 then
      displayItems[#displayItems + 1] = { type = "none" }
    else
      for _, entry in ipairs(manualEntries) do
        displayItems[#displayItems + 1] = { type = "sound", entry = entry }
      end
    end
    displayItems[#displayItems + 1] = { type = "header", text = "Auto-muted sounds from current spells:" }
    local hasAutoGroups = false
    for _, spellName in ipairs(sortedSpellNames) do
      local group = spellGroups[spellName]
      if #group > 0 then
        hasAutoGroups = true
        displayItems[#displayItems + 1] = { type = "spell_header", text = spellName }
        for _, entry in ipairs(group) do
          displayItems[#displayItems + 1] = { type = "sound", entry = entry }
        end
      end
    end
    if not hasAutoGroups then
      displayItems[#displayItems + 1] = { type = "none" }
    end

    -- Render rows
    local soundRowIdx = 0
    for idx, item in ipairs(displayItems) do
      local row = muteListRows[idx]
      if not row then
        row = CreateFrame("Frame", nil, muteListContainer)
        row:SetHeight(ROW_HEIGHT)
        muteListRows[idx] = row

        row.text = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.text:SetPoint("LEFT", 4, 0)
        row.text:SetPoint("RIGHT", row, "RIGHT", -44, 0)
        row.text:SetJustifyH("LEFT")
        row.text:SetWordWrap(false)

        row.playBtn = makeIconButton(row, "Interface\\Buttons\\UI-SpellbookIcon-NextPage-Up", 22, "Play sound")
        row.playBtn:SetPoint("RIGHT", row, "RIGHT", -20, 0)

        row.removeBtn = makeIconButton(row, "Interface\\Buttons\\UI-StopButton", 18, "Remove")
        row.removeBtn:SetPoint("RIGHT", row, "RIGHT", -2, 0)
      end

      row:SetPoint("TOPLEFT", muteListContainer, "TOPLEFT", 0, -(idx - 1) * ROW_HEIGHT)
      row:SetPoint("RIGHT", muteListContainer, "RIGHT", 0, 0)

      -- Hide all interactive elements by default
      row.playBtn:Hide()
      row.removeBtn:Hide()
      if row.muteToggle then row.muteToggle:Hide() end

      if item.type == "header" then
        row.text:SetFontObject(GameFontNormal)
        row.text:SetPoint("LEFT", 4, 0)
        row.text:SetPoint("RIGHT", row, "RIGHT", -4, 0)
        row.text:SetText(item.text)
        if item.showClearAll then
          row.text:SetPoint("RIGHT", row, "RIGHT", -134, 0)
          clearAllBtn:SetParent(row)
          clearAllBtn:ClearAllPoints()
          clearAllBtn:SetPoint("LEFT", row.text, "RIGHT", 6, 0)
          clearAllBtn:Show()
        end
      elseif item.type == "none" then
        row.text:SetFontObject(GameFontDisableSmall)
        row.text:SetPoint("LEFT", 12, 0)
        row.text:SetPoint("RIGHT", row, "RIGHT", -4, 0)
        row.text:SetText("None")
      elseif item.type == "spell_header" then
        row.text:SetFontObject(GameFontHighlightSmall)
        row.text:SetPoint("LEFT", 8, 0)
        row.text:SetPoint("RIGHT", row, "RIGHT", -4, 0)
        row.text:SetText("|cff66aaff[" .. item.text .. "]|r")
      elseif item.type == "sound" then
        soundRowIdx = soundRowIdx + 1
        local entry = item.entry
        local fid = entry.fid

        row.text:SetFontObject(GameFontHighlightSmall)

        local display
        local path = lookupFIDPath(fid)
        if path then
          display = formatSoundDisplay(path, fid)
        else
          display = "|cffff8800" .. fid .. "|r"
        end
        local isAuto = entry.source ~= "manual"
        if isAuto and entry.excluded then
          display = "|cff888888[unmuted]|r " .. display
        end
        row.text:SetText(display)

        row.playBtn:Show()
        row.playBtn:SetScript("OnClick", function() safePlaySound(fid) end)

        if not row.muteToggle then
          row.muteToggle = makeButton(row, "Unmute", 60, nil)
          row.muteToggle:SetPoint("RIGHT", row.playBtn, "LEFT", -4, 0)
        end

        row.removeBtn:SetEnabled(true)
        row.removeBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

        if isAuto then
          row.removeBtn:Hide()
          row.muteToggle:Show()
          row.muteToggle:SetText(entry.excluded and "Mute" or "Unmute")
          row.text:SetPoint("LEFT", 16, 0)
          row.text:SetPoint("RIGHT", row, "RIGHT", -114, 0)
          row.muteToggle:SetScript("OnClick", function()
            profile = Resonance.db.profile
            if entry.excluded then
              for sid in pairs(profile.spell_config or {}) do
                local excl = profile.spell_config[sid].muteExclusions
                if excl then excl[fid] = nil end
              end
              Resonance.rebuildAutoMutes()
              MuteSoundFile(fid)
              Resonance.msg("Re-muted FID " .. fid)
            else
              for sid in pairs(profile.spell_config or {}) do
                local spellFids = Resonance_SpellMuteData and Resonance_SpellMuteData[sid]
                if spellFids then
                  for _, sfid in ipairs(spellFids) do
                    if sfid == fid then
                      if not profile.spell_config[sid].muteExclusions then
                        profile.spell_config[sid].muteExclusions = {}
                      end
                      profile.spell_config[sid].muteExclusions[fid] = true
                      break
                    end
                  end
                end
              end
              Resonance.rebuildAutoMutes()
              UnmuteSoundFile(fid)
              Resonance.msg("Unmuted FID " .. fid)
            end
            refreshMuteList()
          end)
        else
          row.muteToggle:Hide()
          row.removeBtn:Show()
          row.text:SetPoint("LEFT", 8, 0)
          row.text:SetPoint("RIGHT", row, "RIGHT", -44, 0)
          row.removeBtn:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:AddLine("Unmute", 1, 1, 1)
            GameTooltip:Show()
          end)
          row.removeBtn:SetScript("OnClick", function()
            profile.mute_file_data_ids[fid] = nil
            UnmuteSoundFile(fid)
            refreshMuteList()
          end)
        end
      end

      -- Striping for sound rows only
      if item.type == "sound" then
        if not row.stripe then
          row.stripe = row:CreateTexture(nil, "BACKGROUND")
          row.stripe:SetAllPoints()
          row.stripe:SetColorTexture(1, 1, 1, 0.04)
        end
        row.stripe:SetShown(soundRowIdx % 2 == 0)
      else
        if row.stripe then row.stripe:Hide() end
      end

      row:Show()
    end

    for i = #displayItems + 1, #muteListRows do muteListRows[i]:Hide() end
    local totalH = math.max(#displayItems * ROW_HEIGHT, ROW_HEIGHT)
    muteListContainer:SetHeight(totalH)
    muteListEmpty:SetShown(false)
    recalcContentHeight(3)
  end

  setMuteMode("spells")

  -------------------------------------------------------------------
  -- Tab 4: Presets
  -------------------------------------------------------------------
  local presetTab = tabFrames[4].content

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

  local eiActionBtn = makeButton(eiFrame, "Close", 80, nil)
  eiActionBtn:SetPoint("BOTTOMRIGHT", eiFrame, "BOTTOMRIGHT", -16, 14)

  local eiMode = "export"

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
        eiStatus:SetText("|cff00ff00Imported preset '" .. name .. "': " .. sc .. " spells, " .. mc .. " mutes.|r")
        if refreshPresetList then refreshPresetList() end
      end
    end
  end)

  -- Presets tab layout
  local presetHeader = presetTab:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
  presetHeader:SetPoint("TOPLEFT", 16, -16)
  presetHeader:SetText("Presets")

  local presetDesc = presetTab:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  presetDesc:SetPoint("TOPLEFT", presetHeader, "BOTTOMLEFT", 0, -4)
  presetDesc:SetWidth(CONTENT_WIDTH)
  presetDesc:SetJustifyH("LEFT")
  presetDesc:SetText("Load built-in class presets or your own saved configurations. Each preset contains spell sound settings and manual mutes.")

  local presetSaveBtn = makeButton(presetTab, "Save Current Config", 130, nil)
  presetSaveBtn:SetPoint("TOPLEFT", presetDesc, "BOTTOMLEFT", 0, -8)

  local presetImportBtn = makeButton(presetTab, "Import", 54, nil)
  presetImportBtn:SetPoint("LEFT", presetSaveBtn, "RIGHT", 6, 0)

  -- Inline save name input (hidden by default)
  local presetSaveFrame = CreateFrame("Frame", nil, presetTab)
  presetSaveFrame:SetPoint("TOPLEFT", presetSaveBtn, "BOTTOMLEFT", 0, -6)
  presetSaveFrame:SetPoint("RIGHT", presetTab, "RIGHT", -16, 0)
  presetSaveFrame:SetHeight(26)
  presetSaveFrame:Hide()

  local presetSaveNameLabel = presetSaveFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  presetSaveNameLabel:SetPoint("LEFT", 0, 0)
  presetSaveNameLabel:SetText("Name:")

  local presetSaveNameBox = makeEditBox(presetSaveFrame, 200, presetSaveNameLabel, 0, 0, "Preset name...")
  presetSaveNameBox:ClearAllPoints()
  presetSaveNameBox:SetPoint("LEFT", presetSaveNameLabel, "RIGHT", 6, 0)

  local presetSaveConfirmBtn = makeButton(presetSaveFrame, "Save", 50, nil)
  presetSaveConfirmBtn:SetPoint("LEFT", presetSaveNameBox, "RIGHT", 4, 0)

  local presetSaveCancelBtn = makeButton(presetSaveFrame, "Cancel", 50, nil)
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
  presetHdrName:SetText("Preset")

  local presetHdrInfo = presetTableHeader:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  presetHdrInfo:SetPoint("LEFT", presetHdrName, "RIGHT", 8, 0)
  presetHdrInfo:SetWidth(140)
  presetHdrInfo:SetJustifyH("LEFT")
  presetHdrInfo:SetText("Contents")

  local presetHdrActions = presetTableHeader:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  presetHdrActions:SetPoint("RIGHT", presetTableHeader, "RIGHT", -2, 0)
  presetHdrActions:SetJustifyH("RIGHT")
  presetHdrActions:SetText("Actions")

  -- Preset list container
  local presetListContainer = CreateFrame("Frame", nil, presetTab)
  presetListContainer:SetPoint("TOPLEFT", presetTableHeader, "BOTTOMLEFT", 0, -2)
  presetListContainer:SetPoint("RIGHT", presetTab, "RIGHT", -16, 0)
  presetListContainer:SetHeight(ROW_HEIGHT)

  local presetListEmpty = presetListContainer:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  presetListEmpty:SetPoint("TOPLEFT", 4, 0)
  presetListEmpty:SetText("No presets available.")

  local presetListRows = {}

  -- Remove All Preset Spells button
  local presetRemoveAllBtn = makeButton(presetTab, "Remove All Preset Spells", 170, nil)
  presetRemoveAllBtn:SetPoint("TOPLEFT", presetListContainer, "BOTTOMLEFT", 0, -8)
  presetRemoveAllBtn:Hide()

  -- Preset list rendering
  refreshPresetList = function()
    profile = Resonance.db.profile
    for _, row in ipairs(presetListRows) do row:Hide() end

    local presets = {}

    -- Built-in class presets
    if Resonance_ClassTemplates then
      local classList = {}
      for classKey in pairs(Resonance_ClassTemplates) do
        classList[#classList + 1] = classKey
      end
      table.sort(classList, function(a, b)
        return (CLASS_DISPLAY[a] or a) < (CLASS_DISPLAY[b] or b)
      end)
      for _, classKey in ipairs(classList) do
        local tpl = Resonance_ClassTemplates[classKey]
        local spellCount = #tpl
        local activeCount = 0
        for _, entry in ipairs(tpl) do
          if profile.preset_spells[entry.spellID] == classKey then
            activeCount = activeCount + 1
          end
        end
        presets[#presets + 1] = {
          name = CLASS_DISPLAY[classKey] or classKey,
          key = classKey,
          source = "class",
          spellCount = spellCount,
          muteCount = 0,
          activeCount = activeCount,
        }
      end
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

        row.applyBtn = makeButton(row, "Apply", 50, nil)
        row.removeBtn = makeButton(row, "Remove", 56, nil)
        row.exportBtn = makeButton(row, "Export", 50, nil)
        row.deleteBtn = makeIconButton(row, "Interface\\Buttons\\UI-StopButton", 18, "Delete preset")
      end

      row:SetPoint("TOPLEFT", presetListContainer, "TOPLEFT", 0, -(idx - 1) * ROW_HEIGHT)
      row:SetPoint("RIGHT", presetListContainer, "RIGHT", 0, 0)

      -- Stripe
      if idx % 2 == 0 then
        if not row.stripe then
          row.stripe = row:CreateTexture(nil, "BACKGROUND")
          row.stripe:SetAllPoints()
          row.stripe:SetColorTexture(1, 1, 1, 0.04)
        end
        row.stripe:Show()
      elseif row.stripe then row.stripe:Hide() end

      -- Name
      local nameDisplay = preset.name
      if preset.source == "class" then
        nameDisplay = nameDisplay .. "  |cff888888(Class)|r"
      end
      row.nameText:SetText(nameDisplay)

      -- Info
      local info = preset.spellCount .. " spells"
      if preset.muteCount > 0 then
        info = info .. ", " .. preset.muteCount .. " mutes"
      end
      if preset.activeCount > 0 then
        info = info .. "  |cff00ff00(" .. preset.activeCount .. " active)|r"
      end
      row.infoText:SetText(info)

      -- Build spell list for tooltip preview
      local spellList = {}
      if preset.source == "class" then
        local tpl = Resonance_ClassTemplates[preset.key]
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
          Resonance.msg(("Deleted preset '%s'."):format(preset.name))
          refreshPresetList()
          if refreshList then refreshList() end
        end)
        rightEdge = rightEdge - 22
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
          eiTitle:SetText("Export Preset: " .. preset.name)
          local exportStr = Resonance:ExportPresetData(preset.name, data)
          eiEditBox:SetText(exportStr)
          eiActionBtn:SetText("Close")
          local sc = 0
          for _ in pairs(data.spells or {}) do sc = sc + 1 end
          local mc = 0
          for _ in pairs(data.mutes or {}) do mc = mc + 1 end
          eiStatus:SetText(sc .. " spells, " .. mc .. " mutes.")
          eiFrame:Show()
          eiEditBox:SetFocus()
          eiEditBox:HighlightText()
        end
      end)
      rightEdge = rightEdge - 54

      -- Remove button (only if preset has active spells)
      if preset.activeCount > 0 then
        row.removeBtn:ClearAllPoints()
        row.removeBtn:SetPoint("RIGHT", row, "RIGHT", rightEdge, 0)
        row.removeBtn:SetText("Remove " .. preset.activeCount)
        row.removeBtn:Show()
        row.removeBtn:SetScript("OnClick", function()
          local removed = Resonance:RemovePresetSpells(preset.key)
          Resonance.msg(("Removed %d preset spells from '%s'."):format(removed, preset.name))
          refreshPresetList()
          if refreshList then refreshList() end
        end)
        rightEdge = rightEdge - 72
      else
        row.removeBtn:Hide()
      end

      -- Apply button
      row.applyBtn:ClearAllPoints()
      row.applyBtn:SetPoint("RIGHT", row, "RIGHT", rightEdge, 0)
      row.applyBtn:Show()
      row.applyBtn:SetScript("OnClick", function()
        if preset.source == "class" then
          local added, skipped = Resonance:ApplyClassTemplate(preset.key)
          Resonance.msg(("Preset '%s' applied: %d spells added, %d skipped."):format(preset.name, added, skipped))
        else
          local added, skipped, addedMutes = Resonance:ApplySavedPreset(preset.key)
          Resonance.msg(("Preset '%s' applied: %d spells, %d mutes added (%d skipped)."):format(preset.name, added, addedMutes, skipped))
        end
        refreshPresetList()
        if refreshList then refreshList() end
      end)

      row:Show()
    end

    -- Hide extra rows
    for i = #presets + 1, #presetListRows do presetListRows[i]:Hide() end

    local listH = math.max(#presets * ROW_HEIGHT, ROW_HEIGHT)
    presetListContainer:SetHeight(listH)
    presetListEmpty:SetShown(#presets == 0)

    -- Remove All button
    presetRemoveAllBtn:SetShown(hasActivePresetSpells)

    recalcContentHeight(4)
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
    recalcContentHeight(4)
  end)

  presetSaveConfirmBtn:SetScript("OnClick", function()
    local name = presetSaveNameBox:GetText()
    if name == "" then Resonance.msg("Enter a preset name."); return end
    if Resonance.db.profile.saved_presets[name] then
      Resonance.msg(("Preset '%s' already exists. Choose a different name."):format(name))
      return
    end
    Resonance:SaveCurrentAsPreset(name)
    Resonance.msg(("Saved current config as preset '%s'."):format(name))
    presetSaveFrame:Hide()
    presetListAnchor:ClearAllPoints()
    presetListAnchor:SetPoint("TOPLEFT", presetSaveBtn, "BOTTOMLEFT", 0, -10)
    refreshPresetList()
  end)

  presetSaveCancelBtn:SetScript("OnClick", function()
    presetSaveFrame:Hide()
    presetListAnchor:ClearAllPoints()
    presetListAnchor:SetPoint("TOPLEFT", presetSaveBtn, "BOTTOMLEFT", 0, -10)
    recalcContentHeight(4)
  end)

  presetSaveNameBox:SetScript("OnEnterPressed", function() presetSaveConfirmBtn:Click() end)
  presetSaveNameBox:SetScript("OnEscapePressed", function() presetSaveCancelBtn:Click() end)

  -- Import button
  presetImportBtn:SetScript("OnClick", function()
    eiMode = "import"
    eiTitle:SetText("Import Preset")
    eiEditBox:SetText("")
    eiActionBtn:SetText("Import")
    eiStatus:SetText("Paste a preset string below.")
    eiFrame:Show()
    eiEditBox:SetFocus()
  end)

  -- Remove All Preset Spells button
  presetRemoveAllBtn:SetScript("OnClick", function()
    local removed = Resonance:RemovePresetSpells()
    Resonance.msg(("Removed %d preset spells."):format(removed))
    refreshPresetList()
    if refreshList then refreshList() end
  end)

  -------------------------------------------------------------------
  -- Tab 5: Profiles (AceDBOptions)
  -------------------------------------------------------------------
  local profTab = tabFrames[5].content

  local profContainer = CreateFrame("Frame", nil, profTab)
  profContainer:SetPoint("TOPLEFT", 16, -16)
  profContainer:SetPoint("TOPRIGHT", -16, 0)
  profContainer:SetHeight(400)

  local function buildProfilesTab()
    local container = aceGUI:Create("SimpleGroup")
    container:SetLayout("Fill")
    container.frame:SetParent(profTab)
    container.frame:SetAllPoints(profContainer)
    container.frame:Show()

    AceConfigDialog:Open("Resonance_Profiles", container)
  end

  profContainer:SetScript("OnShow", function(self)
    self:SetScript("OnShow", nil)
    buildProfilesTab()
  end)

  -------------------------------------------------------------------
  -- Dropdown management & panel events
  -------------------------------------------------------------------
  allDropdowns = { edBrowseDD, edSpellSearchDD, muteDD }

  panel:SetScript("OnShow", function() invalidateSpellCache(); selectTab(1) end)
  panel:SetScript("OnHide", function()
    for _, dd in ipairs(allDropdowns) do dd:Hide() end
  end)

  editorFrame:HookScript("OnHide", function()
    edBrowseDD:Hide()
    edSpellSearchDD:Hide()
  end)

  -- Click catcher to close dropdowns when clicking outside
  local clickCatcher = CreateFrame("Button", nil, UIParent)
  clickCatcher:SetAllPoints()
  clickCatcher:SetFrameStrata("TOOLTIP")
  clickCatcher:SetFrameLevel(0)
  clickCatcher:Hide()
  clickCatcher:RegisterForClicks("AnyUp")
  clickCatcher:SetScript("OnClick", function()
    for _, dd in ipairs(allDropdowns) do dd:Hide() end
    clickCatcher:Hide()
  end)

  for _, dd in ipairs(allDropdowns) do
    dd:HookScript("OnShow", function() clickCatcher:Show() end)
    dd:HookScript("OnHide", function()
      local anyVisible = false
      for _, d in ipairs(allDropdowns) do
        if d:IsShown() then anyVisible = true; break end
      end
      if not anyVisible then clickCatcher:Hide() end
    end)
  end
end

---------------------------------------------------------------------------
-- SetupOptions (called from Core.lua OnInitialize)
---------------------------------------------------------------------------
function Resonance:SetupOptions()
  registerPanel()
  buildLayout()
end
