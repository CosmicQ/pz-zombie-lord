--[[
    NocturnalReign_Server.lua

    Server-authoritative simulation for Nocturnal Reign. Files under
    media/lua/server/ are only ever executed on the server (and on the
    embedded server that a single-player game runs internally) - the game's
    own mod loader guarantees that, so this file never runs on a remote
    client. We still keep a couple of defensive isClient()/isServer() checks
    inline because it costs nothing and protects against this code ever
    being copy/pasted into a shared file by mistake.

    PERFORMANCE NOTE:
    Events.OnZombieUpdate fires once per zombie *per simulation tick*, which
    makes it the hottest possible hook in the game - fine for a handful of
    cheap checks, dangerous for anything that walks other lists or does
    string/table work. Every zombie-population pass in this file (Modules 1
    and 2) is therefore driven by Events.EveryOneMinute instead: one sweep of
    the cell's zombie list per in-game minute is dramatically cheaper than
    per-tick-per-zombie, while still feeling responsive to the player. Only
    Module 3 (the rare Zombie Lord) runs on a tighter, OnTick-driven cadence,
    and even then only iterates the small set of currently-active Lords.

    B42 API NOTE:
    Build 42 reworked large parts of zombie AI/movement while this mod was
    written, and a few per-zombie setters (individual speed override, raw
    sight/hearing/memory floats) were still in flux. Rather than hard-code a
    single method name that might not exist on your exact build and silently
    do nothing, trySetters() below probes a short list of plausible method
    names and uses whichever one actually exists. If none of them exist on
    your build, check your installed game's IsoZombie/IsoGameCharacter Lua
    bindings (or the PZ modding Discord/wiki for your build number) and add
    the correct name to the relevant list - everything else in the file is
    written against stable, long-documented API and does not need touching.
]]

require "NocturnalReign_SandboxOptions"

NocturnalReign = NocturnalReign or {}
NocturnalReign.Server = NocturnalReign.Server or {}
local Server = NocturnalReign.Server
local Options = NocturnalReign.Options
local Keys = NocturnalReign.ModDataKeys

-- Weak-keyed so an entry is dropped automatically once its zombie is no
-- longer referenced elsewhere (removed/reaped/despawned), instead of us
-- having to remember to clean up manually every time a Lord dies.
Server.lords = setmetatable({}, { __mode = "k" })

----------------------------------------------------------------------------
-- Small utility: try a list of candidate setter names on `obj` until one of
-- them exists and doesn't error. Returns the name that worked, or nil.
-- See "B42 API NOTE" above for why this exists.
----------------------------------------------------------------------------
local function trySetters(obj, methodNames, ...)
    for i = 1, #methodNames do
        local fn = obj[methodNames[i]]
        if type(fn) == "function" then
            local ok = pcall(fn, obj, ...)
            if ok then return methodNames[i] end
        end
    end
    return nil
end

--- Same idea as trySetters, but for getters: tries each candidate method
--- name and returns the first non-nil result instead of just a success flag.
local function tryGetters(obj, methodNames, ...)
    for i = 1, #methodNames do
        local fn = obj[methodNames[i]]
        if type(fn) == "function" then
            local ok, result = pcall(fn, obj, ...)
            if ok and result ~= nil then return result end
        end
    end
    return nil
end

local function isZombieLord(zombie)
    return zombie:getModData()[Keys.IS_LORD] == true
end

----------------------------------------------------------------------------
-- MODULE 1: Photophobia (daytime)
----------------------------------------------------------------------------

--- A zombie is "in direct sunlight" if its current square has no roof
--- overhead (isOutside) AND the world's ambient daylight is actually bright
--- (getDayLightStrength ~1 at noon, ~0 at night/heavy overcast dusk) - this
--- keeps zombies safe under deep dusk/dawn gloom even while technically
--- outdoors and inside the configured day window.
local function isZombieInDirectSunlight(zombie)
    local square = zombie:getCurrentSquare()
    if not square or not square:isOutside() then return false end

    local climate = getClimateManager()
    local daylight = climate and climate:getDayLightStrength() or 1.0
    return daylight > 0.35
end

local function applyPhotophobia(zombie)
    local md = zombie:getModData()
    if md[Keys.IS_SUNSICK] then return end
    md[Keys.IS_SUNSICK] = true

    -- Force the slowest possible gait while exposed. `0` is the shambler
    -- index in every speed-enum revision we've seen.
    trySetters(zombie, { "setSpeedType", "setZombieSpeedType" }, 0)
    zombie:setRunning(false)
    if zombie.setSprinting then zombie:setSprinting(false) end
end

local function revertPhotophobia(zombie)
    local md = zombie:getModData()
    if not md[Keys.IS_SUNSICK] then return end
    md[Keys.IS_SUNSICK] = nil
    -- Restore the normal daytime gait so a zombie that reached shelter
    -- behaves normally again. (If it's actually nighttime, Module 2's pass
    -- immediately after this one upgrades it to a sprinter anyway.)
    trySetters(zombie, { "setSpeedType", "setZombieSpeedType" }, 2)
