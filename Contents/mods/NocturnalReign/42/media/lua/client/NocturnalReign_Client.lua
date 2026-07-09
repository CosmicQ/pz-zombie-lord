--[[
    NocturnalReign_Client.lua

    Client-side flavour layer for Nocturnal Reign. Files under
    media/lua/client/ only ever run on the client (including the local
    client of a single-player game), so this file never touches the
    authoritative simulation - it only *reads* state the server already
    wrote (via ModData, which the engine syncs on IsoGameCharacter/IsoObject
    automatically) and turns it into on-screen feedback.

    Nothing here mutates gameplay state: worst case if this file's checks
    are ever wrong, the player sees a missing/incorrect warning banner, not
    a broken simulation.
]]

require "NocturnalReign_SandboxOptions"

NocturnalReign = NocturnalReign or {}
NocturnalReign.Client = NocturnalReign.Client or {}
local Client = NocturnalReign.Client
local Options = NocturnalReign.Options
local Keys = NocturnalReign.ModDataKeys

local lastPeriod = nil
local scanCounter = 0
local lordWarningCooldownTicks = 0

-- Purely a UI polling cadence, not a gameplay one: ~30 OnPlayerUpdate calls
-- is roughly 1 second at 30fps - tight enough that the Lord's follow-light
-- (below) keeps pace with its slow walk. Cheap enough to run unconditionally
-- since it only ever looks at the local player and their already-loaded cell.
local SCAN_EVERY_TICKS = 30
local LORD_WARNING_COOLDOWN_SCANS = 30 -- ~30s between repeat warnings

local function announce(player, text)
    -- HaloTextHelper floats a short-lived label over the character - a
    -- lightweight way to surface a transition notice without building a
    -- dedicated UI panel for what is a purely cosmetic cue. Signature
    -- verified against the decompiled 42.19 HaloTextHelper class: every
    -- colored overload is (player, text, separator, color) - there is NO
    -- (player, text, color) form, and passing one throws "No implementation
    -- found". "[br/]" is the separator active vanilla callers use.
    if HaloTextHelper and HaloTextHelper.addText then
        pcall(function() HaloTextHelper.addText(player, text, "[br/]", HaloTextHelper.getColorRed()) end)
    else
        print("[NocturnalReign] " .. text)
    end
end

local function checkDayNightTransition(player)
    local hour = getGameTime():getHour()
    local daytime = Options.isDaytimeHour(hour)
    local period = daytime and "day" or "night"
    if period == lastPeriod then return end
    lastPeriod = period

    if daytime then
        if Options.isPhotophobiaEnabled() then
            announce(player, "The sun rises - exposed zombies will burn in the open.")
        end
    else
        if Options.isNightMutationEnabled() then
            announce(player, "Night falls - the horde grows fast and sharp-eyed.")
        end
    end
end

----------------------------------------------------------------------------
-- Lord glow: the unmistakable "that is NOT a normal zombie" cue.
--
-- Two layers, both purely cosmetic and client-side (the server never sees
-- either):
--
--   1. A blood-red engine highlight tint over the Lord's whole sprite -
--      setHighlighted/setHighlightColor, the same IsoObject mechanism the
--      debug tools use to mark objects. Reapplied every scan so it survives
--      any engine-side highlight reset.
--
--   2. An IsoLightSource pinned to the Lord's tile - an eerie red glow cast
--      on the ground around it, readable from well outside melee range and
--      striking at night. Light sources are static engine objects with no
--      move API, so the scan removes and recreates the lamp whenever the
--      Lord crosses onto a new tile (the standard follow-light pattern).
----------------------------------------------------------------------------

local LORD_GLOW_R, LORD_GLOW_G, LORD_GLOW_B = 0.9, 0.08, 0.08
local LORD_GLOW_RADIUS = 6 -- tiles of red light around the Lord

