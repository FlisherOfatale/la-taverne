# Guild relay: handover notes

Status (2026-11-21): **phase 1 (guild chat) written and reviewed, not tested in game yet.**
Phases 2 and 3 and a second pass on phase 1 are still to do (see "What's left"). These notes are
for whoever continues (Oylex or Flisher). Not in the addon zip (`.pkgmeta` ignores this file).

## What it does
Today an allied guild only sees the guild chat of players who run La Taverne: each player's own
addon shares their lines. The relay fills in for the others: in each guild, one La Taverne player
(the **relay**) passes on the guild lines of members **without** La Taverne to the allied guilds.

- Relayed lines look exactly like other allied lines (tag, lynx, links rebuilt).
- One direction only: nothing is ever written in the real guild chat.
- On by default. Each player can opt out (Options), each guild's officers can turn it off for
  the whole guild (Guild Info line, Setup page).
- Players with La Taverne still send their own lines as before; the relay only covers the others.
- Old versions never see any of it (new prefix, never registered by them).

## How it works (short)
- **Prefix** `LaTaverneR`, on the alliance channel, same checks as `LaTaverneA` (its own message
  budget, so groups, positions and chat of La Taverne users are never slowed down).
- **Jobs**: each job has its own relay per guild. Only `chat` exists now; `map` is phase 2.
- **Tier** (each client for itself, nothing broadcast): 0 city (resting), 1 world, 2 fought in
  the last 5 min, 3 last resort (raid group, or away 20 min). **Can't**: switch off, officers'
  line off, Guild Info not read yet, alliance or channel not ready, allied chat off, a newer
  relay protocol in the guild (heard in the last 10 min), in an instance, logging out.
  A fight never makes a relay give up: sending waits until it's over.
- **`RLY` messages**: `ask` (I just joined: holders answer with a beacon, at most every 3 s),
  `claim` (after a delay by tier: offset + tier × 3 s + 0.5 s unless held lately + 0-1.5 s by a
  name hash), `hold` (beacon every 60 s, lease 150 s), `off` (planned handoff, with a reason).
  After claiming, 2 s to settle, then everyone applies the same order (newest protocol, tier,
  held lately, hash, name): the best takes the job and beacons. No beacon within 15 s: the round
  starts again. Challenge (`ch = 1`): a candidate 2 tiers better than the holder for 2 min asks
  for it. Two holders: the worse one (by their last beacons) stops silently.
- **Chat job**: every candidate keeps the guild lines of the last 60 s (40 lines; 180 s / 100
  in or after a fight). A line is covered by the author's own `CHAT` or any `RCHAT` (same author,
  same text key, within 10 s; or, if no text matches, the author's oldest owed line within 10 s:
  the profanity filter changes the lines a player gets). The holder sends what's owed (`RCHAT`)
  from its own queue: 8 at once then 1 a second, a long line counts 2. For an author who runs La
  Taverne it waits 5 s for their own copy first.
- **Stall watch**: a line owed 8 s while the holder was silent 5 s opens one election per line
  (void if the holder is heard again); a new holder replays what's owed. **Gap fill**: the
  holder is alive but missed a line (owed 15 s + tier × 3 s + 0-6 s): one watcher sends just that
  line. Holder offline in the roster (and silent 5 s), or lease over: election.
- **Receivers** (`AllyChat.lua`): author name checked (no codes, ≤ 48 bytes), not my guild, time
  clamped to ±5 min, copies dropped (guild + author + text key within 10 s), then at most 90
  relayed lines a minute per guild, then the ignore list.
- **Guild Info line** (each guild, for its own members, written by the Setup page like `LT:ai`):
  no line = every job; `LT:r:off` = nothing; `LT:r:chat` = only these jobs. Not exported.
- **Hellos** (`HI`, already on the alliance channel) now also count my guildmates as running La
  Taverne, and carry `afk`, `rl` (switch on), `cap` (jobs it can do), `rp` (relay protocol).

