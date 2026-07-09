--[[
    NocturnalReign_SandboxOptions.lua  (shared)

    Central configuration layer for Nocturnal Reign. This file is loaded on
    both server and client (media/lua/shared/) because both sides need to
    agree on day/night boundaries and radii for their respective jobs: the
    server drives the actual simulation, the client only needs the same
    numbers to render matching UI cues.

    The real values come from SandboxVars.NocturnalReign, which the game
    populates automatically from media/sandbox-options.txt. We never write
    to SandboxVars ourselves; this module only *reads* it and falls back to
    sane defaults if a value hasn't been populated yet (e.g. this mod was
    added to an in-progress save and the sandbox schema hasn't been merged
    in until the next full reload).
]]

NocturnalReign = NocturnalReign or {}

local DEFAULTS = {
    EnablePhotophobia            = true,
    EnableSunburnDamage           = false,
    EnableNightMutation            = true,
    EnableZombieLord               = true,
    EnableLordFog                   = true,
    EnableLordLoot                   = true,
    LordHealthMultiplier              = 10,
    DayStartHour                  = 5,
    NightStartHour                 = 20,
    BurnTickSeconds                = 10,
    BurnDamagePercentPerTick        = 2,
    ZombieLordSpawnChancePercent    = 0.5,
    SprinterSpeedMultiplier         = 2.0,
    LordCommandRadius               = 25,
    LordAlertRadius                  = 40,
    LordSeekRadius                  = 400,
    EnableLordGlow                  = true,
    EnableLordDoorUse               = true,
    EnableHordeSummon                 = true,
    HordeSummonCooldownDays            = 1,
    HordeSummonMaxZombies               = 20,
    HordeSummonHealthPercent             = 50,
    HordeSummonRadius                     = 25,
}

--- Reads a single option live from SandboxVars every call (rather than
--- caching it) so that debug-menu edits to sandbox vars during testing are
--- picked up immediately without needing a save reload.
local function readOption(name)
    local sv = SandboxVars and SandboxVars.NocturnalReign
    if sv and sv[name] ~= nil then
        return sv[name]
    end
    return DEFAULTS[name]
end

NocturnalReign.Options = NocturnalReign.Options or {}
local Options = NocturnalReign.Options

function Options.isPhotophobiaEnabled()   return readOption("EnablePhotophobia") end
function Options.isSunburnDamageEnabled() return readOption("EnableSunburnDamage") end
function Options.isNightMutationEnabled() return readOption("EnableNightMutation") end
function Options.isZombieLordEnabled()    return readOption("EnableZombieLord") end
function Options.isLordFogEnabled()       return readOption("EnableLordFog") end
function Options.isLordLootEnabled()      return readOption("EnableLordLoot") end
function Options.getLordHealthMultiplier() return readOption("LordHealthMultiplier") end

function Options.getDayStartHour()   return readOption("DayStartHour") end
function Options.getNightStartHour() return readOption("NightStartHour") end

function Options.getBurnTickSeconds()          return readOption("BurnTickSeconds") end
function Options.getBurnDamagePercentPerTick()  return readOption("BurnDamagePercentPerTick") end

function Options.getZombieLordSpawnChancePercent() return readOption("ZombieLordSpawnChancePercent") end
function Options.getSprinterSpeedMultiplier()      return readOption("SprinterSpeedMultiplier") end
function Options.getLordCommandRadius()             return readOption("LordCommandRadius") end
function Options.getLordAlertRadius()                return readOption("LordAlertRadius") end
function Options.getLordSeekRadius()                 return readOption("LordSeekRadius") end
function Options.isLordGlowEnabled()                 return readOption("EnableLordGlow") end
function Options.isLordDoorUseEnabled()              return readOption("EnableLordDoorUse") end

function Options.isHordeSummonEnabled()             return readOption("EnableHordeSummon") end
function Options.getHordeSummonCooldownDays()        return readOption("HordeSummonCooldownDays") end
function Options.getHordeSummonMaxZombies()          return readOption("HordeSummonMaxZombies") end
function Options.getHordeSummonHealthPercent()       return readOption("HordeSummonHealthPercent") end
function Options.getHordeSummonRadius()              return readOption("HordeSummonRadius") end

--- Shared day/night test so server (simulation) and client (UI) always
--- agree on which side of the boundary a given hour falls on, including the
--- edge case where a user configures NightStartHour < DayStartHour is NOT
--- true (normal case) vs. a wrap-around misconfiguration.
--- @param hour number  0-23, typically from getGameTime():getHour()
--- @return boolean true if `hour` falls inside the daytime (photophobia) window
function Options.isDaytimeHour(hour)
    local dayStart, nightStart = Options.getDayStartHour(), Options.getNightStartHour()
    if dayStart < nightStart then
        return hour >= dayStart and hour < nightStart
    end
    -- Defensive fallback if a user sets DayStartHour >= NightStartHour
    -- (e.g. both left at odd custom values): treat it as a wrap-around
    -- window instead of producing a permanently-day or permanently-night
    -- result.
    return hour >= dayStart or hour < nightStart
end

-- ModData keys shared by the server (writer) and client (reader). Centralised
-- here so a typo can't cause the two sides to silently disagree on a key name.
NocturnalReign.ModDataKeys = {
    INITIALIZED   = "NR_Initialized",
    IS_LORD        = "NR_IsZombieLord",
    IS_SUNSICK      = "NR_IsSunsick",
    IS_SPRINTER      = "NR_IsNightSprinter",
    LAST_BURN_TICK    = "NR_LastBurnTick",
    COMMANDED_BY_LORD  = "NR_CommandedByLord",
    LAST_SUMMON_DAY     = "NR_LastSummonDay",
}
