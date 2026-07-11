# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- **Admin campaign reset** — a "Nocturnal Reign (Admin)" world right-click menu (admins/moderators in multiplayer, always available in single-player) that puts the current town — or every town — back under its Lord's reign: slain-day records for the Lord and its chosen are erased and the full court rises again on the next approach. The server re-validates the sender's access level; the client-side menu gate is UI only.

### Fixed

- Every server restart left every town boss-less for 12 in-game hours: the lost-boss grace window's sighting clock was persisted into the save, but restarts reap the live boss zombies it was vouching for (observed on the dedicated server — an entire session of sweeps with no Lord, hence no fog, no summon, no glow). The sighting clock is now in-memory and session-scoped, so bosses respawn as soon as a player enters town after a restart, while the within-session anti-duplicate grace still works exactly as before.

## [1.1.0] - 2026-07-11

### Added

- **Territorial Lords** — every major town is now the domain of its own named Zombie Lord ("The Lord of Rosewood", "The Lord of Louisville"), the first phase of a Valheim-style boss progression:
  - 12 built-in territories across the Build 42 map, each with a difficulty tier (1–4). Tier scales the Lord's health (+25% per tier above 1); Louisville is the endgame domain.
  - A town's Lord rises when a survivor first enters its territory, and is leashed to it — it stalks prey within (and slightly beyond) its borders and walks home instead of being kited across the map.
  - **Liberation** — slaying a town's Lord liberates the town: its zombies no longer mutate into night sprinters (toggleable), and the Lord stays dead forever or respawns after a configurable number of days.
  - Campaign state (which towns are liberated, and when) persists in world ModData across saves and server restarts.
  - Random roaming Lords still spawn, but only in the wilderness between towns.