-- [zombie] = { light = IsoLightSource, x, y, z } for every currently-glowing
-- Lord. Strong keys on purpose: entries are removed explicitly by the scan's
-- cleanup pass, which must run removeLamppost before the reference drops -
-- a weak table would let the zombie (and our handle to its lamp) vanish
-- first, stranding an orphaned red light in the world.
local lordLights = {}

local function removeLordLight(zombie)
    local entry = lordLights[zombie]
    if not entry then return end
    lordLights[zombie] = nil
    pcall(function() getCell():removeLamppost(entry.light) end)
end

--- Both cosmetic setters probed in two signature forms, same philosophy as
--- the server's trySetters: B42 unstable has shuffled overloads before, and
--- a silently-skipped tint beats a hard error in a render-path callback.
local function applyLordHighlight(zombie)
    if not pcall(function() zombie:setHighlightColor(1.0, 0.15, 0.15, 0.7) end) then
        pcall(function() zombie:setHighlightColor(ColorInfo.new(1.0, 0.15, 0.15, 0.7)) end)
    end
    if not pcall(function() zombie:setHighlighted(true) end) then
        pcall(function() zombie:setHighlighted(true, false) end)
    end
end

local function updateLordLight(zombie)
    local x = math.floor(zombie:getX())
    local y = math.floor(zombie:getY())
    local z = math.floor(zombie:getZ())

    local entry = lordLights[zombie]
    if entry and entry.x == x and entry.y == y and entry.z == z then return end
    removeLordLight(zombie)

    pcall(function()
        local light = IsoLightSource.new(x, y, z, LORD_GLOW_R, LORD_GLOW_G, LORD_GLOW_B, LORD_GLOW_RADIUS)
        getCell():addLamppost(light)
        lordLights[zombie] = { light = light, x = x, y = y, z = z }
    end)
end

--- One pass over the loaded cell's zombies: apply the glow to every Lord,
--- warn (with cooldown) when one is close, and clean up lights whose Lord
--- died, despawned, or walked out of the loaded area since the last scan.
local function scanForLords(player)
    if lordWarningCooldownTicks > 0 then
        lordWarningCooldownTicks = lordWarningCooldownTicks - 1
    end

    local lordsEnabled = Options.isZombieLordEnabled()
    local glowEnabled = lordsEnabled and Options.isLordGlowEnabled()

    local seen = {}
    local cell = player:getCell()
    local list = cell and cell:getZombieList()
    if list and lordsEnabled then
        local px, py = player:getX(), player:getY()
        local warnRadiusSq = 30 * 30

        for i = 0, list:size() - 1 do
            local zombie = list:get(i)
            if zombie and not zombie:isDead() and zombie:getModData()[Keys.IS_LORD] then
                if glowEnabled then
                    seen[zombie] = true
                    applyLordHighlight(zombie)
                    updateLordLight(zombie)
                end
                if lordWarningCooldownTicks <= 0 then
                    local dx, dy = zombie:getX() - px, zombie:getY() - py
                    if (dx * dx + dy * dy) <= warnRadiusSq then
                        announce(player, "Something huge is commanding the dead nearby...")
                        lordWarningCooldownTicks = LORD_WARNING_COOLDOWN_SCANS
                    end
                end
            end
        end
    end

    -- Cleanup: any tracked light whose Lord we did not just see (dead,
    -- despawned, out of the loaded area, or glow toggled off mid-game).
    -- Clearing a key mid-pairs is legal Lua; only *adding* keys is not.
    for zombie in pairs(lordLights) do
        if not seen[zombie] then
            pcall(function() zombie:setHighlighted(false) end)
            removeLordLight(zombie)
        end
    end
end

local function onPlayerUpdate(player)
    if player ~= getPlayer() then return end -- ignore any non-local-player callback quirks

    scanCounter = scanCounter + 1
    if scanCounter < SCAN_EVERY_TICKS then return end
    scanCounter = 0

    checkDayNightTransition(player)
    scanForLords(player)
end

Events.OnPlayerUpdate.Add(onPlayerUpdate)
