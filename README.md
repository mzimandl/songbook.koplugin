# KOReader Songbook

KOReader plugin for songs with guitar chords (ChordPro). It downloads songs from
static song servers, renders them with chords above the lyrics (transposition,
Czech H/B notation) and opens them in the reader. A playlist, autoscroll and a
jam session (sharing the song now playing with phones and other readers on the
same Wi-Fi) help when playing.

## Install

- **ZenPM**: add the source `https://raw.githubusercontent.com/mzimandl/koplugins/master/`
  (see [koplugins](https://github.com/mzimandl/koplugins)) and install *Songbook*.
  ZenPM also offers its updates.
- **By hand**: put this repository into `koreader/plugins/` as `songbook.koplugin`
  (Kindle: `/mnt/us/koreader/plugins/`, Kobo: `/mnt/onboard/.adds/koreader/plugins/`).
  `tests/` isn't needed on the device.

Then restart KOReader and open **Tools → Songbook**.

## Song repositories

The first start adds [Songbook Library](https://github.com/mzimandl/songbook-library),
a song server you can also copy as a starting point for your own collection
(songs, the `index.json` generator and a GitHub Action that keeps it up to date).

Add more in **Settings → Song repositories → Add repository…** (or *Manage
repositories…* in the ☰ menu of Browse online). The address is either:
- a GitHub repository: `https://github.com/<user>/<repo>` (default branch, `index.json`
  in the root) or `https://github.com/<user>/<repo>/tree/<branch>/<folder>`, or
- any URL of the folder with `index.json`, e.g. `https://raw.githubusercontent.com/<user>/<repo>/<branch>/`
  or a GitHub Pages address (not `https://github.com/<user>/<repo>/raw/…`).

The repository's name comes from `"name"` in `index.json` (from `songbook.json`
in the song repo), else from the URL. `updated` in the index is a content hash,
so a song is downloaded again only when its file changed.

## Song lists

The Songbook menu has *Song options* (of the open song), the song lists, *Playlist*,
*Jam session* and *Settings*. Every list starts with search, and actions for the
whole list are in the ☰ menu at the left of its title bar. Long-press a song for
its actions: favorite, collections, playlist, *Play now*, re-download or delete.

- **Browse online**: pick a repository, or *All repositories* for one combined
  list. Tap a song to download (when new or changed) and open it. ☰ → *Download
  all* gets the new and changed songs for offline use.
- **My songs**: downloaded songs, each with its repository, plus `.cho` files you
  copy to `koreader/songbook/songs/`.
- **Favorites** (★): adding an online song downloads it.
- **Collections**: your named song lists (*Campfire*, *Christmas*…), songs from any
  repository. *New collection…*; in a collection *Add songs…* (tap to add or
  remove); long-press a collection to rename or delete it (its songs stay).

## Open song

The ☰ button in the bottom right corner of an open song (inverted while the song
is the one now playing) opens its options: *Transpose*, *Start/Stop autoscroll*,
*Song length*, favorite, collection, playlist, *Play now* / *Finished*, *Next
song* and *Open now playing*. The same options are *Song options* in the Songbook
menu. Taps in that corner beside the button still turn pages.

- **Transpose**: −1 / +1, *Original key* or a key picked directly, then *Apply*.
  Saved per song.
- **Autoscroll**: scrolls so that the song ends with its length (`{duration: 3:45}`
  in the file, or *Song length* set on the device). In scroll mode it moves an
  eighth of the screen at a time, keeping the played line near the top; in page
  mode it turns pages. A manual page turn re-times it. Songs open in scroll mode
  unless you turn it off in Settings.

## Playlist

*Now playing*, *Up next* and *Played*. Opening a song only shows it (unless
*Settings → Opening a song plays it* is on), so you can look for the next one
while playing. *Play now* makes a song the one now playing: it is what the jam
session shares, and the previous one goes to Played (so does it after
*Finished*). *Next song* plays the first song of Up next.

In the playlist: *Add songs…* (tap to add or remove), tap a song of Up next to
play it, long-press it to *Play next* or remove it, long-press a played song to
queue it again. ☰ → *Save played songs as collection…* keeps the evening's set
list; *Clear playlist* starts over.

## Jam session

**Share songs on the network** starts a small web server. Guests on the same
Wi-Fi open the shown address (tap it for a QR code) in a phone browser and see
the song now playing, in your key. Each guest can transpose, switch notation,
hide chords and change the font size for themselves, and request songs from your
playlist (they join Up next). There is no password: share only on networks you
trust.

**Follow another songbook…** lists the readers sharing on the network (or
*Enter address…*, e.g. `192.168.1.5`). Every song the other reader plays opens on
yours, in its key; you can still transpose it. While you have another song open,
a new one is only announced. While following:
- the other reader is a repository in Browse online (download any of its songs;
  followed songs themselves are kept apart, not in My songs);
- *Playlist* shows its playlist; *Request songs…* there, or long-press → *Request
  to play*, asks it to play a song;
- with *Share my songs while following* (on by default) your songs are offered to
  the other reader and its guests too.

Following clears your own playlist. A reader either shares or follows, not both.
*Device name* is how other readers see this one (default: the device model).
The device doesn't go to standby while sharing.

Ports: TCP 8765 (changeable while not sharing), UDP 8766 (answers searches) and
8767 (a search listens). On Kindle they are opened in the firewall while in use.

## Settings

- **Song repositories**: add, edit the URL, rename or remove (optionally with its songs).
- **Songs folder**: where songs are stored.
- **Formatting**: chord notation (Czech H, B = B♭, or English), show chords,
  repeat chorus text (print the chorus where the song says `{chorus}`), line width
  (lower it if lines are cut off on the right).
- **Scrolling**: continuous scroll mode, autoscroll when a song starts playing,
  autoscroll step.
- **Quick menu**: the ☰ button of an open song.
- **Opening a song plays it**.

## Gestures

Under Taps & gestures, all starting with *Songbook:*.
- Reader: *transpose up / down*, *transpose / choose key*, *song options*,
  *add/remove favorite*, *start/stop autoscroll*, *autoscroll faster / slower*
  (±10 %, kept for the song).
- General: *my songs*, *favorites*, *collections*, *playlist*, *last song list*
  (with its search and page), *open the song now playing*, *next song in the playlist*.

## Supported ChordPro

| | |
|---|---|
| Meta | `{title}` `{t}` `{subtitle}` `{st}` `{artist}` `{key}` `{capo}` `{tempo}` `{duration}` `{meta: name value}` … |
| Sections | `{start_of_chorus}`/`{soc}`, verse, bridge, tab, grid; labels as `{soc: Ref.}` or `label="…"` |
| Repeat | `{chorus}` |
| Comments | `{c:}` `{ci:}` `{cb:}`, `#` lines ignored |
| Chords | `[Am]` inline, slash chords `[C/H]`, annotations `[*N.C.]` (never transposed) |
| Czech | `Ami`, `Fis`, `Cis`, `Es`, `As`, `H`, `B` (= B♭). `Esus4`/`Asus2` are not read as flats. |

## Notes

- Songs are stored in `koreader/songbook/songs/<repository>/<id>.cho`, rendered
  to `koreader/songbook/rendered/` (one file per option combination, so the reader
  never shows stale chords).
- Songs are set in Droid Sans Mono inside `<pre>`, which keeps the chords
  aligned even with *Ignore publisher font families*.
- Opening `.cho` files from the file browser isn't supported; use *My songs*.

## Translations

KOReader's catalog doesn't have the plugin's strings, so they live in
`songbook/l10n/<lang>.lua` (English → translation). Czech is included; for
another language copy `cs.lua` and translate the values.

## Development

```
main.lua                UI: menus, lists, download, settings, gestures, jam session
songbook/chordpro.lua   ChordPro parser
songbook/transpose.lua  chord transposition
songbook/render.lua     song → HTML layout
songbook/repo.lua       index.json + HTTP fetch
songbook/jam.lua        jam session: HTTP API, guest page, playlist
songbook/discovery.lua  finding shared songbooks (UDP)
songbook/l10n.lua       translations
tests/                  off-device tests
```

```sh
luajit tests/run.lua     # modules, translations
luajit tests/smoke.lua   # main.lua against stubbed KOReader modules
```

For UI work use the KOReader emulator (`./kodev run`) with the plugin symlinked
into `plugins/`.
