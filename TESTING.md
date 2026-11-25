# Tests still to run in game

Everything here is written but not yet tested in game (the code is checked with luacheck, and the
guild relay's elections with the simulator in `tests/`, but only the game shows the rest). Tests are in priority order: what one player can check alone first,
then what needs a second player running this version. Once a test passes, move it to "Done" in
one line; write down what you saw when it doesn't.

**Before testing:** `/console scriptErrors 1`. After: `/taverne errors`, and for relay tests
`/taverne relay` and `/taverne msglog` on each PC. Test mode (`/taverne test`) uses a private
channel instead of the real guild, so two PCs (or two accounts) in two test guilds can try
everything. A new file in `media/` needs a full game restart, not just `/reload`. How the relay
works and how to set up its tests: `GUILD-RELAY.md`.

To start the vouching tests from a clean slate (keeps every setting):
`/run LaTaverneDB.rosterSnapshots = nil; LaTaverneDB.vouchLedger = nil; ReloadUI()`

## 1. Alone: essential (stability, and the new features doing their main job)
- [ ] Away check (nothing to set up, just play with script errors on): no "secret boolean" error
      from `Vouch.lua` or `Players.lua` after fights and boss encounters.
- [ ] Advanced mode (Options, General): ticked, a small tab with a flare shows right of the
      Alliance tab (not over it, not far from it; Mind vision or a torch if the client has no
      flare), a green dot on it while you relay; unticked, it's gone, and the relay page, if it
      was open, gives way to the Alliance page.
- [ ] Relay page: the guild cards fit (in French too), the folds open and close, the tooltips
      (job rows, the badge, the counts) show, Copy report opens the text over the window.
      `/taverne relay` opens the page without Advanced mode.
- [ ] Minimap button's tooltip: each guild's relay line shows both jobs (chat and map).

## 2. Alone: useful, not urgent
- [ ] Probe: `/taverne probe roster` with the guild window's "show offline members" box unticked
      (are offline members still readable? if not, an alt's snapshot is partial).
- [ ] Probe: `/taverne probe who Firstname Lastname` twice within a few seconds: does the second
      get results, or a "wait" line (the server's limit)? Needed before vouching phase 2.
- [ ] Away check: `/afk` and back, out of combat: the relay counts ("N away") follow.
- [ ] Guild relay: right after a `/reload`, the Alliance page "You" row tooltip (and the stop
      popup) say "Probably N more..." for guildmates seen with La Taverne before; after 5
      minutes, only those who said hello count.
- [ ] Vouching: after 7 days without seeing a player (1 day for what others told me), their
      record expires.

## 3. With a second player: essential
Needs two players **in the same guild**, both on this version (the tests across two guilds
passed: see "Done").
- [ ] Guild relay, two candidates: exactly one relays (`/taverne relay` on both).
- [ ] Relay page, same guild: a handover shows as a planned holder change, a killed game as
      unplanned; the other candidate shows in "Who can relay" within 5 minutes.
- [ ] Guild relay: `/taverne dev say Firstname Lastname: text` (test mode) shows once on the
      allied PC; the La Taverne players' own lines also show once (no double line).
- [ ] Guild relay, handover: switch "Help relay for my guild" off (popup first), `/reload`, log
      out, join a raid group, enter an instance: the other candidate takes over, and lines said
      meanwhile are sent late (not lost).
- [ ] Guild relay in a fight: lines wait, nobody else takes over if the fight is short. The
      relay's game killed: the other takes over (~13 s after a line is owed).
- [ ] Relayed line mark: a relayed line shows a grey lynx instead of the gold one (full game
      restart first: new file `media/lynx_icon_grey.tga`), and once the line "Allied lines
      marked ... can't see your answers".
- [ ] Vouching: someone in my group claiming a guild the game doesn't show for them: denied,
      with one chat line saying why, and a hidden-message count on their Alliance page row.
- [ ] Vouching: auto-invite in "Right away" mode: an allied player not checked yet (or disputed)
      is queued for a click, not invited.

## 4. With a second player: later
- [ ] Map job, dots: on the allied side, a relayed dot's tooltip says "Shares through OpenMap · passed on by ...", it
      moves about every 30 s, and it's gone within ~10 s once that player stops sharing.
- [ ] A chat line sent again (relay page, Your sending: "sent again" above 0): the allied side
      shows it once.
- [ ] Relayed line mark: the guild window (Communities) and the test guild window show the same
      mark, also after closing and reopening them. With Chattynator: the mark shows there too.
- [ ] Guild relay, real guild, profanity filter on for one player: a La Taverne author's swear
      word shows once on the allied side.
- [ ] Probe: `/taverne probe guildlines` on while someone joins, leaves or is removed from the
      guild: do the lines match (in English and French clients)?

## Done
- 2026-11-22: guild relay across two real guilds, one relay each side ([NDQ] and [NDQA]): 12
  relayed lines and 176 relayed map positions received from the other guild, none refused; each
  side sees the other relay's figures from its beacon ("last minute", budget, throttled); players
  with La Taverne are never relayed (their own places skipped: 1445 from 60 players).
- 2026-11-22: refused messages in play: game code 8 (channel throttle) on chat lines and
  coordination, mostly in the seconds after taking both jobs; code 9 (general error) twice on a
  holder's signal. Chat lines sent again (2), none lost.
- 2026-11-22: an early test build of the relay in [NDQ] (chat only): it holds that guild's chat,
  its beacon has no load figures and its hello no tier ("tier not said"); [NDQ]'s map then has no
  relay. No errors on either side.
- 2026-11-22: guild relay live window (now the relay page's Copy report), alone, test mode and
  the real guild: fills itself every 3 s (pauses under the mouse), Copy selects it all, you
  counted per tier, your sending and the last events shown; real guild: guild lines counted, 9
  OpenMap sharers without La Taverne relayed (map about 8 % of the game's limit), 47 La Taverne
  users skipped.
- 2026-11-22: map job, alone (test mode, `/taverne dev walk`, a pretend ally in the test Guild
  Info): you hold "Map positions" with chat, places heard every 10 s, a position passed on about
  every 30 s, a stop counted, map budget 5 %, nothing refused. (No dot on your own map: by design.)
- 2026-11-22: vouching, marks in lists: after the clean slate, allied players "online, not
  checked yet"; a nameplate turns one "confirmed" live, no `/reload`.
- 2026-11-22: minimap tooltip: one relay line per guild ("you (city)" for mine, orange "nobody"
  where La Taverne players are online, white elsewhere), "Relaying: Guild chat".
- 2026-11-22: vouching, an alt's guild roster confirms that guild's members on another
  character: tooltip "Seen in [NDQ] by <alt> (guild roster), 7 min ago."
- 2026-11-22: guild relay, one candidate alone takes the relay (after a game restart).
- 2026-11-22: loads without errors in two guilds of the alliance and with no guild (enUS).
- 2026-11-22: vouching, an allied player's nameplate confirms their guild: green check,
  "confirmed", tooltip "Seen in [NDQ] by <my character> (nameplate), just now."
- 2026-11-22, probes: `/who` from a typed command works, from a timer is blocked, from a click on
  a chat link works; exact names with spaces, any case; the guild comes back exactly; the Who
  window stays closed. Nameplates and mouseover give the guild of players outside my group (nil
  = no evidence, sometimes the guild comes 1 s later). The roster lists offline members (box
  ticked). Guild addon messages name the sender "Firstname Lastname".

## Not tested on purpose
Settings switches (the officers' "Guild chat" box in the Guild Info, the relayed-line mark and
lynx options): left to players to report if one doesn't work.