end

-- How far (in tiles) a sunlit zombie will look for a covered square to
-- retreat to. Ring-perimeter search, so worst case is ~8*r squares per ring
-- - cheap enough per-zombie at one sweep per in-game minute, but keep this
-- modest; it's O(radius^2) in total squares visited.
local SHADE_SEARCH_RADIUS = 10

local function isCovered(cell, x, y, z)
    local sq = cell:getGridSquare(x, y, z)
    return sq ~= nil and not sq:isOutside()
end

--- "Deep shade" = a covered, walkable square whose four cardinal neighbours
--- are covered too - i.e. genuinely inside a building, not the sill square
--- just inside a broken window. Targeting deep shade matters because the
--- engine's own WanderFromWindow behaviour actively pulls a zombie standing
--- at a window back out through it, producing an in-out-in oscillation if
--- we park zombies on the first covered square we find (playtested).
local function isDeepShadeTarget(cell, x, y, z)
    local sq = cell:getGridSquare(x, y, z)
    if sq == nil or sq:isOutside() or not sq:isFree(false) then return false end
    return isCovered(cell, x + 1, y, z) and isCovered(cell, x - 1, y, z)
       and isCovered(cell, x, y + 1, z) and isCovered(cell, x, y - 1, z)
end

--- The core "desire indoors" behaviour: find the nearest deep-shade square
--- and path the zombie to it via IsoZombie.pathToLocationF (signature
--- verified against the 42.19 class file). Falls back to the nearest merely
--- covered square if no deep interior exists in range. Runs every sweep for
--- every sunlit zombie so the retreat re-asserts itself if the engine's
--- wander behaviour overrides the path between sweeps.
local function seekShade(zombie)
    -- Hunting beats hiding: never override a zombie with a live target,
    -- or daytime aggro would break entirely.
    if zombie:getTarget() then return end

    local square = zombie:getCurrentSquare()
    if not square then return end
    local cell = zombie:getCell()
    if not cell then return end
    local zx, zy, zz = square:getX(), square:getY(), square:getZ()

    -- Expanding ring-perimeter search: nearest deep shade wins; remember the
    -- nearest shallow cover as a fallback so a lone awning still beats
    -- standing in the open.
    local fallbackX, fallbackY
    for r = 1, SHADE_SEARCH_RADIUS do
        for dx = -r, r do
            for dy = -r, r do
                if math.abs(dx) == r or math.abs(dy) == r then
                    local x, y = zx + dx, zy + dy
                    if isDeepShadeTarget(cell, x, y, zz) then
                        pcall(function() zombie:pathToLocationF(x + 0.5, y + 0.5, zz) end)
                        return
                    end
                    if fallbackX == nil then
                        local sq = cell:getGridSquare(x, y, zz)
                        if sq and not sq:isOutside() and sq:isFree(false) then
                            fallbackX, fallbackY = x, y
                        end
                    end
                end
            end
        end
    end
    if fallbackX then
        pcall(function() zombie:pathToLocationF(fallbackX + 0.5, fallbackY + 0.5, zz) end)
    end
end

--- The other half of the anti-oscillation fix: a sheltered zombie during
--- daytime is re-pinned to its current spot each sweep, so the engine's
--- wander (and WanderFromWindow in particular) can't drift it back into the
--- sun. Deliberately skipped for zombies with a live target - lurking
--- zombies still notice and attack players normally.
local function holdShelter(zombie)
    if zombie:getTarget() then return end
    local square = zombie:getCurrentSquare()
    if not square or square:isOutside() then return end
    local zx, zy, zz = square:getX(), square:getY(), square:getZ()
    pcall(function() zombie:pathToLocationF(zx + 0.5, zy + 0.5, zz) end)
end

--- Optional (default OFF) burn damage, on a per-zombie throttle
--- (Options.getBurnTickSeconds) rather than every sweep, so the tick rate
--- sandbox option means something even though the sweep runs once a minute.
--- Deliberately no stagger/hit reaction: a synchronized flinch across every
--- sunlit zombie once a minute reads as a glitchy mass "repulse", not as
--- burning (playtested; it looked exactly that bad).
local function tickBurnDamage(zombie)
    if not Options.isSunburnDamageEnabled() then return end

    local md = zombie:getModData()
    local nowSeconds = getGameTime():getWorldAgeHours() * 3600
    local last = md[Keys.LAST_BURN_TICK] or 0
    if nowSeconds - last < Options.getBurnTickSeconds() then return end
    md[Keys.LAST_BURN_TICK] = nowSeconds

    local dmgFrac = Options.getBurnDamagePercentPerTick() / 100
    zombie:setHealth(math.max(0, zombie:getHealth() - dmgFrac))
    -- Health reaching 0 needs no special handling: the engine's normal
    -- death processing takes over on the zombie's own next update.
