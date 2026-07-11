--[[
    NocturnalReign_Client.lua

    Client-side layer for Nocturnal Reign. Files under media/lua/client/
    only ever run on the client (including the local client of a
    single-player game).

    TWO JOBS, TWO MULTIPLAYER REALITIES:

    1. Flavour (glow, banners, warnings). Object ModData is NOT synchronized
       between server and clients (PZwiki "Mod data"; MP QA confirmed - the
       glow diagnostics never printed on a remote client because its copy of
       the Lord carries no NR_IsZombieLord flag). Boss identity therefore
       arrives from the server's once-per-second "state" broadcast, matched
       to local zombies by onlineID; the direct ModData read remains as the
       single-player / co-op-host path, where server and client share one
       Lua state.

    2. Gait (the one genuinely gameplay-touching pass in this file). PZ
       multiplayer gives authority over each zombie's simulation to the
       CLIENT nearest to it ("Zed Clients" / "OwnerZhip" dev blogs), so the
       server's photophobia/night-mutation stat changes never reach the
       zombies remote players are actually fighting. The pass at the bottom
       of this file runs the same deterministic rules (shared module
       NocturnalReign_Mutation.lua, keyed to the world clock and climate
       every machine already agrees on) over this client's loaded zombies.
       It runs ONLY on multiplayer clients - in single-player and on the
       hosting process the server module's sweep already does this work.
]]

require "NocturnalReign_SandboxOptions"
require "NocturnalReign_Zones"
require "NocturnalReign_Mutation"

NocturnalReign = NocturnalReign or {}
NocturnalReign.Client = NocturnalReign.Client or {}
local Client = NocturnalReign.Client
local Options = NocturnalReign.Options
local Keys = NocturnalReign.ModDataKeys
local Zones = NocturnalReign.Zones
local Mutation = NocturnalReign.Mutation

-- Mirror of the server's once-per-second "state" broadcast (multiplayer
-- only; stays empty in single-player, where the ModData fast paths below
-- serve instead). See onServerCommand for the payload shape.
local remoteBosses = {}  -- [onlineID] = { id, mini = type|nil, fake = bool }
local remoteCalm = {}    -- [zoneName] = true
local remoteFog = nil    -- nil until the first state packet arrives

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

-- Lords burn blood-red; their chosen (mini-bosses) smoulder ember-amber -
-- unmistakably "boss", unmistakably not the throne. r/g/b tint the ground
-- light, hr/hg/hb the sprite highlight.
local LORD_GLOW = { r = 0.9, g = 0.08, b = 0.08, hr = 1.0, hg = 0.1, hb = 0.1 }
local MINI_GLOW = { r = 0.9, g = 0.45, b = 0.05, hr = 1.0, hg = 0.55, hb = 0.1 }
local LORD_GLOW_RADIUS = 8 -- tiles of light around a boss (subtle by day, striking at night)

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
--- Returns whether any form took, for the one-time diagnostic below -
--- Kahlua swallows pure-Lua errors inside pcall without logging, so a
--- broken cosmetic looks like "the Lord looks normal" with a clean console
--- unless we print a receipt ourselves.
local function applyLordHighlight(zombie, glow)
    glow = glow or LORD_GLOW
    local colorOk = pcall(function() zombie:setHighlightColor(glow.hr, glow.hg, glow.hb, 1.0) end)
    if not colorOk then
        colorOk = pcall(function() zombie:setHighlightColor(ColorInfo.new(glow.hr, glow.hg, glow.hb, 1.0)) end)
    end
    local flagOk = pcall(function() zombie:setHighlighted(true) end)
    if not flagOk then
        flagOk = pcall(function() zombie:setHighlighted(true, false) end)
    end
    return colorOk and flagOk
end

local function updateLordLight(zombie, glow)
    glow = glow or LORD_GLOW
    local x = math.floor(zombie:getX())
    local y = math.floor(zombie:getY())
    local z = math.floor(zombie:getZ())

    local entry = lordLights[zombie]
    if entry and entry.x == x and entry.y == y and entry.z == z then return true end
    removeLordLight(zombie)

    return pcall(function()
        local light = IsoLightSource.new(x, y, z, glow.r, glow.g, glow.b, LORD_GLOW_RADIUS)
        getCell():addLamppost(light)
        lordLights[zombie] = { light = light, x = x, y = y, z = z }
    end)
end

-- Printed once per session, the first time the glow is applied to a Lord.
local glowDiagnosed = false

