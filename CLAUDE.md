# KOReader Songbook
- Repo root is the plugin folder (songbook.koplugin); pure-Lua modules in songbook/ must not require KOReader modules (testable off-device).
- Only main.lua and repo.fetch() touch KOReader APIs. Verify API names against koreader/koreader source before using them.
- LuaJIT 2.1 / Lua 5.1: no utf8 library, use Render.width() / Render.truncate() for character counts.
- Tests: `luajit tests/run.lua` and `luajit tests/smoke.lua` must pass before finishing any change (`lua5.1` works too when luajit isn't installed). smoke.lua stubs KOReader modules and addresses menu items by index (`items.songbook.sub_item_table[n]`), so update it when the menu changes.
- Czech notation: H = B natural, B = B flat. Chords are never transposed when marked [*...].
- Song format: ChordPro (.cho), server = static index.json + songs/. The song server is a separate repo (mzimandl/koreader-songbook-repo); its tools/build_index.py writes index.json (optional "name" from songbook.json).

## Data model (main.lua)
- Several song repositories: setting `servers` = list of `{ key, url, name, index_name }`. `key` is made once by Repo.server_key() and never changes (it is the folder name). The old single `server_url` is migrated in migrateSingleServer().
- A song is identified by its uid: `"<key>/<id>"` (stored in `songs/<key>/<id>.cho`) or `"<id>"` for .cho files copied straight into `songs/`. Rendered files are `rendered/<uid with / → ~>@<options>.html`.
- Jam session: songbook/jam.lua is pure (request parsing, routing, guest page); main.lua owns the SimpleTCPServer + UIManager:insertZMQ(). State lives in the module-level `jam` table, not on `self`, because every ReaderUI/FileManager gets a new plugin instance; requests go through `jam.owner` (the newest instance). The receiveCallback must return nil (UIManager treats a return value as an input event). SimpleTCPServer reads only headers, so the jam API is GET-only. Following another songbook polls its /state.json with UIManager:scheduleIn (follow_poll) and saves songs under the reserved key `jam` (songs/jam/, never used for a repository). The playlist (setting `jam_playlist` = `{ history, queue }`) is updated by Jam.played() in openSong() while sharing and by guests via /queue/add; deleteSong() leaves it alone (entries keep their title).
- Per-song settings maps are keyed by uid: `downloaded`, `transpose`, `favorites`; `collections` = list of `{ name, songs = { [uid] = true } }` (names unique). deleteSong() must clean all of them.

## Gotchas
- `_` is gettext: don't name a loop variable `_` when the loop body (or a closure in it) calls `_()`; use `_i` etc.
- KOReader's Menu gives `mandatory` (right-hand text) all the width it needs and truncates the title, so keep `mandatory` short (see details() in main.lua).
- TouchMenu items with `keep_menu_open` don't redraw by themselves: call `touchmenu_instance:updateItems()` (or replace `touchmenu_instance.item_table` for submenus built by `sub_item_table_func`).
