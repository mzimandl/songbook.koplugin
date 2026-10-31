-- Off-device tests. Run from the repo root:  luajit tests/run.lua
package.path = "songbook.koplugin/?.lua;" .. package.path

local ChordPro = require("songbook/chordpro")
local Transpose = require("songbook/transpose")
local Render = require("songbook/render")

local passed, failed = 0, 0
local function eq(actual, expected, name)
    if actual == expected then
        passed = passed + 1
    else
        failed = failed + 1
        print(("FAIL %s\n  expected: %q\n  actual:   %q"):format(name, tostring(expected), tostring(actual)))
    end
end

-- Transpose: Czech notation ---------------------------------------------
local cz = { notation = "cz" }
eq(Transpose.chord("Ami", 2, cz), "Hmi", "cz Ami+2")
eq(Transpose.chord("H7", 1, cz), "C7", "cz H7+1")
eq(Transpose.chord("B", 1, cz), "H", "cz B is Bb")
eq(Transpose.chord("C", -2, cz), "B", "cz C-2 -> B")
eq(Transpose.chord("C", 10, cz), "B", "cz C+10 -> B")
eq(Transpose.chord("Fis", 1, cz), "G", "cz Fis+1")
eq(Transpose.chord("F", 1, cz), "F#", "cz F+1 sharp default up")
eq(Transpose.chord("Es", 2, cz), "F", "cz Es+2")
eq(Transpose.chord("Esus4", 1, cz), "Fsus4", "cz Esus4 not E-flat")
eq(Transpose.chord("Asus2", 2, cz), "Hsus2", "cz Asus2 not A-flat")
eq(Transpose.chord("Asmi", 1, cz), "Ami", "cz Asmi (Ab minor)")
eq(Transpose.chord("Cis", 2, cz), "Dis", "cz german style kept")
eq(Transpose.chord("Bb", 2, cz), "C", "cz Bb treated as B")
eq(Transpose.chord("Am/G", 2, cz), "Hm/A", "cz slash chord")
eq(Transpose.chord("C/H", 2, cz), "D/C#", "cz slash bass H")
eq(Transpose.chord("C6/9", 2, cz), "D6/9", "6/9 is not a slash chord")
eq(Transpose.chord("N.C.", 3, cz), "N.C.", "N.C. unchanged")
eq(Transpose.chord("(Dmaj7)", 2, cz), "(Emaj7)", "parenthesised")
eq(Transpose.chord("Ami", 0, cz), "Ami", "zero shift keeps spelling")
eq(Transpose.chord("Ami", 12, cz), "Ami", "octave shift keeps spelling")

-- Transpose: English notation -------------------------------------------
local en = { notation = "en" }
eq(Transpose.chord("B", 1, en), "C", "en B is B natural")
eq(Transpose.chord("Bb7", 2, en), "C7", "en Bb7+2")
eq(Transpose.chord("A", 1, en), "A#", "en A+1 up -> sharp")
eq(Transpose.chord("A", 1, { notation = "en", flats = true }), "Bb", "en forced flats")
eq(Transpose.chord("C", -1, en), "B", "en C-1")
eq(Transpose.chord("D", -1, en), "Db", "en down -> flat")

-- Key decides spelling ----------------------------------------------------
eq(Transpose.key_prefers_flats("C", 5, "en"), true, "C+5 = F major -> flats")
eq(Transpose.key_prefers_flats("C", 7, "en"), false, "C+7 = G major -> sharps")
eq(Transpose.key_prefers_flats("Ami", 0, "cz"), nil, "Ami is neutral")
eq(Transpose.key_prefers_flats("Dmi", 0, "cz"), true, "Dmi -> F major -> flats")
eq(Transpose.key_prefers_flats("Emi", 0, "cz"), false, "Emi -> G major -> sharps")

