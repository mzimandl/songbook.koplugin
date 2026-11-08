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

[![Download songbook.koplugin.zip](https://img.shields.io/badge/Download-songbook.koplugin.zip-2ea44f?style=for-the-badge)](https://github.com/mzimandl/songbook.koplugin/releases/latest/download/songbook.koplugin.zip)

1. Download the zip above.
2. Connect the reader to the computer and unpack the zip into KOReader's
   `plugins` folder, so that there is a folder `songbook.koplugin` in it:

   | Device | Folder |
   |---|---|
   | Kindle | `koreader/plugins/` on the Kindle's drive |
   | Kobo | `.adds/koreader/plugins/` on the Kobo's drive (`.adds` is a hidden folder) |
   | PocketBook | `applications/koreader/plugins/` |
   | Android | `koreader/plugins/` in the internal storage |
   | Linux (AppImage) | `~/.config/koreader/plugins/` |
   | Linux (Flatpak) | `~/.var/app/rocks.koreader.KOReader/config/koreader/plugins/` |
   | macOS | `~/Library/Application Support/koreader/plugins/` |

   Elsewhere it is the `plugins` folder inside the KOReader folder.
3. Restart KOReader.

To update, download the zip again and replace the `songbook.koplugin` folder.
Your songs and settings are kept: they are stored outside the plugin's folder.

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

Free software under the
[GNU Affero General Public License](https://github.com/mzimandl/songbook.koplugin/blob/master/LICENSE),
version 3 or later, like KOReader itself.
