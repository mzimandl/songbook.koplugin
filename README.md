# KOReader Songbook

KOReader plugin that downloads songs with guitar chords (ChordPro) from a static
server, renders them locally (chords above lyrics, transposition, Czech H/B
notation) and opens them in the reader.

The repository root is the plugin folder (`songbook.koplugin`):

```
_meta.lua
main.lua                UI: menus, lists, download, settings, gestures
songbook/chordpro.lua   ChordPro parser          (pure Lua, tested)
songbook/transpose.lua  chord transposition      (pure Lua, tested)
songbook/render.lua     song → HTML layout       (pure Lua, tested)
songbook/repo.lua       index.json + HTTP fetch
tests/                  off-device tests (LuaJIT, not used by the plugin)
```

## Install

1. Put this repository into `koreader/plugins/` as a folder named
   `songbook.koplugin` (Kindle: `/mnt/us/koreader/plugins/`,
   Kobo: `/mnt/onboard/.adds/koreader/plugins/`), e.g.
   `git clone https://github.com/mzimandl/songbook.koplugin`.
   `tests/` can be deleted on the device.
2. Restart KOReader → **Tools → Songbook**.
3. On the first start the sample repository
   [Songbook Library](https://github.com/mzimandl/songbook-library) is already added.
   **Settings → Song repositories → Add repository…** → enter another song server
   address. You can add several. For a GitHub repository the ordinary address
   is enough:
   - `https://github.com/<user>/<repo>`: default branch, `index.json` in the repo root
   - `https://github.com/<user>/<repo>/tree/<branch>/<folder>`: other branch or subfolder

   The plugin downloads these from `raw.githubusercontent.com`. Any other
   address must point straight to the folder with `index.json`, e.g.
   `https://raw.githubusercontent.com/<user>/<repo>/<branch>/` or a GitHub Pages
   URL. An address like `https://github.com/<user>/<repo>/raw/…` won't work.

## Song server (GitHub)

The song server lives in its own repository:
[mzimandl/songbook-library](https://github.com/mzimandl/songbook-library)
(added by default on the first start).
Use it as a starting point for your own song collection. It has the songs, the
`index.json` generator and the GitHub Action that keeps it up to date.

`updated` in the index is a content hash, so the plugin re-downloads a song
only when its file changed. An optional top-level `"name"` in `index.json` is
shown as the repository name. `build_index.py` takes it from `songbook.json`
(`{"name": "My songs"}`) in the song repo root. Without it the name comes from the URL
(`user/repo`).

## Using it

- **Browse online**: with more than one repository, pick one first, or
  *All repositories* for one combined list. Tap a song to download (if new or
  changed) and open it. Long-press to add to favorites or collections, or to force re-download.
  The first list item is search.
- **My songs**: downloaded songs from all repositories, plus any `.cho` you copy
  to `koreader/songbook/songs/`. Each song shows which repository it came
  from. Long-press to add to favorites or collections, or to delete.
- **Favorites**: songs marked with ★. Add or remove them by long-pressing a
  song in any list, or with **Favorite** in the Songbook menu while a song is
  open. Favoriting an online song downloads it. Gesture actions:
  *Songbook: favorites* (General) and *Songbook: add/remove favorite* (Reader).
- **Collections**: your own named song lists (e.g. *Campfire*, *Christmas*).
  A song can be in several collections, from any repository. Create them in
  **Collections → New collection…**, or from a song: long-press it in a list
  → *Collections…*, or **Add to collection…** in the Songbook menu while a song
  is open. Long-press a collection to rename or delete it (its songs stay on
  the device). Adding an online song downloads it. Gesture action:
  *Songbook: collections* (General).
- **Playlist**: *Up next* and *Played*. Every song you open is recorded as
  played (a song from Up next leaves it). Add songs with *Add songs…* in the
  playlist (tap a song to add it, tap again to remove; songs already in the
  playlist are hidden, *Show songs already in the playlist* lists them too),
  or by long-pressing a song in any list → *Add to playlist*. **Next song** in
  the Songbook menu opens the first song of Up next. In the playlist, tap a
  song to play it, long-press a song of Up next to move it to the top (*Play
  next*) or remove it. *Save played songs as collection…* keeps the evening's
  set list; *Clear playlist* starts over. Gesture actions: *Songbook:
  playlist* and *Songbook: next song in the playlist* (General).
- **Transpose** (in the menu while a song is open): ±1 semitone / original key,
  or *Choose key…* to pick the key directly (from `{key}`, else the first chord).
  It is saved per song (separately for the same song from two repositories). It is also available as gesture actions
  (*Songbook: transpose up/down*) under Taps & gestures → General.
- **Jam session**: *Share songs on the network* starts a small web server.
  Guests on the same Wi-Fi open the shown address (tap it for a QR code) in a
  phone browser and see the song you are playing; it changes when you open
  another song or transpose. Each guest can transpose, switch notation, hide
  chords and change the font size for themselves; lines wrap to the phone's
  width. The default port is 8765 (changeable while not sharing). The device
  does not go to standby while sharing. There is no password: share only on
  networks you trust.
  Guests also see your playlist and can ask for songs on the web page (tab
  *Playlist*: search, tap +, optionally with their name); you get a short
  notice and the request joins Up next (at most 30 guests' requests).
  - *Request to play* (long-press a song in any list while following): asks
    the followed reader to play it (it must have the song: one it sent you,
    one from its repository, or one both of you have from the same
    repository).
  - *Follow another songbook…*: enter the address shown on another reader
    (e.g. `192.168.1.5`, port 8765 is added). Every song it opens opens on
    yours too, in its key; you can still transpose it yourself until it
    changes song or key. Followed songs are kept apart (`songs/jam/`, not in
    My songs, removed when you follow again); to keep one, download it with
    *Browse their songs*. Following stops when you open a song of your own,
    or when the other reader is unreachable for a while. Following clears
    your playlist: *Playlist* shows the other reader's one, and *Request
    songs…* there lists its songs to ask for.
  - *Browse their songs*: adds the followed reader as a song repository, so
    you can download any of its songs.
- **Settings**:
  - Song repositories: add, edit the URL, rename or remove. Removing asks
    whether to delete the songs downloaded from it.
  - Chord notation: Czech (H, B = B♭) or English.
  - Line width: wrap column. Lower it if lines are cut off on the right.
  - Show chords: lyrics-only mode.
  - Repeat chorus text: `{chorus}` prints the chorus instead of a label.
  - Download all songs: from all repositories, for offline use.

## Supported ChordPro

| | |
|---|---|
| Meta | `{title}` `{t}` `{subtitle}` `{st}` `{artist}` `{key}` `{capo}` `{tempo}` `{meta: name value}` … |
| Sections | `{start_of_chorus}`/`{soc}`, verse, bridge, tab, grid; labels as `{soc: Ref.}` or `label="…"` |
| Repeat | `{chorus}` |
| Comments | `{c:}` `{ci:}` `{cb:}`, `#` lines ignored |
| Chords | `[Am]` inline, slash chords `[C/H]`, annotations `[*N.C.]` (never transposed) |
| Czech | `Ami`, `Fis`, `Cis`, `Es`, `As`, `H`, `B` (= B♭). `Esus4`/`Asus2` are not read as flats. |

## Development

```sh
luajit tests/run.lua     # parser, transposer, layout, HTML, repo and jam server helpers
luajit tests/smoke.lua   # main.lua against stubbed KOReader modules
```

For UI work use the KOReader emulator (`./kodev run`) with the plugin
symlinked into `plugins/`.

## Notes and limitations

- Downloaded songs are stored in `koreader/songbook/songs/<repository>/<id>.cho`.
  The folder name is fixed when the repository is added.
- Rendering goes to `koreader/songbook/rendered/<repository>~<id>@<options>.html`. Each option
  combination gets its own file name, so the reader cache never shows stale
  chords. Older variants of the same song are removed automatically.
- Chord alignment needs a monospace font. Songs are rendered in `<pre>`
  with Droid Sans Mono (bundled with KOReader). KOReader keeps `<pre>`
  monospace even with *Ignore publisher font families* enabled.
- Opening `.cho` files directly from the file browser isn't supported yet. Use
  *My songs*.
