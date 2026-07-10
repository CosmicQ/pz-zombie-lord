# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- **Territorial Lords** — every major town is now the domain of its own named Zombie Lord ("The Lord of Rosewood", "The Lord of Louisville"), the first phase of a Valheim-style boss progression:
  - 12 built-in territories across the Build 42 map, each with a difficulty tier (1–4). Tier scales the Lord's health (+25% per tier above 1); Louisville is the endgame domain.
  - A town's Lord rises when a survivor first enters its territory, and is leashed to it — it stalks prey within (and slightly beyond) its borders and walks home instead of being kited across the map.
  - **Liberation** — slaying a town's Lord liberates the town: its zombies no longer mutate into night sprinters (toggleable), and the Lord stays dead forever or respawns after a configurable number of days.
  - Campaign state (which towns are liberated, and when) persists in world ModData across saves and server restarts.
  - Random roaming Lords still spawn, but only in the wilderness between towns.
- New shared zone module (`NocturnalReign_Zones.lua`) with a pluggable backend seam, designed for a future integration with the "More Difficult Zones" mod so bosses can follow admin-drawn zones.
- 3 new sandbox options: **Enable Territorial Lords**, **Territorial Lord Respawn (days)**, and **Liberation Calms the Night**.

- **Tier-scaled boss loot** — a slain Lord's corpse now pays 1 + zone tier distinct loot bundles (wilderness Lords: 2), from an expanded table: katana, assault rifle/shotgun/hunting rifle with ammo, sledgehammer, machete + hunting knife, gold bar + gold necklace, and an army ALICE pack stocked with medical supplies.

### Fixed

- Constant console exception spam (and the in-game error icon) while a Lord was active: the per-tick attempt to write `IsoZombie.cognition` always throws on 42.19 — Kahlua rejects raw field writes and the build has no `setCognition` method. The write is now a silent one-time capability probe; Lord door-use is dormant until the game exposes a per-zombie cognition API, and the console says so once per session.
- The Lord's regalia now actually renders: B42 zombies draw their model from a named outfit, not from worn inventory items, so the Lord dresses in the game's bone-armour outfit (`ArmorTest_Bone`, top hat included) with hooded `Cultist` robes as the female-model fallback. The skull-and-bone worn items remain in inventory as lootable trophies.
- Duplicate territorial Lords: a Lord whose chunk unloaded was replaced instantly (QA saw six Lords of Rosewood at once); a lost Lord now gets a 12-in-game-hour grace window to resurface before a replacement rises.

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

[1.0.0]: https://github.com/CosmicQ/pz-zombie-lord/releases/tag/v1.0.0
