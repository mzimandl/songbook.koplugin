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
songbook/l10n.lua       translations (songbook/l10n/<lang>.lua, Czech: cs.lua)
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
   **Settings → Song repositories → Add repository…** (or the ☰ menu of an online
   list → *Manage repositories…*) → enter another song server
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

The Songbook menu has *Song options* of the open song, the song lists (My songs, Favorites, Collections,
Browse online) and *Playlist* (a submenu: *Show playlist*, *Now playing* and
*Next song*, disabled while there is none). Then come *Jam session* and *Settings*.

While a song is open, the ☰ button in the bottom right corner (above the
status bar) opens the song's options: *Transpose*; *Start/Stop autoscroll* and
*Song length*; *+/− Favorites*, *+ Collection* and *+/− Playlist* side by side;
*Open now playing* (while another song is playing); *Playlist*; *Play now* /
*Finished* and *Next song* (plays the first song of Up next; disabled while Up
next is empty). The button is inverted while the open song is the one now playing.
The gesture action *Songbook: song options* (Reader) and *Song options* at the
top of the Songbook menu (disabled while no song is open; without the
playlist items, which the menu has anyway) open them too;
*Settings → Quick menu* hides the button. Taps in that corner
beside the button still turn pages.

Every song list starts with search. Actions for the whole list are in the ☰
menu at the left of the title bar. The gesture action *Songbook: last song
list* (General) opens the list you used last again, with its search and page.

- **Browse online**: with more than one repository, pick one first, or
  *All repositories* (at the top) for one combined list. Tap a song to download (if new or
  changed) and open it. Long-press to add to favorites or collections, or to force re-download.
  The ☰ menu has *Download all* (the songs of the shown repositories that are
  new or changed, for offline use) and *Manage repositories…*.
- **My songs**: downloaded songs from all repositories, plus any `.cho` you copy
  to `koreader/songbook/songs/`. Each song shows which repository it came
  from. Long-press to add to favorites or collections, or to delete. An empty
  list offers *Browse online*.
- **Favorites**: songs marked with ★. Add or remove them by long-pressing a
  song in any list, or in the song's options (song button) while a song is
  open. Favoriting an online song downloads it. Gesture actions:
  *Songbook: favorites* (General) and *Songbook: add/remove favorite* (Reader).
- **Collections**: your own named song lists (e.g. *Campfire*, *Christmas*).
  A song can be in several collections, from any repository. Create them in
  **Collections → New collection…**, or from a song: long-press it in a list
  → *Collections…*, or *Add to collection* in the song's options while a song
  is open. In a collection, *Add songs…* (☰ menu, or in an empty collection)
  lists your songs: tap to add or remove them. Long-press a song in a
  collection to remove it from that collection. Long-press a collection to rename or delete it (its songs stay on
  the device). Adding an online song downloads it. Gesture action:
  *Songbook: collections* (General).
- **Playlist**: *Now playing*, *Up next* and *Played*. Opening a song only
  shows it, so you can look for the next song while playing. *Play now* (in
  the song's options, by long-pressing a song in a list, or a tap on a song of
  Up next) makes it the song now playing; the jam session shares only that
  one. When another song starts playing, or you tap *Finished*, it goes to
  Played. *Settings → Opening a song plays it* makes every song you open the
  song now playing. *Open now playing* (song's options, Songbook menu → Playlist, a tap
  on it in the playlist, gesture *Songbook: open the song now playing*) goes
  back to it. Add songs with *Add songs…* in the
  playlist (tap a song to add it, tap again to remove; songs already in the
  playlist are hidden, *Show songs already in the playlist* in its ☰ menu lists them too),
  or by long-pressing a song in any list → *Add to playlist* (or in the song's
  options for the open song). **Next song** in Songbook menu → Playlist or in the
  song's options plays the first song of Up next. In the playlist, tap a
  song of Up next to play it or a played song to open it, long-press a song
  of Up next to move it to the top (*Play next*) or remove it, long-press a
  played song to queue it again (*Add to Up next*), long-press the song now
  playing to finish it. The ☰ menu has *Save played songs as collection…*, which keeps the evening's
  set list (with the song now playing), and *Clear playlist*, which starts over. Gesture actions: *Songbook:
  playlist* and *Songbook: next song in the playlist* (General).
