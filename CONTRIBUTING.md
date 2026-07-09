# Contributing to Nocturnal Reign

Thanks for your interest! Bug reports, balance feedback, compatibility reports (especially multiplayer/dedicated-server), and pull requests are all welcome.

## Reporting bugs

Open an issue with:

- Your exact game version (e.g. `42.19.0`) and whether it's single-player, splitscreen, or a dedicated server.
- The relevant `[NocturnalReign]` lines from `~/Zomboid/console.txt` (Windows: `C:\Users\<you>\Zomboid\console.txt`). The mod logs a heartbeat on load and once per in-game hour, plus every Lord promotion, fog call, Raise the Dead cast, and Lord death — those lines usually pinpoint the problem immediately.
- Your Nocturnal Reign sandbox settings if they differ from defaults.

## Development setup

There is no build step — the repository *is* the mod, laid out in Build 42's versioned Workshop format (`Contents/mods/NocturnalReign/42/...`). The fastest loop:

1. Symlink the mod folder into your mods directory:
   ```sh
   ln -s /path/to/pz-zombie-lord/Contents/mods/NocturnalReign ~/Zomboid/mods/NocturnalReign
   ```
2. Enable the mod in-game and load a save.
3. Edit Lua, then reload the save to pick up changes.
4. Watch the log while you play:
   ```sh
   tail -f ~/Zomboid/console.txt | grep NocturnalReign
   ```

Debug mode (`-debug` launch option) is invaluable: the debug menu lets you edit sandbox vars live (the mod re-reads them every call, no reload needed), spawn hordes, and teleport. To force-test Lord behaviour, temporarily set **Zombie Lord Chance** to `100`.

## Layout and where things live

All paths below are relative to the version folder, `Contents/mods/NocturnalReign/42/`:

| File | Runs on | Contains |
|---|---|---|
| `media/lua/shared/NocturnalReign_SandboxOptions.lua` | both | Option accessors, day/night test, ModData key registry |
| `media/lua/server/NocturnalReign_Server.lua` | server¹ | **All gameplay**: photophobia, night mutation, the Lord |
| `media/lua/client/NocturnalReign_Client.lua` | client | Cosmetics only: glow, lights, warning banners |
| `media/sandbox-options.txt` | — | Sandbox schema |
| `media/lua/shared/Translate/EN/Sandbox_EN.txt` | — | Option labels and tooltips |

¹ Including the embedded server inside a single-player game.

Repo-root files (`workshop.txt`, `preview.png`, and everything outside `Contents/`) are Steam Workshop metadata and project docs — the game never loads them.

## Releasing to the Steam Workshop (maintainers)

The repo root is already shaped as a Workshop staging folder. Symlink it into the game's Workshop directory and use the in-game uploader:

```sh
ln -s /path/to/pz-zombie-lord ~/Zomboid/Workshop/NocturnalReign
```

Then **Main menu → Workshop → Create/Update item**. After the first upload the game writes the assigned Workshop `id=` into `workshop.txt` — commit that change so future updates target the same item.

## Code conventions

These are load-bearing — please keep to them:

- **Gameplay stays server-side; the client only reads.** Client code must never mutate simulation state. If a feature needs both sides, the server writes ModData and the client reads it. All shared ModData key names live in `NocturnalReign.ModDataKeys` — never inline a key string.
- **Never hook `OnZombieUpdate`.** It fires per zombie per tick. Population-wide passes belong in the `EveryOneMinute` sweep; only the rare Lords get the ~1-second `OnTick` cadence.
- **Probe unstable APIs, don't hard-code them.** Build 42 has renamed per-zombie setters between patches. Use `trySetters()`/`tryGetters()` with a candidate list so a missing method degrades to a no-op instead of an error.
- **`pcall` around engine calls in hot or render-path code**, so one build-specific quirk can't take down a whole sweep.
- **Comment the *verification*, not the *what*.** The most valuable comments in this codebase record which vanilla file or decompiled class an API usage was verified against (e.g. "signature verified against the 42.19 HaloTextHelper class"). If you use an engine API in a non-obvious way, say where you confirmed it works.
- **New tunables get the full treatment:** an entry in `media/sandbox-options.txt`, a matching default in the shared `DEFAULTS` table, an accessor in `NocturnalReign.Options`, and a label + tooltip in `Sandbox_EN.txt`. The defaults in the two places must agree.

## Adding a sandbox option (checklist)

1. `media/sandbox-options.txt` — add the `option NocturnalReign.YourOption { ... }` block.
2. `NocturnalReign_SandboxOptions.lua` — add to `DEFAULTS` (same default!) and add an `Options.getYourOption()` accessor.
3. `Sandbox_EN.txt` — add `Sandbox_NocturnalReign_YourOption` and `_tooltip` entries.
4. Read it only through the accessor, never through `SandboxVars` directly.

## QA before opening a PR

There is no automated test harness (the mod is pure engine integration), so a manual pass matters:

- Load a save with the change, confirm the `[NocturnalReign] Server module loaded` and sweep heartbeat lines appear, and play through at least one full day/night transition.
- If you touched Lord logic: set Lord chance to 100, confirm the regalia, glow, stalking, pack gathering, fog, and Raise the Dead still behave, and that killing the Lord drops loot and lifts the fog.
- Confirm `console.txt` shows no new Lua errors.
- Note in the PR which game version you tested against.

## Commit style

Short imperative subject lines describing player-visible behaviour, matching the existing history (e.g. `Lord opens unlocked doors (EnableLordDoorUse toggle)`).
