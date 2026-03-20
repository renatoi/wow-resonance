#!/usr/bin/env lua
-- Generate AmbientSoundData.lua for the Resonance addon
-- Reads the wow-listfile and groups ambient sounds by zone/expansion

local input = io.open("/tmp/wow-listfile-unix.csv", "r")
if not input then print("ERROR: cannot open listfile"); os.exit(1) end

-- Collect all ambient entries
local entries = {}
for line in input:lines() do
  local fid, path = line:match("^(%d+);(sound/ambience/.+%.ogg)$")
  if fid then
    fid = tonumber(fid)
    local filename = path:match("[^/]+$"):lower():gsub("%.ogg$", "")
    local subfolder = path:match("sound/ambience/([^/]+)/")
    entries[#entries + 1] = { fid = fid, path = path, filename = filename, subfolder = subfolder }
  end
end
input:close()

-- Zone mapping: pattern -> { display_name, expansion, category }
-- category: "zone", "dungeon", "raid", "city", "general"
local zone_map = {
  -- === Midnight (12.0) ===
  { pat = "12eversong", name = "Eversong Woods", exp = "Midnight", cat = "zone" },
  { pat = "12silvermoon", name = "Silvermoon City", exp = "Midnight", cat = "city" },
  { pat = "12isle", name = "Isle of Quel'Danas", exp = "Midnight", cat = "zone" },
  { pat = "12magister", name = "Magisters' Terrace", exp = "Midnight", cat = "dungeon" },
  { pat = "stormfields", name = "Storm Fields", exp = "Midnight", cat = "zone" },
  { pat = "maisaracaverns", name = "Maisara Caverns", exp = "Midnight", cat = "dungeon" },
  { pat = "maisaradeeps", name = "Maisara Deeps", exp = "Midnight", cat = "dungeon" },
  { pat = "voidstorm", name = "Voidstorm", exp = "Midnight", cat = "zone" },
  { pat = "voidspireraid", name = "Voidspire Raid", exp = "Midnight", cat = "raid" },
  { pat = "karesh", name = "K'aresh", exp = "Midnight", cat = "zone" },
  { pat = "sunwell", name = "Sunwell", exp = "Midnight", cat = "zone" },
  { pat = "windrunner", name = "Windrunner Spire", exp = "Midnight", cat = "dungeon" },
  { pat = "murderrow", name = "Murder Row", exp = "Midnight", cat = "dungeon" },
  { pat = "zulaman", name = "Zul'Aman", exp = "Midnight", cat = "zone" },
  { pat = "nalorakk", name = "Zul'Aman", exp = "Midnight", cat = "zone" },
  { pat = "harandar", name = "Harandar", exp = "Midnight", cat = "zone" },

  -- === The War Within (11.0) ===
  { pat = "11zone1", name = "Isle of Dorn", exp = "The War Within", cat = "zone" },
  { pat = "11zone2", name = "The Ringing Deeps", exp = "The War Within", cat = "zone" },
  { pat = "11zone3", name = "Hallowfall", exp = "The War Within", cat = "zone" },
  { pat = "11zone4", name = "Azj-Kahet", exp = "The War Within", cat = "zone" },
  { pat = "azjkahet", name = "Azj-Kahet", exp = "The War Within", cat = "zone" },
  { pat = "hallowfall", name = "Hallowfall", exp = "The War Within", cat = "zone" },
  { pat = "dornogal", name = "Dornogal", exp = "The War Within", cat = "city" },
  { pat = "delve", name = "Delves", exp = "The War Within", cat = "dungeon" },
  { pat = "nerubar", name = "Nerub'ar Palace", exp = "The War Within", cat = "raid" },
  { pat = "110warband", name = "Warband Camp", exp = "The War Within", cat = "general" },
  { pat = "earthen", name = "Earthen", exp = "The War Within", cat = "zone" },
  { pat = "webwarren", name = "Web Warrens", exp = "The War Within", cat = "dungeon" },
  { pat = "umbralbazaar", name = "Umbral Bazaar", exp = "The War Within", cat = "zone" },
  { pat = "highhollows", name = "High Hollows", exp = "The War Within", cat = "zone" },
  { pat = "tricklingabyss", name = "Trickling Abyss", exp = "The War Within", cat = "zone" },
  { pat = "themaddeningdeep", name = "The Maddening Deep", exp = "The War Within", cat = "zone" },
  { pat = "fungaravillage", name = "Fungara Village", exp = "The War Within", cat = "zone" },
  { pat = "waterworksdungeon", name = "The Waterworks", exp = "The War Within", cat = "dungeon" },
  { pat = "thewaterworks", name = "The Waterworks", exp = "The War Within", cat = "dungeon" },
  { pat = "froststonevault", name = "Froststone Vault", exp = "The War Within", cat = "dungeon" },
  { pat = "niffinhub", name = "Niffin Hub", exp = "The War Within", cat = "zone" },
  { pat = "resonantpeaks", name = "Resonant Peaks", exp = "The War Within", cat = "zone" },
  { pat = "mereldar", name = "Mereldar", exp = "The War Within", cat = "zone" },
  { pat = "hewnkobold", name = "Hewn Kobold Catacombs", exp = "The War Within", cat = "dungeon" },
  { pat = "proveyourworth", name = "Prove Your Worth", exp = "The War Within", cat = "dungeon" },
  { pat = "palacenerubian", name = "Palace of the Nerubians", exp = "The War Within", cat = "raid" },
  { pat = "ecodomedungeon", name = "Ecodome Dungeon", exp = "The War Within", cat = "dungeon" },

  -- TWW dungeons
  { pat = "cinderbrewmeadery", name = "Cinderbrew Meadery", exp = "The War Within", cat = "dungeon" },
  { pat = "cinderbrew", name = "Cinderbrew Meadery", exp = "The War Within", cat = "dungeon" },
  { pat = "darkflamecleft", name = "Darkflame Cleft", exp = "The War Within", cat = "dungeon" },
  { pat = "darkflame", name = "Darkflame Cleft", exp = "The War Within", cat = "dungeon" },
  { pat = "prioryofthesacredflame", name = "Priory of the Sacred Flame", exp = "The War Within", cat = "dungeon" },
  { pat = "priory", name = "Priory of the Sacred Flame", exp = "The War Within", cat = "dungeon" },
  { pat = "rookery", name = "The Rookery", exp = "The War Within", cat = "dungeon" },
  { pat = "floodgate", name = "Operation: Floodgate", exp = "The War Within", cat = "dungeon" },

  -- === Undermine (11.1) ===
  { pat = "undermine", name = "Undermine", exp = "The War Within", cat = "zone" },
  { pat = "scrapdrift", name = "Scrapdrift", exp = "The War Within", cat = "zone" },

  -- === Dragonflight (10.0) ===
  { pat = "dragonisleszone", name = "Dragon Isles", exp = "Dragonflight", cat = "zone" },
  { pat = "ohnahranplains", name = "Ohn'ahran Plains", exp = "Dragonflight", cat = "zone" },
  { pat = "azurespan", name = "The Azure Span", exp = "Dragonflight", cat = "zone" },
  { pat = "thaldraz", name = "Thaldraszus", exp = "Dragonflight", cat = "zone" },
  { pat = "wakingshore", name = "The Waking Shores", exp = "Dragonflight", cat = "zone" },
  { pat = "zaralekc", name = "Zaralek Cavern", exp = "Dragonflight", cat = "zone" },
  { pat = "emeralddream", name = "Emerald Dream", exp = "Dragonflight", cat = "zone" },
  { pat = "102tree", name = "Amirdrassil", exp = "Dragonflight", cat = "raid" },
  { pat = "forbiddenreach", name = "The Forbidden Reach", exp = "Dragonflight", cat = "zone" },
  { pat = "valdrakken", name = "Valdrakken", exp = "Dragonflight", cat = "city" },
  { pat = "primalist", name = "Primalist", exp = "Dragonflight", cat = "zone" },
  { pat = "flashfrostenclave", name = "Flashfrost Enclave", exp = "Dragonflight", cat = "dungeon" },
  { pat = "centaurdungeon", name = "Centaur Dungeon", exp = "Dragonflight", cat = "dungeon" },
  { pat = "brackenhide", name = "Brackenhide Hollow", exp = "Dragonflight", cat = "dungeon" },
  { pat = "scalecrackerkeep", name = "Scalecracker Keep", exp = "Dragonflight", cat = "dungeon" },
  { pat = "bluedragonvault", name = "Blue Dragon Vault", exp = "Dragonflight", cat = "dungeon" },
  { pat = "dreamriftraid", name = "Amirdrassil Raid", exp = "Dragonflight", cat = "raid" },
  { pat = "nokhudon", name = "Nokhudon", exp = "Dragonflight", cat = "zone" },

  -- === Shadowlands (9.0) ===
  { pat = "ardenweald", name = "Ardenweald", exp = "Shadowlands", cat = "zone" },
  { pat = "tirnanoch", name = "Tirna Noch", exp = "Shadowlands", cat = "zone" },
  { pat = "bastion", name = "Bastion", exp = "Shadowlands", cat = "zone" },
  { pat = "maldraxxus", name = "Maldraxxus", exp = "Shadowlands", cat = "zone" },
  { pat = "revendreth", name = "Revendreth", exp = "Shadowlands", cat = "zone" },
  { pat = "oribos", name = "Oribos", exp = "Shadowlands", cat = "city" },
  { pat = "maw", name = "The Maw", exp = "Shadowlands", cat = "zone" },
  { pat = "torghast", name = "Torghast", exp = "Shadowlands", cat = "dungeon" },
  { pat = "korthia", name = "Korthia", exp = "Shadowlands", cat = "zone" },
  { pat = "zereth", name = "Zereth Mortis", exp = "Shadowlands", cat = "zone" },
  { pat = "sepulcher", name = "Sepulcher of the First Ones", exp = "Shadowlands", cat = "raid" },
  { pat = "sanctumofdomination", name = "Sanctum of Domination", exp = "Shadowlands", cat = "raid" },
  { pat = "thejailersarmory", name = "The Jailer's Armory", exp = "Shadowlands", cat = "dungeon" },
  { pat = "kyriancovenanthall", name = "Kyrian Covenant Hall", exp = "Shadowlands", cat = "zone" },
  { pat = "91battle", name = "Battle of Ardenweald", exp = "Shadowlands", cat = "zone" },
  { pat = "91dungeon", name = "Shadowlands Dungeon", exp = "Shadowlands", cat = "dungeon" },
  { pat = "ebonholdstage", name = "Ebon Hold", exp = "Shadowlands", cat = "zone" },
  { pat = "houseofplagues", name = "House of Plagues", exp = "Shadowlands", cat = "dungeon" },
  { pat = "dominationsgrasp", name = "Domination's Grasp", exp = "Shadowlands", cat = "zone" },
  { pat = "landoftheprogenitors", name = "Zereth Mortis Interior", exp = "Shadowlands", cat = "zone" },
  { pat = "theaterofpain", name = "Theater of Pain", exp = "Shadowlands", cat = "dungeon" },

  -- === BFA (8.0) ===
  { pat = "nazjatar", name = "Nazjatar", exp = "Battle for Azeroth", cat = "zone" },
  { pat = "mechagon", name = "Mechagon", exp = "Battle for Azeroth", cat = "zone" },
  { pat = "zuldazar", name = "Zuldazar", exp = "Battle for Azeroth", cat = "zone" },
  { pat = "zandalar", name = "Zandalar", exp = "Battle for Azeroth", cat = "zone" },
  { pat = "boralus", name = "Boralus", exp = "Battle for Azeroth", cat = "city" },
  { pat = "voldun", name = "Vol'dun", exp = "Battle for Azeroth", cat = "zone" },
  { pat = "drustvar", name = "Drustvar", exp = "Battle for Azeroth", cat = "zone" },
  { pat = "tiragarde", name = "Tiragarde Sound", exp = "Battle for Azeroth", cat = "zone" },
  { pat = "stormsong", name = "Stormsong Valley", exp = "Battle for Azeroth", cat = "zone" },
  { pat = "kultiras", name = "Kul Tiras", exp = "Battle for Azeroth", cat = "zone" },
  { pat = "nazmir", name = "Nazmir", exp = "Battle for Azeroth", cat = "zone" },
  { pat = "atalabasi", name = "Atal'Dazar", exp = "Battle for Azeroth", cat = "dungeon" },
  { pat = "underrot", name = "Underrot", exp = "Battle for Azeroth", cat = "dungeon" },
  { pat = "waycrest", name = "Waycrest Manor", exp = "Battle for Azeroth", cat = "dungeon" },
  { pat = "uldir", name = "Uldir", exp = "Battle for Azeroth", cat = "raid" },
  { pat = "nzoth", name = "N'Zoth Visions", exp = "Battle for Azeroth", cat = "zone" },
  { pat = "80_zul", name = "Zul'Nazman", exp = "Battle for Azeroth", cat = "dungeon" },
  { pat = "motherlode", name = "The MOTHERLODE!!", exp = "Battle for Azeroth", cat = "dungeon" },
  { pat = "arathikobyssisland", name = "Arathi Kobys Island", exp = "Battle for Azeroth", cat = "zone" },

  -- === Legion (7.0) ===
  { pat = "argus", name = "Argus", exp = "Legion", cat = "zone" },
  { pat = "suramar", name = "Suramar", exp = "Legion", cat = "zone" },
  { pat = "azsuna", name = "Azsuna", exp = "Legion", cat = "zone" },
  { pat = "brokenshore", name = "Broken Shore", exp = "Legion", cat = "zone" },
  { pat = "brokenisles", name = "Broken Isles", exp = "Legion", cat = "zone" },
  { pat = "stormheim", name = "Stormheim", exp = "Legion", cat = "zone" },
  { pat = "valsharah", name = "Val'sharah", exp = "Legion", cat = "zone" },
  { pat = "highmountain", name = "Highmountain", exp = "Legion", cat = "zone" },
  { pat = "dalaran", name = "Dalaran", exp = "Legion", cat = "city" },
  { pat = "helheim", name = "Helheim", exp = "Legion", cat = "zone" },
  { pat = "seatofthetriumvirate", name = "Seat of the Triumvirate", exp = "Legion", cat = "dungeon" },

  -- === General/Special ===
  { pat = "ghoststate", name = "Ghost/Death World", exp = "General", cat = "general" },
  { pat = "undwater", name = "Underwater", exp = "General", cat = "general" },
  { pat = "weather", name = "Weather Effects", exp = "General", cat = "general" },
  { pat = "rain", name = "Rain", exp = "General", cat = "general" },
  { pat = "snow", name = "Snow", exp = "General", cat = "general" },
  { pat = "sandstorm", name = "Sandstorm", exp = "General", cat = "general" },
  { pat = "lava", name = "Lava/Volcanic", exp = "General", cat = "general" },
  { pat = "river", name = "River/Water", exp = "General", cat = "general" },
  { pat = "ocean", name = "Ocean", exp = "General", cat = "general" },
  { pat = "tavern", name = "Tavern/Inn", exp = "General", cat = "general" },
  { pat = "submarine", name = "Submarine", exp = "General", cat = "general" },
  { pat = "subway", name = "Deeprun Tram", exp = "General", cat = "general" },
}

-- Process entries
local zones = {}  -- key -> { name, exp, cat, fids = {} }

local function getZoneKey(e)
  local fn = e.filename
  for _, zm in ipairs(zone_map) do
    if fn:find(zm.pat, 1, true) then
      return zm.pat, zm
    end
  end
  return nil
end

for _, e in ipairs(entries) do
  local key, zm = getZoneKey(e)
  if key then
    if not zones[key] then
      zones[key] = { name = zm.name, exp = zm.exp, cat = zm.cat, fids = {} }
    end
    zones[key].fids[#zones[key].fids + 1] = e.fid
  end
  -- Skip unmatched (older/generic sounds) for now
end

-- Merge zones with same expansion+name (e.g., multiple patterns mapping to "Hallowfall")
local merged = {}  -- "exp|name" -> { name, exp, cat, fids = {} }
for _, z in pairs(zones) do
  local mkey = z.exp .. "|" .. z.name
  if not merged[mkey] then
    merged[mkey] = { name = z.name, exp = z.exp, cat = z.cat, fids = {} }
  end
  for _, fid in ipairs(z.fids) do
    merged[mkey].fids[#merged[mkey].fids + 1] = fid
  end
end
-- Deduplicate FIDs within each merged zone
for _, z in pairs(merged) do
  local seen = {}
  local unique = {}
  for _, fid in ipairs(z.fids) do
    if not seen[fid] then
      seen[fid] = true
      unique[#unique + 1] = fid
    end
  end
  z.fids = unique
end
zones = merged

-- Generate Lua output
-- Resolve output path relative to the script's location
local scriptDir = arg[0]:match("(.*/)")  or "./"
local out = io.open(scriptDir .. "../data/AmbientSoundData.lua", "w")

out:write("-- Ambient/environmental sound data for selective muting\n")
out:write("-- Generated from wowdev/wow-listfile community data\n")
out:write("-- Format: Resonance_AmbientSoundData[expansion][zone] = \"fid1,fid2,...\"\n")
out:write("-- Each entry is a comma-separated string of FileDataIDs (same format as SpellMuteData)\n")
out:write("\n")
out:write("Resonance_AmbientSoundData = {\n")

local expansionOrder = {
  "Midnight", "The War Within", "Dragonflight", "Shadowlands",
  "Battle for Azeroth", "Legion", "General"
}

for _, exp in ipairs(expansionOrder) do
  -- Collect zones for this expansion
  local zoneList = {}
  for mkey, z in pairs(zones) do
    if z.exp == exp then
      zoneList[#zoneList + 1] = { key = mkey, zone = z }
    end
  end
  if #zoneList == 0 then goto continue end

  table.sort(zoneList, function(a, b) return a.zone.name < b.zone.name end)

  out:write(string.format("  [\"%s\"] = {\n", exp))

  for _, entry in ipairs(zoneList) do
    local z = entry.zone
    table.sort(z.fids)
    local fidStrs = {}
    for _, fid in ipairs(z.fids) do fidStrs[#fidStrs + 1] = tostring(fid) end
    local catTag = z.cat ~= "zone" and (" -- " .. z.cat) or ""
    out:write(string.format("    [\"%s\"]=\"%s\",%s\n", z.name, table.concat(fidStrs, ","), catTag))
  end

  out:write("  },\n")
  ::continue::
end

out:write("}\n")
out:close()

-- Print stats
local totalFids = 0
local totalZones = 0
for _, z in pairs(zones) do
  totalZones = totalZones + 1
  totalFids = totalFids + #z.fids
end
io.stderr:write(string.format("Generated: %d zones, %d FileDataIDs across %d expansions\n",
  totalZones, totalFids, #expansionOrder))