- **Transpose** (in the song's options): a dialog with −1 / +1,
  *Original key* and the keys to pick directly (from `{key}`, else the first
  chord). Pick the key step by step, then tap *Apply* to redraw the song
  (*Cancel* keeps the old key). With chords hidden it offers to show them.
  The transposition is saved per song (separately for the same song from two repositories). It is also available as gesture actions
  (*Songbook: transpose up/down*, *Songbook: transpose / choose key*) under Taps & gestures → Reader.
- **Autoscroll** (in the song's options): *Start/Stop autoscroll*
  scrolls the song so that it ends with the song's length, `{duration: 3:45}` in the song file or
  *Song length* set on the device. In scroll mode it moves an eighth of the
  screen at a time (*Settings → Scrolling → Autoscroll step*), keeping the line being
  played near the top; in page mode it turns pages. A manual page turn or scroll re-times it from there.
  Songs open in continuous (scroll) mode (*Settings → Scrolling → Continuous scroll mode*).
  *Settings → Scrolling → Autoscroll when a song starts playing* starts it by itself
  (not for songs that are only open). Gesture
  actions (Reader): *Songbook: start/stop autoscroll*, *autoscroll faster /
  slower* (±10 %, the new length is kept for the song).
- **Jam session**: *Share songs on the network* starts a small web server.
  Guests on the same Wi-Fi open the shown address (tap it for a QR code) in a
  phone browser and see the song now playing (not the one you only have
  open); it changes when another song starts playing or you transpose it. Each guest can transpose, switch notation, hide
  chords and change the font size for themselves; lines wrap to the phone's
  width. The default port is 8765 (changeable while not sharing); UDP 8766
  answers other readers searching for it, UDP 8767 is where a search listens
  (on Kindle these ports are opened in the firewall while in use). The device
  does not go to standby while sharing. There is no password: share only on
  networks you trust.
  Guests also see your playlist and can ask for songs on the web page (tab
  *Playlist*: search, tap +, optionally with their name); you get a short
  notice and the request joins Up next (at most 30 guests' requests).
  - *Request to play* (long-press a song in any list while following): asks
    the followed reader to play it (it must have the song: one it sent you,
    one from its repository, or one both of you have from the same
    repository).
  - *Follow another songbook…*: lists the readers sharing songs on the
    network (found by UDP broadcast, named by their device model); tap one.
    When none shows up (some networks block broadcasts), *Enter address…*
    takes the address shown on the other reader (e.g. `192.168.1.5`, port
    8765 is added). Every song it plays opens on
    yours too, in its key; you can still transpose it yourself until it
    changes song or key. While you have one of your own songs open, a new
    song is only announced (*Now playing: …*); *Open now playing* goes to it. Followed songs are kept apart (`songs/jam/`, not in
    My songs, removed when you follow again); to keep one, download it with
    *Browse their songs*. Following stops in the Jam session menu, or when the
    other reader is unreachable for a while. Following clears
    your playlist: *Playlist* shows the other reader's one, and *Request
    songs…* there lists its songs to ask for.
  - *Browse their songs*: adds the followed reader as a song repository, so
    you can download any of its songs.
- **Settings**:
  - Song repositories: add, edit the URL, rename or remove. Removing asks
    whether to delete the songs downloaded from it.
  - Songs folder: where downloaded songs are stored (and your own `.cho` files go).
  - Formatting: chord notation (Czech H, B = B♭, or English), show chords
    (lyrics-only mode), repeat chorus text (`{chorus}` prints the chorus
    instead of a label), line width (wrap column; lower it if lines are cut
    off on the right).
  - Scrolling: continuous scroll mode (open songs in scroll mode), autoscroll
    when a song starts playing, autoscroll step (1/2 to 1/16 of the screen).
  - Quick menu: the ☰ button of an open song (off: hidden).
  - Opening a song plays it (off: opening only shows a song).

## Supported ChordPro

| | |
|---|---|
| Meta | `{title}` `{t}` `{subtitle}` `{st}` `{artist}` `{key}` `{capo}` `{tempo}` `{duration}` `{meta: name value}` … |
| Sections | `{start_of_chorus}`/`{soc}`, verse, bridge, tab, grid; labels as `{soc: Ref.}` or `label="…"` |
| Repeat | `{chorus}` |
| Comments | `{c:}` `{ci:}` `{cb:}`, `#` lines ignored |
| Chords | `[Am]` inline, slash chords `[C/H]`, annotations `[*N.C.]` (never transposed) |
| Czech | `Ami`, `Fis`, `Cis`, `Es`, `As`, `H`, `B` (= B♭). `Esus4`/`Asus2` are not read as flats. |

## Translations

KOReader's own catalog doesn't contain the plugin's strings, so the plugin
keeps its translations in `songbook/l10n/<lang>.lua` (English text → translation)
and picks the one for KOReader's language. Czech is included. To add a
language, copy `cs.lua` to e.g. `de.lua` and translate the values.
`tests/run.lua` checks that every string in `main.lua` has a Czech entry.

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
