# User guide

[← Songbook](../README.md)

Open the plugin in **Tools → Songbook**. The menu has *Song options* (of the
song that is open), the song lists, *Playlist*, *Jam session* and *Settings*.

## Song lists

Every list starts with a search: title or artist, case and diacritics don't
matter (`pisen` finds *Píseň*). Actions for the whole list are in the ☰ menu at
the left of its title bar. Long-press a song for its actions: favorite,
collections, playlist, *Play now*, download again or delete.

- **Browse online**: pick a song repository, or *All repositories* for one
  combined list. Tap a song to download it (when it is new or changed) and open
  it. ☰ → *Download all* gets the new and changed songs for offline use.
- **My songs**: the songs on the device, each with its repository, and `.cho`
  files you copy to `koreader/songbook/songs/`.
- **Favorites** (★): adding an online song downloads it.
- **Collections**: your own song lists (*Campfire*, *Christmas*…), with songs from
  any repository. *New collection…*; in a collection *Add songs…* (tap to add or
  remove); long-press a collection to rename or delete it (its songs stay).

In My songs, Favorites and a collection, ☰ → *Add to playlist* puts the listed
songs into *Up next* (after a search only those found; songs already in the
playlist are skipped).

## The open song

The ☰ button in the bottom right corner of a song opens its options (the same
are *Song options* in the Songbook menu). It is inverted while the song is the
one now playing. Taps in that corner beside the button still turn pages.

- **Transpose**: −1 / +1, *Original key* or a key picked directly, then *Apply*.
  The key is kept for the song.
- **Autoscroll**: scrolls so that the song ends with its length: `{duration: 3:45}`
  in the song, or *Song length* set on the device. In scroll mode it moves an
  eighth of the screen at a time and keeps the played line near the top; in page
  mode it turns pages. Turning a page by hand re-times it.
- Favorite, collection, playlist, *Play now* / *Finished*, *Next song* and
  *Open now playing*.

Songs open in continuous (scroll) mode unless you turn it off in Settings.

## Playlist

*Now playing*, *Up next* and *Played*. Opening a song only shows it, so you can
look for the next one while playing (or turn on *Settings → Opening a song plays
it*). *Play now* makes a song the one now playing: the jam session shares it, and
the previous one goes to Played, as after *Finished*. *Next song* plays the first
song of Up next.

In the playlist: *Add songs…* (tap to add or remove; a whole list of songs comes
from ☰ → *Add to playlist* in My songs, Favorites or a collection), tap a song of Up next to
play it, long-press it to *Play next* or remove it, long-press a played song to
queue it again. ☰ → *Save played songs as collection…* keeps the evening's set
list; *Clear playlist* starts over.

## Settings

- **Song repositories**: add, edit the address, rename, set an access token
  (private GitHub repositories) or remove (optionally with its songs). See
  [Song repositories](repositories.md).
- **Songs folder**: shows where the songs are stored.
- **Formatting**: chord names (Czech H, B = B♭, Ami, or English B, Bb, Am;
  songs are converted to it), show chords, repeat
  the chorus text where the song says `{chorus}`.
- **Scrolling**: continuous scroll mode, autoscroll when a song starts playing,
  autoscroll step.
- **Quick menu**: the ☰ button of an open song.
- **Opening a song plays it**.

## Gestures

In KOReader's *Taps and gestures*, all starting with *Songbook:*.
- Reader: *transpose up / down*, *transpose / choose key*, *song options*,
  *add/remove favorite*, *start/stop autoscroll*, *autoscroll faster / slower*
  (±10 %, kept for the song).
- General: *my songs*, *favorites*, *collections*, *playlist*, *last song list*
  (with its search and page), *open the song now playing*, *next song in the playlist*.

## Good to know

- Songs are stored in `koreader/songbook/songs/<repository>/<id>.cho` and
  rendered to `koreader/songbook/rendered/`.
- Songs use the reader's font. Every chord is placed over its syllable as a
  small block, so the chords stay aligned in any font and size, and long lines
  wrap between words (the rest of the line is indented). This needs the
  document's styles: keep *Embedded style* on (in the bottom menu).
- `.cho` files can't be opened from KOReader's file browser; copy them to
  `koreader/songbook/songs/` and open them from *My songs*.
- Songs you open stay out of KOReader's reading history, so it lists only books.
