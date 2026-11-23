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
| Sections | `{start_of_chorus}`/`{soc}`, verse, bridge, tab, grid (see below); labels as `{soc: Ref.}` or `label="…"` |
| Repeat | `{chorus}` |
| Comments | `{c:}` `{ci:}` `{cb:}`; lines starting with `#` are ignored |
| Chords | `[Am]` inline, slash chords `[C/H]`, annotations `[*N.C.]` (never transposed) |
| Notation | `{meta: notation en}` (B, B♭ = `Bb`, `Am`) or `{meta: notation cz}` (H, B = B♭, `Ami`) |
| Czech | `Ami`, `Fis`, `Cis`, `Es`, `As`, `H`, `B` (= B♭); `Esus4`/`Asus2` are not read as flats |

`{duration: 3:45}` sets the song's length for autoscroll; `{key}` is shown and
transposed with the song.

## Rhythm: chords without words

For an instrumental part, write a chord grid. Each cell is one beat, `.` means
the chord goes on, `|` is a bar line and `~` puts two chords on one beat
(`G~Am`); `||`, `|:`, `:|`, `%` (repeat the bar) work too. The plugin shows it
as a table, so the beats line up from row to row in any font; its chords are
transposed like the others.

```
{start_of_grid: label="Instrumental"}
| Am . . G  | Am C  . G  |
| F  . Em . | Am .  G  . |
{end_of_grid}
```

Text before the first bar line (`x2 | …`) and after the last one is shown
beside the grid. With chords hidden the grid isn't shown, nor are tabs.

Between chords in a line, more spaces than one keep their width:
`Kitty alone [C]    [G]` leaves a gap before G, so a pause or the chords
after the words can be spaced without a grid.

## Chord notation

The reader shows chords in the notation chosen in the settings, whatever the
song is written in: Czech `H`, `B` (= B♭) and `Ami`, or English `B`, `Bb` and
`Am`. The root and the minor mark are converted (`Ami` ↔ `Am`, `Fis` → `F#`);
`maj7`, `sus`, `dim` and the rest stay as written.

`B` means a different note in each notation, so a song says which one it is
written in with `{meta: notation en}` or `{meta: notation cz}`. Without it the
plugin reads the song in the notation chosen in the settings. Songbook Library
is written in the English notation.