end

----------------------------------------------------------------------------
-- MODULE 2: Nightfall mutation
----------------------------------------------------------------------------

local function applyNightMutation(zombie)
    local md = zombie:getModData()
    if md[Keys.IS_SPRINTER] then return end
    md[Keys.IS_SPRINTER] = true

    -- `3` is the sprinter index in every speed-enum revision we've seen;
    -- adjust if your build differs. We also probe for a direct multiplier
    -- setter so the SprinterSpeedMultiplier sandbox option does something
    -- concrete on builds that expose one; it's a harmless no-op otherwise.
    trySetters(zombie, { "setSpeedType", "setZombieSpeedType" }, 3)
    trySetters(zombie, { "setSpeedMultiplier" }, Options.getSprinterSpeedMultiplier())
    zombie:setRunning(true)
    if zombie.setSprinting then zombie:setSprinting(true) end

    -- Maximise senses. Every name probed maps to "as sharp as the engine
    -- allows" rather than a tunable magnitude, since B42 does not yet expose
    -- granular per-zombie sensory floats in a stable, documented way.
    trySetters(zombie, { "setSight", "setVisionStrength" }, 1.0)
    trySetters(zombie, { "setHearing", "setHearingStrength" }, 1.0)
    trySetters(zombie, { "setMemory", "setTrackingMemory" }, 100)
end

local function revertNightMutation(zombie)
    local md = zombie:getModData()
    if not md[Keys.IS_SPRINTER] then return end
    md[Keys.IS_SPRINTER] = nil

    trySetters(zombie, { "setSpeedType", "setZombieSpeedType" }, 2) -- back to a "normal" fast-shambler baseline
    trySetters(zombie, { "setSight", "setVisionStrength" }, 0.5)
    trySetters(zombie, { "setHearing", "setHearingStrength" }, 0.5)
    trySetters(zombie, { "setMemory", "setTrackingMemory" }, 50)
end

----------------------------------------------------------------------------
-- MODULE 3: The Zombie Lord
----------------------------------------------------------------------------

-- The Lord's regalia: skull face, B42 bone armour over a black robe, combat
-- boots - a skeletal warlord silhouette built entirely from vanilla items.
-- (42.19 has no crown or cape item; the skeleton mask and BlackRobe are the
-- closest vanilla equivalents.) Bump the version string whenever this list
-- changes: already-dressed Lords compare against it and re-dress themselves.
local LORD_ATTIRE_VERSION = "bone-king-2"
local LORD_ATTIRE = {
    "Base.Hat_HalloweenMaskSkeleton", -- skull face
    "Base.BlackRobe",                 -- flowing black robe (cloak stand-in)
    "Base.Cuirass_Bone",              -- B42 bone armour set
    "Base.Gloves_BoneGloves",
    "Base.GreaveBone_Left",
    "Base.GreaveBone_Right",
    "Base.ThighBone_L",
    "Base.ThighBone_R",
    "Base.Shoes_ArmyBoots",           -- combat boots
}

--- Visual tell for Lords. Dressing pattern verified against vanilla usage:
--- the Trailer3 scenarios dress characters item-by-item with
--- InventoryItemFactory.CreateItem + setWornItem(getBodyLocation(), item),
--- and the tutorial's scripted zombie establishes the
--- setDressInRandomOutfit/resetModelNextFrame bracketing. Invoked at
--- promotion and from the sweep's re-registration path, so Lords from older
--- saves (or an older attire version) get re-dressed retroactively.
function Server.ensureLordOutfit(zombie)
    local md = zombie:getModData()
    if md.NR_LordDressed == LORD_ATTIRE_VERSION then return end
    md.NR_LordDressed = LORD_ATTIRE_VERSION

    pcall(function() zombie:setDressInRandomOutfit(false) end)
    -- Strip whatever it died in (including a previous attire version) so
    -- the regalia reads clean.
    pcall(function() zombie:getWornItems():clear() end)
    for _, itemId in ipairs(LORD_ATTIRE) do
        pcall(function()
            -- Created via the zombie's own inventory rather than
            -- InventoryItemFactory: that class is not exposed to the
            -- server-side Lua sandbox (verified the hard way - it indexes
            -- as nil there), while getInventory():AddItem works in every
            -- context. Side benefit: the regalia rides in the Lord's
            -- inventory, so it drops as lootable trophies with the corpse.
            local item = zombie:getInventory():AddItem(itemId)
            if item then
                zombie:setWornItem(item:getBodyLocation(), item)
            end
        end)
    end
    pcall(function() zombie:resetModelNextFrame() end)
end

