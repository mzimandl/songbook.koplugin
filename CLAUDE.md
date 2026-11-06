# KOReader Songbook
- Repo root is the plugin folder (songbook.koplugin). Pure-Lua modules in songbook/ must not require KOReader modules (testable off-device); only main.lua and Repo.fetch() touch KOReader APIs. Verify API names against koreader/koreader source before using them.
- LuaJIT 2.1 / Lua 5.1: no utf8 library; count characters with Render.width() / Render.truncate().
- Tests: `luajit tests/run.lua` and `luajit tests/smoke.lua` must pass before finishing any change (`lua5.1` works too). smoke.lua stubs KOReader and finds items by id: menu_item(name) by `songbook_item` (give new top-level items one), playlist_entry(name), song_action(id).
- Translations: main.lua's `_` (songbook/l10n.lua) looks up songbook/l10n/<lang>.lua first. Every new `_("…")` needs an entry in songbook/l10n/cs.lua (run.lua checks both ways); _meta.lua keeps its Czech inline.
- Czech notation: H = B natural, B = B flat. Chords marked [*...] are never transposed.
- Releases: bump `version` in _meta.lua for every change that should reach devices (ZenPM via mzimandl/koplugins, see the workspace CLAUDE.md).
- Songs: ChordPro (.cho) from static servers (index.json + songs/); the default one is the separate repo mzimandl/songbook-library.

## Data model (main.lua)
- Setting `servers` = list of `{ key, url, name, index_name }`. `key` (Repo.server_key(), made once) is the folder name and never changes. While `servers` is unset (first start) init() adds DEFAULT_SERVER_URL; an emptied list stays empty.
- A song's uid: `"<key>/<id>"` (`songs/<key>/<id>.cho`) or `"<id>"` for .cho files copied into `songs/`. Rendered: `rendered/<uid with / → ~>@<options>.html`.
- Per-song maps keyed by uid: `downloaded`, `transpose`, `favorites`, `duration` (seconds, overrides `{duration}`); `collections` = list of `{ name, songs = { [uid] = true } }` (unique names). deleteSong() must clean all of them (not the playlist).
- Rendered songs stay out of KOReader's history: init() wraps ReadHistory addItem()/updateLastBookTime() (hide_songs_from_history()), so "lastfile" stays the last book.

## Migrations
- Released installs keep `settings/songbook.lua` and `songbook/songs/`, `rendered/`. Changing their format (renamed/restructured setting, moved folder, new uid scheme) needs a step in `MIGRATIONS` (main.lua); a new setting with a DEFAULTS entry doesn't.
- `MIGRATIONS[n](self)` upgrades schema n - 1 to n; migrate() runs the missing ones from init() before anything reads settings and saves `schema`. Installs without `schema` (fresh ones too) are schema 0, so every step must cope with empty settings and missing files.
- Only append; never change, reorder or remove a released step. Each step gets a smoke.lua test and a version bump.

