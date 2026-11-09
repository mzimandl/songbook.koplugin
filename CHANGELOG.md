# Changelog

Versions are the `version` in `_meta.lua`; each has a
[release](https://github.com/mzimandl/songbook.koplugin/releases) with
`songbook.koplugin.zip`.

## 1.3.0-beta.1 – 2026-11-09

- Chords stay over their syllables in any font: each chord and its syllable
  are set as one block instead of a monospace chord line, which drifted with
  KOReader's synthetic bold. Songs use the reader's font, long lines wrap
  between words by themselves, so the *Line width* setting is gone.

## 1.2.0 – 2026-11-08

- Chords are shown in the chosen notation also without transposing: Czech
  H, B, Ami or English B, Bb, Am. A song tells its own notation with
  `{meta: notation en}` (or `cz`); without it, it is read in the chosen one.

## 1.1.0 – 2026-11-08

- My songs, Favorites and collections: ☰ → *Add to playlist* puts the listed
  songs (after a search, those found) into Up next.

## 1.0.0 – 2026-11-08

First stable release. From now on `index.json`, the jam session's API and the
plugin's settings stay compatible: later versions read them, and settings of
earlier installs are migrated.

- **Songs**: ChordPro from static song repositories (GitHub or any web folder
  with `index.json`; private GitHub ones with an access token), Songbook Library
  added on the first start; My songs, favorites, collections, search; own `.cho`
  files in `koreader/songbook/songs/`.
- **Reading**: chords above the lyrics, transposition and choosing the key,
  Czech (H, B = B♭) or English notation, lyrics only, repeated chorus, scroll
  mode, song button with the song's options, autoscroll timed by the song's length.
- **Playlist**: Now playing, Up next and Played; Save played songs as collection.
- **Jam session**: share the song now playing with phones (web page) and other
  readers on the Wi-Fi, guests' song requests, follow another songbook (found on
  the network or by address), guests share their own songs.
- Czech translation; gestures for the main actions.
- Install from the release zip (download button in the README); user guide and
  documentation in `docs/`.

## 0.7.0 – 2026-11-08

- Private GitHub repositories, with an access token typed in the repository's
  settings or loaded from `koreader/songbook/token.txt`.
- The jam session's web page no longer shows an older song or key when answers
  to its requests arrive out of order.
- Licensed under AGPL-3.0-or-later, like KOReader.

## 0.6.5 – 2026-11-08

- An `index.json` or jam session of a newer, incompatible format is reported
  ("needs a newer version") instead of being misread (`"version"` in the index,
  `"api"` in the jam session's `/state.json`).
- Your playlist is put aside while following another songbook and comes back
  when you stop (it used to be cleared).
- Download all stops after 3 failed songs in a row (lost connection) instead of
  waiting for every song's timeout.
- Songs and rendered files are written through a temporary file, so a failed
  write keeps the previous version.
- Kindle: firewall rules left by a crash are not added twice.
- Search ignores diacritics (`pisen` finds *Píseň*) and lists sort accented
  titles among the others (*Čert* with the C's, not after Z).
- Song lists open faster: song metadata is read again only when a file changes.
- The jam session's address is found also on a Wi-Fi without internet access
  (no default route), from the network interfaces.
- The plugin's code is split into modules (songbook/ui/); no change in behavior.

## 0.6.4 and earlier – 2026-10-31 to 2026-11-06

Development versions.
