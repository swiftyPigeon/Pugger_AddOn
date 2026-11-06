# Changelog

## 0.1.3 (2026-11-06)
- **Players can see each other on Forever.** Forever drops add-on messages on custom channels
  (every PUG Social so far sent into the void and saw "1 user"), and lets an add-on write on a
  channel only during a click. Now what you do (post, reply, repost, like, delete, a call, an
  invite) goes on the hidden channel as a line of chat text, at the click; catching up,
  profiles and stones go by whisper to players in the channel. Everyone needs this version:
  0.1.2 and earlier hear nothing.
- "N users" is the channel's member list: right at once, not after half an hour.
- Forever's channels reach players of other realms, a whisper only yours and the ones connected
  to it: posts reach everyone in the channel, and nobody gets whispered where a whisper can't
  go (no more "No player named ... is currently playing").
- The feed's hidden channel no longer takes **/1** from General on Forever (General comes in
  late there, and our channel took its number: typing /1 went to the wrong place). It now
  joins after the game's own channels and moves behind them if it got there first.
- The "N users" count fills in much faster: everyone checks in every ten minutes (was half an
  hour; slower on a busy realm, as before), and on a small feed someone heard for the first
  time is asked for their profile at once, so they count within seconds.
- The count's tooltip reads "Players with PUG Social online now: 1" (was "1 players").
- After a `/reload` the add-on says it's here right away (its profile and a sync check), as at
  login, instead of staying quiet up to 15 minutes.
- Hovering over the feed's title no longer gives a Lua error on newer clients (the tooltip
  asked for its text the old way).
- The limits "i" by the close button shows on Forever (it was hidden under the title bar).
- The window, minimized, has room between its header row and its bottom edge, and no metal
  spikes standing out above or below it on Forever.
- No more "secret keys" errors on Forever when hovering over things in the world: newer clients
  hand some game data over as secret values (tooltip text, spell ids, links, the target), and
  the add-on now leaves those alone instead of reading them.
- `/pug status` shows "echo": your own messages the server sent back, so you can tell the
  channel works even when nobody else is online. A second line counts the add-on messages that
  come in (every add-on's, ours, hidden by the client, from another channel).
- `/pug measure echo` sends one message to yourself on each way (the channel, logged, a whisper,
  say, guild) and says which the server sent back.

## 0.1.2 (2026-11-04)
- Shown as PUG Social, its name on CurseForge: the window, buttons, tooltips, setup, key binding
  and add-on list. The folder, saved data, channels and `/pug` stay as they were, so nothing
  is lost and 0.1.1 users still see each other.
- Notifications in one place: right-click PUG Social's button (or the menu), then Notifications.
  Turn every card off, or pause them for an hour, in one click; or keep only some: mentions,
  rares, quest groups, dungeon groups (all, or only the dungeons ticked), at your level, with or
  without the sound. Asks to join your own groups always show. The button greys while cards are
  off. `/pug cards on | off | pause` does the same from chat.

## 0.1.1 (2026-11-03)
- The feed's title shows how many players use Pugger right now ("12 users"): those heard from in
  the last half hour, you included. Its tooltip tells more, and how many are known in the feed.
- The group dialog, tidied: the dungeon's name as its title, the game's checkboxes on the role
  buttons, each role named under its icon, the row centred.
- Pugger's button sits by the chat: the logo in a rounded square just above the game's social
  button, while the window is closed, with the unread mentions on its corner. The minimap button
  is now a choice, off by default.
- Cards stack up from just above the chat (or beside the minimap, or at the top of the screen).
- A short setup at the first launch: where the button and the cards go, each choice shown at
  once. Again any time from the menu (Buttons and cards...) or `/pug setup`.
- The feed lives in the moment: posts stay 6 hours, 2 on a busy feed (not three days). Mentions
  of you stay a day, your own posts a week. Catch-up covers only those hours, in hour buckets
  (its messages renamed: 0.1.0's are ignored).
- A busy feed focuses: past 120 posts an hour, the faction's tab shows the people you follow,
  then posts written near you; a line says how many were left out, and shows them all on a click.
- On a big feed (past 250 players) profiles and catch-up slow down in step, so the channel
  carries about the same however many join.
- No spamming from one spot: at most 3 posts (and reposts) within 100 yards in 15 minutes;
  moving on opens posting again. Replies are free. Everyone's add-on drops the extra ones.
- A dungeon group ends once its caller is 200 yards from the stone.
- A new logo: a "p" whose stem wraps round it in a ring, as the @'s tail does (the other way).
- A yellow "i" in the title bar lists every limit (posts, spots, rares, groups) on hover.
- Rare calls: one just voted dead can't be called again in its zone for 5 minutes, and one rare
  can be called 5 times an hour at most, whoever calls it (a different rare is its own count).
  The hourly limits of calls are kept by everyone's add-on, not only the caller's.
- Fixed: shift-clicking an item from the bags didn't put its link in a post on newer clients
  (MoP Classic): every way the game passes a link is now heard.

## 0.1.0 (2026-11-03): the first release
- First build: posts (80 characters), follows, likes, reposts, replies, mentions, tags, profiles,
  signed posts and catch-up sync, map calls (rare, camp, quest / farm group, dungeon group at
  meeting stones), mute, block, word filter, backup channels, Phase 0 measurement tools.
- Named Pugger (was Faxion), with its own logo; mentions get a speech bubble, groups a meeting stone.
- Every post shows the zone and coordinates where it was written (the zone alone in a dungeon);
  a post without one says so.
- Group calls ask for roles (tank, healer, damage) with the group finder's icons; asks name the
  role, and an invite takes it off the call for everyone.
- Quiet in group instances: no window and no cards inside; live calls catch up on the way out.
- A thinner window: the faction's name as the feed's title, one header row, a compose box of one
  line until used.
- Fixed: a redraw took the cursor out of the compose box.
