-- Class Templates: sensible defaults per class
-- Mutes modern spell sounds and replaces with classic-era sound FIDs
-- Original classes: 567000-569999 (vanilla/TBC/Wrath), DK: 568000-615000 (Wrath/Cata), Monk: 606000-631000 (MoP)
-- Only includes spells that have both mute data in SpellMuteData and a confirmed classic FID
-- Classic FIDs cross-referenced against DB2 ClassicSpellSounds + Wowhead Classic/TBC/MoP spell pages
--
-- Format: { spellID, name (for readability), sound (classic FID or table), [muteExclusions] }
-- sound can be: number (single FID), {fid, ...} (play all), or {fid, random={fid,...}} (play fixed + 1 random from pool)
-- Class keys match select(2, UnitClass("player"))
--
-- Projectile spells use a classic cast/channel sound as the replacement (plays at cast time
-- via UNIT_SPELLCAST_SUCCEEDED) and muteExclusions for modern cast-start and impact FIDs
-- so the retail precast buildup and projectile impact still play naturally.
-- Instant-impact spells use the classic impact sound directly (timing is correct).

Resonance_ClassTemplates = {
  WARRIOR = {
    { spellID = 163201, name = "Execute",           sound = 568274 },  -- SealOfMight.ogg (DB2-verified classic Execute)
    { spellID = 5308,   name = "Execute",           sound = 568274 },  -- SealOfMight.ogg (classic base ID)
    { spellID = 280735, name = "Execute",           sound = 568274 },  -- SealOfMight.ogg (Fury variant)
    { spellID = 1680,   name = "Whirlwind",         sound = 568519 },  -- WhirlwindShort.ogg
    { spellID = 190411, name = "Whirlwind",         sound = 568519 },  -- WhirlwindShort.ogg (Fury variant)
    { spellID = 6343,   name = "Thunder Clap",      sound = 569222, muteFIDs = {1362397, 1362398, 1362399, 1362400} },  -- ThunderClap.ogg
    { spellID = 1464,   name = "Slam",              sound = 569828, muteFIDs = {1302598, 1302599, 1302600} },  -- SwingWeaponSpecialWarriorA.ogg
    { spellID = 1269383, name = "Slam",             sound = 569828, muteFIDs = {1324858, 1324859, 1324860, 1324861, 1324862} },  -- SwingWeaponSpecialWarriorA.ogg (Midnight variant)
    { spellID = 7384,   name = "Overpower",         sound = {569828, 569098}, muteFIDs = {1258146, 1258147, 1258148, 1258149} },  -- SwingWeaponSpecialWarriorA.ogg + DecisiveStrike.ogg
    { spellID = 772,    name = "Rend",              sound = 568003 },  -- RendTarget.ogg
    { spellID = 845,    name = "Cleave",            sound = 568227 },  -- CleaveTarget.ogg
    { spellID = 12294,  name = "Mortal Strike",     sound = 569098 },  -- DecisiveStrike.ogg
    { spellID = 23922,  name = "Shield Slam",       sound = 567879 },  -- m1hSwordHitMetalShieldCrit.ogg
    { spellID = 6572,   name = "Revenge",           sound = 569098 },  -- DecisiveStrike.ogg
    -- Heroic Leap removed: sound plays on cast, not on landing (WoW API limitation)
    { spellID = 34428,  name = "Victory Rush",      sound = 568003 },  -- RendTarget.ogg
    { spellID = 6552,   name = "Pummel",            sound = 567944 },  -- mWooshMediumCrit.ogg
    { spellID = 5246,   name = "Intimidating Shout", sound = 568028 }, -- BattleShoutTarget.ogg
    { spellID = 1160,   name = "Demoralizing Shout", sound = 568028 }, -- BattleShoutTarget.ogg
    { spellID = 2565,   name = "Shield Block",      sound = 569473 },  -- ShieldWallTarget.ogg
    { spellID = 167105, name = "Colossus Smash",    sound = 568664 },  -- colossussmash_impact_01.ogg
    { spellID = 46924,  name = "Bladestorm",         sound = 568519 },  -- WhirlwindShort.ogg
    { spellID = 20243,  name = "Devastate",          sound = 568983 },  -- warrior_devastate1.ogg
    { spellID = 23881,  name = "Bloodthirst",        sound = 568003 },  -- RendTarget.ogg
    { spellID = 335096, name = "Bloodthirst",        sound = 568003 },  -- RendTarget.ogg (talent variant)
    { spellID = 85288,  name = "Raging Blow",        sound = 568003 },  -- RendTarget.ogg
    { spellID = 335097, name = "Bloodbath",          sound = 568003 },  -- RendTarget.ogg (talent replacing Raging Blow)
    { spellID = 184367, name = "Rampage",            sound = 569098 },  -- DecisiveStrike.ogg (classic Mortal Strike sound)
    { spellID = 1715,   name = "Hamstring",          sound = 568003 },  -- RendTarget.ogg
    { spellID = 46968,  name = "Shockwave",          sound = 569193 },  -- warrior_shockwave_area.ogg
    -- Ravager talent (replaces Bladestorm, may proc from Revenge)
    { spellID = 384110, name = "Ravager",            sound = nil },  -- mute-only
    -- Buffs / Defensives
    { spellID = 23920,  name = "Spell Reflection",     sound = 568951 },  -- spellreflection_state_shield.ogg
    { spellID = 871,    name = "Shield Wall",           sound = 568510 },  -- defensivestance.ogg
    { spellID = 1719,   name = "Recklessness",          sound = 569491 },  -- recklessnesstarget.ogg
    { spellID = 12975,  name = "Last Stand",             sound = 569329 },  -- druid_survival_istincts.ogg
    { spellID = 184364, name = "Enraged Regeneration",   sound = 568589 },  -- endlessrage_state_head.ogg
    { spellID = 18765,  name = "Sweeping Strikes",       sound = 568227 },  -- cleavetarget.ogg
    { spellID = 6673,   name = "Battle Shout",           sound = 568028 },  -- battleshouttarget.ogg
    { spellID = 97462,  name = "Rallying Cry",           sound = 568028 },  -- battleshouttarget.ogg
    { spellID = 12323,  name = "Piercing Howl",          sound = {568028, 568268} },  -- battleshouttarget.ogg + taunt.ogg
    -- Ranged (Heroic Throw, Shattering Throw removed: projectiles, not instant impact — keep retail sounds)
    { spellID = 3411,   name = "Intervene",              sound = 568712 },  -- heroricleap.ogg
    -- Mountain Thane hero talent variants
    { spellID = 435222, name = "Thunder Blast",     sound = 569222, muteFIDs = {1362397, 1362398, 1362399, 1362400, 4544034, 4544036, 4544038, 4544040, 4544042, 4544044, 4544046, 4544048, 4544050, 4544052, 4544054} },  -- ThunderClap.ogg
    { spellID = 435791, name = "Lightning Strike",  sound = 568516 },            -- LightningBoltImpact.ogg
  },
  MAGE = {
    -- Projectile: classic cast sound + keep modern impact
    { spellID = 133,    name = "Fireball",          sound = 569764, muteExclusions = {1685533, 1685534, 1685535, 1689933, 1689934} },  -- firecast.ogg (+cast-start)
    { spellID = 116,    name = "Frostbolt",         sound = 569765, muteExclusions = {1631383, 1631384, 1631385, 1631386, 1631387, 1631388, 1631389, 1631390, 1631391, 1631392, 1631393, 1631394} },  -- frostcast.ogg (+cast-start)
    { spellID = 11366,  name = "Pyroblast",         sound = 569764, muteExclusions = {1392377, 1392378, 1392379, 1392380, 1392381, 1685536, 1685537, 1694574, 1694581} },  -- firecast.ogg (+cast-start)
    -- Instant impact
    { spellID = 108853, name = "Fire Blast",        sound = {569764, random = {568461, 568429, 569449, 569559}} },  -- firecast.ogg + 1 random impact (fireballimpact a/b/c, MoltenBlastImpact)
    { spellID = 190356, name = "Blizzard",          sound = 568542 },  -- BlizzardImpact1a.ogg
    { spellID = 122,    name = "Frost Nova",        sound = 569378 },  -- FrostNova.ogg
    { spellID = 118,    name = "Polymorph",         sound = 569526 },  -- Polymorph.ogg
    { spellID = 2120,   name = "Flamestrike",       sound = 568641 },  -- Flamestrike.ogg
    { spellID = 1449,   name = "Arcane Explosion",  sound = {568678, random = {569631, 569565, 569554}} },  -- ArcaneExplosion.ogg + 1 random impact (ArcaneMissileImpact 1a/1b/1c)
    { spellID = 2139,   name = "Counterspell",      sound = 568860 },  -- Counterspell.ogg
    { spellID = 2948,   name = "Scorch",            sound = {569764, random = {569559, 568461, 568429, 569449}}, muteExclusions = {1694574, 1694581, 1685538, 1685539, 1685540} },  -- firecast.ogg + 1 random impact; keep retail precast
    { spellID = 5143,   name = "Arcane Missiles",   sound = 569631 },  -- ArcaneMissileImpact1a.ogg
    { spellID = 30455,  name = "Ice Lance",         sound = 569765, muteExclusions = {1675108, 1675109, 1675110, 1394898, 1394899, 1394900, 1394901} },  -- frostcast.ogg on cast; retail impact plays natively
    { spellID = 120,    name = "Cone of Cold",      sound = {568982, random = {568542, 568843, 568493, 569304, 569145, 568128}} },  -- coneofcoldhand.ogg + 1 random frost impact
    { spellID = 31661,  name = "Dragon's Breath",   sound = 568894 },  -- mage_dragons_breath.ogg
    { spellID = 45438,  name = "Ice Block",         sound = 568316 },  -- icebarrirerstate.ogg
    { spellID = 11426,  name = "Ice Barrier",       sound = 569018 },  -- icebarrirerimpact.ogg
    { spellID = 1953,   name = "Blink",             sound = 569735 },  -- teleport.ogg
    { spellID = 212653, name = "Shimmer",           sound = 569735 },  -- teleport.ogg (Blink talent variant)
    { spellID = 44425,  name = "Arcane Barrage",    sound = 568149 },  -- arcanebarrage_impact1.ogg
    { spellID = 44457,  name = "Living Bomb",       sound = 569435 },  -- livingbomb_area.ogg
    -- Buffs / Cooldowns
    { spellID = 55342,  name = "Mirror Image",     sound = 569735 },  -- teleport.ogg
    { spellID = 12472,  name = "Icy Veins",        sound = 568767 },  -- iceveinsa.ogg
    { spellID = 190319, name = "Combustion",        sound = 569262 },  -- firewardtarget.ogg
    { spellID = 12042,  name = "Arcane Power",      sound = 569084 },  -- lightningshieldimpact.ogg
    { spellID = 235219, name = "Cold Snap",         sound = 568083 },  -- frostwardtarget.ogg
    { spellID = 30449,  name = "Spellsteal",        sound = 569658 },  -- unstableaffliction_impact_chest.ogg
    { spellID = 110959, name = "Greater Invisibility", sound = 569698 },  -- invisibility_impact_chest.ogg
    -- Frostfire hero talent variant
    { spellID = 431044, name = "Frostfire Bolt",    sound = 569765, muteExclusions = {4626795, 4626797, 4626799, 4626801, 4626803, 4626805, 4626807, 4626809, 4626927, 4626929, 4626931, 4626951, 4626953, 4626955, 4626963, 4626965, 4626967} },  -- frostcast.ogg; keep modern impact (+cast-start)
  },
  ROGUE = {
    { spellID = 53,     name = "Backstab",          sound = 569059 },  -- Strike.ogg
    { spellID = 196819, name = "Eviscerate",        sound = 567983 },  -- ExecuteTarget.ogg
    { spellID = 1752,   name = "Sinister Strike",   sound = 569227 },  -- sinisterstrikeimpact.ogg
    { spellID = 1776,   name = "Gouge",             sound = 568415 },  -- gougetarget.ogg
    { spellID = 408,    name = "Kidney Shot",       sound = 569110 },  -- kidneyshot.ogg
    { spellID = 1856,   name = "Vanish",            sound = 568798 },  -- vanish.ogg
    { spellID = 51723,  name = "Fan of Knives",     sound = 568260 },  -- bladesringimpact.ogg
    { spellID = 36563,  name = "Shadowstep",        sound = 568399 },  -- ShadowWordSilence.ogg
    { spellID = 1329,   name = "Mutilate",          sound = 568080 },  -- mutilate_impact_chest.ogg
    { spellID = 5938,   name = "Shiv",              sound = 569098 },  -- DecisiveStrike.ogg
    { spellID = 185313, name = "Shadow Dance",      sound = 568653 },  -- rogue_shadowdance_state.ogg
    { spellID = 8676,   name = "Ambush",            sound = 569059 },  -- Strike.ogg
    { spellID = 1943,   name = "Rupture",           sound = 568003 },  -- RendTarget.ogg
    { spellID = 703,    name = "Garrote",           sound = 568003 },  -- RendTarget.ogg
    { spellID = 1766,   name = "Kick",              sound = {567944, 569236} },  -- mWooshMediumCrit.ogg + challengingshout.ogg
    { spellID = 2094,   name = "Blind",             sound = 568719 },  -- BeastSoothe.ogg
    { spellID = 5277,   name = "Evasion",           sound = {569698, 569766} },  -- invisibility_impact_chest.ogg + shadowcast.ogg
    { spellID = 31224,  name = "Cloak of Shadows",  sound = 569040 },  -- shadowformimpact.ogg
    { spellID = 1833,   name = "Cheap Shot",        sound = 569110 },  -- kidneyshot.ogg
    { spellID = 32645,  name = "Envenom",           sound = 569420 },  -- disembowel_impact.ogg
    -- Buffs / Utility
    { spellID = 2983,   name = "Sprint",            sound = 568146 },  -- bullrush.ogg
    { spellID = 13750,  name = "Adrenaline Rush",   sound = 568146 },  -- bullrush.ogg
    { spellID = 13877,  name = "Blade Flurry",      sound = 569015 },  -- innerfirea.ogg
    { spellID = 5171,   name = "Slice and Dice",    sound = 568227 },  -- cleavetarget.ogg
    { spellID = 57934,  name = "Tricks of the Trade", sound = 568981 },  -- firestarter_impact01.ogg
  },
  PALADIN = {
    -- Projectile: classic cast sound + keep modern impact
    { spellID = 20271,  name = "Judgement",               sound = 569763, muteExclusions = {1250596, 1250597, 1250598, 1250599, 1250600, 1260561, 1260564, 1260565, 1706711, 1706712, 1706713} },  -- holycast.ogg
    { spellID = 275779, name = "Judgment",                sound = 569763, muteExclusions = {1250596, 1250597, 1250598, 1250599, 1250600, 1260561, 1260564, 1260565, 1706711, 1706712, 1706713} },  -- holycast.ogg
    { spellID = 31935,  name = "Avenger's Shield",        sound = 568371, muteExclusions = {1360126, 1360127, 1360128, 1360129, 1360130, 1362393, 1362394, 1362395, 1362396, 3745490, 3745492, 3745494, 3745496, 3745498, 3745500, 3745502, 3745504, 3745506, 3745508, 3745510, 3745512, 3745514, 3745516, 3745518, 3745520} },  -- PreCastHolyMagicMedium.ogg
    { spellID = 24275,  name = "Hammer of Wrath",         sound = 569763, muteExclusions = {1376084, 1376085, 1376086, 1376087, 1376088, 1377116, 1377117, 1377118, 1377119, 1377120, 1377121, 1377122, 4543538, 4543541, 4543546, 4543551, 4543555, 4543559, 4543563, 4543566, 4543570, 4543576} },  -- holycast.ogg
    -- Instant impact
    { spellID = 53385,  name = "Divine Storm",            sound = 569213 },  -- divinestormdamage1.ogg
    { spellID = 53595,  name = "Hammer of the Righteous", sound = 569272 },  -- hammeroftherighteousimpact.ogg
    { spellID = 31884,  name = "Avenging Wrath",          sound = 568175 },  -- avengingwrath_impact_base.ogg
    { spellID = 642,    name = "Divine Shield",           sound = 569738 },  -- divineshield.ogg
    { spellID = 82326,  name = "Holy Light",              sound = 569383 },  -- holylight_low_head.ogg
    { spellID = 633,    name = "Lay on Hands",            sound = 568145 },  -- layonhands_low_chest.ogg
    { spellID = 184575, name = "Blade of Justice",        sound = 569123 },  -- templarsverdict_impact_01.ogg
    { spellID = 53600,  name = "Shield of the Righteous", sound = 568492 },  -- shieldofrighteousness1.ogg
    { spellID = 35395,  name = "Crusader Strike",         sound = 569098 },  -- DecisiveStrike.ogg
    { spellID = 26573,  name = "Consecration",            sound = 569768 },  -- HolyImpactDDLow.ogg
    { spellID = 853,    name = "Hammer of Justice",       sound = {569763, 569344} },  -- HolyCast.ogg + fistofjustice.ogg
    { spellID = 10326,  name = "Turn Evil",               sound = {568915, 568253} },  -- PreCastHolyMagicLow.ogg + turnundeadtarget.ogg
    { spellID = 85222,  name = "Light of Dawn",           sound = 568915 },  -- PreCastHolyMagicLow.ogg
    { spellID = 498,    name = "Divine Protection",       sound = 569738 },  -- DivineShield.ogg
    { spellID = 96231,  name = "Rebuke",                  sound = 567944 },  -- mWooshMediumCrit.ogg
    -- Blessings / Defensives
    { spellID = 1022,   name = "Blessing of Protection",  sound = 568274 },  -- sealofmight.ogg
    { spellID = 1044,   name = "Blessing of Freedom",     sound = 568274 },  -- sealofmight.ogg
    { spellID = 62124,  name = "Hand of Reckoning",       sound = 568268 },  -- taunt.ogg
  },
  DRUID = {
    -- Projectile: classic cast sound + keep modern impact
    { spellID = 5176,   name = "Wrath",             sound = 569767, muteExclusions = {1597451, 1597452, 1597453, 1597783} },  -- naturecast.ogg (+cast-start)
    { spellID = 197626, name = "Starsurge",         sound = 569361, muteExclusions = {1597457, 1597458, 1597459, 1597782} },  -- druid_starfallmissile1.ogg (+cast-start)
    { spellID = 78674,  name = "Starsurge",         sound = 569361, muteExclusions = {1597457, 1597458, 1597459} },  -- druid_starfallmissile1.ogg (alt ID, no cast-start data)
    -- Instant impact
    { spellID = 8921,   name = "Moonfire",          sound = 569023 },  -- moonfireimpact.ogg
    { spellID = 155625, name = "Moonfire",          sound = 569023 },  -- moonfireimpact.ogg (Balance variant)
    { spellID = 194153, name = "Starfire",          sound = 568008 },  -- starfireimpact.ogg
    { spellID = 106785, name = "Swipe",             sound = 568398 },  -- swipe.ogg
    { spellID = 33917,  name = "Mangle",            sound = 568003 },  -- RendTarget.ogg
    { spellID = 339,    name = "Entangling Roots",  sound = 568636 },  -- entanglingroots.ogg
    { spellID = 774,    name = "Rejuvenation",      sound = 569594 },  -- rejuvenation.ogg
    { spellID = 33763,  name = "Lifebloom",         sound = 568755 },  -- lifebloom_impact.ogg
    { spellID = 740,    name = "Tranquility",       sound = 568379 },  -- tranquility.ogg
    { spellID = 6807,   name = "Maul",              sound = 568003 },  -- RendTarget.ogg
    { spellID = 191034, name = "Starfall",          sound = 568008 },  -- StarFireImpact.ogg
    { spellID = 33786,  name = "Cyclone",           sound = 569413 },  -- cycloneofelements.ogg
    { spellID = 22812,  name = "Barkskin",          sound = 569738 },  -- DivineShield.ogg
    { spellID = 8936,   name = "Regrowth",          sound = 568917 },  -- RestorationImpact.ogg
    { spellID = 77758,  name = "Thrash",            sound = 568398 },  -- swipe.ogg
    { spellID = 22568,  name = "Ferocious Bite",    sound = 567983 },  -- ExecuteTarget.ogg
    { spellID = 1079,   name = "Rip",               sound = 568003 },  -- RendTarget.ogg
    { spellID = 93402,  name = "Sunfire",           sound = 569770 },  -- HolyImpactDDUber.ogg
    -- Buffs / Utility
    { spellID = 29166,  name = "Innervate",         sound = 568917 },  -- restorationimpact.ogg
    { spellID = 48438,  name = "Wild Growth",       sound = 569008 },  -- druid_flourish.ogg
    { spellID = 20484,  name = "Rebirth",           sound = 568667 },  -- resurrection.ogg
    { spellID = 61336,  name = "Survival Instincts", sound = 569329 },  -- druid_survival_istincts.ogg
    { spellID = 22842,  name = "Frenzied Regeneration", sound = 568028 },  -- battleshouttarget.ogg
    { spellID = 192081,  name = "Ironfur",              sound = 568503 },  -- defensivestance_impact_chest.ogg
    { spellID = 1253799, name = "Sundering Roar",      sound = 544959 },  -- mBearAggroA.ogg
    { spellID = 5217,   name = "Tiger's Fury",      sound = 568524 },  -- cower.ogg
    { spellID = 1850,   name = "Dash",              sound = 568146 },  -- bullrush.ogg
    { spellID = 1126,   name = "Mark of the Wild",  sound = 568735 },  -- burningspirit.ogg
  },
  WARLOCK = {
    -- Projectile: classic cast sound + keep modern impact
    { spellID = 686,    name = "Shadow Bolt",       sound = 569766, muteExclusions = {1488056, 1488057, 1488058, 1488059, 1488060, 1488061, 1488062, 1488063, 1488065, 1488067, 2068270, 2068271, 2068272} },  -- shadowcast.ogg (+cast-start)
    { spellID = 6789,   name = "Death Coil",        sound = 569766, muteExclusions = {2068334, 2068335, 2068336} },  -- shadowcast.ogg (no cast-start data)
    { spellID = 29722,  name = "Incinerate",        sound = 569764, muteExclusions = {2066576, 2066581, 2066582, 2125625, 2125626, 2125627, 2125628, 2066602, 2066603} },  -- firecast.ogg (+cast-start)
    { spellID = 116858, name = "Chaos Bolt",        sound = 569764, muteExclusions = {2068263, 2068264, 2068265, 2068266, 1477361, 1477362, 1477363, 1477364, 2068270, 2068271, 2068272} },  -- firecast.ogg (+cast-start)
    { spellID = 48181,  name = "Haunt",             sound = 569766, muteExclusions = {568159, 568612, 569297, 3092207, 3092208} },  -- shadowcast.ogg (+cast-start)
    { spellID = 27243,  name = "Seed of Corruption", sound = 569079, muteExclusions = {1120207, 1120208, 1120209, 1120210, 1696325, 1696326, 1696327, 1696328, 1696329, 2068362, 2068363, 2068364, 2068337, 2068338, 2068339} },  -- curse.ogg (+cast-start)
    { spellID = 6353,   name = "Soul Fire",          sound = 569764, muteExclusions = {1306190, 1306191, 1306192, 1360221, 1360222, 1360223, 1360224, 1494223, 1494224, 1494225, 1494226, 1494227, 1494228, 1494229, 1494230, 1494231, 1494232, 1467561, 1467562, 1467563} },  -- firecast.ogg (+cast-start)
    -- Instant impact
    { spellID = 5782,   name = "Fear",              sound = 567950 },  -- Fear.ogg
    { spellID = 348,    name = "Immolate",          sound = 569153 },  -- Immolate.ogg
    { spellID = 5740,   name = "Rain of Fire",      sound = 569173 },  -- rainoffireimpact01.ogg
    { spellID = 710,    name = "Banish",            sound = 569407 },  -- ShadowWordFumble.ogg
    { spellID = 1714,   name = "Curse of Tongues",  sound = 567957 },  -- curseoftounges.ogg
    { spellID = 702,    name = "Curse of Weakness",  sound = 569079 },  -- curse.ogg
    { spellID = 172,    name = "Corruption",        sound = {568208, 568670} },  -- BestowDiseaseImpact.ogg + DeathCoilTarget.ogg
    { spellID = 1949,   name = "Hellfire",          sound = 569045 },  -- PreCastFireLow.ogg
    { spellID = 17962,  name = "Conflagrate",       sound = 569559 },  -- MoltenBlastImpact.ogg
    { spellID = 17877,  name = "Shadowburn",        sound = 569220 },  -- MindRotTarget.ogg
    { spellID = 980,    name = "Agony",              sound = 569079 },  -- curse.ogg
    { spellID = 30108,  name = "Unstable Affliction", sound = 569658 }, -- unstableaffliction_impact_chest.ogg
    { spellID = 30283,  name = "Shadowfury",         sound = 569474 },  -- shadowfury_impact_base.ogg
    -- Utility / Defensives
    { spellID = 5484,   name = "Howl of Terror",     sound = 567950 },  -- fear.ogg
    { spellID = 48020,  name = "Demonic Circle: Teleport", sound = 569150 },  -- demonicsummonteleport1.ogg
    { spellID = 108416, name = "Dark Pact",          sound = 568735 },  -- burningspirit.ogg
    { spellID = 1122,   name = "Summon Infernal",    sound = 569601 },  -- infernalimpactbase.ogg
    -- Hellcaller hero talent variant
    { spellID = 445468, name = "Wither",             sound = {568208, 568670} },  -- BestowDiseaseImpact.ogg + DeathCoilTarget.ogg (replaces Corruption/Immolate)
  },
  PRIEST = {
    { spellID = 2060,   name = "Heal",              sound = 568017 },  -- GreaterHeal_Low_Base.ogg
    { spellID = 139,    name = "Renew",             sound = 569376 },  -- Renew.ogg
    { spellID = 17,     name = "Power Word: Shield", sound = 569738 }, -- DivineShield.ogg
    { spellID = 589,    name = "Shadow Word: Pain", sound = 569138 },  -- ShadowWordPainTarget.ogg
    { spellID = 596,    name = "Prayer of Healing", sound = 569383 },  -- HolyLight_Low_Head.ogg
    { spellID = 33076,  name = "Prayer of Mending", sound = 569611 },  -- prayerofmending_impact.ogg
    { spellID = 528,    name = "Dispel Magic",      sound = 569632 },  -- NullifyPoison.ogg
    { spellID = 34861,  name = "Circle of Healing", sound = 569419 },  -- FlashHeal_Low_Base.ogg
    { spellID = 2061,   name = "Flash Heal",        sound = 569419 },  -- FlashHeal.ogg
    { spellID = 585,    name = "Smite",             sound = 569402 },  -- HolyBolt.ogg
    { spellID = 8092,   name = "Mind Blast",        sound = 569220 },  -- MindRotTarget.ogg
    { spellID = 15407,  name = "Mind Flay",         sound = 569766 },  -- ShadowCast.ogg
    { spellID = 14914,  name = "Holy Fire",         sound = 569770 },  -- HolyImpactDDUber.ogg
    { spellID = 8122,   name = "Psychic Scream",    sound = 567950 },  -- Fear.ogg
    { spellID = 586,    name = "Fade",              sound = 569423 },  -- Stealth.ogg
    { spellID = 32379,  name = "Shadow Word: Death", sound = 568353 }, -- ShadowWordPain_Chest.ogg
    { spellID = 34914,  name = "Vampiric Touch",    sound = 568719 },  -- BeastSoothe.ogg
    { spellID = 10060,  name = "Power Infusion",    sound = 569084 },  -- LightningShieldImpact.ogg
    { spellID = 47788,  name = "Guardian Spirit",   sound = 569218 },  -- priest_guardianspirit_state01.ogg
    { spellID = 88625,  name = "Holy Word: Chastise", sound = 569770 }, -- HolyImpactDDUber.ogg
    { spellID = 32375,  name = "Mass Dispel",       sound = 568392 },  -- dispel_low_base.ogg
    -- Buffs / Cooldowns
    { spellID = 19236,  name = "Desperate Prayer",  sound = 568145 },  -- layonhands_low_chest.ogg
    { spellID = 64843,  name = "Divine Hymn",       sound = 569359 },  -- priest_divinehymnstand.ogg
    { spellID = 15487,  name = "Silence",           sound = 567957 },  -- curseoftounges.ogg
    { spellID = 47585,  name = "Dispersion",        sound = 568999 },  -- priestdispersionstand.ogg
    { spellID = 15286,  name = "Vampiric Embrace",  sound = 568719 },  -- beastsoothe.ogg
  },
  SHAMAN = {
    -- Projectile: classic cast sound + keep modern impact
    { spellID = 188196, name = "Lightning Bolt",    sound = 569767, muteExclusions = {568188, 568516, 568529, 569513, 569544, 1100346, 1100347, 1100348, 4544016, 4544018, 4544020, 4544022, 4544024, 4544026, 4544028, 4544030, 4544032, 4544034, 4544040, 4544042, 4544044, 4544050, 4544052, 4544056, 4544058, 4544060, 4544062, 4544064, 4544066, 4544070, 4544072, 4544076, 4544080, 4544082, 4544086, 4544088, 4544092} },  -- naturecast.ogg (+cast-start)
    -- Instant impact (Lava Burst: no retail impact FIDs in mute data to preserve)
    { spellID = 188443, name = "Chain Lightning",   sound = 566684 },  -- BlastedLandsLightningBolt01Stand-Bolt3.ogg
    { spellID = 51505,  name = "Lava Burst",        sound = 569666 },  -- shaman_lavaburstimpact1.ogg
    { spellID = 77472,  name = "Healing Wave",      sound = 568917 },  -- RestorationImpact.ogg
    { spellID = 370,    name = "Purge",             sound = 568736 },  -- purge.ogg
    { spellID = 57994,  name = "Wind Shear",        sound = 569725 },  -- shaman_windshear_01.ogg
    { spellID = 8042,   name = "Earth Shock",       sound = 568516 },  -- LightningBoltImpact.ogg
    { spellID = 17364,  name = "Stormstrike",       sound = 568516 },  -- LightningBoltImpact.ogg
    { spellID = 1064,   name = "Chain Heal",        sound = 569570 },  -- Heal_Low_Base.ogg
    { spellID = 60103,  name = "Lava Lash",         sound = 568981 },  -- FirestarterImpact01.ogg
    { spellID = 51490,  name = "Thunderstorm",      sound = 568049 },  -- shaman_thunder.ogg
    { spellID = 61295,  name = "Riptide",           sound = 568741 },  -- ChainsOfIceImpact.ogg
    { spellID = 98008,  name = "Spirit Link Totem", sound = 568624 },  -- shaman_spiritlink01_1.ogg
    { spellID = 51514,  name = "Hex",               sound = 598523 },  -- hex_frog.ogg
    { spellID = 51533,  name = "Feral Spirit",      sound = 569157 },  -- shaman_feralspiritimpact.ogg
    { spellID = 73920,  name = "Healing Rain",      sound = 569084 },  -- LightningShieldImpact.ogg
    { spellID = 196840, name = "Frost Shock",       sound = 568128 },  -- BlizzardImpact1f.ogg
    { spellID = 188389, name = "Flame Shock",       sound = 568429 },  -- FireBallImpactB.ogg
    -- Buffs / Cooldowns
    { spellID = 32182,  name = "Heroism",           sound = 569013 },  -- heroism_cast.ogg
    { spellID = 2825,   name = "Bloodlust",         sound = 568812 },  -- bloodlust_player_cast_head.ogg
    { spellID = 114051, name = "Ascendance",        sound = 568735 },  -- burningspirit.ogg
  },
  HUNTER = {
    -- Hunter shots: arrows/bullets travel fast, no classic cast sounds exist, keep impact sounds
    { spellID = 5116,   name = "Concussive Shot",   sound = 569554 },  -- ArcaneMissileImpact1c.ogg
    { spellID = 34026,  name = "Kill Command",      sound = 568075 },  -- killcommand.ogg
    { spellID = 212431, name = "Explosive Shot",    sound = 569082 },  -- hunter_explosiveshotimpact1.ogg
    { spellID = 257044, name = "Rapid Fire",        sound = 568637 },  -- hunter_rapidfire.ogg
    { spellID = 34477,  name = "Misdirection",      sound = 569634 },  -- misdirection_impact_head.ogg
    { spellID = 186270, name = "Raptor Strike",     sound = 569098 },  -- DecisiveStrike.ogg
    { spellID = 19434,  name = "Aimed Shot",        sound = 569554 },  -- ArcaneMissileImpact1c.ogg
    { spellID = 2643,   name = "Multi-Shot",        sound = 569491 },  -- RecklessnessTarget.ogg
    { spellID = 185358, name = "Arcane Shot",       sound = 569631 },  -- ArcaneMissileImpact1a.ogg
    { spellID = 271788, name = "Serpent Sting",     sound = 568208 },  -- BestowDiseaseImpact.ogg
    { spellID = 781,    name = "Disengage",         sound = 567944 },  -- mWooshMediumCrit.ogg
    { spellID = 260243, name = "Volley",            sound = 569565 },  -- ArcaneMissileImpact1b.ogg
    { spellID = 56641,  name = "Steady Shot",       sound = 569098 },  -- DecisiveStrike.ogg
    { spellID = 53351,  name = "Kill Shot",         sound = 569098 },  -- DecisiveStrike.ogg
    { spellID = 3355,   name = "Freezing Trap",     sound = 568316 },  -- IceBarrirerState.ogg
    -- Buffs / Utility
    { spellID = 19574,  name = "Bestial Wrath",     sound = 569675 },  -- challengingroar.ogg
    { spellID = 1543,   name = "Flare",             sound = 569284 },  -- flare.ogg
    { spellID = 19801,  name = "Tranquilizing Shot", sound = 569491 },  -- recklessnesstarget.ogg
  },
  DEATHKNIGHT = {
    -- Frost
    { spellID = 49020,  name = "Obliterate",         sound = 568257 },  -- deathknight_obliterate1.ogg
    { spellID = 49143,  name = "Frost Strike",       sound = 568404 },  -- deathknight_froststrike1.ogg
    { spellID = 49184,  name = "Howling Blast",      sound = 568272 },  -- deathknight_howlingblastprimary.ogg
    { spellID = 51271,  name = "Pillar of Frost",    sound = 568905 },  -- spell_sh_unleashfrost_state_01.ogg
    { spellID = 196770, name = "Remorseless Winter", sound = 614997 },  -- spell_dk_remorselesswinter_cast.ogg
    -- Unholy
    { spellID = 55090,  name = "Scourge Strike",     sound = 568441 },  -- deathknight_plaguestrike1.ogg
    { spellID = 77575,  name = "Outbreak",           sound = 569184 },  -- spell_dk_outbreak_01.ogg
    -- Blood
    { spellID = 49998,  name = "Death Strike",       sound = 568267 },  -- deathknight_deathstrike1.ogg
    { spellID = 206930, name = "Heart Strike",       sound = 568459 },  -- deathknight_bloodstrike3.ogg
    { spellID = 50842,  name = "Blood Boil",         sound = 568473 },  -- deathknight_bloodboil.ogg
    { spellID = 49028,  name = "Dancing Rune Weapon", sound = 568356 }, -- deathknight_frozenruneweapon_impact.ogg
    -- Shared
    { spellID = 43265,  name = "Death and Decay",    sound = 568835 },  -- dk_deathndecayimpact.ogg
    { spellID = 45524,  name = "Chains of Ice",      sound = 568741 },  -- chainsoficeimpact.ogg
    { spellID = 47528,  name = "Mind Freeze",        sound = 568927 },  -- deathknight_mindfreeze.ogg
    { spellID = 48707,  name = "Anti-Magic Shell",   sound = 568163 },  -- deathknight_antimagicshell.ogg
    { spellID = 51052,  name = "Anti-Magic Zone",    sound = 568690 },  -- deathknight_antimagiczone.ogg
    { spellID = 48792,  name = "Icebound Fortitude",  sound = 569577 }, -- deathknight_iceboundfortitudestand.ogg
    { spellID = 47568,  name = "Empower Rune Weapon", sound = 569688 }, -- deathknight_empowerruneblade.ogg
    { spellID = 48743,  name = "Death Pact",         sound = 568079 },  -- deathknight_deathpactcaster.ogg
    { spellID = 221562, name = "Asphyxiate",         sound = 606165 },  -- spell_dk_asphyxiate_impact.ogg
    { spellID = 55233,  name = "Vampiric Blood",     sound = 569723 },  -- deathknightbloodtap.ogg
    { spellID = 49206,  name = "Summon Gargoyle",    sound = 568699 },  -- summonghouls1.ogg
    { spellID = 49576,  name = "Death Grip",         sound = 568670 },  -- deathcoiltarget.ogg
    { spellID = 195181, name = "Bone Shield",        sound = 569738 },  -- divineshield.ogg
    { spellID = 46584,  name = "Raise Dead",         sound = 569148 },  -- shadowprecasthigh.ogg
    { spellID = 42650,  name = "Army of the Dead",   sound = 569148 },  -- shadowprecasthigh.ogg
  },
  MONK = {
    -- Windwalker
    { spellID = 100780, name = "Tiger Palm",         sound = 618300 },  -- spell_mk_impact_med02.ogg
    { spellID = 100784, name = "Blackout Kick",      sound = 606779 },  -- spell_mk_blackoutkick_cast_01.ogg
    { spellID = 185099, name = "Rising Sun Kick",    sound = 638282 },  -- spell_thunderingfists_impact_01.ogg
    { spellID = 113656, name = "Fists of Fury",      sound = 613935 },  -- spell_mk_fistoffury_channel.ogg
    { spellID = 101546, name = "Spinning Crane Kick", sound = 623876 }, -- fx_mk_impact_med_01.ogg
    { spellID = 322109, name = "Touch of Death",     sound = 568670 },  -- DeathCoilTarget.ogg
    { spellID = 115098, name = "Chi Wave",           sound = 613904 },  -- spell_mk_revival.ogg
    { spellID = 123986, name = "Chi Burst",          sound = 626309 },  -- spell_mk_chiburst_cast01.ogg
    -- Brewmaster
    { spellID = 121253, name = "Keg Smash",          sound = 612300 },  -- spell_mk_kegsmash_01.ogg
    { spellID = 115181, name = "Breath of Fire",     sound = 613886 },  -- spell_mk_breathfire_03.ogg
    { spellID = 119582, name = "Purifying Brew",     sound = 612294 },  -- spell_mk_brew_drink01.ogg
    { spellID = 115203, name = "Fortifying Brew",    sound = 630452 },  -- spell_mk_fortifyingbrew_stone.ogg
    -- Mistweaver
    { spellID = 116670, name = "Vivify",             sound = 613902 },  -- spell_mk_resuscitate.ogg
    { spellID = 124682, name = "Enveloping Mist",    sound = 613902 },  -- spell_mk_resuscitate.ogg
    { spellID = 116849, name = "Life Cocoon",        sound = 616050 },  -- spell_mk_lifecocoon_state_loop.ogg
    { spellID = 322101, name = "Expel Harm",         sound = 612296 },  -- spell_mk_expelharm.ogg
    -- Shared
    { spellID = 117952, name = "Crackling Jade Lightning", sound = 606801 }, -- spell_mk_cracklinglightning_cast_01.ogg
    { spellID = 116847, name = "Rushing Jade Wind",  sound = 622508 },  -- spell_mk_jadewind_cast01.ogg
    { spellID = 119381, name = "Leg Sweep",          sound = 606891 },  -- spell_mk_legsweep.ogg
    { spellID = 115078, name = "Paralysis",          sound = 606893 },  -- spell_mk_paralysis.ogg
    { spellID = 116095, name = "Disable",            sound = 569396 },  -- MaimImpact.ogg
    { spellID = 122278, name = "Dampen Harm",        sound = 616279 },  -- spell_mk_dampenharm.ogg
  },
}
