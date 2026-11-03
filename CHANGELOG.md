# Changelog

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
- Twelve hours of posts kept (3, 6 or 12 in the menu), not three days: the next login brings
  newer ones. Catch-up works in hours to match (its messages renamed: 0.1.0's are ignored).
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
