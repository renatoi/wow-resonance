-- Class Templates: sensible defaults per class
-- Mutes modern spell sounds and replaces with classic-era sound FIDs
-- Original classes: 567000-569999 (vanilla/TBC/Wrath), DK: 568000-615000 (Wrath/Cata), Monk: 606000-631000 (MoP)
-- Only includes spells that have both mute data in SpellMuteData and a confirmed classic FID
-- Classic FIDs sourced from Wowhead Classic spell pages (sound kit references)
--
-- Format: { spellID, name (for readability), sound (classic FID) }
-- Class keys match select(2, UnitClass("player"))

Resonance_ClassTemplates = {
  WARRIOR = {
    { spellID = 163201, name = "Execute",           sound = 567983 },  -- Execute.ogg
    { spellID = 1680,   name = "Whirlwind",         sound = 568519 },  -- WhirlwindShort.ogg
    { spellID = 6343,   name = "Thunder Clap",      sound = 569222 },  -- ThunderClap.ogg
    { spellID = 772,    name = "Rend",              sound = 568003 },  -- RendTarget.ogg
    { spellID = 845,    name = "Cleave",            sound = 568227 },  -- CleaveTarget.ogg
    { spellID = 12294,  name = "Mortal Strike",     sound = 569098 },  -- DecisiveStrike.ogg
    { spellID = 23922,  name = "Shield Slam",       sound = 567879 },  -- m1hSwordHitMetalShieldCrit.ogg
    { spellID = 6572,   name = "Revenge",           sound = 569120 },  -- warrior_revenge1.ogg
    -- Heroic Leap removed: sound plays on cast, not on landing (WoW API limitation)
    { spellID = 34428,  name = "Victory Rush",      sound = 568430 },  -- victory_rush_impact.ogg
    { spellID = 6552,   name = "Pummel",            sound = 567944 },  -- mWooshMediumCrit.ogg
    { spellID = 5246,   name = "Intimidating Shout", sound = 567950 }, -- Fear.ogg
    { spellID = 1160,   name = "Demoralizing Shout", sound = 568028 }, -- BattleShoutTarget.ogg
    { spellID = 2565,   name = "Shield Block",      sound = 569473 },  -- ShieldWallTarget.ogg
    { spellID = 167105, name = "Colossus Smash",    sound = 568664 },  -- colossussmash_impact_01.ogg
    { spellID = 46924,  name = "Bladestorm",         sound = 568202 },  -- warrior_bladestorm.ogg
    { spellID = 20243,  name = "Devastate",          sound = 568983 },  -- warrior_devastate1.ogg
    { spellID = 46968,  name = "Shockwave",          sound = 569193 },  -- warrior_shockwave_area.ogg
    -- Mountain Thane hero talent procs (mute-only, no replacement sound)
    { spellID = 435222, name = "Thunder Blast",     sound = nil },     -- mute electric zap/sizzle sounds
    { spellID = 435791, name = "Lightning Strike",  sound = nil },     -- mute lightning bolt impact sounds
  },
  MAGE = {
    { spellID = 133,    name = "Fireball",          sound = 568461 },  -- FireBallImpactA.ogg
    { spellID = 190356, name = "Blizzard",          sound = 568542 },  -- BlizzardImpact1a.ogg
    { spellID = 122,    name = "Frost Nova",        sound = 569378 },  -- FrostNova.ogg
    { spellID = 118,    name = "Polymorph",         sound = 569526 },  -- Polymorph.ogg
    { spellID = 2120,   name = "Flamestrike",       sound = 568641 },  -- Flamestrike.ogg
    { spellID = 1449,   name = "Arcane Explosion",  sound = 568678 },  -- ArcaneExplosion.ogg
    { spellID = 2139,   name = "Counterspell",      sound = 568860 },  -- Counterspell.ogg
    { spellID = 2948,   name = "Scorch",            sound = 568023 },  -- Scorch.ogg
    { spellID = 5143,   name = "Arcane Missiles",   sound = 569631 },  -- ArcaneMissileImpact1a.ogg
    { spellID = 116,    name = "Frostbolt",         sound = 568571 },  -- curtainfrost_impact_01.ogg
    { spellID = 30455,  name = "Ice Lance",         sound = 569403 },  -- ice_lance_impact1.ogg
    { spellID = 120,    name = "Cone of Cold",      sound = 568982 },  -- coneofcoldhand.ogg
    { spellID = 11366,  name = "Pyroblast",         sound = 569449 },  -- fireballimpactc.ogg
    { spellID = 31661,  name = "Dragon's Breath",   sound = 568894 },  -- mage_dragons_breath.ogg
    { spellID = 45438,  name = "Ice Block",         sound = 568316 },  -- icebarrirerstate.ogg
    { spellID = 11426,  name = "Ice Barrier",       sound = 569018 },  -- icebarrirerimpact.ogg
    { spellID = 1953,   name = "Blink",             sound = 569735 },  -- teleport.ogg
    { spellID = 44425,  name = "Arcane Barrage",    sound = 568149 },  -- arcanebarrage_impact1.ogg
    { spellID = 44457,  name = "Living Bomb",       sound = 569435 },  -- livingbomb_area.ogg
  },
  ROGUE = {
    { spellID = 53,     name = "Backstab",          sound = 569555 },  -- backstab_impact_chest.ogg
    { spellID = 196819, name = "Eviscerate",        sound = 569637 },  -- evisceratetarget.ogg
    { spellID = 1752,   name = "Sinister Strike",   sound = 569227 },  -- sinisterstrikeimpact.ogg
    { spellID = 1776,   name = "Gouge",             sound = 568415 },  -- gougetarget.ogg
    { spellID = 408,    name = "Kidney Shot",       sound = 569110 },  -- kidneyshot.ogg
    { spellID = 1856,   name = "Vanish",            sound = 568798 },  -- vanish.ogg
    { spellID = 51723,  name = "Fan of Knives",     sound = 569425 },  -- fanofknivesloop.ogg
    { spellID = 36563,  name = "Shadowstep",        sound = 568893 },  -- shadowstepimpact.ogg
    { spellID = 1329,   name = "Mutilate",          sound = 568080 },  -- mutilate_impact_chest.ogg
    { spellID = 5938,   name = "Shiv",              sound = 569471 },  -- shadowstrike_impact_chest.ogg
    { spellID = 185313, name = "Shadow Dance",      sound = 568653 },  -- rogue_shadowdance_state.ogg
    { spellID = 8676,   name = "Ambush",            sound = 569059 },  -- Strike.ogg
    { spellID = 1943,   name = "Rupture",           sound = 568003 },  -- RendTarget.ogg
    { spellID = 703,    name = "Garrote",           sound = 568003 },  -- RendTarget.ogg
    { spellID = 1766,   name = "Kick",              sound = 567944 },  -- mWooshMediumCrit.ogg
    { spellID = 2094,   name = "Blind",             sound = 568719 },  -- BeastSoothe.ogg
    { spellID = 5277,   name = "Evasion",           sound = 569423 },  -- Stealth.ogg
    { spellID = 1833,   name = "Cheap Shot",        sound = 569110 },  -- kidneyshot.ogg
    { spellID = 32645,  name = "Envenom",           sound = 569420 },  -- disembowel_impact.ogg
  },
  PALADIN = {
    { spellID = 20271,  name = "Judgement",               sound = 568169 },  -- judgementofthepure.ogg
    { spellID = 53385,  name = "Divine Storm",            sound = 569213 },  -- divinestormdamage1.ogg
    { spellID = 53595,  name = "Hammer of the Righteous", sound = 569272 },  -- hammeroftherighteousimpact.ogg
    { spellID = 31884,  name = "Avenging Wrath",          sound = 568175 },  -- avengingwrath_impact_base.ogg
    { spellID = 642,    name = "Divine Shield",           sound = 569738 },  -- divineshield.ogg
    { spellID = 82326,  name = "Holy Light",              sound = 569383 },  -- holylight_low_head.ogg
    { spellID = 633,    name = "Lay on Hands",            sound = 568145 },  -- layonhands_low_chest.ogg
    { spellID = 184575, name = "Blade of Justice",        sound = 569123 },  -- templarsverdict_impact_01.ogg
    { spellID = 53600,  name = "Shield of the Righteous", sound = 568492 },  -- shieldofrighteousness1.ogg
    { spellID = 35395,  name = "Crusader Strike",         sound = 568504 },  -- sealofcrusader_impact.ogg
    { spellID = 275779, name = "Judgment",                sound = 568169 },  -- judgementofthepure.ogg
    { spellID = 26573,  name = "Consecration",            sound = 569768 },  -- HolyImpactDDLow.ogg
    { spellID = 853,    name = "Hammer of Justice",       sound = 569763 },  -- HolyCast.ogg
    { spellID = 10326,  name = "Turn Evil",               sound = 568915 },  -- PreCastHolyMagicLow.ogg
    { spellID = 85222,  name = "Light of Dawn",           sound = 568915 },  -- PreCastHolyMagicLow.ogg
    { spellID = 498,    name = "Divine Protection",       sound = 569738 },  -- DivineShield.ogg
    { spellID = 96231,  name = "Rebuke",                  sound = 567944 },  -- mWooshMediumCrit.ogg
    { spellID = 31935,  name = "Avenger's Shield",        sound = 568371 },  -- PreCastHolyMagicMedium.ogg
    { spellID = 24275,  name = "Hammer of Wrath",         sound = 567966 },  -- Holy_ImpactDD_Uber_Chest.ogg
  },
  DRUID = {
    { spellID = 8921,   name = "Moonfire",          sound = 569023 },  -- moonfireimpact.ogg
    { spellID = 194153, name = "Starfire",          sound = 568008 },  -- starfireimpact.ogg
    { spellID = 106785, name = "Swipe",             sound = 568398 },  -- swipe.ogg
    { spellID = 33917,  name = "Mangle",            sound = 569315 },  -- mangle_impact.ogg
    { spellID = 5176,   name = "Wrath",             sound = 568563 },  -- druid_wrath_impact01.ogg
    { spellID = 339,    name = "Entangling Roots",  sound = 568636 },  -- entanglingroots.ogg
    { spellID = 774,    name = "Rejuvenation",      sound = 569594 },  -- rejuvenation.ogg
    { spellID = 33763,  name = "Lifebloom",         sound = 568755 },  -- lifebloom_impact.ogg
    { spellID = 740,    name = "Tranquility",       sound = 568379 },  -- tranquility.ogg
    { spellID = 6807,   name = "Maul",              sound = 569437 },  -- spell_dr_maul_impact_01.ogg
    { spellID = 197626, name = "Starsurge",         sound = 568795 },  -- starsurge_missile_loop.ogg
    { spellID = 191034, name = "Starfall",          sound = 569361 },  -- druid_starfallmissile1.ogg
    { spellID = 33786,  name = "Cyclone",           sound = 569413 },  -- cycloneofelements.ogg
    { spellID = 78674,  name = "Starsurge",         sound = 568795 },  -- starsurge_missile_loop.ogg (alt ID)
    { spellID = 22812,  name = "Barkskin",          sound = 569738 },  -- DivineShield.ogg
    { spellID = 8936,   name = "Regrowth",          sound = 568917 },  -- RestorationImpact.ogg
    { spellID = 77758,  name = "Thrash",            sound = 568398 },  -- swipe.ogg
    { spellID = 22568,  name = "Ferocious Bite",    sound = 567983 },  -- ExecuteTarget.ogg
    { spellID = 1079,   name = "Rip",               sound = 568003 },  -- RendTarget.ogg
    { spellID = 93402,  name = "Sunfire",           sound = 569023 },  -- moonfireimpact.ogg
  },
  WARLOCK = {
    { spellID = 5782,   name = "Fear",              sound = 567950 },  -- Fear.ogg
    { spellID = 348,    name = "Immolate",          sound = 569153 },  -- Immolate.ogg
    { spellID = 6789,   name = "Death Coil",        sound = 568670 },  -- DeathCoilTarget.ogg
    { spellID = 29722,  name = "Incinerate",        sound = 569016 },  -- Incinerate.ogg
    { spellID = 116858, name = "Chaos Bolt",        sound = 568508 },  -- ChaosBolt.ogg
    { spellID = 5740,   name = "Rain of Fire",      sound = 569173 },  -- rainoffireimpact01.ogg
    { spellID = 710,    name = "Banish",            sound = 569503 },  -- banish_chest_purpleloop.ogg
    { spellID = 1714,   name = "Curse of Tongues",  sound = 567957 },  -- curseoftounges.ogg
    { spellID = 702,    name = "Curse of Weakness",  sound = 569079 },  -- curse.ogg
    { spellID = 48181,  name = "Haunt",             sound = 569297 },  -- hauntimpact1.ogg
    { spellID = 172,    name = "Corruption",        sound = 568208 },  -- BestowDiseaseImpact.ogg
    { spellID = 686,    name = "Shadow Bolt",       sound = 568670 },  -- DeathCoilTarget.ogg
    { spellID = 1949,   name = "Hellfire",          sound = 569045 },  -- PreCastFireLow.ogg
    { spellID = 17962,  name = "Conflagrate",       sound = 569559 },  -- MoltenBlastImpact.ogg
    { spellID = 17877,  name = "Shadowburn",        sound = 568670 },  -- DeathCoilTarget.ogg
    { spellID = 27243,  name = "Seed of Corruption", sound = 569079 },  -- curse.ogg
    { spellID = 980,    name = "Agony",              sound = 569079 },  -- curse.ogg
    { spellID = 30108,  name = "Unstable Affliction", sound = 569658 }, -- unstableaffliction_impact_chest.ogg
    { spellID = 30283,  name = "Shadowfury",         sound = 569474 },  -- shadowfury_impact_base.ogg
    { spellID = 6353,   name = "Soul Fire",          sound = 593908 },  -- spell_wl_soulfire_impact01.ogg
  },
  PRIEST = {
    { spellID = 2060,   name = "Heal",              sound = 569570 },  -- Heal_Low_Base.ogg
    { spellID = 139,    name = "Renew",             sound = 569376 },  -- Renew.ogg
    { spellID = 17,     name = "Power Word: Shield", sound = 569419 }, -- FlashHeal.ogg
    { spellID = 589,    name = "Shadow Word: Pain", sound = 568353 },  -- shadowwordpain_chest.ogg
    { spellID = 596,    name = "Prayer of Healing", sound = 569300 },  -- prayerofhealing.ogg
    { spellID = 33076,  name = "Prayer of Mending", sound = 569611 },  -- prayerofmending_impact.ogg
    { spellID = 528,    name = "Dispel Magic",      sound = 568392 },  -- dispel_low_base.ogg
    { spellID = 34861,  name = "Circle of Healing", sound = 569300 },  -- prayerofhealing.ogg
    { spellID = 2061,   name = "Flash Heal",        sound = 569419 },  -- FlashHeal.ogg
    { spellID = 585,    name = "Smite",             sound = 569402 },  -- HolyBolt.ogg
    { spellID = 8092,   name = "Mind Blast",        sound = 569220 },  -- MindRotTarget.ogg
    { spellID = 15407,  name = "Mind Flay",         sound = 569766 },  -- ShadowCast.ogg
    { spellID = 14914,  name = "Holy Fire",         sound = 569770 },  -- HolyImpactDDUber.ogg
    { spellID = 8122,   name = "Psychic Scream",    sound = 567950 },  -- Fear.ogg
    { spellID = 586,    name = "Fade",              sound = 569423 },  -- Stealth.ogg
    { spellID = 32379,  name = "Shadow Word: Death", sound = 569220 }, -- MindRotTarget.ogg
    { spellID = 34914,  name = "Vampiric Touch",    sound = 568353 },  -- shadowwordpain_chest.ogg
    { spellID = 10060,  name = "Power Infusion",    sound = 568534 },  -- priest_powerinfusion1.ogg
    { spellID = 47788,  name = "Guardian Spirit",   sound = 569218 },  -- priest_guardianspirit_state01.ogg
    { spellID = 88625,  name = "Holy Word: Chastise", sound = 569770 }, -- HolyImpactDDUber.ogg
    { spellID = 32375,  name = "Mass Dispel",       sound = 568392 },  -- dispel_low_base.ogg
  },
  SHAMAN = {
    { spellID = 188196, name = "Lightning Bolt",    sound = 568516 },  -- LightningBoltImpact.ogg
    { spellID = 188443, name = "Chain Lightning",   sound = 568102 },  -- ChainLightning.ogg
    { spellID = 51505,  name = "Lava Burst",        sound = 569666 },  -- shaman_lavaburstimpact1.ogg
    { spellID = 77472,  name = "Healing Wave",      sound = 568572 },  -- greaterhealingwave_impact.ogg
    { spellID = 370,    name = "Purge",             sound = 568736 },  -- purge.ogg
    { spellID = 57994,  name = "Wind Shear",        sound = 569725 },  -- shaman_windshear_01.ogg
    { spellID = 8042,   name = "Earth Shock",       sound = 568516 },  -- LightningBoltImpact.ogg
    { spellID = 17364,  name = "Stormstrike",       sound = 568516 },  -- LightningBoltImpact.ogg
    { spellID = 1064,   name = "Chain Heal",        sound = 569570 },  -- Heal_Low_Base.ogg
    { spellID = 60103,  name = "Lava Lash",         sound = 569559 },  -- MoltenBlastImpact.ogg
    { spellID = 51490,  name = "Thunderstorm",      sound = 568049 },  -- shaman_thunder.ogg
    { spellID = 61295,  name = "Riptide",           sound = 568126 },  -- riptide_impact.ogg
    { spellID = 98008,  name = "Spirit Link Totem", sound = 568624 },  -- shaman_spiritlink01_1.ogg
    { spellID = 51514,  name = "Hex",               sound = 598523 },  -- hex_frog.ogg
    { spellID = 51533,  name = "Feral Spirit",      sound = 569157 },  -- shaman_feralspiritimpact.ogg
    { spellID = 73920,  name = "Healing Rain",      sound = 568033 },  -- healingrain_persistant_loop_01.ogg
    { spellID = 196840, name = "Frost Shock",       sound = 568516 },  -- LightningBoltImpact.ogg
    { spellID = 188389, name = "Flame Shock",       sound = 569153 },  -- Immolate.ogg
  },
  HUNTER = {
    { spellID = 5116,   name = "Concussive Shot",   sound = 568411 },  -- ConcussiveShot.ogg
    { spellID = 34026,  name = "Kill Command",      sound = 568075 },  -- killcommand.ogg
    { spellID = 212431, name = "Explosive Shot",    sound = 569082 },  -- hunter_explosiveshotimpact1.ogg
    { spellID = 257044, name = "Rapid Fire",        sound = 568637 },  -- hunter_rapidfire.ogg
    { spellID = 34477,  name = "Misdirection",      sound = 569634 },  -- misdirection_impact_head.ogg
    { spellID = 186270, name = "Raptor Strike",     sound = 568288 },  -- savageblowtarget.ogg
    { spellID = 19434,  name = "Aimed Shot",        sound = 569554 },  -- ArcaneMissileImpact1c.ogg
    { spellID = 2643,   name = "Multi-Shot",        sound = 569491 },  -- RecklessnessTarget.ogg
    { spellID = 185358, name = "Arcane Shot",       sound = 569631 },  -- ArcaneMissileImpact1a.ogg
    { spellID = 271788, name = "Serpent Sting",     sound = 568208 },  -- BestowDiseaseImpact.ogg
    { spellID = 781,    name = "Disengage",         sound = 567944 },  -- mWooshMediumCrit.ogg
    { spellID = 260243, name = "Volley",            sound = 569565 },  -- ArcaneMissileImpact1b.ogg
    { spellID = 56641,  name = "Steady Shot",       sound = 568003 },  -- RendTarget.ogg
    { spellID = 53351,  name = "Kill Shot",         sound = 569098 },  -- DecisiveStrike.ogg
    { spellID = 3355,   name = "Freezing Trap",     sound = 568316 },  -- IceBarrirerState.ogg
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
    { spellID = 206930, name = "Heart Strike",       sound = 569261 },  -- deathknight_heartstrike1.ogg
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
  },
  MONK = {
    -- Windwalker
    { spellID = 100780, name = "Tiger Palm",         sound = 606899 },  -- spell_mk_tigerpalm_cast_01.ogg
    { spellID = 100784, name = "Blackout Kick",      sound = 606779 },  -- spell_mk_blackoutkick_cast_01.ogg
    { spellID = 185099, name = "Rising Sun Kick",    sound = 606987 },  -- spell_mk_risingsunkick.ogg
    { spellID = 113656, name = "Fists of Fury",      sound = 613935 },  -- spell_mk_fistoffury_channel.ogg
    { spellID = 101546, name = "Spinning Crane Kick", sound = 612320 }, -- spell_mk_spinningcranekick_state.ogg
    { spellID = 322109, name = "Touch of Death",     sound = 606907 },  -- spell_mk_touchofdeath.ogg
    { spellID = 115098, name = "Chi Wave",           sound = 613912 },  -- spell_mk_chiwave_dmgimpact_01.ogg
    { spellID = 123986, name = "Chi Burst",          sound = 626309 },  -- spell_mk_chiburst_cast01.ogg
    -- Brewmaster
    { spellID = 121253, name = "Keg Smash",          sound = 612300 },  -- spell_mk_kegsmash_01.ogg
    { spellID = 115181, name = "Breath of Fire",     sound = 613882 },  -- spell_mk_breathfire_01.ogg
    { spellID = 119582, name = "Purifying Brew",     sound = 612294 },  -- spell_mk_brew_drink01.ogg
    { spellID = 115203, name = "Fortifying Brew",    sound = 630452 },  -- spell_mk_fortifyingbrew_stone.ogg
    -- Mistweaver
    { spellID = 116670, name = "Vivify",             sound = 613937 },  -- spell_mk_jadeheal_impact.ogg
    { spellID = 124682, name = "Enveloping Mist",    sound = 628392 },  -- spell_mk_envelopingmists_heal.ogg
    { spellID = 116849, name = "Life Cocoon",        sound = 616050 },  -- spell_mk_lifecocoon_state_loop.ogg
    { spellID = 322101, name = "Expel Harm",         sound = 612296 },  -- spell_mk_expelharm.ogg
    -- Shared
    { spellID = 117952, name = "Crackling Jade Lightning", sound = 606801 }, -- spell_mk_cracklinglightning_cast_01.ogg
    { spellID = 116847, name = "Rushing Jade Wind",  sound = 622508 },  -- spell_mk_jadewind_cast01.ogg
    { spellID = 119381, name = "Leg Sweep",          sound = 606891 },  -- spell_mk_legsweep.ogg
    { spellID = 115078, name = "Paralysis",          sound = 606893 },  -- spell_mk_paralysis.ogg
    { spellID = 116095, name = "Disable",            sound = 606815 },  -- spell_mk_disable.ogg
    { spellID = 122278, name = "Dampen Harm",        sound = 616279 },  -- spell_mk_dampenharm.ogg
  },
}
