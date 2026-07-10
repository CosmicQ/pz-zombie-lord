--[[
    NocturnalReign_Zones.lua  (shared)

    Zone provider for Nocturnal Reign's territorial bosses. Answers exactly
    one question for the rest of the mod: "what named territory, if any, is
    world position (x, y) inside, and what difficulty tier is it?"

    Loaded on both sides (media/lua/shared/) for the same reason as the
    sandbox options module: the server uses zones to drive boss spawning and
    liberation, and the client will eventually want the same answer for UI
    cues ("You have entered the domain of the Lord of Rosewood").

    BACKEND SEAM:
    Zone geometry is deliberately pluggable. Today there is one backend -
    the BUILTIN table below - so the mod is fully standalone. A second
    backend is planned for the "More Difficult Zones" mod (workshop id
    3325808670), whose global Zone.list / checkZoneAtXY() cover the same
    ground and are editable in-game; when that integration lands, zoneAt()
    will defer to MDZ whenever it is installed so bosses, zombie scaling and
    the admin's zone editor all agree on one set of boxes. Everything else
    in this mod goes through zoneAt()/byName() and never reads the table
    directly, so swapping backends touches only this file.

    TIER MEANING (the one knob driving everything):
      tier N  =>  the zone's Lord has (1 + 0.25*(N-1)) x the base Lord
                  health, and - in a later phase - the zone hosts N-1
                  mini-bosses guarding it. Tier 1 towns are the intended
                  starting fights; Louisville is the endgame.

    The boxes below are a first pass: generous rectangles around each
    town's built-up area, drawn from the community map project's world
    coordinates and rounded outward. They are data, not logic - tune them
    freely in playtesting without touching any other file.
]]

NocturnalReign = NocturnalReign or {}
NocturnalReign.Zones = NocturnalReign.Zones or {}
local Zones = NocturnalReign.Zones

-- {x1, y1} is the north-west corner, {x2, y2} the south-east (world tile
-- coordinates, same space as IsoObject:getX/getY).
local BUILTIN = {
    -- Tier 1: starter towns - a lone, baseline Lord.
    { name = "Rosewood",      x1 = 7400,  y1 = 11200, x2 = 8800,  y2 = 12600, tier = 1 },
    { name = "Riverside",     x1 = 5900,  y1 = 4900,  x2 = 7000,  y2 = 5700,  tier = 1 },
    { name = "EchoCreek",     x1 = 3100,  y1 = 10700, x2 = 3950,  y2 = 11500, tier = 1 },

    -- Tier 2: the classic mid-game towns.
    { name = "Muldraugh",     x1 = 10450, y1 = 9200,  x2 = 11300, y2 = 10450, tier = 2 },
    { name = "Ekron",         x1 = 100,   y1 = 9200,  x2 = 1250,  y2 = 10100, tier = 2 },
    { name = "FallasLake",    x1 = 6800,  y1 = 8000,  x2 = 7650,  y2 = 8600,  tier = 2 },
    { name = "Irvington",     x1 = 700,   y1 = 12800, x2 = 4050,  y2 = 15000, tier = 2 },

    -- Tier 3: dense, dangerous, or fortified.
    { name = "WestPoint",     x1 = 10800, y1 = 6500,  x2 = 12500, y2 = 7600,  tier = 3 },
    { name = "MarchRidge",    x1 = 9600,  y1 = 12300, x2 = 10650, y2 = 13500, tier = 3 },
    { name = "Brandenburg",   x1 = 1000,  y1 = 5300,  x2 = 3100,  y2 = 6700,  tier = 3 },
    { name = "ValleyStation", x1 = 12200, y1 = 4600,  x2 = 13800, y2 = 5900,  tier = 3 },

    -- Tier 4: the endgame. Louisville's Lord is the strongest thing the
    -- mod spawns (until the King arrives in a later phase).
    { name = "Louisville",    x1 = 11700, y1 = 900,   x2 = 15000, y2 = 4600,  tier = 4 },
}

-- Sorted smallest-area-first once at load, so zoneAt()'s first hit is
-- automatically the innermost zone. That is the whole nested-zone story:
-- a future tier-5 "LouisvilleMall" box dropped inside Louisville just
-- works, with no nesting flags or parent/child bookkeeping.
table.sort(BUILTIN, function(a, b)
    return (a.x2 - a.x1) * (a.y2 - a.y1) < (b.x2 - b.x1) * (b.y2 - b.y1)
end)

local byName = {}
for i = 1, #BUILTIN do
    local zone = BUILTIN[i]
    zone.centerX = math.floor((zone.x1 + zone.x2) / 2)
    zone.centerY = math.floor((zone.y1 + zone.y2) / 2)
    byName[zone.name] = zone
end

--- The zone containing world position (x, y), or nil for wilderness.
--- Innermost (smallest) zone wins where boxes overlap; see the sort above.
--- @return table|nil  { name, tier, x1, y1, x2, y2, centerX, centerY }
function Zones.zoneAt(x, y)
    for i = 1, #BUILTIN do
        local zone = BUILTIN[i]
        if x >= zone.x1 and x <= zone.x2 and y >= zone.y1 and y <= zone.y2 then
            return zone
        end
    end
    return nil
end

--- Zone record by name, or nil if no such zone (e.g. a persisted boss
--- record whose zone was renamed between mod versions - callers must treat
--- that as "zone no longer exists" and drop the record, not error).
function Zones.byName(name)
    return byName[name]
end

--- Whether (x, y) lies inside `zone` expanded outward by `margin` tiles on
--- every side. The leash test: Lords chase prey a little beyond their
--- borders but not across the map, and walk home once outside this band.
function Zones.containsWithMargin(zone, x, y, margin)
    return x >= zone.x1 - margin and x <= zone.x2 + margin
       and y >= zone.y1 - margin and y <= zone.y2 + margin
end

--- All zones, smallest first. Exposed for debug tooling and the client's
--- future territory UI; simulation code should prefer zoneAt()/byName().
function Zones.all()
    return BUILTIN
end