--- The Lord's bearing: everything about *how* it moves, re-assertable.
--- Applied at promotion and again every lordUpdate tick, because the
--- engine's own stat passes (DoZombieStats and friends) can rewrite these
--- per-zombie values from sandbox lore behind our back.
---
---   Gait: the Lord never hurries. A slow, deliberate shambler walk (`0`
---   is the slowest index, same convention as Module 1) reads as
---   confidence rather than weakness, and makes it instantly
---   distinguishable at night when the rest of the horde is sprinting.
---
---   Cognition: `cognition` is a public IsoZombie field read directly by
---   IsoDoor/IsoWindow/IsoThumpable (verified against the 42.19 jar) when
---   deciding how a specific zombie interacts with them. `1` is the
---   "Navigate + Use Doors" tier - the Lord turns the knob on unlocked
---   doors and paths intelligently; locked/barricaded doors still stop it.
---   `-1` means "defer to the sandbox lore setting", i.e. what every
---   normal zombie carries - assigning it when the toggle is off means
---   flipping the option mid-game genuinely reverts existing Lords.
local function applyLordBearing(zombie)
    trySetters(zombie, { "setSpeedType", "setZombieSpeedType" }, 0)
    zombie:setRunning(false)

    local cognition = Options.isLordDoorUseEnabled() and 1 or -1
    -- Raw field write first (the documented modding route for per-zombie
    -- lore stats); setter probe as the fallback, per the B42 API note.
    if not pcall(function() zombie.cognition = cognition end) then
        trySetters(zombie, { "setCognition" }, cognition)
    end
end

function Server.promoteToZombieLord(zombie)
    local md = zombie:getModData()
    md[Keys.IS_LORD] = true

    -- Tougher, so players get a boss fight rather than a one-swing kill.
    -- Zombie health scales with the sandbox lore "Toughness" setting, so we
    -- multiply rather than assigning a fixed value. Note this does not
    -- prevent instant-kill crits (jaw stabs etc.) - those are engine
    -- mechanics; the multiplier mainly makes the Lord shrug off gunfire
    -- and blunt swings.
    zombie:setHealth(zombie:getHealth() * Options.getLordHealthMultiplier())

    Server.ensureLordOutfit(zombie)
    applyLordBearing(zombie)

    Server.lords[zombie] = true
    print(string.format(
        "[NocturnalReign] A Zombie Lord has risen at (%d, %d, %d).",
        zombie:getX(), zombie:getY(), zombie:getZ()
    ))
end

--- Called once, the first time we ever see a given zombie, to roll for
--- promotion. Gated behind a ModData flag so re-running the sweep never
--- re-rolls the same zombie.
local function initZombieIfNeeded(zombie)
    local md = zombie:getModData()
    if md[Keys.INITIALIZED] then return end
    md[Keys.INITIALIZED] = true

    if not Options.isZombieLordEnabled() then return end

    -- ZombRand is the engine's own RNG helper (as opposed to math.random),
    -- used here for consistency with the rest of the codebase's zombie
    -- logic. Chance is a percent with up to 2 decimal places of precision,
    -- e.g. 0.5% -> 50 out of 10000.
    local chance = Options.getZombieLordSpawnChancePercent()
    if chance > 0 and ZombRand(10000) < math.floor(chance * 100) then
        Server.promoteToZombieLord(zombie)
    end
end

