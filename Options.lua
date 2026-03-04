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
  local allDropdowns = {}

  -------------------------------------------------------------------
  -- Tab system
  -------------------------------------------------------------------
  local TAB_NAMES = { "General", "Spell Sounds", "Muted Sounds", "Profiles" }
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
  contentBox:SetPoint("TOPLEFT", panel, "TOPLEFT", 4, -(TAB_HEIGHT + 6 - TAB_OVERLAP))
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

    -- Mask that hides the bottom border when tab is active
    btn.bottomMask = btn:CreateTexture(nil, "OVERLAY")
    btn.bottomMask:SetColorTexture(CONTENT_BG[1], CONTENT_BG[2], CONTENT_BG[3], 1)
    btn.bottomMask:SetPoint("BOTTOMLEFT", 3, -TAB_OVERLAP)
    btn.bottomMask:SetPoint("BOTTOMRIGHT", -3, -TAB_OVERLAP)
    btn.bottomMask:SetHeight(TAB_OVERLAP + 8)
    btn.bottomMask:Hide()

    if i == 1 then
      btn:SetPoint("TOPLEFT", panel, "TOPLEFT", 8, -6)
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
      local _, yRange = self:GetVerticalScrollRange()
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
        btn:SetBackdropColor(CONTENT_BG[1], CONTENT_BG[2], CONTENT_BG[3], CONTENT_BG[4])
        btn:SetBackdropBorderColor(0.45, 0.45, 0.45, 1)
        btn:SetFrameLevel(contentBox:GetFrameLevel() + 2)
        btn.text:SetFontObject("GameFontHighlight")
        btn.bottomMask:Show()
      else
        btn:SetBackdropColor(0.08, 0.08, 0.08, 0.5)
        btn:SetBackdropBorderColor(0.4, 0.4, 0.4, 0.7)
        btn:SetFrameLevel(contentBox:GetFrameLevel() + 1)
        btn.text:SetFontObject("GameFontNormal")
        btn.bottomMask:Hide()
      end
    end
    for _, dd in ipairs(allDropdowns) do dd:Hide() end
    if id == 1 then recalcContentHeight(1) end
    if id == 2 and refreshList then refreshList() end
    if id == 3 and refreshMuteList then refreshMuteList() end
  end

  for i, btn in ipairs(tabButtons) do
    btn:SetScript("OnClick", function() selectTab(i) end)
  end

  -------------------------------------------------------------------
  -- Tab 1: General (AceConfig embedded)
  -------------------------------------------------------------------
  local gen = tabFrames[1].content

  local aceContainer = CreateFrame("Frame", nil, gen)
  aceContainer:SetPoint("TOPLEFT", 0, 0)
  aceContainer:SetPoint("TOPRIGHT", 0, 0)
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

  -- Template section (only shown when ClassTemplates data is available)
  local templateSection = CreateFrame("Frame", nil, spellTab)
  templateSection:SetPoint("TOPLEFT", 16, -16)
  templateSection:SetPoint("RIGHT", spellTab, "RIGHT", -16, 0)
  templateSection:SetHeight(1) -- resized dynamically

  local templateAnchorBottom = templateSection -- used for anchoring spell list below

  if Resonance_ClassTemplates then
    local tplHeader = templateSection:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    tplHeader:SetPoint("TOPLEFT", 0, 0)
    tplHeader:SetText("Class Templates")

    -- Class dropdown
    local _, playerClass = UnitClass("player")
    local selectedClass = playerClass

    local tplClassLabel = templateSection:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    tplClassLabel:SetPoint("TOPLEFT", tplHeader, "BOTTOMLEFT", 0, -8)
    tplClassLabel:SetText("Class:")

    local tplClassBtn = CreateFrame("Button", nil, templateSection, "UIPanelButtonTemplate")
    tplClassBtn:SetSize(120, 22)
    tplClassBtn:SetPoint("LEFT", tplClassLabel, "RIGHT", 6, 0)

    local CLASS_DISPLAY = {
      WARRIOR = "Warrior", MAGE = "Mage", ROGUE = "Rogue", PALADIN = "Paladin",
      DRUID = "Druid", WARLOCK = "Warlock", PRIEST = "Priest", SHAMAN = "Shaman",
      HUNTER = "Hunter", DEATHKNIGHT = "Death Knight", MONK = "Monk",
      DEMONHUNTER = "Demon Hunter", EVOKER = "Evoker",
    }

    local function getClassDisplay(key)
      return CLASS_DISPLAY[key] or key
    end

    tplClassBtn:SetText(getClassDisplay(selectedClass))

    local tplInfoText = templateSection:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    tplInfoText:SetPoint("TOPLEFT", tplClassLabel, "BOTTOMLEFT", 0, -6)

    local tplStatusText = templateSection:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    tplStatusText:SetPoint("TOPLEFT", tplInfoText, "BOTTOMLEFT", 0, -4)

    local tplApplyBtn = makeButton(templateSection, "Apply Template", 110, nil)
    tplApplyBtn:SetPoint("TOPLEFT", tplStatusText, "BOTTOMLEFT", 0, -6)

    local tplRemoveBtn = makeButton(templateSection, "Remove Template Spells", 160, nil)
    tplRemoveBtn:SetPoint("LEFT", tplApplyBtn, "RIGHT", 8, 0)

    local function updateTemplateInfo()
      local template = Resonance_ClassTemplates[selectedClass]
      if template then
        tplInfoText:SetText(#template .. " spells with classic sound replacements")
      else
        tplInfoText:SetText("|cff888888No template available for this class.|r")
      end

      -- Count active template spells
      local p = Resonance.db.profile
      local active, total = 0, 0
      if template then
        total = #template
        for _, entry in ipairs(template) do
          if p.template_spells[entry.spellID] then active = active + 1 end
        end
      end
      if active > 0 then
        tplStatusText:SetText("|cff66aaff" .. active .. " of " .. total .. " template spells active|r")
      else
        tplStatusText:SetText("")
      end

      tplApplyBtn:SetEnabled(template ~= nil)
      tplRemoveBtn:SetEnabled(active > 0)
    end

    -- Class dropdown menu (custom popup, no EasyMenu dependency)
    local tplClassPopup = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
    tplClassPopup:SetFrameStrata("TOOLTIP")
    tplClassPopup:SetClampedToScreen(true)
    tplClassPopup:Hide()
    tplClassPopup:SetBackdrop({
      bgFile = "Interface\\BUTTONS\\WHITE8X8",
      edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
      edgeSize = 14, insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    tplClassPopup:SetBackdropColor(0.05, 0.05, 0.07, 0.97)
    tplClassPopup:SetBackdropBorderColor(0.25, 0.25, 0.30, 0.7)

    local classList = {}
    for classKey in pairs(Resonance_ClassTemplates) do
      classList[#classList + 1] = classKey
    end
    table.sort(classList, function(a, b) return getClassDisplay(a) < getClassDisplay(b) end)

    local CLASS_ROW_H = 20
    tplClassPopup:SetSize(130, #classList * CLASS_ROW_H + 8)
    for i, classKey in ipairs(classList) do
      local row = CreateFrame("Button", nil, tplClassPopup)
      row:SetSize(124, CLASS_ROW_H)
      row:SetPoint("TOPLEFT", 3, -(i - 1) * CLASS_ROW_H - 4)
      row.text = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
      row.text:SetPoint("LEFT", 6, 0)
      row.text:SetText(getClassDisplay(classKey))
      row:SetHighlightTexture("Interface\\BUTTONS\\WHITE8X8")
      row:GetHighlightTexture():SetAlpha(0.15)
      row:SetScript("OnClick", function()
        selectedClass = classKey
        tplClassBtn:SetText(getClassDisplay(classKey))
        updateTemplateInfo()
        tplClassPopup:Hide()
      end)
    end

    tplClassBtn:SetScript("OnClick", function(self)
      if tplClassPopup:IsShown() then
        tplClassPopup:Hide()
      else
        tplClassPopup:ClearAllPoints()
        tplClassPopup:SetPoint("TOPLEFT", self, "BOTTOMLEFT", 0, -2)
        tplClassPopup:Show()
      end
    end)
    -- Hide popup when clicking elsewhere
    tplClassPopup:SetScript("OnShow", function(self)
      self:SetScript("OnUpdate", function(s)
        if not s:IsMouseOver() and not tplClassBtn:IsMouseOver() and IsMouseButtonDown("LeftButton") then
          s:Hide()
        end
      end)
    end)
    tplClassPopup:SetScript("OnHide", function(self)
      self:SetScript("OnUpdate", nil)
    end)

    tplApplyBtn:SetScript("OnClick", function()
      local added, skipped = Resonance:ApplyClassTemplate(selectedClass)
      Resonance.msg(("Template applied: %d spells added, %d skipped (already configured)."):format(added, skipped))
      updateTemplateInfo()
      if refreshList then refreshList() end
    end)

    tplRemoveBtn:SetScript("OnClick", function()
      local removed = Resonance:RemoveTemplateSpells()
      Resonance.msg(("Removed %d template spells."):format(removed))
      updateTemplateInfo()
      if refreshList then refreshList() end
    end)

    -- Separator line
    local tplSep = templateSection:CreateTexture(nil, "ARTWORK")
    tplSep:SetHeight(1)
    tplSep:SetPoint("TOPLEFT", tplApplyBtn, "BOTTOMLEFT", 0, -10)
    tplSep:SetPoint("RIGHT", templateSection, "RIGHT", 0, 0)
    tplSep:SetColorTexture(0.3, 0.3, 0.35, 0.5)

    templateSection:SetHeight(100) -- approximate; content height managed by recalc
    templateAnchorBottom = tplSep

    -- Update on show
    templateSection:SetScript("OnShow", function()
      updateTemplateInfo()
    end)
    updateTemplateInfo()
  end

  local secHeader = spellTab:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
  secHeader:SetPoint("TOPLEFT", templateAnchorBottom, "BOTTOMLEFT", 0, -12)
  secHeader:SetText("Spell Sounds")

  local addBtn = makeButton(spellTab, "+ Add Spell", 80, nil)
  addBtn:SetPoint("LEFT", secHeader, "RIGHT", 12, 0)

  local exportBtn = makeButton(spellTab, "Export", 54, nil)
  exportBtn:SetPoint("LEFT", addBtn, "RIGHT", 6, 0)

  local importBtn = makeButton(spellTab, "Import", 54, nil)
  importBtn:SetPoint("LEFT", exportBtn, "RIGHT", 4, 0)

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

  -------------------------------------------------------------------
  -- Export/Import dialog
  -------------------------------------------------------------------
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

  local eiCloseBtn = CreateFrame("Button", nil, eiTitleBar, "UIPanelCloseButton")
  eiCloseBtn:SetPoint("TOPRIGHT", eiFrame, "TOPRIGHT", -2, -2)

  tinsert(UISpecialFrames, "ResonanceExportImport")

  -- Scrollable text box
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

  -- Status text
  local eiStatus = eiFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  eiStatus:SetPoint("BOTTOMLEFT", eiFrame, "BOTTOMLEFT", 16, 18)
  eiStatus:SetWidth(300)
  eiStatus:SetJustifyH("LEFT")

  -- Action button
  local eiActionBtn = makeButton(eiFrame, "Close", 80, nil)
  eiActionBtn:SetPoint("BOTTOMRIGHT", eiFrame, "BOTTOMRIGHT", -16, 14)

  local eiMode = "export"

  exportBtn:SetScript("OnClick", function()
    eiMode = "export"
    eiTitle:SetText("Export Configuration")
    local exportStr = Resonance:ExportConfig()
    eiEditBox:SetText(exportStr)
    eiActionBtn:SetText("Close")
    -- Count entries for status
    local spellCount, muteCount = 0, 0
    for _ in pairs(Resonance.db.profile.spell_config or {}) do spellCount = spellCount + 1 end
    for _, v in pairs(Resonance.db.profile.mute_file_data_ids or {}) do if v then muteCount = muteCount + 1 end end
    eiStatus:SetText(spellCount .. " spells, " .. muteCount .. " mutes exported.")
    eiFrame:Show()
    eiEditBox:SetFocus()
    eiEditBox:HighlightText()
  end)

  importBtn:SetScript("OnClick", function()
    eiMode = "import"
    eiTitle:SetText("Import Configuration")
    eiEditBox:SetText("")
    eiActionBtn:SetText("Import")
    eiStatus:SetText("")
    eiFrame:Show()
    eiEditBox:SetFocus()
  end)

  eiActionBtn:SetScript("OnClick", function()
    if eiMode == "export" then
      eiFrame:Hide()
    else
      local text = eiEditBox:GetText()
      local added, skippedOrErr, addedMutes = Resonance:ImportConfig(text)
      if not added then
        -- skippedOrErr is the error message
        eiStatus:SetText("|cffff4444" .. (skippedOrErr or "Import failed.") .. "|r")
      else
        eiStatus:SetText(("Added %d spells, %d mutes (%d skipped)."):format(added, addedMutes, skippedOrErr))
        refreshList()
      end
    end
  end)

  -- Spell list rendering
  refreshList = function()
    profile = Resonance.db.profile
    for _, row in ipairs(listRows) do row:Hide() end

    local sorted = {}
    for sid, cfg in pairs(profile.spell_config or {}) do
      sorted[#sorted + 1] = { spellID = sid, cfg = cfg }
    end
    table.sort(sorted, function(a, b) return a.spellID < b.spellID end)

    for idx, entry in ipairs(sorted) do
      local row = listRows[idx]
      if not row then
        row = CreateFrame("Frame", nil, listContainer)
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
      end

      row:SetPoint("TOPLEFT", listContainer, "TOPLEFT", 0, -(idx - 1) * ROW_HEIGHT)
      row:SetPoint("RIGHT", listContainer, "RIGHT", 0, 0)

      if idx % 2 == 0 then
        if not row.stripe then
          row.stripe = row:CreateTexture(nil, "BACKGROUND")
          row.stripe:SetAllPoints()
          row.stripe:SetColorTexture(1, 0.82, 0, 0.08)
        end
        row.stripe:Show()
      elseif row.stripe then row.stripe:Hide() end

      local spellName = Resonance.getSpellName(entry.spellID) or "?"
      local isTemplate = profile.template_spells and profile.template_spells[entry.spellID]
      row.nameText:SetText(spellName .. " (" .. entry.spellID .. ")" .. (isTemplate and " |cff66aaff[T]|r" or ""))

      local cfg = entry.cfg
      if cfg.sound then
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
      else
        row.soundText:SetText("|cff888888no sound|r")
      end

      row.playBtn:SetEnabled(cfg.sound ~= nil)
      row.playBtn:SetScript("OnClick", function() if cfg.sound then safePlaySound(cfg.sound) end end)
      row.editBtn:SetScript("OnClick", function() openEditor(entry.spellID) end)
      row.delBtn:SetScript("OnClick", function()
        Resonance.removeAutoMutesForSpell(entry.spellID)
        Resonance.db.profile.spell_config[entry.spellID] = nil
        closeEditor()
        refreshList()
      end)

      row:Show()
    end

    local totalH = math.max(#sorted * ROW_HEIGHT, ROW_HEIGHT)
    listContainer:SetHeight(totalH)
    listEmpty:SetShown(#sorted == 0)
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

  -- Muted IDs list
  local muteListHeader = muteTab:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  muteListHeader:SetPoint("TOPLEFT", muteSearchFrame, "BOTTOMLEFT", 0, -10)
  muteListHeader:SetText("Muted IDs:")

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
  clearAllBtn:SetPoint("LEFT", muteListHeader, "RIGHT", 8, 0)

  local muteListContainer = CreateFrame("Frame", nil, muteTab)
  muteListContainer:SetPoint("TOPLEFT", muteListHeader, "BOTTOMLEFT", 0, -4)
  muteListContainer:SetPoint("RIGHT", muteTab, "RIGHT", -4, 0)
  muteListContainer:SetHeight(ROW_HEIGHT)

  local muteListEmpty = muteListContainer:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  muteListEmpty:SetPoint("TOPLEFT", 4, 0)
  muteListEmpty:SetText("|cff888888No sounds muted.|r")

  local muteListRows = {}

  refreshMuteList = function()
    profile = Resonance.db.profile
    for _, row in ipairs(muteListRows) do row:Hide() end

    -- Collect all muted FIDs, tracking source
    local fidSet = {}
    for fid, enabled in pairs(profile.mute_file_data_ids or {}) do
      if enabled then fidSet[fid] = { source = "manual" } end
    end
    -- Build reverse lookup: FID -> { spells, excluded }
    -- Include ALL auto-mute FIDs (even excluded ones) so they stay visible in the list
    local autoFidInfo = {}  -- [fid] = { spells = {}, excluded = bool }
    for sid in pairs(profile.spell_config or {}) do
      local fids = Resonance_SpellMuteData and Resonance_SpellMuteData[sid]
      if fids then
        local excl = profile.spell_config[sid].muteExclusions
        for _, fid in ipairs(fids) do
          if not autoFidInfo[fid] then autoFidInfo[fid] = { spells = {}, excluded = true } end
          local name = Resonance.getSpellName(sid) or tostring(sid)
          autoFidInfo[fid].spells[#autoFidInfo[fid].spells + 1] = name
          -- If ANY spell does NOT exclude this FID, it's actively muted
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

    local sorted = {}
    for fid, info in pairs(fidSet) do
      sorted[#sorted + 1] = { fid = fid, source = info.source, spells = info.spells }
    end
    table.sort(sorted, function(a, b) return a.fid < b.fid end)

    for idx, entry in ipairs(sorted) do
      local fid = entry.fid
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

      local display
      local path = lookupFIDPath(fid)
      if path then
        display = formatSoundDisplay(path, fid)
      else
        display = "|cffff8800" .. fid .. "|r"
      end
      local isAuto = entry.source == "auto" or entry.source == "auto_excluded" or entry.source == "both"
      local spellTag = ""
      if isAuto and entry.spells and #entry.spells > 0 then
        spellTag = table.concat(entry.spells, ", ")
      end
      if isAuto then
        if entry.excluded then
          display = "|cff888888[unmuted]|r |cff66aaff[" .. (spellTag ~= "" and spellTag or "auto") .. "]|r " .. display
        else
          display = "|cff66aaff[" .. (spellTag ~= "" and spellTag or "auto") .. "]|r " .. display
        end
      end
      row.text:SetText(display)

      row.playBtn:SetScript("OnClick", function() safePlaySound(fid) end)

      -- Create muteToggle button if needed (separate from removeBtn)
      if not row.muteToggle then
        row.muteToggle = makeButton(row, "Unmute", 52, nil)
        row.muteToggle:SetPoint("RIGHT", row.playBtn, "LEFT", -2, 0)
      end

      row.removeBtn:SetEnabled(true)
      row.removeBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

      if isAuto then
        -- Auto-muted: show mute/unmute toggle, hide remove button
        row.removeBtn:Hide()
        row.muteToggle:Show()
        row.muteToggle:SetText(entry.excluded and "Mute" or "Unmute")
        row.text:SetPoint("RIGHT", row, "RIGHT", -100, 0)
        row.muteToggle:SetScript("OnClick", function()
          if entry.excluded then
            -- Re-mute: remove exclusions for this FID from all spells
            for sid in pairs(profile.spell_config or {}) do
              local excl = profile.spell_config[sid].muteExclusions
              if excl then excl[fid] = nil end
            end
          else
            -- Unmute: add exclusion to all spells that auto-mute this FID
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
          end
          Resonance.rebuildAutoMutes()
          Resonance.clearMutes()
          if profile.enabled then Resonance.applyMutes() end
          refreshMuteList()
        end)
      else
        -- Manual-only: show remove button, hide toggle
        row.muteToggle:Hide()
        row.removeBtn:Show()
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

      if not row.stripe and idx % 2 == 0 then
        row.stripe = row:CreateTexture(nil, "BACKGROUND")
        row.stripe:SetAllPoints()
        row.stripe:SetColorTexture(1, 1, 1, 0.04)
      end
      if row.stripe then row.stripe:SetShown(idx % 2 == 0) end

      row:Show()
    end

    local totalH = math.max(#sorted * ROW_HEIGHT, ROW_HEIGHT)
    muteListContainer:SetHeight(totalH)
    muteListEmpty:SetShown(#sorted == 0)
    recalcContentHeight(3)
  end

  setMuteMode("spells")

  -------------------------------------------------------------------
  -- Tab 4: Profiles (AceDBOptions)
  -------------------------------------------------------------------
  local profTab = tabFrames[4].content

  local profContainer = CreateFrame("Frame", nil, profTab)
  profContainer:SetPoint("TOPLEFT", 0, 0)
  profContainer:SetPoint("TOPRIGHT", 0, 0)
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