## Where it lives
| File | What |
|---|---|
| `Relay.lua` (new) | tiers, elections, beacons, chat job (buffer, queue, stall, gap fill), status, switch + popup, `/taverne relay` |
| `Comm.lua` | `LaTaverneR` prefix; my guild's `HI`, `CHAT`, `RCHAT`, `RLY` on the alliance channel go to the guild handlers; message log counters |
| `AllyChat.lua` | `TextKey`, copy check for `CHAT` and `RCHAT`, `RCHAT` receive checks and flood cap, test-mode fake member |
| `Alliance.lua` | `LT:r` parse / write, `RelayAllows`, `IsInfoKnown` |
| `Vouch.lua`, `Players.lua` | hello fields, `GetGuildHellos`, `RunsAddon` |
| `UI.lua` | Setup page "Guild relay"; Alliance page relay rows (and "You"); Options "Help relay for my guild" |
| `Minimap.lua` | speech-bubble badge while I relay; one tooltip line per guild |
| `Core.lua`, `Locale.lua` | `relay = { help, told }` defaults; every string in French |
| `Dev.lua`, `Tests.lua` | `/taverne dev say`; `/taverne probe` (phase 0 measurements) |

## Commands
- `/taverne relay`: the full report in the copy window (me, every guild's relay, my view of the
  election, buffer, queue, counts). Paste it when reporting a problem.
- `/taverne probe`: phase 0 measurements (chat readable or secret, throttles, logout, resting).
- Test mode: `/taverne dev say Firstname Lastname: text`: a test guild member without La Taverne
  says a line (the relay passes it on). Only the test guild's fake chat is relayed in test mode,
  never the real guild chat.

## Testing (not done yet)
1. Two PCs in the same test guild, a third in an allied test guild (or 2 PCs, one per guild),
   `/console scriptErrors 1`.
2. One candidate alone holds the job within ~15 s ("You're relaying..." line once, badge,
   Alliance page row); with two, exactly one holds (`/taverne relay` on both).
3. `/taverne dev say ...` shows once on the allied PC; the authors' own lines also show once.
4. Handoffs: switch off (popup), `/reload`, logout, raid group, instance: the other takes over,
   lines said meanwhile are replayed.
5. Holder in a fight: lines wait, no takeover if it's back quickly; holder's game killed: the
   other takes over after a line is owed ~13 s.
6. Officers: Setup page, untick "Guild chat", paste the Guild Info: nobody relays, allies see
   "turned off by the officers".
7. Profanity filter on one PC (real guild): a La Taverne author's swear word shows once on the
   allied side.
8. Bring back `/taverne relay`, the message log and `/taverne errors` from each PC.

## What's left
**Phase 2: map relay.** Dots on the allied guilds' maps for members without La Taverne.
- A `map` job in `Relay.lua` (state kind: one batch every 10 s with the changes, everything
  every 60 s, `off` after 150 s without news), claim offset +5 s, the chat relay counts one tier
  worse when claiming it (jobs spread over players).
- Source: register OpenMap's prefix `OpenMapLoc` (works without OpenMap installed); skip players
  who run La Taverne (they send their own `POS`); parse defensively (not a public format).
- `RMAP` on its own prefix (`LaTaverneM`), BULK priority; `AllyMap.lua` draws them as allied dots.
- Its own box on the Setup page (`LT:r:chat,map`), status rows, tooltip.

**Phase 3, only if testing shows a need.** A compact format instead of AceSerializer; several
waiting lines packed in one message; catch-up: the last 30 min of allied lines for a player who
just logged in (one answer for everyone who asked in the same 10 s).

**Second pass on phase 1.**
- Witnesses: guildmates check the relay's lines against their own guild chat (`RLY bad`, two
  confirmed witnesses needed); mute a relay locally.
- Relays: only Vouch-confirmed (or unverified, an option) relays accepted by receivers.
- A holder that stalled twice in 10 min skipped for 30 min (the same rule everywhere).
- Saving the buffer and queue at logout / `/reload`, sent at login if under 60 s old.
- `LT:rv:N`: minimum relay protocol in a guild (officers), repeated in the beacon.
- 48 h history per hour (lines, coverage, queue, budget, minutes without a relay); warnings in
  the message log; a relay panel in the Debug tab.
- Authors could stop sending their own `CHAT` once no old receivers are left (only then: an old
  receiver can't read `RCHAT`).
- Maybe: a minimap ring when a guild has no relay (dropped for now: players can't act on it).

**Known and kept as is.**
- The same author repeating a line within 10 s ("+1" twice) shows once on the allied side.
- The author-and-time fallback of the copy check can cover the wrong line of one author if the
  holder and a watcher each miss a different line of that author within 10 s.
- Right after a login, the count of others who can relay is incomplete for ~5 min (guildmates
  don't answer my hello): the Stop popup and the Alliance page say so.
