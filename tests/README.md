# Relay simulator

The guild relay (`LaTaverne/Relay.lua`, explained in `GUILD-RELAY.md`) elects one player per guild
and job (chat, map) to pass things on to the allied guilds. Getting that wrong rarely shows on one
PC: it takes several players logging in, fighting, entering dungeons and leaving. The simulator
plays that out of the game, in a few seconds.

```
luajit tests/run.lua                         every scenario, seeds 1 to 3 (a few seconds)
luajit tests/run.lua --seeds 20              more seeds, for a change to the election
luajit tests/run.lua --only "busy" -v        one scenario, with its figures
luajit tests/run.lua --seed 7 --only "busy" --trace   every relay event, to see why
```

It needs Lua 5.1 or LuaJIT, the game's Lua: LuaJIT from your package manager (`winget install
DEVCOM.LuaJIT`, `apt install luajit`, `brew install luajit`). The exit code is 1 when a scenario
fails. GitHub runs it on every push and pull request.

## How it works

- `sim/world.lua`: a simulated clock and timers, the guild channel and the alliance channel (with
  latency, and losses when a scenario asks for them), and the players. Each player loads the real
  `Relay.lua`, in its own environment: the game's API and the other La Taverne modules are small
  fakes. A fake that's missing (the relay now calls something new) stops the run with
  `simulator: ... has no fake`: add it there.
- `sim/scenarios.lua`: what happens (logins, logouts, disconnects, fights, dungeons), and what must
  hold, checked every simulated second for each guild and job:
  - **two holders**: how long two players held the job at once (they missed each other's claims);
  - **no holder**: how long nobody held it while someone could;
  - **split**: how long the guild's players didn't all name the same holder;
  - **unseen by allies**: how long the allied guilds didn't see that holder;
  - **changes**: how many times the job changed hands.
- `run.lua`: runs them and prints `ok`, `FAIL` (a limit passed: the figures follow) or `KNOWN`.

The same seed always plays the same way: a failure seen once can be traced (`--seed N --trace`)
until it's understood.

## Known limitations

A `KNOWN` scenario shows something the relay doesn't handle yet. It's printed and never fails the
run. Once the relay handles it, remove `known = true`, so it can't come back.

- **Holder fighting when someone logs in**: in a fight, the holder sends nothing (the game would
  hold it). So it doesn't answer a newcomer asking who relays, nor beacon back at a claim. The
  newcomer takes the job, and the holder steps down: a needless handover, and two holders until
  the holder's next beacon (up to a minute). The busy evening scenario allows for it.
- **Holder's alliance messages lost**: the holder's alliance channel looks fine, but its messages
  don't arrive. Its own guild still hears it on the guild channel, so nobody takes over, and the
  allied guilds see no relay for that guild.

## Adding a scenario

Copy one in `sim/scenarios.lua`. `Settled()` gives two guilds with everyone logged in and the jobs
taken. Players: `c:Login()`, `c:Logout()` (the normal way, with the countdown), `c:Drop()` (game
closed), `c:Fight(seconds)`, and the fields `inInstance`, `inRaid`, `resting`, `away`,
`faults.allyOutLost` (its alliance messages never arrive), `faults.allyInLost` (it never gets
any). `w:After(seconds, fn)` plans something, `w:Run(seconds)` plays it. End with `Check(rec, limits)`.
