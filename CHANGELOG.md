# Changelog

Versions are the `version` in `_meta.lua`; each has a
[release](https://github.com/mzimandl/songbook.koplugin/releases) with
`songbook.koplugin.zip`.

## 1.3.3-beta.2

- With chords hidden, tabs (`{start_of_tab}`) are hidden too, instead of
  leaving their label.
- Following: after the reader wakes up, polls that fail while the Wi-Fi comes
  back no longer stop following.
- While the reader scrolls with the followed songbook, the *autoscroll faster /
  slower* gestures say that the other songbook sets the speed, instead of
  changing it for a moment.
- *Edit URL* of a repository refuses the address of another added repository.
- Browsing a jam session's songbook no longer rewrites the settings each time.
- The diagnostic log's description says it writes the state every 15 seconds.

## 1.3.3-beta.1 – 2026-11-22

- Songs always open with their own style, also where KOReader has
  *Embedded style* off by default (Android), so chords stay above the words.

## 1.3.2 – 2026-11-21

- Jam session: a Kindle no longer freezes when it is due to sleep while
  sharing. Sharing and following no longer keep the reader awake; when it
  goes to sleep they pause and start again a few seconds after it wakes.
  While a song autoscrolls the reader still stays awake.
- *Settings → Diagnostic log*: for finding problems, writes what the songbook
  does, the reader's sleep and wake-up events and every 15 seconds its state
  to `koreader/songbook/diag.log`. Off by default.

## 1.3.1 – 2026-11-21

- KOReader no longer crashes when it quits or restarts (an update through
  ZenPM, for example) while the jam session shares, follows or searches.

## 1.3.0 – 2026-11-21

Songs
- Chords stay over their syllables in any font: each chord and its syllable
  are one block instead of a monospace chord line, which drifted with
  KOReader's synthetic bold. Songs use the reader's font and long lines wrap
  between words, so the *Line width* setting is gone.
- Chord grids (`{start_of_grid}`, ChordPro's way to write the rhythm of an
  instrumental part) are a table: one cell per beat, `.` for a beat the chord
  goes on, bar lines, `~` for two chords on one beat; transposed like the rest.
- More than one space between chords keeps its width, so chords without words
  (`[Am]    [G]`) can be spaced.
- With chords hidden, lines of chords alone leave no empty lines.
- A song stays where it was scrolled to when it is transposed or its options
  change.
- Copied `.chopro` files open.

Autoscroll
- The step can be as small as 1/32 of the screen, and in continuous scroll
  mode autoscroll moves without the e-ink flash.
- It doesn't move the song under an open menu (the song flickered); it
  catches up when the menu closes. A transposition doesn't stop it.
- The reader doesn't suspend by itself while it autoscrolls, shares or
  follows; on a Kindle with its framework the Kindle doesn't sleep either.

Jam session
- The guests' pages scroll along with the host's autoscroll, evenly and to the
  last line. Scrolling by hand pauses it on that phone; the ⇣ button resumes
  it or turns it off.
- A reader that follows another one scrolls along with its autoscroll
  (*Scroll with the followed songbook*, on by default).
- Following no longer freezes the reader when the other songbook stops
  answering.

Collections and lists
- Collections can list their songs in the order they were added: ☰ → *Sort
  by order added*; played songs saved as a collection keep the order they
  were played in.
- Lists stay on their page when they change.
- Removing a repository with its songs is much faster; a web page (a Wi-Fi
  login) is no longer saved as a song; the same repository can't be added
  twice.

Betas (1.3.0-beta.1 to beta.14) came before this release, for ZenPM's Beta
updates.

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
