# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
