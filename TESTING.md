# Tests still to run in game

Everything here is written but not yet tested in game (there's no Lua on the dev machine: code is
only checked by reading it). Tick a test once it passes in game; write down what you saw when it
doesn't. Remove a section when everything in it passes.

**Before testing:** `/console scriptErrors 1`. After: `/taverne errors`, and for relay tests
`/taverne relay` and `/taverne msglog` on each PC. Test mode (`/taverne test`) uses a private
channel instead of the real guild, so two PCs (or two accounts) in two test guilds can try
everything. A new file in `media/` needs a full game restart, not just `/reload`.

## Guild relay (branch `feature/guild-relay`)
How it works and how to set up the test: `GUILD-RELAY.md`.

- [ ] Loads without errors on every PC, with and without an alliance.
- [ ] One candidate alone takes the relay within ~15 s: "You're relaying..." once, the minimap
      speech bubble, the Alliance page "Relay: Guild chat" row. With two candidates, exactly one
      relays (`/taverne relay` on both).
- [ ] `/taverne dev say Firstname Lastname: text` (test mode) shows once on the allied PC; the
      La Taverne players' own lines also show once (no double line).
- [ ] Handover: switch "Help relay for my guild" off (popup first), `/reload`, log out, join a
      raid group, enter an instance: the other candidate takes over, and lines said meanwhile
      are sent late (not lost).
- [ ] The relay in a fight: lines wait, nobody else takes over if the fight is short. The relay's
      game killed: the other takes over (~13 s after a line is owed).
- [ ] Officers: Setup page, untick "Guild chat", paste the Guild Info: nobody relays, the allies
      see "turned off by the officers".
- [ ] Real guild, profanity filter on for one player: a La Taverne author's swear word shows
      once on the allied side.
- [ ] Right after a `/reload`: the Alliance page "You" row tooltip (and the stop popup) say
      "Probably N more..." for guildmates seen with La Taverne before; after 5 minutes, only
      those who said hello count.

## "Can't see your answers" mark on relayed lines
- [ ] A relayed line shows a grey lynx instead of the gold one (full game restart first: new file
      `media/lynx_icon_grey.tga`), and once the line "Allied lines marked ... can't see your
      answers".
- [ ] Lynx turned off in Options: a grey dot instead. "Mark players who can't see your answers"
      turned off: the line looks like any other allied line.
- [ ] The guild window (Communities) and the test guild window show the same mark, also after
      closing and reopening them.
- [ ] With Chattynator: the mark shows there too.

## Away check (secret value in fights)
- [ ] No "secret boolean" error from `Vouch.lua` or `Players.lua` after fights and encounters
      (it came from checking whether I'm away during a fight). Going away (`/afk`) and back
      still updates the relay counts ("N away") when out of combat.

## Vouching: probes (`/taverne probe ...`, output in `/taverne probe show`)
Done on 2026-11-22: `/who` from a typed command (works; blocked from a timer; exact names with
spaces, any case; the guild comes back exactly; the Who window stays closed), nameplates and
mouseover give the guild of players outside my group (nil = no evidence, sometimes the guild
comes 1 s later), the roster lists offline members, guild addon messages name the sender
"Firstname Lastname".

- [ ] `/taverne probe who Firstname Lastname`, then click the blue "[try 3: /who from a click]"
      link it prints ~16 s later: does a `/who` from a click work?
- [ ] The same command twice within a few seconds: does the second get results, or a "wait"
      line (the server's limit)?
- [ ] `/taverne probe guildlines` on while someone joins, leaves or is removed from the guild:
      do the lines match (in English and French clients)?
- [ ] `/taverne probe roster` with the guild window's "show offline members" box unticked.

## Vouching phase 1: evidence instead of questions
Trust in an allied player's guild comes from what the game shows (group, target, mouseover,
nameplates) and from my alts' saved guild rosters; the old questions (VQ/VA) stay as a fallback.

- [ ] Target or mouse over an allied player: their state says the game showed their guild.
- [ ] Log an alt in an allied guild, then back on the main: that guild's members are confirmed
      ("your alt saw them in the roster").
- [ ] Someone in my group claiming a guild the game doesn't show for them: denied, with one chat
      line saying why, and a hidden-message count on their Alliance page row.
- [ ] Auto-invite in "Right away" mode: an allied player not checked yet (or disputed) is queued
      for a click, not invited.
- [ ] Lists (invite queue, Players page, group tooltip, Alliance page) show "not checked yet" and
      "disputed" correctly, and update when a player gets confirmed (no stale mark).
- [ ] After 7 days without seeing a player (1 day for what others told me), their record expires.