local function diagnoseGlow(zombie)
    if glowDiagnosed then return end
    glowDiagnosed = true
    print(string.format(
        "[NocturnalReign] glow diagnostics: highlight=%s, light=%s, IsoLightSource=%s, ColorInfo=%s",
        tostring(applyLordHighlight(zombie)),
        tostring(updateLordLight(zombie)),
        tostring(IsoLightSource ~= nil),
        tostring(ColorInfo ~= nil)
    ))
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
            if zombie and not zombie:isDead() then
                -- ModData is the single-player/co-op-host fast path; it is
                -- never synced over the network (see file header), so on a
                -- remote client boss identity comes from the server's state
                -- broadcast instead, matched by onlineID.
                local md = zombie:getModData()
                local isLord = md[Keys.IS_LORD] == true
                local isMini = md[Keys.MINI_TYPE] ~= nil
                if not isLord and not isMini then
                    local id = nil
                    pcall(function() id = zombie:getOnlineID() end)
                    local entry = id and remoteBosses[id]
                    -- entry.fake: the server says this chosen is playing
                    -- dead - leave it unmarked even if the local
                    -- isFakeDead() below can't tell.
                    if entry and not entry.fake then
                        isMini = entry.mini ~= nil
                        isLord = not isMini
                    end
                end
                -- A chosen playing dead must LOOK dead: no glow, no
                -- highlight, until the ambush springs. The cleanup pass
                -- below removes its light because it isn't in `seen`.
                if isMini then
                    pcall(function() if zombie:isFakeDead() then isMini = false end end)
                end
                if isLord or isMini then
                    if glowEnabled then
                        seen[zombie] = true
                        diagnoseGlow(zombie)
                        local glow = isLord and LORD_GLOW or MINI_GLOW
                        applyLordHighlight(zombie, glow)
                        updateLordLight(zombie, glow)
                    end
                    -- The proximity dread is reserved for the throne; the
                    -- chosen announce themselves by silhouette and glow.
                    if isLord and lordWarningCooldownTicks <= 0 then
                        local dx, dy = zombie:getX() - px, zombie:getY() - py
                        if (dx * dx + dy * dy) <= warnRadiusSq then
                            announce(player, "Something huge is commanding the dead nearby...")
                            lordWarningCooldownTicks = LORD_WARNING_COOLDOWN_SCANS
                        end
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

----------------------------------------------------------------------------
-- Server state mirror, multiplayer leg.
--
-- The server pushes one small "state" command every lord-tick (~1s); see
-- MODULE 3e in NocturnalReign_Server.lua for the payload and the reasoning
-- (object ModData never syncs, and one-shot toggles miss mid-fight
-- joiners). This handler is the receiving end for all of it:
--
--   fog    - applied to the local ClimateManager, because on a dedicated
--            server the server's own override only affects the server's
--            simulation. Single-player never fires OnServerCommand, and
--            there the server module's local set already lands on the one
--            shared ClimateManager, so this stays MP-only by construction.
--   bosses - stored in remoteBosses for scanForLords (glow, warnings).
--   calm   - stored in remoteCalm for the client gait pass below.
--
-- The two fog constants mirror MODULE 3c in NocturnalReign_Server.lua -
-- keep them in sync by hand (the server file's locals are not visible
-- here without promoting them to the shared options module).
----------------------------------------------------------------------------

local FOG_CLIMATE_ID = 5   -- ClimateManager float id: fog intensity
local FOG_INTENSITY = 0.85 -- 0..1; heavy but not a total whiteout

local function applyFogOverride(on)
    return pcall(function()
        local fogFloat = getClimateManager():getClimateFloat(FOG_CLIMATE_ID)
        if on then
            fogFloat:setEnableOverride(true)
            fogFloat:setOverride(FOG_INTENSITY, 1)
        else
            fogFloat:setEnableOverride(false)
        end
    end)
end