- New shared zone module (`NocturnalReign_Zones.lua`) with a pluggable backend seam, designed for a future integration with the "More Difficult Zones" mod so bosses can follow admin-drawn zones.
- 3 new sandbox options: **Enable Territorial Lords**, **Territorial Lord Respawn (days)**, and **Liberation Calms the Night**.
- **Mini-bosses: the Lord's chosen** — towns of tier 2+ field a court of (tier − 1) lieutenants, each embodying one of the Lord's powers and stripping it from that town's Lord when slain: the Shepherd (escort pack, priest's cassock), the Herald (position broadcast, cultist's hood), the Gravedigger (Raise the Dead, scarecrow's rags), and the Brute (the Lord's tier health bonus, spiked armour). Chosen glow ember-amber, drop one boss-loot bundle each, stay dead for the rest of the reign, and return only if the whole reign resets. Toggleable via the new **Enable Mini-Bosses** sandbox option.
- **Feign death** — once per life, a chosen that drops to half health or is knocked off its feet collapses among the dead: its glow goes dark, it lies still as any corpse, and it lunges when someone comes close enough to loot it. Uses the engine's native fake-dead ambush state.

- **Tier-scaled boss loot** — a slain Lord's corpse now pays 1 + zone tier distinct loot bundles (wilderness Lords: 2), from an expanded table: katana, assault rifle/shotgun/hunting rifle with ammo, sledgehammer, machete + hunting knife, gold bar + gold necklace, and an army ALICE pack stocked with medical supplies.
- Steam Workshop packaging: `workshop.txt` rewritten for the boss-progression feature set, unlisted visibility during family playtesting, Build 42/Multiplayer/WIP tags.

### Changed

- Repository renamed from `pz-zombie-lord` to `pz-nocturnal-reign` to match the mod; all documentation and `mod.info` links updated.
- **Multiplayer architecture pass** (Build 42 unstable MP, 42.13+). Research against PZwiki and the developers' networking blogs surfaced two facts the original design missed: object ModData is *never* synchronized between server and clients, and each zombie's simulation is owned by the *client* nearest to it, not the server. Three structural changes follow:
  - New shared module `NocturnalReign_Mutation.lua`: the photophobia/night-mutation stat rules are now deterministic functions of the world clock and climate (state every machine already shares), applied by the server sweep *and* by a new once-per-minute client pass — so the zombies a remote player is actually fighting (the ones their own client simulates) finally slow in the sun and sprint at night in multiplayer. Pathing orders, burn damage, and boss AI remain server-authoritative.
  - The server now broadcasts one small `state` command per second: the live boss roster (matched client-side by zombie onlineID), current fog state, and liberated-zone names. This replaces the one-shot fog toggle and is what makes boss glow, proximity warnings, feign-death concealment, and liberation-calmed nights work on remote clients at all — and players who join mid-fight now get the Lord's fog within a second.
  - Zombie gait changes prefer the official Build 42.18+ `IsoZombie` API (`doShambler()`, `doFastShambler()`, `doSprinter()`) with the legacy `setSpeedType` probe kept as a fallback for older 42.x builds.
- **Raise the Dead reworked to summon a rising horde.** The old mechanic consumed real corpses and spawned replacements 1:1, which leaned on the two least-standardized APIs in PZ modding (corpse removal, manual `IsoZombie` construction — the latter unsyncable in multiplayer) and did nothing when the Lord engaged in a corpse-free field. Now the summoner calls a horde up out of the earth around it: each zombie is spawned through the MP-safe engine helper and born in the engine's fake-dead state — sprawled among the dead — then climbs to its feet as the summoner's shriek or an approaching survivor stirs it, all under the fog the Lord has already called. The mod's own population sweeps now leave any fake-dead zombie untouched (summoned, feigning, or vanilla ambusher) so nothing yanks one out of the act mid-sprawl. Sandbox option labels/tooltips updated to match.
  - **The summoning shriek** — every cast opens with the game's blood-curdling `MetaScream` played from the summoner itself, whether or not the ground can answer. Locally audible in single-player and co-op hosting, and rendered by each remote client at the boss's position via a one-shot server command (server-played sounds never reach clients on their own).
  - **Horde size scales with the summoner's level** — the base sandbox value (new default 10, was a flat 20) is multiplied by the summoner's level: zone tier for a territorial Lord (Rosewood 10, Louisville 40 at defaults), 1 for a wilderness Lord, and always 1 for a Gravedigger — the Lord's apprentice, never its equal. Hard-capped at 60 per cast so a maxed slider can't turn one summon into a lag event.

### Fixed

- Constant console exception spam (and the in-game error icon) while a Lord was active: the per-tick attempt to write `IsoZombie.cognition` always throws on 42.19 — Kahlua rejects raw field writes and the build has no `setCognition` method. The write is now a silent one-time capability probe; Lord door-use is dormant until the game exposes a per-zombie cognition API, and the console says so once per session.
- The Lord's regalia now actually renders: B42 zombies draw their model from a named outfit, not from worn inventory items, so the Lord dresses in the game's bone-armour outfit (`ArmorTest_Bone`, top hat included) with hooded `Cultist` robes as the female-model fallback. The skull-and-bone worn items remain in inventory as lootable trophies.
- Duplicate territorial Lords: a Lord whose chunk unloaded was replaced instantly (QA saw six Lords of Rosewood at once); a lost Lord now gets a 12-in-game-hour grace window to resurface before a replacement rises.
- The Lord's fog now reaches multiplayer clients: the server's ClimateManager override only affects its own simulation, so players on a dedicated server fought under clear skies. The server now broadcasts the fog toggle as a server command and each client applies the identical override locally (single-player unaffected).
- Random wilderness Lord promotions are capped at one per population sweep: when a dense horde's cell loaded, every zombie in it rolled in the same minute, and multiplayer QA saw eleven Lords rise in a single frame from one packed basement horde.
- Raise the Dead's manual `IsoZombie.new` fallback is disabled on dedicated servers: a hand-rolled zombie is never registered with the server's net-sync, so it would have been invisible and unhittable for every client. The primary `addZombiesInOutfit` path (which syncs internally) is unaffected.

## [1.0.0] - 2026-07-09

First public release, developed and tested against Project Zomboid Build 42.19.

### Added

- **Daytime Photophobia** — zombies caught in direct outdoor sunlight are slowed to the weakest shamble and actively retreat to deep interior shelter; sheltered zombies hold position instead of wandering back into the sun. Cloud gloom and heavy fog shield outdoor zombies.
- **Sunburn Damage** (optional, off by default) — exposed zombies slowly burn to death, with configurable tick rate and damage.
- **Nightfall Mutation** — between dusk and dawn the horde becomes fast sprinters with maximised sight, hearing, and tracking memory; everything reverts at sunrise. Day/night boundary hours are configurable.
- **The Zombie Lord** — a rare (default 0.5%) alpha zombie:
  - Immune to daylight, with a configurable health multiplier (default 10×).
  - Dressed in skull mask, bone armour, black robe, and combat boots — all vanilla items, lootable from its corpse.
  - Blood-red highlight tint and an eerie red ground glow (client-side, toggleable).
  - Long-range prey sense: stalks slowly toward the closest survivor from up to 400 tiles (configurable), gathering every zombie it passes into an escort pack.
  - Broadcasts a spotted player's position to the horde for coordinated swarms.
  - Calls thick fog while engaged, shielding its horde from the sun.
  - Opens unlocked doors regardless of world Cognition lore (toggleable).
  - **Raise the Dead** — once per configurable cooldown, resurrects nearby corpses into fresh zombies at reduced health.
  - Boss loot: a slain Lord's corpse carries two distinct rolls of rare high-value gear.
- **23 sandbox options** covering every timing, damage, chance, and radius value, with English labels and tooltips.
- Client-side flavour: day/night transition banners and a proximity warning when a Lord is commanding the dead nearby.

[1.1.0]: https://github.com/CosmicQ/pz-nocturnal-reign/releases/tag/v1.1.0
[1.0.0]: https://github.com/CosmicQ/pz-nocturnal-reign/releases/tag/v1.0.0
