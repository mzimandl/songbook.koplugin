# Song repositories

[← Songbook](../README.md)

A song repository is a folder on the web with an `index.json` (the list of
songs) and the songs as ChordPro files. The first start adds
[Songbook Library](https://github.com/mzimandl/songbook-library).

## Adding a repository

**Settings → Song repositories → Add repository…** (or *Manage repositories…* in
the ☰ menu of *Browse online*). The address is either:
- a GitHub repository: `https://github.com/<user>/<repo>` (its default branch,
  `index.json` in the root) or `https://github.com/<user>/<repo>/tree/<branch>/<folder>`, or
- any address of the folder with `index.json`, for example
  `https://raw.githubusercontent.com/<user>/<repo>/<branch>/` or a GitHub Pages
  address (not `https://github.com/<user>/<repo>/raw/…`).

The repository's name comes from its `index.json`, else from the address; you
can rename it. A song is downloaded again only when its file changed.

## Private GitHub repositories

A private repository needs an access token:

1. On GitHub: *Settings → Developer settings → Personal access tokens →
   Fine-grained tokens → Generate new token*. Give it access to this repository
   only and the permission *Contents: Read-only*.
2. In the plugin, add the repository; as its song list can't be loaded, the
   plugin offers *Access token…* (later: tap the repository in *Song
   repositories* → *Access token…*).
3. Type the token, or copy it into `koreader/songbook/token.txt` over USB and tap
   *Load from file* (the file is deleted then).

The token is sent only to the GitHub API (`api.github.com`), never to other
addresses. It is stored in plain text in `koreader/settings/songbook.lua`, so give
it no more access than this. Songs from a private repository are songs on the
device like the others: the jam session offers them to its guests too.

## Your own song repository

The easiest start is a copy of
[Songbook Library](https://github.com/mzimandl/songbook-library) on GitHub: put
your songs into `songs/`, set the name in `songbook.json`, and its GitHub Action
rebuilds `index.json` after every push. Then add your repository's address in
the plugin. How to write the songs: [Writing songs](chordpro.md).

### index.json

```json
{ "version": 1, "name": "My songs",
  "songs": [ { "id": "amazing-grace", "title": "Amazing Grace", "artist": "John Newton",
               "key": "G", "file": "songs/amazing-grace.cho", "updated": "d583db33c6" } ] }
```

- Only `file` is required: the song's path relative to the folder of
  `index.json`, or a full address.
- `id` defaults to the file name. It names the downloaded file, so don't change
  it once the song is published.
- `title` defaults to the id; `artist` and `key` are shown in the lists.
- The song is downloaded again whenever `updated` changes (Songbook Library
  uses a hash of the file).
- Unknown fields are ignored, so new optional fields keep `"version": 1`. A
  higher version is for changes older plugins would misread; they then say that
  the repository needs a newer plugin.
