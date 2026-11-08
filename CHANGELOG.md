# Changelog

Versions are the `version` in `_meta.lua`, which ZenPM offers as updates.

## 1.0.0 – unreleased

First stable release. From now on the formats below stay readable by later
versions; settings of earlier installs are migrated.

- **Songs**: ChordPro from static song repositories (GitHub or any web folder
  with `index.json`), Songbook Library added on the first start; My songs,
  favorites, collections, search; own `.cho` files in `koreader/songbook/songs/`.
- **Reading**: chords above the lyrics, transposition and choosing the key,
  Czech (H, B = B♭) or English notation, lyrics only, repeated chorus, scroll
  mode, song button with the song's options, autoscroll timed by the song's length.
- **Playlist**: Now playing, Up next and Played; Save played songs as collection.
- **Jam session**: share the song now playing with phones (web page) and other
  readers on the Wi-Fi, guests' song requests, follow another songbook (found on
  the network or by address), guests share their own songs.
- Czech translation; gestures for the main actions.

Changes before the release:
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

## 0.x – 2026-10-31 to 2026-11-06

Development versions.
