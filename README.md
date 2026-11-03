# Pugger

A public social feed for **WoW: Forever**, inside the game: post, follow, like, reply and repost,
read a timeline of your realm and faction, and call rares, camps and groups on everyone's map.
Built on legacy chat: nothing outside the game. Main command: **`/pug`**.

Version **0.1.1** (2026-11-03).

## What it does
- **Posts** of up to 80 characters, with item, spell and quest links (shift-click), `#tags` and
  `@mentions`. Every post shows the zone and coordinates where it was written (click it for a map
  pin). Level 10 to post; reading is open to everyone.
- **Tabs:** your faction's feed (Alliance or Horde), Following, Mentions on the left; Groups,
  Nearby, Me on the right. Threads one level deep, a tag view, profiles with a short bio.
- **Map calls:** Rare call (target a real rare), Camp (an hour), Quest / farm group (only players
  within 300 yards ever see it), Dungeon group (only at that dungeon's meeting stone; asks from
  fitting levels anywhere). Nobody is invited without the caller's click.
- **Roles:** groups ask for a tank, a healer and damage with the group finder's icons. Askers pick
  a role their class can fill; once invited, that role comes off the call on every card.
- **Meeting stones:** found from the game's own tooltip; players' add-ons learn each stone's spot
  from each other, silently.
- **Quiet in group instances:** in a dungeon, raid, battleground or arena with others, the window
  steps aside and no cards pop up; on the way out, calls still live (rares, groups, asks to join
  yours) catch up as cards. A switch in the window's menu.
- **Busy realms:** twelve hours of posts kept. When the feed passes 120 posts an hour, it shows
  who you follow, then posts written near you (one click shows everything); on a big realm the
  add-on's own messages slow down so the channel stays light.
- **Where it sits:** Pugger's button by the chat (just above the game's social button, with your
  unread mentions) or on the minimap, and its cards above the chat, by the minimap or at the top
  of the screen: a short setup at the first launch, `/pug setup` after.
- **Safety:** mute, block, word filter, flood limits (3 posts from one spot in 15 minutes: move
  on 100 yards to post again; 20 an hour), call limits checked by everyone, signed posts (a relayed post shows only once
  its author's signature checks), backup channels when one is locked.

Posts are public to everyone on your realm and faction with the add-on, and every post shows the
zone and coordinates where it was written, so anyone can find the player behind it to report or
mute. Deleting removes a post from the feed, not from anyone who already saved it. See
`/pug privacy`.

## Commands
| Command | What it does |
|---|---|
| `/pug` | show or hide the feed |
| `/pug reset`, `/pug lock` | back under the minimap; lock in place |
| `/pug rare`, `/pug camp [note]`, `/pug group [n] [quest]` | map calls |
| `/pug map` | which calls show on the map |
| `/pug setup` | where Pugger's button (by the chat, on the minimap, or both) and its cards go |
| `/pug bio`, `/pug filter`, `/pug mute|block|follow <name>` | your profile, the word filter, people |
| `/pug privacy`, `/pug status`, `/pug bug` | the limits; what the add-on sees; a bug report to copy |
| `/pug demo [off]` | sample posts and calls, only on your screen |
| `/pug stone here <dungeon>`, `/pug stone export` | record meeting stone spots (Phase 0) |
| `/pug measure ...` | Phase 0 tests: message rates, logged messages, signing speed, events |

## Developing
- `luajit tools/sim.lua` runs the offline test bench: several clients against a fake WoW API.
- `tools/build-zip.sh` builds the release zip from the committed tree.

## Credits and licenses
- Pugger by SwiftyPigeon512, MIT (`LICENSE.txt`). Parts are copied from Guild Master Forever
  (MIT), itself derived from the Olympus add-on (MIT); `LICENSE.txt` keeps both notices.
- Libraries, each under its own license: HereBeDragons (BSD, `libs/HereBeDragons/LICENSE.txt`),
  CallbackHandler-1.0 (BSD, `libs/CallbackHandler-1.0/LICENSE-Ace3.txt`), LibStub (public domain).
- Fonts, under the SIL Open Font License 1.1: Source Sans 3 by Adobe (`media/fonts/OFL-SourceSans3.md`)
  and Cinzel by the Cinzel Project Authors (`media/fonts/OFL-Cinzel.txt`; the Bold weight cut from
  its variable font).
- The name: a "PUG" is a pick-up group, and a pugger is a player who joins them; this feed is where
  your realm and faction find one. Pugger is free, never monetized, and has nothing to do with X Corp.