## Jam session
- songbook/jam.lua is pure (request parsing, routing, JSON, the guest page PAGE with `%s` placeholders and `%%` for %, playlist and follow helpers); main.lua owns the sockets and passes a `ctx` of callbacks (documented at the top of jam.lua). songbook/discovery.lua (UDP, `socket` passed in) is pure too.
- State is module-level (`jam`, `finder`), not on `self`: every ReaderUI/FileManager makes a new plugin instance; init() sets `jam.owner` to the newest one, which serves and polls.
- Sharing: SimpleTCPServer polled through UIManager:insertZMQ() (receiveCallback must return nil: a return value is taken as an input event), preventStandby(), Kindle iptables rules (jam_rules / search_rules, removed with the same list), stopped in onExit(). SimpleTCPServer reads only headers: the API is GET-only. It shares the song now playing (nowPlayingUid()), not the open one; state "rev" = uid + renderSignature(), so the host's transposition and options reach guests. It also answers UDP searches (port 8766) with the jam port and deviceName().
- Sharing and following exclude each other (menu enabled_func).
- Following: follow_poll() fetches /state.json and downloads Jam.song_path(state.uid) (not /song.cho, which may already be the next song), saved as uid `jam/<Jam.song_id(host uid)>`. It opens the song (in the host's key) only while the open song is the followed one, none, or following just started; otherwise it notifies. Reserved key `jam` (JAM_KEY): never a repository, hidden from listLocal() (My songs, favorites, collections), cleared when following starts. Requests block the UI: use FOLLOW_TIMEOUT with Repo.fetch().
- Session songbooks are repositories only while connected: onlineServers() adds jamServers() (`{ key, url, name, jam = true }`, never saved in `servers`): the followed host and its other sharing guests (state.json `peers`), or our guests while sharing (jamPeers()). Their keys (`jam_servers` = { [url] = key }) and names (`jam_names`) are kept, so downloaded songs keep their folder and source name.
- Guests share their songs (`jam_share_songs`, default on): startLibrary() serves /index.json and /songs/ on the jam port; follow polls send `?name=&share=<port>`; the host registers them by address in `jam.peers` (dropped after PEER_EXPIRE). A request for a song the host lacks (`/queue/add?from=<port>&uid=`) is accepted only from a registered peer and downloaded on UIManager:nextTick() (the guest is blocked in its request until it returns).
- The host's songs as a repository: /index.json (ids = Jam.song_id(uid), plus `uid`), Jam.song_path(uid). Every uid from a request must pass Jam.valid_uid() before it reaches songPath().

## Playlist
- Setting `playlist` = `{ now, history, queue }` (Now playing / Played / Up next), entries `{ uid, title, artist, by, at }`; `now` may be missing (older settings and hosts). Not tied to the jam session.
- Opening a song only shows it. playSong() makes it the song now playing (Jam.play(): the previous one to history, the new one out of the queue) and opens it; finishPlaying() moves it to history. `play_on_open` makes openSong() play every song (not while following, not jam/ songs).
- nowPlayingUid() (`now.uid`, or the followed jam/ song) is what the jam session shares, what autoscroll on open waits for and what the song button marks.
- Guests add via /queue/add (at most Jam.MAX_QUEUE; local adds aren't limited). Following clears our playlist; the Playlist list then shows the host's /playlist.json read-only and its picker requests the host's songs. An open Playlist list refreshes through `jam.playlist_refresh`.

## Autoscroll
- Per reader instance (`self.autoscroll`), stopped in onCloseDocument()/onSuspend. Setting `autoscroll` starts it for the song now playing only (onReaderReady(), playSong()). Length = songDuration(uid).
- The length is spread over the document height (the played line); when it is `trigger` screens below the view top, GotoViewRel(`step`) runs (scroll mode: step 1 / `autoscroll_step`, trigger AUTOSCROLL_PLAYED + step; page mode: AUTOSCROLL_PAGE). PosUpdate/PageUpdate not caused by it re-anchor the timing.
- `scroll_mode` (default on): openSong() writes `copt_view_mode = 1` into the rendered file's DocSettings unless it has a mode, so one chosen in the reader stays. In scroll mode onReaderReady() replaces the footer's getBookProgress() with the scrolled part.

## Menu and lists
- The Songbook menu is built on opening (mainMenu()): Song options (songActions() without MENU_SKIPS_ACTION), libraryMenu() (song lists, Playlist submenu), Jam session, settingsMenu().
- The open song's actions are songActions() (each with an `id`; actions with the same `row` share a dialog row, labelled `short`), shown by showSongDialog() from the song button or a gesture. While following, favorite/collection apply to the followed song through collectableUid() / keepFollowedSong() (copied from jam/ into the songbook's folder first).
- Song button (`song_button`, Settings → Quick menu): addSongButton() paints a view module above the footer and adds a tap zone (SONG_BUTTON_ZONE) that overrides page turns; taps outside the button return nil and go on.
- Full-screen lists use list_menu(); whole-list actions go in the title bar ☰ menu (show_actions()), not in rows. Rows above the songs: only Search and the list's main action (Add songs…, New collection…, Add repository…).
- Gesture "last song list": showList() with `opts.last` sets `last_list` (kind, arg, query; page saved in closeList()).
- Key dialog: steps only re-show the dialog; Apply saves the transposition and re-opens the song.

## Gotchas
- `_` is gettext: don't name a loop variable `_` when the loop body (or a closure in it) calls `_()`; use `_i`.
- KOReader's Menu gives `mandatory` (right-hand text) all the width it needs and truncates the title: keep it short (details()). It calls `close_callback` after every item tap, not only on close.
- Song lists open over the kept-open Songbook menu and over each other; each is registered with trackList(), and song callbacks call closeList(), which closes all of them and the menu.
- TouchMenu items with `keep_menu_open` don't redraw by themselves: call `touchmenu_instance:updateItems()` (or replace `item_table` for `sub_item_table_func` submenus).
- Jam.json() encodes an empty table as `[]` (lists may be empty; objects never are).
