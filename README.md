# Songbook for KOReader

A songbook with guitar chords on your e-reader. Download songs, read them with
the chords above the lyrics, change their key, let them scroll by themselves and
play together with friends: their phones and readers show the song you play.

- Songs from online song collections, at hand also offline; your own collections and favorites
- Transposition to any key, Czech (H, B) or English chord names
- Autoscroll timed by the song's length
- Playlist for the evening: now playing, up next, played
- Jam session over Wi-Fi: others follow your song on a phone or another reader
- English and Czech

## Install

1. In [ZenPM](https://github.com/xZenLabs/zen-pm) → Sources, add
   `https://raw.githubusercontent.com/mzimandl/koplugins/master/`.
2. Install **Songbook** and restart KOReader. ZenPM also offers its updates.

Without ZenPM: download the
[zip](https://github.com/mzimandl/songbook.koplugin/archive/refs/heads/master.zip),
unpack it into `koreader/plugins/` and rename the folder to `songbook.koplugin`.

## First steps

1. Open **Tools → Songbook → Browse online**. The plugin starts with
   [Songbook Library](https://github.com/mzimandl/songbook-library), a free collection
   of folk songs and carols.
2. Tap a song: it downloads and opens.
3. Tap the **☰ button** in the bottom right corner of the song to transpose it,
   start autoscroll, add it to favorites or to the playlist.
4. Your songs are in **My songs**, also without Wi-Fi. Every list has a search
   (`pisen` finds *Píseň*).

Want to play together? Open **Jam session → Share songs on the network**: guests
on the same Wi-Fi open the shown address (or its QR code) on their phones.

## More

- [User guide](https://github.com/mzimandl/songbook.koplugin/blob/master/docs/guide.md):
  song lists, the open song, playlist, settings and gestures
- [Jam session](https://github.com/mzimandl/songbook.koplugin/blob/master/docs/jam-session.md):
  sharing with phones and following another reader
- [Song repositories](https://github.com/mzimandl/songbook.koplugin/blob/master/docs/repositories.md):
  adding more songs, private repositories, your own song server
- [Writing songs](https://github.com/mzimandl/songbook.koplugin/blob/master/docs/chordpro.md):
  the ChordPro format the plugin reads
- [Development](https://github.com/mzimandl/songbook.koplugin/blob/master/docs/development.md):
  code, tests, translations and releases
- [Changes](https://github.com/mzimandl/songbook.koplugin/blob/master/CHANGELOG.md)

Found a bug or have an idea? [Open an issue](https://github.com/mzimandl/songbook.koplugin/issues).

## License

Copyright (C) 2026 Martin Zimandl. Free software under the
[GNU Affero General Public License](https://github.com/mzimandl/songbook.koplugin/blob/master/LICENSE),
version 3 or later, like KOReader itself.
