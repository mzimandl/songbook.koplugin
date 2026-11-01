# KOReader Songbook
- Repo root is the plugin folder (songbook.koplugin); pure-Lua modules in songbook/ must not require KOReader modules (testable off-device).
- Only main.lua and Repo.fetch() touch KOReader APIs. Verify API names against koreader/koreader source before using them.
- LuaJIT 2.1 / Lua 5.1: no utf8 library, use Render.width() / Render.truncate() for character counts.
- Tests: `luajit tests/run.lua` and `luajit tests/smoke.lua` must pass before finishing any change (`lua5.1` works too when luajit isn't installed). smoke.lua stubs KOReader modules and addresses menu items by index (`items.songbook.sub_item_table[n]`), so update it when the menu changes.
- Czech notation: H = B natural, B = B flat. Chords are never transposed when marked [*...].
- Distributed through ZenPM from mzimandl/koplugins (manifest.json, installs the master branch zip). ZenPM offers an update only when `version` in _meta.lua grows: bump it for every change that should reach devices; a workflow in koplugins copies it into the manifest.
- Song format: ChordPro (.cho), server = static index.json + songs/. The song server is a separate repo (mzimandl/songbook-library); its tools/build_index.py writes index.json (optional "name" from songbook.json).

## Data model (main.lua)
- Several song repositories: setting `servers` = list of `{ key, url, name, index_name }`. `key` is made once by Repo.server_key() and never changes (it is the folder name). While `servers` is unset (first start), init() adds DEFAULT_SERVER_URL (songbook-library); an emptied list stays empty.
- A song is identified by its uid: `"<key>/<id>"` (stored in `songs/<key>/<id>.cho`) or `"<id>"` for .cho files copied straight into `songs/`. Rendered files are `rendered/<uid with / → ~>@<options>.html`.
- Rendered songs stay out of KOReader's reading history: init() wraps ReadHistory addItem()/updateLastBookTime() once (hide_songs_from_history(), matched by path, see is_song_file()), so "lastfile" stays the last book.
- Per-song settings maps are keyed by uid: `downloaded`, `transpose`, `favorites`; `collections` = list of `{ name, songs = { [uid] = true } }` (names unique). deleteSong() must clean all of them.

## Migrations
- Released installs keep their settings (`settings/songbook.lua`) and files (`songbook/songs/`, `rendered/`) across updates. Any change to their format (renamed/restructured setting, moved folder, new uid scheme) needs a migration step; adding a new setting with a DEFAULTS entry does not.
- Steps live in `MIGRATIONS` in main.lua: `MIGRATIONS[n](self)` upgrades schema n - 1 to n. migrate() (from init(), before anything reads settings) runs the missing steps and saves setting `schema` = #MIGRATIONS.
- Installs without `schema` are schema 0, fresh installs too, so every step must work on empty settings and missing files (check for nil, don't assume old data exists).
- Only append: never change, reorder or remove a released step.
- Each step gets a smoke.lua test: prepare old settings/files, create the plugin, check the result. Bump `version` in _meta.lua with it.

## Jam session
- songbook/jam.lua is pure: request parsing, routing, JSON, the guest page (PAGE; `%s` placeholders, `%%` = literal %), playlist and follow helpers. main.lua owns the sockets and passes a `ctx` of callbacks (documented at the top of jam.lua).
- State lives in the module-level `jam` table in main.lua, not on `self`: every ReaderUI/FileManager gets a new plugin instance, and init() sets `jam.owner` to the newest one, which serves requests and runs polls.
- Sharing: SimpleTCPServer + UIManager:insertZMQ(); preventStandby() while it runs, iptables hole on Kindle, stopped in onExit(). receiveCallback must return nil (UIManager treats a return value as an input event). SimpleTCPServer reads only headers, so the API is GET-only. The shared song is currentSongId(), else the last one (`jam.uid`); state "rev" = uid + renderSignature(), so host transposition/options reach guests.
- Following: follow_poll() (UIManager:scheduleIn) fetches /state.json, downloads Jam.song_path(state.uid) (not /song.cho, which may already be the next song), saves new songs as uid `jam/<Jam.song_id(host uid)>` and opens them with the host's transposition. Reserved key `jam` (JAM_KEY): never a repository key, hidden from listLocal() (not in My songs/favorites/collections, see currentOwnSongId()), cleared when following starts (except the open song). Opening a non-jam song stops following. Requests block the UI, so use FOLLOW_TIMEOUT with Repo.fetch().
- Host songs as a repository: /index.json (ids = Jam.song_id(uid), plus `uid`) and Jam.song_path(uid) = songs/<uid with / → ~, URL-encoded>.cho. /queue/add takes `uid` or that `id`. Every uid from a request must pass Jam.valid_uid() (one level, no leading dot) before it reaches songPath().

## Playlist
- Not tied to the jam session: setting `playlist` = `{ history, queue }` (Up next / Played), entries `{ uid, title, artist, by, at }`. openSong() records every opened song (playlistPlayed() → Jam.played), except while following and jam/ songs. deleteSong() leaves the playlist alone.
- Main menu: Playlist (onSongbookShowPlaylist) and Next song (nextInPlaylist(): first queued song on the device; gesture SongbookNextSong). Long-press dialogs get playlistButton() (Add/Remove, "Request to play" while following).
- Picker (showPlaylistPicker(), "Add songs…" in the Playlist list): tap adds/removes, songs already in the playlist (queued or played) are hidden while `playlist_hide_added` is on.
- Sharing serves this playlist; guests add via /queue/add (limited to Jam.MAX_QUEUE, local adds aren't). Following clears ours (startFollowing()); then the Playlist list shows the host's /playlist.json read-only and the picker lists the host's /index.json and requests by its ids. An open Playlist list refreshes through `jam.playlist_refresh`.

## Gotchas
- `_` is gettext: don't name a loop variable `_` when the loop body (or a closure in it) calls `_()`; use `_i` etc.
- KOReader's Menu gives `mandatory` (right-hand text) all the width it needs and truncates the title, so keep `mandatory` short (see details() in main.lua).
- KOReader's Menu calls `close_callback` after every item tap, not only on close.
- Song lists open over the kept-open Songbook menu (`keep_menu_open`); the collections menu / repository picker stays under its song list via setParentList(). Song callbacks call closeList(), which closes the list, its parent and the main menu.
- Jam.json() encodes an empty table as `[]` (lists may be empty; objects never are).
- TouchMenu items with `keep_menu_open` don't redraw by themselves: call `touchmenu_instance:updateItems()` (or replace `touchmenu_instance.item_table` for submenus built by `sub_item_table_func`).