--- The summoning shriek, remote-client leg (see bossShriek in
--- NocturnalReign_Server.lua): rendered locally at the boss's coordinates.
--- MetaScream carries for hundreds of tiles by design - hearing it from
--- across town and knowing what it means is the feature. The two
--- PlayWorldSound attempts cover the overload variants B42 has shipped
--- ((name, square, dropoff, distance, pitch, bool) and the same with a
--- trailing repeat-radius float); the guard against non-clients keeps an
--- in-process co-op host from double-playing over its own local playback.
local function playShriek(args)
    if not isClient() then return end
    if not args or not args.x then return end
    pcall(function()
        local square = getCell():getGridSquare(args.x, args.y, args.z)
        if not square then return end -- too far away to be loaded = out of earshot
        local sm = getSoundManager()
        if not pcall(function() sm:PlayWorldSound("MetaScream", square, 0, 200, 1.0, false) end) then
            pcall(function() sm:PlayWorldSound("MetaScream", square, 0, 200, 1.0, 0, false) end)
        end
    end)
end

local function onServerCommand(module, command, args)
    if module ~= "NocturnalReign" then return end
    if command == "shriek" then return playShriek(args) end
    if command == "resetDone" then
        local player = getPlayer()
        if player then
            announce(player, (args and args.zone)
                and (args.zone .. " returns to its Lord's reign.")
                or "Every town returns to its Lord's reign.")
        end
        return
    end
    if command ~= "state" then return end
    args = args or {}

    -- Rebuild rather than merge: the packet is the complete roster, so a
    -- boss the server stopped mentioning (died, despawned) drops out here
    -- automatically.
    remoteBosses = {}
    if type(args.bosses) == "table" then
        for _, entry in pairs(args.bosses) do
            if type(entry) == "table" and entry.id then
                remoteBosses[entry.id] = entry
            end
        end
    end

    remoteCalm = {}
    if type(args.calm) == "table" then
        for _, zoneName in pairs(args.calm) do
            remoteCalm[zoneName] = true
        end
    end

    local fogOn = args.fog == true
    if fogOn then
        -- Re-assert the override on EVERY packet while the fog holds, not
        -- just on the transition: the engine's own MP climate sync stomps
        -- client-side overrides between our packets (playtested - the
        -- server's fog held while the client's visual faded within
        -- seconds). Worst case the fog flickers for the sub-second gap
        -- between a climate sync and our next state packet.
        local ok = applyFogOverride(true)
        if remoteFog ~= true then
            remoteFog = true
            -- Receipt on purpose: Kahlua swallows pure-Lua pcall failures
            -- silently, and "the fog didn't show" is otherwise
            -- indistinguishable from "the command never arrived".
            print(string.format("[NocturnalReign] fog rolls in (server state, applied=%s)", tostring(ok)))
        end
    elseif remoteFog == nil then
        remoteFog = false -- first packet of the session, nothing to undo
    elseif remoteFog then
        remoteFog = false
        local ok = applyFogOverride(false)
        print(string.format("[NocturnalReign] fog lifts (server state, applied=%s)", tostring(ok)))
    end
end

Events.OnServerCommand.Add(onServerCommand)

