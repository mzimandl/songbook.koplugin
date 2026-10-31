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
3. **Settings → Server** → enter the folder URL that contains `index.json`, e.g.
   `https://raw.githubusercontent.com/<user>/<repo>/<branch>/`

## Song server (GitHub)

The song server lives in its own repository:
[mzimandl/koreader-songbook-repo](https://github.com/mzimandl/koreader-songbook-repo).
Use it as a starting point for your own song collection. It has the songs, the
`index.json` generator and the GitHub Action that keeps it up to date.

`updated` in the index is a content hash, so the plugin re-downloads a song
only when its file changed.

## Using it

- **Browse online**: tap a song to download (if new or changed) and open it.
  Long-press to force re-download. The first list item is search.
- **My songs**: downloaded songs, plus any `.cho` you copy to
  `koreader/songbook/songs/`. Long-press to delete.
- **Transpose** (in the menu while a song is open): ±1 semitone / original key.
  It is saved per song. It is also available as gesture actions
  (*Songbook: transpose up/down*) under Taps & gestures → General.
- **Settings**:
  - Chord notation: Czech (H, B = B♭) or English.
  - Line width: wrap column. Lower it if lines are cut off on the right.
  - Show chords: lyrics-only mode.
  - Repeat chorus text: `{chorus}` prints the chorus instead of a label.
  - Download all songs: for offline use.

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
luajit tests/run.lua     # parser, transposer, layout, HTML, repo helpers
luajit tests/smoke.lua   # main.lua against stubbed KOReader modules
```

For UI work use the KOReader emulator (`./kodev run`) with the plugin
symlinked into `plugins/`.

## Notes and limitations

- Rendering goes to `koreader/songbook/rendered/<id>@<options>.html`. Each option
  combination gets its own file name, so the reader cache never shows stale
  chords. Older variants of the same song are removed automatically.
- Chord alignment needs a monospace font. Songs are rendered in `<pre>`
  with Droid Sans Mono (bundled with KOReader). KOReader keeps `<pre>`
  monospace even with *Ignore publisher font families* enabled.
- Opening `.cho` files directly from the file browser isn't supported yet. Use
  *My songs*.
