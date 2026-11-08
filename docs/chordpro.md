# Writing songs

[← Songbook](../README.md)

Songs are text files in the [ChordPro](https://www.chordpro.org/) format, with
the chords in square brackets right before the syllable they belong to:

```
{title: Skákal pes}
{artist: Lidová}
{key: C}

[C]Skákal pes [G]přes oves,
[C]přes zelenou [G]louku,
```

[template.cho](https://github.com/mzimandl/songbook-library/blob/master/template.cho)
in Songbook Library uses everything the plugin reads; copy it to start a new
song. Put your files into `koreader/songbook/songs/` to have them in *My songs*,
or into a [song repository](repositories.md).

## What the plugin reads

| | |
|---|---|
| Meta | `{title}` `{t}` `{subtitle}` `{st}` `{artist}` `{key}` `{capo}` `{tempo}` `{duration}` `{meta: name value}` … |
| Sections | `{start_of_chorus}`/`{soc}`, verse, bridge, tab, grid; labels as `{soc: Ref.}` or `label="…"` |
| Repeat | `{chorus}` |
| Comments | `{c:}` `{ci:}` `{cb:}`; lines starting with `#` are ignored |
| Chords | `[Am]` inline, slash chords `[C/H]`, annotations `[*N.C.]` (never transposed) |
| Czech | `Ami`, `Fis`, `Cis`, `Es`, `As`, `H`, `B` (= B♭); `Esus4`/`Asus2` are not read as flats |

`{duration: 3:45}` sets the song's length for autoscroll; `{key}` is shown and
transposed with the song.