----------------------------------------------------------------------------
-- Admin campaign reset (world right-click menu).
--
-- Puts a liberated town - or the whole map - back under its Lord's reign.
-- Shown only to admins/moderators in multiplayer (the server re-validates
-- the sender's access level; this gate is just UI hygiene) and always in
-- single-player, where it's your own world. In MP the request travels as
-- a client command; in SP the server module shares this Lua state and is
-- called directly.
----------------------------------------------------------------------------

local function requestCampaignReset(zoneName)
    if isClient() then
        pcall(function()
            sendClientCommand("NocturnalReign", "resetCampaign", { zone = zoneName })
        end)
    elseif NocturnalReign.Server and NocturnalReign.Server.resetCampaign then
        NocturnalReign.Server.resetCampaign(zoneName)
        local player = getPlayer()
        if player then
            announce(player, zoneName
                and (zoneName .. " returns to its Lord's reign.")
                or "Every town returns to its Lord's reign.")
        end
    end
end

local function onFillWorldObjectContextMenu(playerNum, context, worldObjects, test)
    if test then return end
    -- MP: admins and moderators only. SP: always available.
    local allowed = isClient() and (isAdmin() or isModerator and isModerator()) or not isClient()
    if not allowed then return end

    pcall(function()
        local player = getSpecificPlayer(playerNum)
        if not player then return end

        local option = context:addOption("Nocturnal Reign (Admin)", worldObjects, nil)
        local subMenu = ISContextMenu:getNew(context)
        context:addSubMenu(option, subMenu)

        local zone = Zones.zoneAt(player:getX(), player:getY())
        if zone then
            subMenu:addOption("Reset bosses: " .. zone.name, nil, function()
                requestCampaignReset(zone.name)
            end)
        end
        subMenu:addOption("Reset bosses: ALL towns", nil, function()
            requestCampaignReset(nil)
        end)
    end)
end

Events.OnFillWorldObjectContextMenu.Add(onFillWorldObjectContextMenu)

local function onPlayerUpdate(player)
    if player ~= getPlayer() then return end -- ignore any non-local-player callback quirks

    scanCounter = scanCounter + 1
    if scanCounter < SCAN_EVERY_TICKS then return end
    scanCounter = 0

    checkDayNightTransition(player)
    scanForLords(player)
end

Events.OnPlayerUpdate.Add(onPlayerUpdate)

----------------------------------------------------------------------------
-- Multiplayer gait pass (Modules 1 & 2, client leg).
--
-- Multiplayer clients own the simulation of the zombies nearest to them
-- (see the file header), so the server's photophobia/night-mutation stats
-- never reach exactly the zombies this player is fighting. This pass runs
-- the same deterministic shared rules (NocturnalReign_Mutation.lua) over
-- this client's loaded zombies, on the same once-per-in-game-minute
-- cadence as the server sweep. Because the rules key only off the world
-- clock and the (engine-synced) climate, every machine reaches the same
-- verdict for the same zombie - no coordination needed, and machines
-- double-applying to the same zombie is a harmless no-op thanks to the
-- ModData idempotence flags.
--
-- Deliberately NOT here: pathing (shade-seeking/shelter-holding stays a
-- server-side order), burn damage (health is authoritative state), and
-- bosses (the server manages their bearing; we skip anything the state
-- broadcast or local ModData marks as a boss).
----------------------------------------------------------------------------

local function clientGaitSweep()
    if not isClient() then return end -- SP/host: the server module's sweep owns this

    local player = getPlayer()
    if not player then return end
    local cell = player:getCell()
    local list = cell and cell:getZombieList()
    if not list then return end

    local photophobiaOn = Options.isPhotophobiaEnabled()
    local nightMutationOn = Options.isNightMutationEnabled()
    if not photophobiaOn and not nightMutationOn then return end

    local sunThreat = Mutation.isSunThreatNow()

    for i = 0, list:size() - 1 do
        local zombie = list:get(i)
        if zombie and not zombie:isDead() then
            local md = zombie:getModData()
            local id = nil
            pcall(function() id = zombie:getOnlineID() end)
            local entry = id and remoteBosses[id]
            local isBoss = entry ~= nil
                or md[Keys.IS_LORD] == true or md[Keys.MINI_TYPE] ~= nil

            if isBoss then
                -- A boss's slow, deliberate bearing must also be asserted
                -- by the machine that actually simulates it - this client,
                -- whenever the boss is nearest this player - or the Lord
                -- sprints like any other night zombie for remote players.
                -- Exception: a chosen playing dead is left untouched so
                -- nothing disturbs the act.
                local fake = entry ~= nil and entry.fake == true
                if not fake then
                    pcall(function() fake = zombie:isFakeDead() end)
                end
                if not fake then
                    md[Keys.IS_SUNSICK] = nil
                    md[Keys.IS_SPRINTER] = nil
                    Mutation.setGait(zombie, "shamble")
                    zombie:setRunning(false)
                end
            else
                -- Anything lying in the engine's fake-dead state (the
                -- Lord's freshly-summoned horde, vanilla ambushers) is
                -- left exactly as it lies - a gait change here would yank
                -- it out of the act mid-sprawl. It joins this branch
                -- normally once it rises.
                local fakeDead = false
                pcall(function() fakeDead = zombie:isFakeDead() end)
                if fakeDead then
                    -- skip
                elseif sunThreat then
                    if photophobiaOn and Mutation.isZombieInDirectSunlight(zombie) then
                        Mutation.applySunSlow(zombie)
                    elseif photophobiaOn then
                        Mutation.revertSunSlow(zombie)
                    end
                    Mutation.revertNight(zombie)
                else
                    Mutation.revertSunSlow(zombie)
                    local calmed = false
                    if nightMutationOn then
                        local zone = Zones.zoneAt(zombie:getX(), zombie:getY())
                        calmed = zone ~= nil and remoteCalm[zone.name] == true
                    end
                    if nightMutationOn and not calmed then
                        Mutation.applyNight(zombie)
                    else
                        Mutation.revertNight(zombie)
                    end
                end
            end
        end
    end
end

Events.EveryOneMinute.Add(clientGaitSweep)
