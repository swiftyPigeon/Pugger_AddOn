# Pugger

A public social feed for **WoW: Forever**, inside the game: post, follow, like, reply and repost,
read a timeline of your realm and faction, and call rares, camps and groups on everyone's map.
No server outside the game. Main command: **`/pug`**.

Version **0.1.0**, not released yet (Phase 0 measurements on Forever come first).

## What it does
- **Posts** of up to 80 characters, with item, spell and quest links (shift-click), a map pin,
  `#tags` and `@mentions`. Level 10 to post; reading is open to everyone.
- **Tabs:** Realm, Following, Mentions on the left; Groups, Nearby, Me on the right. Threads one
  level deep, a tag view, profiles with a short bio.
- **Map calls:** Rare call (target a real rare), Camp (an hour), Quest / farm group (only players
  within 300 yards ever see it), Dungeon group (only at that dungeon's meeting stone; asks from
  fitting levels anywhere). Nobody is invited without the caller's click.
- **Safety:** mute, block, word filter, flood limits, signed posts (a relayed post shows only once
  its author's signature checks), backup channels when one is locked.

Posts are public to everyone on your realm and faction with the add-on. Deleting removes a post
from the feed, not from anyone who already saved it. See `/pug privacy`.

## Commands
| Command | What it does |
|---|---|
| `/pug` | show or hide the feed |
| `/pug reset`, `/pug lock` | back under the minimap; lock in place |
| `/pug rare`, `/pug camp [note]`, `/pug group [n] [quest]` | map calls |
| `/pug map` | which calls show on the map |
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
