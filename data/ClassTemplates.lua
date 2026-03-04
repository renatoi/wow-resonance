-- Class Templates: sensible defaults per class
-- Mutes modern spell sounds and replaces with classic-era sound FIDs (567000-569999 range)
-- Only includes spells that have both mute data in SpellMuteData and a confirmed classic FID
-- Classic FIDs sourced from Wowhead Classic spell pages (sound kit references)
--
-- Format: { spellID, name (for readability), sound (classic FID) }
-- Class keys match select(2, UnitClass("player"))

Resonance_ClassTemplates = {
  WARRIOR = {
    { spellID = 163201, name = "Execute",           sound = 567983 },  -- Execute.ogg
    { spellID = 1680,   name = "Whirlwind",         sound = 568214 },  -- Whirlwind.ogg
    { spellID = 6343,   name = "Thunder Clap",      sound = 569222 },  -- ThunderClap.ogg
    { spellID = 772,    name = "Rend",              sound = 568003 },  -- RendTarget.ogg
    { spellID = 845,    name = "Cleave",            sound = 568646 },  -- HeroicStrikeImpacts.ogg
    { spellID = 12294,  name = "Mortal Strike",     sound = 568664 },  -- ColossusSmash.ogg
    { spellID = 6572,   name = "Revenge",           sound = 569571 },  -- Devastate.ogg
    -- Heroic Leap removed: sound plays on cast, not on landing (WoW API limitation)
    { spellID = 34428,  name = "Victory Rush",      sound = 568555 },  -- DecisiveStrike.ogg
    { spellID = 6552,   name = "Pummel",            sound = 567944 },  -- mWooshMediumCrit.ogg
    { spellID = 5246,   name = "Intimidating Shout", sound = 569675 }, -- ChallengingRoar.ogg
    { spellID = 1160,   name = "Demoralizing Shout", sound = 568028 }, -- BattleShoutTarget.ogg
    { spellID = 2565,   name = "Shield Block",      sound = 569473 },  -- ShieldWallTarget.ogg
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
  },
}