----------------------------------------------------------------------------
-- MODULE 3b: Raise the Dead - once-per-day Zombie Lord ability.
--
-- Rather than conjuring zombies out of thin air, this walks the grid
-- squares around the Lord looking for corpses (IsoDeadBody objects - what a
-- zombie becomes once it's fully killed), removes each one, and spawns a
-- fresh zombie in its place at reduced health. Functionally and visually
-- that reads exactly as "the Lord raised the dead", and it's naturally
-- self-limiting: a Lord can only raise as many zombies as there are bodies
-- actually lying around nearby, up to HordeSummonMaxZombies.
--
-- CONFIDENCE NOTE: dynamically instantiating a brand-new IsoZombie from Lua
-- is the single least-standardized part of PZ modding - the exact call
-- sequence has differed across builds and isn't fully pinned down for B42
-- unstable. spawnZombieAt() below uses the sequence most consistently
-- reported to work, with every optional/cosmetic step wrapped in pcall so a
-- failure there can't stop the zombie from existing. If corpses vanish but
-- no zombie appears in their place, check the server console for the
-- "[NocturnalReign] spawnZombieAt failed" message this prints, and compare
-- against IsoZombie's exposed methods on your exact build.
----------------------------------------------------------------------------

--- Scans the square grid centred on (lx, ly, lz) out to `radius` tiles and
--- returns up to `maxCount` {body = IsoDeadBody, square = IsoGridSquare}
--- pairs. Only called from a cooldown-gated cast, never per tick, so the
--- O(radius^2) square scan is an acceptable one-off cost.
local function findNearbyCorpses(cell, lx, ly, lz, radius, maxCount)
    -- Corpse enumeration pattern verified against the vanilla 42.19 debug
    -- horde UI (ISSpawnHordeUI.lua): corpses live in a square's static
    -- moving objects list as IsoDeadBody instances - there is no dedicated
    -- getDeadBodys() accessor on this build.
    local found = {}
    for x = lx - radius, lx + radius do
        for y = ly - radius, ly + radius do
            local square = cell:getGridSquare(x, y, lz)
            if square then
                local objects = square:getStaticMovingObjects()
                for i = 0, objects:size() - 1 do
                    local obj = objects:get(i)
                    if instanceof(obj, "IsoDeadBody") then
                        table.insert(found, { body = obj, square = square })
                        if #found >= maxCount then return found end
                    end
                end
            end
        end
    end
    return found
end

--- Attempts to spawn one live IsoZombie on `square` at `healthFrac` health.
---
--- Primary path is the global addZombiesInOutfit(x, y, z, count, outfit,
--- femaleChance) - the same helper vanilla and many long-lived mods use to
--- place zombies, which handles cell registration, animation state and MP
--- sync internally and has been stable since B41. Only if that global is
--- somehow absent do we fall back to hand-rolling an IsoZombie; see the
--- CONFIDENCE NOTE above the module header.
local function spawnZombieAt(cell, square, healthFrac)
    local x, y, z = square:getX(), square:getY(), square:getZ()

    if type(addZombiesInOutfit) == "function" then
        local ok, spawned = pcall(addZombiesInOutfit, x, y, z, 1, nil, 50)
        if ok and spawned and spawned:size() > 0 then
            local zombie = spawned:get(0)
            zombie:setHealth(healthFrac)
            return zombie
        end
        print("[NocturnalReign] addZombiesInOutfit failed, trying manual spawn fallback.")
    end

    -- Fallback: manual construction. Kept only as a safety net for builds
    -- where the helper above is missing/renamed.
    local ok, zombieOrErr = pcall(function()
        local zombie = IsoZombie.new(cell)
        local fx, fy = x + 0.5, y + 0.5
        zombie:setX(fx)
        zombie:setY(fy)
        zombie:setZ(z)
        zombie:setLx(fx)
        zombie:setLy(fy)
        zombie:setLz(z)
        zombie:setHealth(healthFrac)
        cell:getZombieList():add(zombie)
        return zombie
    end)

    if not ok then
        print("[NocturnalReign] spawnZombieAt failed: " .. tostring(zombieOrErr))
        return nil
    end
    return zombieOrErr
end

local function summonHorde(lordZombie)
    local cell = lordZombie:getCell()
    if not cell then return end

    local lx, ly, lz = lordZombie:getX(), lordZombie:getY(), lordZombie:getZ()
    local radius = Options.getHordeSummonRadius()
    local maxCount = Options.getHordeSummonMaxZombies()
    local healthFrac = Options.getHordeSummonHealthPercent() / 100

    local corpses = findNearbyCorpses(cell, lx, ly, lz, radius, maxCount)
    if #corpses == 0 then return end

    local raised = 0
    for i = 1, #corpses do
        local entry = corpses[i]
        -- removeCorpse() is the dedicated IsoDeadBody removal API (second
        -- arg: don't drop its inventory on the ground - it's being raised,
        -- not looted). RemoveTileObject is a legacy fallback only.
        local removedOk = pcall(function() entry.square:removeCorpse(entry.body, false) end)
        if not removedOk then
            pcall(function() entry.square:RemoveTileObject(entry.body) end)
        end

        local zombie = spawnZombieAt(cell, entry.square, healthFrac)
        if zombie then
            local zmd = zombie:getModData()
            zmd[Keys.COMMANDED_BY_LORD] = true
            zmd[Keys.INITIALIZED] = true -- a resurrected zombie should never itself re-roll into a new Lord
            raised = raised + 1
        end
    end

    if raised > 0 then
        print(string.format("[NocturnalReign] Zombie Lord raised %d zombie(s) from the dead.", raised))
        -- The raising itself is loud enough to draw the new arrivals (and
        -- anything else nearby) toward the Lord, same mechanism as (b)/(c)
        -- in lordUpdate() below.
        addSound(lordZombie, lx, ly, lz, radius, 100)
    end
end

----------------------------------------------------------------------------
-- Player seeking: the Lord's long-range prey sense.
----------------------------------------------------------------------------

--- Returns a java list of every player the simulation knows about, or nil.
--- getOnlinePlayers() is the MP-server accessor; on the embedded server of
--- a single-player game it can exist but come back empty, so we fall back
--- to IsoPlayer.getPlayers() - the local-players array, indexed by
--- splitscreen slot, whose entries may be nil (callers must guard).
local function getAllPlayers()
    local ok, players = pcall(getOnlinePlayers)
    if ok and players and players:size() > 0 then return players end
    local ok2, locals = pcall(function() return IsoPlayer.getPlayers() end)
    if ok2 then return locals end
    return nil
end

--- Closest living player to (lx, ly) within `maxRadius` tiles, or nil.
--- Distance is 2D on purpose: a player three floors up is still prey.
local function findClosestPlayer(lx, ly, maxRadius)
    if maxRadius <= 0 then return nil end
    local players = getAllPlayers()
    if not players then return nil end

    local best, bestDistSq = nil, maxRadius * maxRadius
    for i = 0, players:size() - 1 do
        local p = players:get(i)
        if p and not p:isDead() then
            local dx, dy = p:getX() - lx, p:getY() - ly
            local distSq = dx * dx + dy * dy
            if distSq <= bestDistSq then
                best, bestDistSq = p, distSq
            end
        end
    end
    return best
end

--- Per-Lord AI tick. Design rationale (see also the module doc comment
--- above the AI loop registration below):
--
--   (a) Scan for a player: rather than re-implementing sight/hearing/line-
--       of-sight checks, we simply read the Lord's own getTarget() - the
--       engine already runs that detection for every zombie every update,
--       so piggybacking on it is both correct and free.
--
--   (b) Commandeer nearby zombies: instead of overriding each nearby
--       zombie's internal target/pathing state directly (fragile, and easy
--       to fight the engine's own behaviour tree), the Lord periodically
--       emits a quiet noise at its own position via the global addSound()
--       function. addSound() is the same mechanism vanilla noise sources
--       (gunshots, car alarms, thrown objects) use to alert zombies - any
--       standard zombie within earshot will path toward the Lord exactly as
--       it would path toward any other noise. This means the "commandeer"
--       behaviour scales to any number of nearby zombies without us
--       touching each one's pathfinding state, and can never desync from
--       however the engine's own zombie movement works on a given build.
--
--   (c) Broadcast a spotted player: same mechanism, aimed at the player's
--       coordinates instead, at a louder volume/larger radius - this is the
--       "coordinated pack swarm" trigger.
--
-- We additionally tag nearby standard zombies with a COMMANDED_BY_LORD flag
-- purely as metadata (for UI/debugging/future features); it has no direct
-- gameplay effect on its own.
local function lordUpdate(lordZombie)
    if lordZombie:isDead() then
        Server.lords[lordZombie] = nil
        return
    end

    -- Re-assert gait + cognition once a second; see applyLordBearing's
    -- doc comment for why this can't be set-once.
    applyLordBearing(lordZombie)

    local lx, ly, lz = lordZombie:getX(), lordZombie:getY(), lordZombie:getZ()
    local commandRadius = Options.getLordCommandRadius()

    local target = lordZombie:getTarget()
    local seesPlayer = target ~= nil and instanceof(target, "IsoPlayer")
    local px, py, pz

    if seesPlayer then
        px, py, pz = target:getX(), target:getY(), target:getZ()
        addSound(lordZombie, px, py, pz, Options.getLordAlertRadius(), 100)

        -- The Lord leads from the front: an explicit charge order each tick
        -- so it can never idle in place while its horde does the fighting.
        pcall(function() lordZombie:pathToCharacter(target) end)

        -- Raise the Dead: cast at most once per HordeSummonCooldownDays,
        -- triggered by the same "spotted a player" moment as the alert
        -- broadcast above - thematically the Lord raises corpses when it
        -- actually engages, not on an idle timer. World age (total elapsed
        -- in-game hours) is monotonic, unlike getDay() which is merely the
        -- day-of-month and wraps at month boundaries; it also survives
        -- server restarts/save reloads without extra bookkeeping.
        if Options.isHordeSummonEnabled() then
            local md = lordZombie:getModData()
            local today = math.floor(getGameTime():getWorldAgeHours() / 24)
            local lastSummon = md[Keys.LAST_SUMMON_DAY]
            if lastSummon == nil or today - lastSummon >= Options.getHordeSummonCooldownDays() then
                md[Keys.LAST_SUMMON_DAY] = today
                summonHorde(lordZombie)
            end
        end
    else
        -- No target in sight: the Lord stalks. addSound at its own feet is
        -- the silent rallying call (WorldSounds carry no audio unless the
        -- caller also plays one - players hear nothing), drawing every
        -- zombie in earshot to walk with it exactly as they would to a car
        -- horn. Because it re-fires every tick from the Lord's current
        -- position, the gathered pack flows along behind it as it moves.
        addSound(lordZombie, lx, ly, lz, commandRadius, 40)

        -- Long-range prey sense: walk slowly toward the closest living
        -- player within LordSeekRadius (default 400 tiles - roughly max
        -- sniper-rifle range). This is deliberate omniscience, not a
        -- sight/sound check: the Lord always knows roughly where prey is
        -- and drifts that way, horde in tow, until the engine's normal
        -- senses acquire a real target and the branch above takes over.
        local prey = findClosestPlayer(lx, ly, Options.getLordSeekRadius())
        if prey then
            pcall(function() lordZombie:pathToLocationF(prey:getX(), prey:getY(), prey:getZ()) end)
        end
    end

    local cell = lordZombie:getCell()
    if not cell then return end
    local list = cell:getZombieList()
    if not list then return end

    local radiusSq = commandRadius * commandRadius
    for i = 0, list:size() - 1 do
        local other = list:get(i)
        if other and other ~= lordZombie and not other:isDead() and not isZombieLord(other) then
            local dx, dy = other:getX() - lx, other:getY() - ly
            if (dx * dx + dy * dy) <= radiusSq then
                other:getModData()[Keys.COMMANDED_BY_LORD] = true
                -- Explicit orders beat sound lures for coordination. Only
                -- zombies without their own target are commanded - anything
                -- already fighting keeps fighting. The +/-3 tile jitter
                -- spreads the pack into a loose formation instead of a
                -- single-file conga line onto one square.
                if not other:getTarget() then
                    local jx, jy = ZombRand(7) - 3, ZombRand(7) - 3
                    if seesPlayer then
                        -- Swarm order: converge on the player's position.
                        pcall(function() other:pathToLocationF(px + jx, py + jy, pz) end)
                    else
                        -- Escort order: form a defensive pack on the Lord.
                        pcall(function() other:pathToLocationF(lx + jx, ly + jy, lz) end)
                    end
                end
            end
        end
    end

    return seesPlayer
end

----------------------------------------------------------------------------
-- MODULE 3c: The Lord calls the fog.
--
-- While any Zombie Lord is engaged with a player, a thick fog rolls in,
-- and it lifts a short while after the last Lord loses its target. Uses
-- the ClimateManager float-override mechanism exactly as the vanilla
-- trailer scenarios do (Trailer2Scenario.lua): getClimateFloat(5) is the
-- fog-intensity channel, setOverride(value, lerp) eases toward the target
-- so the fog visibly rolls in rather than popping.
----------------------------------------------------------------------------

local FOG_CLIMATE_ID = 5      -- ClimateManager float id: fog intensity
local FOG_INTENSITY = 0.85    -- 0..1; heavy but not a total whiteout
local FOG_LINGER_TICKS = 30   -- lord-ticks (~30s) fog lingers after combat ends

local fogActive = false
local fogLinger = 0

local function setFogOverride(enabled)
    pcall(function()
        local fogFloat = getClimateManager():getClimateFloat(FOG_CLIMATE_ID)
        if enabled then
            fogFloat:setEnableOverride(true)
            fogFloat:setOverride(FOG_INTENSITY, 1)
        else
            -- Releasing the override hands fog control back to the weather
            -- simulation, which eases back to whatever is natural right now.
            fogFloat:setEnableOverride(false)
        end
    end)
end

local function updateLordFog(anyLordInCombat)
    if not Options.isLordFogEnabled() then
        if fogActive then
            fogActive = false
            setFogOverride(false)
        end
        return
    end

    if anyLordInCombat then
        fogLinger = FOG_LINGER_TICKS
        if not fogActive then
            fogActive = true
            setFogOverride(true)
            print("[NocturnalReign] A Zombie Lord calls the fog.")
        end
    elseif fogActive then
        fogLinger = fogLinger - 1
        if fogLinger <= 0 then
            fogActive = false
            setFogOverride(false)
            print("[NocturnalReign] The Lord's fog lifts.")
        end
    end
end

-- Lords are rare by design (a fraction of a percent of the population), so
-- iterating Server.lords every ~1 second on OnTick is cheap even though
-- OnTick itself fires every render frame - we simply skip almost all of them.
local TICKS_PER_LORD_UPDATE = 30
local lordTickCounter = 0

Events.OnTick.Add(function()
    if isClient() then return end -- belt-and-suspenders; see file header

    lordTickCounter = lordTickCounter + 1
    if lordTickCounter < TICKS_PER_LORD_UPDATE then return end
    lordTickCounter = 0

    local anyLordInCombat = false
    for lordZombie in pairs(Server.lords) do
        local ok, seesPlayer = pcall(lordUpdate, lordZombie)
        if not ok then
            -- Drop a Lord that errors out instead of repeating the same
            -- failure every second (e.g. a zombie ref that went stale
            -- between GC passes on the weak table).
            Server.lords[lordZombie] = nil
        elseif seesPlayer then
            anyLordInCombat = true
        end
    end

    updateLordFog(anyLordInCombat)
end)

----------------------------------------------------------------------------
-- MODULE 3d: Boss loot.
--
-- A slain Zombie Lord's corpse carries serious rewards: two distinct rolls
-- from the table below land in the zombie's inventory during OnZombieDead,
-- which the engine then transfers onto the corpse it creates. All item ids
-- verified against the 42.19 media/scripts definitions.
----------------------------------------------------------------------------

local LORD_LOOT_TABLE = {
    { "Base.Katana" },
    { "Base.AssaultRifle", "Base.556Box", "Base.556Box" },
    { "Base.Shotgun", "Base.ShotgunShellsBox", "Base.ShotgunShellsBox" },
    { "Base.Sledgehammer" },
    { "Base.Machete", "Base.Bullets9mmBox" },
}

local function onZombieDead(zombie)
    if isClient() then return end
    if not Options.isLordLootEnabled() then return end
    if not zombie:getModData()[Keys.IS_LORD] then return end

    local inv = zombie:getInventory()
    if not inv then return end

    -- Two distinct rolls so the drop always feels like a haul but never
    -- duplicates (the classic "pick 2 of N without replacement" trick:
    -- roll the second in a range one smaller and shift it past the first).
    local first = ZombRand(#LORD_LOOT_TABLE) + 1
    local second = ZombRand(#LORD_LOOT_TABLE - 1) + 1
    if second >= first then second = second + 1 end

    for _, roll in ipairs({ first, second }) do
        for _, itemId in ipairs(LORD_LOOT_TABLE[roll]) do
            pcall(function() inv:AddItem(itemId) end)
        end
    end

    print(string.format(
        "[NocturnalReign] A Zombie Lord has fallen at (%d, %d, %d); its corpse carries trophies.",
        zombie:getX(), zombie:getY(), zombie:getZ()
    ))
end

Events.OnZombieDead.Add(onZombieDead)

----------------------------------------------------------------------------
-- Main population sweep (Modules 1 & 2) - once per in-game minute.
----------------------------------------------------------------------------

local sweepCount = 0

local function mainSweep()
    if isClient() then return end -- belt-and-suspenders; see file header

    local cell = getCell()
    if not cell then return end
    local zombieList = cell:getZombieList()
    if not zombieList then return end

    -- Diagnostic heartbeat: verbose for the first few sweeps after load,
    -- then once per in-game hour, so console.txt always shows whether the
    -- sweep is alive, how many zombies it sees, and what config it read.
    sweepCount = sweepCount + 1
    if sweepCount <= 3 or sweepCount % 60 == 0 then
        print(string.format(
            "[NocturnalReign] sweep #%d: %d zombies in cell, hour=%d, daytime=%s, lordChance=%s",
            sweepCount, zombieList:size(), getGameTime():getHour(),
            tostring(Options.isDaytimeHour(getGameTime():getHour())),
            tostring(Options.getZombieLordSpawnChancePercent())
        ))
    end

    local hour = getGameTime():getHour()
    local daytime = Options.isDaytimeHour(hour)
    local photophobiaOn = Options.isPhotophobiaEnabled()
    local nightMutationOn = Options.isNightMutationEnabled()

    -- Heavy fog shields zombies from the sun: under it the horde behaves as
    -- if it were night (sprinters, no shelter-seeking). Reading the actual
    -- climate value (vanilla-verified getFogIntensity, same threshold family
    -- vanilla fishing/foraging use) means both the Zombie Lord's called fog
    -- AND naturally-occurring heavy fog grant the protection.
    local fogShield = false
    pcall(function() fogShield = getClimateManager():getFogIntensity() >= 0.5 end)
    local sunThreat = daytime and not fogShield

    for i = 0, zombieList:size() - 1 do
        local zombie = zombieList:get(i)
        if zombie and not zombie:isDead() then
            initZombieIfNeeded(zombie)

            if isZombieLord(zombie) then
                -- Immune to both daytime photophobia and the nightfall
                -- mutation pass: the Lord manages its own stats once, in
                -- Server.promoteToZombieLord(), and Module 3 handles its
                -- ongoing behaviour separately above.
                --
                -- Re-registering here (idempotent - it's just a table key)
                -- is what revives a Lord's AI after a save reload: the
                -- IS_LORD flag persists in ModData, but Server.lords is
                -- in-memory only and starts empty every session.
                Server.lords[zombie] = true
                Server.ensureLordOutfit(zombie)
            elseif sunThreat then
                if photophobiaOn and isZombieInDirectSunlight(zombie) then
                    applyPhotophobia(zombie)
                    seekShade(zombie)
                    tickBurnDamage(zombie)
                elseif photophobiaOn then
                    revertPhotophobia(zombie)
                    -- Not sunlit right now: if that's because it's under a
                    -- roof, keep it there (see holdShelter); if it's merely
                    -- outside on a dark overcast morning, holdShelter's own
                    -- isOutside() check makes this a no-op.
                    holdShelter(zombie)
                else
                    revertPhotophobia(zombie)
                end
                revertNightMutation(zombie)
            else
                -- True night, or daytime under a fog shield: either way the
                -- sun poses no threat and the horde runs at full ferocity.
                revertPhotophobia(zombie)
                if nightMutationOn then
                    applyNightMutation(zombie)
                end
            end
        end
    end
end

Events.EveryOneMinute.Add(mainSweep)

print("[NocturnalReign] Server module loaded; population sweep registered.")
