# La Taverne

A World of Warcraft addon (the `LaTaverne/` folder) for dungeon groups, availability and guild chat
shared with allied guilds. The game runs Lua 5.1. `README.md` is for players, `GUILD-RELAY.md`
explains the guild relay, `TESTING.md` lists what still needs testing in game.

## Before opening a pull request

Both checks must pass. GitHub runs them on every push and pull request too.

1. **luacheck**: `luacheck LaTaverne` from the repo root (config: `.luacheckrc`). It catches a
   misspelled name, which the game would only show as a nil error while playing. A new game
   function or global goes in `read_globals` in `.luacheckrc`: check it exists in the game first,
   a typo looks the same. Install: the `luacheck.exe` of a release at
   https://github.com/lunarmodules/luacheck/releases, or `luarocks install luacheck`.
2. **Relay simulator**: `luajit tests/run.lua`. Players of several guilds log in, fight, leave and
   disconnect, and the guild relay must keep one relay per guild and job. Needed for any change
   to `Relay.lua`, and to what it calls in `Comm.lua`. For a change to the election, run more
   seeds (`--seeds 20`). How it works: `tests/README.md`.

Neither replaces trying the change in game (`/console scriptErrors 1`, then `/taverne errors`).

## Code

- Every file starts with `local ADDON, ns = ...`; modules are `ns.NewModule("Name")`.
- Player-facing text goes through `L["..."]`, with its French in `Locale.lua`.
- Text stays guild-neutral: other guilds use the addon too.
- Saved variables (`LaTaverneDB`), addon message prefixes and the `LT:` lines in the Guild Info
  never change name: players on older versions depend on them.
