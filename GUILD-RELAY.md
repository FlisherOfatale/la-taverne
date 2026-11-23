# Guild relay: handover notes

Status (2026-11-22): **phase 1 (guild chat), phase 2 (map) and the monitoring work in the real
guilds:** one relay per guild, each side receiving the other's relayed lines and map positions.
Still to test with two players in the same guild: handovers, fights, the choice of one relay
among several (`TESTING.md`). Phase 3 and a second pass on phase 1 are still to do (see "What's
left"). These notes are for whoever continues (Oylex or Flisher). Not in the addon zip
(`.pkgmeta` ignores this file).

## What it does
Today an allied guild only sees the guild chat of players who run La Taverne: each player's own
addon shares their lines. The relay fills in for the others: in each guild, one La Taverne player
(the **relay**) passes on the guild lines of members **without** La Taverne to the allied guilds,
and (map job) the map positions of members without La Taverne who share them through OpenMap.

- Relayed lines look exactly like other allied lines (tag, lynx, links rebuilt).
- One direction only: nothing is ever written in the real guild chat.
- On by default. Each player can opt out (Options), each guild's officers can turn it off for
  the whole guild (Guild Info line, Setup page).
- Players with La Taverne still send their own lines as before; the relay only covers the others.
- Old versions never see any of it (new prefix, never registered by them).

## How it works (short)
- **Prefix** `LaTaverneR`, on the alliance channel, same checks as `LaTaverneA` (its own message
  budget, so groups, positions and chat of La Taverne users are never slowed down).
- **Jobs**: each job has its own relay per guild: `chat` (prefix `LaTaverneR`) and `map`
  (prefix `LaTaverneM`, claim offset +5 s). Holding one job makes a candidate one tier worse
  for the other, so they spread over players.
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
| `Relay.lua` (new) | tiers, elections, beacons, chat job (buffer, queue, stall, gap fill), status, switch + popup, monitoring, the text report and `WindowData` (the page's figures), `/taverne relay` |
| `RelayPage.lua` (new) | the relay's page in La Taverne's window: guild cards, counts since login, Your guild / Your sending / Events folded, Copy report |
| `Comm.lua` | `LaTaverneR` prefix; my guild's `HI`, `CHAT`, `RCHAT`, `RLY` on the alliance channel go to the guild handlers; message log counters |
| `AllyChat.lua` | `TextKey`, copy check for `CHAT` and `RCHAT`, `RCHAT` receive checks and flood cap, test-mode fake member |
| `Alliance.lua` | `LT:r` parse / write, `RelayAllows`, `IsInfoKnown` |
| `Vouch.lua`, `Players.lua` | hello fields, `GetGuildHellos`, `RunsAddon` |
| `UI.lua` | Setup page "Guild relay"; Alliance page relay rows (and "You"); Options "Help relay for my guild" and "Advanced mode"; the relay's small tab beside Alliance (Advanced mode) |
| `Minimap.lua` | speech-bubble badge while I relay; one tooltip line per guild, both jobs |
| `Core.lua`, `Locale.lua` | `relay = { help, told }` and `advanced` defaults; every string in French |
| `Dev.lua`, `Tests.lua` | `/taverne dev say`; `/taverne probe` (phase 0 measurements) |
| `Comm.lua` | `lastSend` (parts and bytes of the last send), `WatchParts` (ChatThrottleLib's callback: parts held back or refused, with the message's type), a chat line refused by the channel throttle sent again once |
| `DebugUI.lua` | "Guild relay" button (opens the relay's page) |
| `AllyMap.lua` | `RMAP` receive: relayed dots (allied guilds only, 300 s lease, never over a player's own `POS`), "Passed on by" tooltip line |
| `Comm.lua`, `Vouch.lua` | `LaTaverneM` prefix; my guild's `RMAP` read by the relay only; `RMAP` passive ("quiet") for vouching |
| `Dev.lua` | `/taverne dev walk` (test mode: a fake OpenMap sharer) |

## Map job
- **Source**: OpenMap's own messages to the guild (`OpenMapLoc`, `L1 map x y class level`
  tab-separated, `L0` stopped), heard by every candidate; La Taverne registers the prefix, so
  OpenMap needn't be installed on the relay. Players who run La Taverne are skipped: they share
  their own place (`POS`). Test mode: never the real guild's; `/taverne dev walk` stands in.
- **Batches** (`RMAP`, BULK): at most every 10 s, 20 players most recently moved first. A player
  is in it when moved more than 1 % of the map since the place last passed on (at most every
  30 s), or still (every 120 s); everyone with class and level every 180 s and when a new holder
  takes the job. `d = "name,map,x,y[,class,level];..."` (x, y: 3 base-36 digits), `o` the names
  that stopped (L0, or no word for 150 s), `q` players still due, `rp`.
- **Busy** (map prefix ≥ 70 % of the game's 1 message a second): steps doubled at once, back to
  normal under 50 %; still ≥ 70 % 2 min later, the map job is handed over (`why = busy`) and not
  claimed back for 10 min. The chat prefix being busy never hands the map job over: it has its
  own prefix, so that wouldn't lighten chat.
- **Stall**: a watcher hears places come in while the holder is silent 90 s (it beacons every
  60 s): stall election, void if the holder is heard again.
- **Receivers**: allied guilds only (my own guild sees OpenMap's own dots, faster). Relayed dots
  last 300 s and glide like the others; a player's own fresh `POS` always wins; refused: names in
  my guild, bad values. They count as allied players' OpenMap sharing (`om`), so my own OpenMap
  drawing a friend keeps one dot.
- **Officers**: the Setup page has a "Map positions" box next to "Guild chat" (`LT:r:chat` = chat
  only).

## Monitoring
- Each client measures its own sending on the relay prefix: messages (parts) and bytes over the
  last 10 s, minute and 10 min, budget % (messages in the last minute against the game's 1 a
  second), the busiest minute, messages per line, the coordination share (`RLY` among all), and
  parts ChatThrottleLib held back 1 s or more, or refused (throttled).
- Budget per prefix (the game limits each prefix on its own). Chat at 70 % or more for 2 min:
  one warning, marked "!!" in the message log; nothing is handed over (chat queues). Map: see
  "Map job".
- The beacon carries `sent`, `mq`, `b` (bytes), `p` (parts), `th` (throttled) since the previous
  one: every guild sees every relay's load.
- The hello carries `tr` (tier for chat, 0-3, or `x` and `tw` why): the count of candidates per
  tier. Only in hellos sent anyway, never one just because the tier changed.
- Stability, from the beacons heard: uptime this hour (fresh beacon while that guild has a La
  Taverne player online), holder changes (planned: after an `off`; unplanned: it went quiet), and
  relays lost with nobody taking over (a guild that had a relay, none for 30 s while it has La
  Taverne players online).
- **Refused messages.** ChatThrottleLib waits and tries again only for the add-on message limit
  (result 3). Anything else the game refuses is dropped: seen in play, 8 (channel throttle, in
  bursts, e.g. right after taking both jobs) and 9 (general error). Refusals are counted per job,
  message type (chat line, map batch, claim, holder's signal...) and result code; a chat line
  counts once however many of its parts were refused. A chat line (`RCHAT`, and an author's own
  `CHAT`) refused by the channel throttle goes out once more, whole, 2 s later; receivers drop
  it if the first one came through (same message number). Map batches and coordination aren't
  sent again: the next batch or beacon replaces them. Counted: lines hit, sent again, refused
  again (lost for the allied guilds).

## Seeing it
- **Everyone:** the Alliance page's relay rows (each guild, each job) and the minimap button's
  tooltip (`[TAG] Relay: chat: who (tier) · map: who (tier)`; "nobody" in orange when that guild
  has La Taverne players online).
- **Advanced mode** (Options, General, off by default): a small tab with a flare beside the
  Alliance tab, opening the relay's page (`RelayPage.lua`): one card per guild (who holds each
  job, tier, uptime bar, budget, held back or refused; one line for a player holding both jobs,
  with their messages a minute; refusals in orange, details in the tooltips), the counts since
  login, then Your guild, Your sending and Events, folded. Filled again every 3 s. Copy report
  gives the same figures as text, to paste when reporting a problem. A green dot on the tab
  while I relay.

## Commands
- `/taverne relay` (or the Debug tab's "Guild relay" button): opens the relay's page, also
  without Advanced mode (until another page is shown).
- `/taverne probe`: phase 0 measurements (chat readable or secret, throttles, logout, resting).
- Test mode: `/taverne dev say Firstname Lastname: text`: a test guild member without La Taverne
  says a line (the relay passes it on). Only the test guild's fake chat is relayed in test mode,
  never the real guild chat.
- Test mode: `/taverne dev walk Firstname Lastname`: a test guild member without La Taverne
  shares their place through OpenMap, walking a circle around where you stood (one place every
  10 s); again to stop. `/taverne map` lists the dots, relayed ones with who passed them on.

## Testing
What's done and what's left: `TESTING.md`. The setup and the checks:
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
8. Bring back `/taverne relay` (Copy report), the message log and `/taverne errors` from each PC.
9. Relay page: the allied PC sees the holder's load from its beacon (messages, bytes, budget);
   the candidates per tier fill in within 5 min of a login; a handover counts as planned, a
   killed game as unplanned.
10. Map job: `/taverne dev walk Firstname Lastname` on a PC of one test guild: the allied PC
   shows the dot (`/taverne map`: "relayed by ..."), moving every 30 s or so, gone within 10 s of
   walking again (stop); the relay's own guild shows none from the relay.

## What's left
**Phase 2: map relay.** Works in the real guilds (2026-11-22), see "Map job". Later, only if the
relay page shows a high map budget: short ids instead of names (full refresh carries name,
class, level, id; updates only the id). Allied guilds whose players are all on a version without
the map job show "nobody" (orange) for it on the Alliance page until they update; an early test
build of the relay (chat only, no tier in its hello) shows as "tier not said".

**Tuning, from play.** The relay page marks one player's relay load as busy from 20 messages a
minute (`HEAVY_PER_MIN`) and uptime under 90 % (`UP_WARN`): first guesses.

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
  the message log. (The live figures are on the relay's page.)
- Authors could stop sending their own `CHAT` once no old receivers are left (only then: an old
  receiver can't read `RCHAT`).
- Maybe: a minimap ring when a guild has no relay (dropped for now: players can't act on it).

**Known and kept as is.**
- The same author repeating a line within 10 s ("+1" twice) shows once on the allied side.
- The author-and-time fallback of the copy check can cover the wrong line of one author if the
  holder and a watcher each miss a different line of that author within 10 s.
- Right after a login, the count of others who can relay is incomplete for ~5 min (guildmates
  don't answer my hello): the Stop popup and the Alliance page say so.
