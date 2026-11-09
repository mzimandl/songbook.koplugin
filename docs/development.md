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
[CHANGELOG.md](../CHANGELOG.md) and tagged `v<version>`. Pushing the tag runs the
*Release* workflow (`.github/workflows/release.yml`): it makes a GitHub release
with `songbook.koplugin.zip` (the plugin folder, without what `.gitattributes`
marks export-ignore: tests, docs, workflows) and the version's CHANGELOG section
as notes. The README's download button points to the latest release's zip. For a
tag pushed earlier, run the workflow by hand (Actions → Release → Run workflow).

Releases also reach readers through ZenPM from
[koplugins](https://github.com/mzimandl/koplugins): the *Release* workflow asks
it to sync, and it lists every release in its manifest.

### Betas

Betas are built on the `beta` branch with a pre-release version such as
`1.3.0-beta.1` (in `_meta.lua`, a CHANGELOG section `## 1.3.0-beta.1 – <date>`
and the tag `v1.3.0-beta.1`). The tag makes a GitHub pre-release: the README's
download button skips it, and ZenPM offers it only to readers with **Beta
updates** on in its settings. The final version merges `beta` into `master`
and is tagged as usual (`v1.3.0`).
