# Development

[← Songbook](../README.md)

## Code

```
main.lua                core: settings, migrations, songs and repositories, rendering, gestures
songbook/ui/            UI, one module per area (see songbook/ui/common.lua):
  reader.lua            open song: transposition, autoscroll, song button, song options
  lists.lua             song lists, My songs, favorites
  collections.lua       collections
  online.lua            repositories: browsing, downloading, managing them
  playlist.lua          playlist
  jam.lua               jam session: sharing, following, finding songbooks
  menu.lua              Songbook menu and settings
  common.lua            what they share: plugin class, translations, state, helpers
songbook/chordpro.lua   ChordPro parser
songbook/transpose.lua  chord transposition
songbook/render.lua     song → HTML layout
songbook/repo.lua       index.json + HTTP fetch, GitHub API for private repositories
songbook/jam.lua        jam session: HTTP API, guest page, playlist
songbook/discovery.lua  finding shared songbooks (UDP)
songbook/search.lua     search and sorting without case and diacritics
songbook/l10n.lua       translations
tests/                  off-device tests
docs/                   this documentation
```

The modules in `songbook/*.lua` are pure Lua (no KOReader modules), so they are
tested off the device.

## Tests

```sh
luajit tests/run.lua     # modules, translations
luajit tests/smoke.lua   # the plugin (main.lua, songbook/ui/) against stubbed KOReader modules
```

For UI work use the KOReader emulator (`./kodev run`) with the plugin symlinked
into `plugins/`.

## Translations

KOReader's catalog doesn't have the plugin's strings, so they live in
`songbook/l10n/<lang>.lua` (English → translation). Czech is included; for
another language copy `cs.lua` and translate the values.

## Compatibility

- `index.json` has `"version"` and the jam session's `/state.json` has `"api"`.
  They rise only for changes older plugins would misread; new optional fields
  keep them. A plugin reports a newer index and stops following a newer API.
- The UDP search has its own version (`songbook/discovery.lua`).
- Settings of earlier installs are upgraded by migrations in `main.lua`.

## Releases

A release is a growing `version` in `_meta.lua`, listed in
[CHANGELOG.md](../CHANGELOG.md) and tagged `v<version>`. ZenPM installs the master
branch through [koplugins](https://github.com/mzimandl/koplugins), whose workflow
copies the version into its manifest. `.gitattributes` keeps tests and docs out of
the zip.