-- Parser --------------------------------------------------------------------
local song = ChordPro.parse([[
{title: Testovací píseň}
{artist: Lidová}
{key: Ami}
# a comment line
[Ami]Ahoj [G]světe, [C]já
jsem tu

{soc: Ref.}
[F]La [G]la
{eoc}
{c: Opakovat}
{chorus}
{sot}
e|--0--|
{eot}
]])
eq(song.meta.title, "Testovací píseň", "meta title")
eq(song.meta.artist, "Lidová", "meta artist")
eq(song.meta.key, "Ami", "meta key")
eq(#song.blocks, 5, "block count")
eq(song.blocks[1].type, "plain", "implicit verse")
eq(#song.blocks[1].lines, 2, "verse lines")
eq(song.blocks[1].lines[1].segments[1].chord, "Ami", "first chord")
eq(song.blocks[1].lines[1].segments[2].text, "světe, ", "segment text")
eq(song.blocks[2].type, "chorus", "chorus block")
eq(song.blocks[2].label, "Ref.", "chorus label")
eq(song.blocks[3].lines[1].type, "comment", "comment line")
eq(song.blocks[4].type, "chorus_ref", "{chorus} ref")
eq(song.blocks[5].type, "tab", "tab block")
eq(song.blocks[5].lines[1].text, "e|--0--|", "tab raw line")

local segs = ChordPro.parse_lyrics("[C][G]")
eq(#segs, 2, "chord-only line segment count")
eq(segs[2].chord, "G", "chord-only second chord")
local an = ChordPro.parse_lyrics("[*N.C.]ticho")
eq(an[1].annotation, true, "annotation flag")
eq(ChordPro.parse("{t:X}\r\n[C]a\r\n").meta.title, "X", "CRLF + short directive")
eq(ChordPro.parse('{start_of_verse: label="Sloka 1"}\n[C]a\n{end_of_verse}').blocks[1].label,
    "Sloka 1", "label= syntax")
eq(ChordPro.parse_meta("{title: A}\n{artist: B}\n[C]x").artist, "B", "parse_meta")

-- Layout ------------------------------------------------------------------
local function rows(line, cols)
    return Render.layout_line(ChordPro.parse_lyrics(line), cols)
end
local r = rows("[Ami]Ahoj [G]světe")
eq(r[1].chords, "Ami  G", "chords aligned (utf8)")
eq(r[1].lyrics, "Ahoj světe", "lyrics")
r = rows("Žlu[Ami]ťou[Dmaj7]čký")
eq(r[1].chords, "   Ami Dmaj7", "utf8 alignment with diacritics")
eq(r[1].lyrics, "Žluťou-čký", "mid-word hyphen padding")
r = rows("[C][G][Ami]")
eq(r[1].chords, "C G Ami", "chord-only line")
eq(r[1].lyrics, "", "chord-only line has no lyrics")
r = rows("[C]jedna dva [G]tři čtyři [Ami]pět šest sedm", 12)
eq(#r, 4, "wrap into 4 rows")
eq(r[1].lyrics, "jedna dva", "wrap row 1")
eq(r[2].chords, "G", "wrap row 2 chord at col 0")
eq(r[2].lyrics, "tři čtyři", "wrap row 2")
eq(r[3].chords, "Ami", "wrap row 3 chord")
eq(r[3].lyrics, "pět šest", "wrap row 3")
eq(r[4].lyrics, "sedm", "wrap row 4")
for i, row in ipairs(r) do
    eq(math.max(Render.width(row.chords), Render.width(row.lyrics)) <= 12, true, "row " .. i .. " fits")
end
eq(Render.width("žluťoučký"), 9, "utf8 width")

-- HTML ----------------------------------------------------------------------
local html = Render.html(song, { transpose = 2, notation = "cz" })
eq(html:find("<h1>Testovací píseň</h1>", 1, true) ~= nil, true, "html title")
eq(html:find("Key: Hmi", 1, true) ~= nil, true, "html transposed key")
eq(html:find("Transposed +2", 1, true) ~= nil, true, "html transposed note")
eq(html:find('<span class="c">Hmi  A', 1, true) ~= nil, true, "html chord row transposed")
eq(html:find('<div class="chorus">', 1, true) ~= nil, true, "html chorus")
local html2 = Render.html(song, { repeat_chorus = true })
local _, n = html2:gsub('<div class="chorus">', "")
eq(n, 2, "repeat_chorus replays chorus")
local ly = Render.html(song, { show_chords = false })
eq(ly:find('class="c"', 1, true), nil, "lyrics-only has no chords")
eq(ly:find("Ahoj světe, já", 1, true) ~= nil, true, "lyrics-only text joined")
eq(Render.html(ChordPro.parse("{title: a<b & c}"), {}):find("a&lt;b &amp; c", 1, true) ~= nil,
    true, "html escaping")

-- Repo helpers ------------------------------------------------------------
local Repo = require("songbook/repo")
eq(Repo.join("https://x.org/s", "index.json"), "https://x.org/s/index.json", "join adds slash")
eq(Repo.join("https://x.org/s/", "/songs/a.cho"), "https://x.org/s/songs/a.cho", "join strips slash")
eq(Repo.join("https://x.org/s/", "https://y.org/a.cho"), "https://y.org/a.cho", "join absolute url")
eq(Repo.sanitize_id("../etc/passwd"), "_etc_passwd", "sanitize traversal")
eq(Repo.sanitize_id("Pec nám spadla"), "Pec_n__m_spadla", "sanitize non-ascii")
local idx = Repo.parse_index("", function()
    return { songs = { { file = "songs/a-b.cho", title = "A" }, { title = "no file" }, { id = "x", file = "x.cho", updated = 3 } } }
end)
eq(#idx, 2, "parse_index skips entries without file")
eq(idx[1].id, "a-b", "parse_index id from file name")
eq(idx[2].updated, "3", "parse_index updated as string")
eq(select(2, Repo.parse_index("", function() error("bad") end)), "invalid index.json", "parse_index bad json")

print(("%d passed, %d failed"):format(passed, failed))
os.exit(failed == 0 and 0 or 1)
