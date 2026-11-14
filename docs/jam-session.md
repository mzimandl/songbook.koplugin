# Jam session

[← Songbook](../README.md)

Play together on the same Wi-Fi: guests see the song you play on their phones,
and other readers can follow you.

## Share with phones

**Jam session → Share songs on the network** starts a small web server. Guests
open the shown address in a phone browser (tap it for a QR code) and see the song
now playing, in your key. Each guest can transpose it, switch chord names, hide
chords and change the font size for themselves, and request songs, which join
your *Up next*.

While the song autoscrolls on your reader, the guests' pages scroll along with
it, smoothly, keeping the line being played a quarter down the screen. A guest
who scrolls by hand pauses this; the ⇣ button resumes it (or turns it off for
good on that phone). Your manual page turns are not followed, so guests can read
ahead.

The page shows the song now playing (*Play now* in the song's options), not the
one you only look at. The reader doesn't go to standby while sharing.

There is no password: share only on networks you trust.

## Follow another reader

**Follow another songbook…** lists the readers sharing on the network, or *Enter
address…* (for example `192.168.1.5`). Every song the other reader plays opens
on yours, in its key; you can still transpose it. While you look at another
song, a new one is only announced.

While following:
- the other reader is a song repository in *Browse online*: download any of its
  songs (the followed songs themselves are kept apart, not in My songs);
- *Playlist* shows its playlist; *Request songs…* there, or long-press a song →
  *Request to play*, asks it to play a song;
- with *Share my songs while following* (on by default) your songs are offered
  to the other reader and its guests too.

Your own playlist is put aside while following and comes back when you stop. A
reader either shares or follows, not both. *Device name* is how other readers
see yours (the device model by default).

## Network

- Ports: TCP 8765 (can be changed while not sharing), UDP 8766 (answers searches)
  and UDP 8767 (a search listens). On Kindle the plugin opens them in the
  firewall while they are in use.
- On a Wi-Fi without internet (a travel router, a phone hotspot) the address is
  found from the reader's network interfaces.
- Readers with different plugin versions work together while their jam session
  API is the same. A reader that follows one with a newer API stops and asks to
  update the plugin.
