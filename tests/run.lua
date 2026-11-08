-- Off-device tests. Run from the repo root:  luajit tests/run.lua
package.path = "./?.lua;" .. package.path

local ChordPro = require("songbook/chordpro")
local Transpose = require("songbook/transpose")
local Render = require("songbook/render")
local Jam = require("songbook/jam")
local Discovery = require("songbook/discovery")
local Search = require("songbook/search")

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
eq(Transpose.chord("Am/G", 2, cz), "Hmi/A", "cz slash chord, minor as mi")
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

-- Notation conversion (song notation `from` -> shown `notation`) -----------
local en2cz = { notation = "cz", from = "en" }
local cz2en = { notation = "en", from = "cz" }
eq(Transpose.chord("Am", 0, cz), "Ami", "cz shows Am as Ami")
eq(Transpose.chord("Ami7", 0, en), "Am7", "en shows Ami7 as Am7")
eq(Transpose.chord("F#m7b5", 0, cz), "F#mi7b5", "cz minor seventh flat five")
eq(Transpose.chord("Cmaj7", 0, cz), "Cmaj7", "maj7 is not minor")
eq(Transpose.chord("Cma7", 0, cz), "Cma7", "ma7 is not minor")
eq(Transpose.chord("Cmin", 0, en), "Cmin", "min left as it is")
eq(Transpose.chord("Cmmaj7", 0, cz), "Cmimaj7", "minor major seventh")
eq(Transpose.chord("Asus4", 0, en), "Asus4", "sus untouched")
eq(Transpose.chord("B", 0, en2cz), "H", "en B -> cz H")
eq(Transpose.chord("Bb", 0, en2cz), "B", "en Bb -> cz B")
eq(Transpose.chord("Bbm", 0, en2cz), "Bmi", "en Bbm -> cz Bmi")
eq(Transpose.chord("G/B", 0, en2cz), "G/H", "en slash bass B -> H")
eq(Transpose.chord("Am", 2, en2cz), "Hmi", "en Am+2 -> cz Hmi")
eq(Transpose.chord("H7", 0, cz2en), "B7", "cz H7 -> en B7")
eq(Transpose.chord("B", 0, cz2en), "Bb", "cz B -> en Bb, even in a sharp key")
eq(Transpose.chord("B", 0, { notation = "en", from = "cz", flats = false }), "Bb", "unshifted keeps flat")
eq(Transpose.chord("Fis", 0, cz2en), "F#", "cz Fis -> en F#")
eq(Transpose.chord("Es", 0, cz2en), "Eb", "cz Es -> en Eb")
eq(Transpose.chord("Hmi/Fis", 0, cz2en), "Bm/F#", "cz slash chord -> en")
eq(Transpose.chord("C#", 0, cz), "C#", "unshifted sharp kept")
eq(Transpose.chord("Db", 0, cz), "Db", "unshifted flat kept")
eq(Transpose.chord("x", 0, cz2en), "x", "unparseable unchanged")
eq(Transpose.song_notation({ notation = "EN" }), "en", "song notation")
eq(Transpose.song_notation({ notation = "de" }), nil, "unknown song notation")
eq(Transpose.song_notation({}), nil, "no song notation")
eq(Transpose.key_choices("Am", "cz", "en")[1].name, "Cmi", "key choices from en to cz")
eq(Transpose.key_choices("B", "cz", "en")[12].name, "H", "en key B is cz H")

-- Key decides spelling ----------------------------------------------------
eq(Transpose.key_prefers_flats("C", 5, "en"), true, "C+5 = F major -> flats")
eq(Transpose.key_prefers_flats("C", 7, "en"), false, "C+7 = G major -> sharps")
eq(Transpose.key_prefers_flats("Ami", 0, "cz"), nil, "Ami is neutral")
eq(Transpose.key_prefers_flats("Dmi", 0, "cz"), true, "Dmi -> F major -> flats")
eq(Transpose.key_prefers_flats("Emi", 0, "cz"), false, "Emi -> G major -> sharps")
local kc = Transpose.key_choices("G", "cz")
eq(#kc, 12, "12 key choices")
eq(kc[1].name .. kc[1].shift, "C5", "G -> C is +5")
eq(kc[2].name .. kc[2].shift, "Db6", "G -> Db is +6, flat key")
eq(kc[3].name .. kc[3].shift, "D-5", "G -> D is -5")
eq(kc[8].name .. kc[8].shift, "G0", "original key")
eq(kc[11].name .. kc[11].shift, "B3", "cz B flat")
eq(kc[12].name .. kc[12].shift, "H4", "cz H")
eq(Transpose.key_choices("Ami", "cz")[1].name, "Cmi", "minor key choices")
eq(Transpose.key_choices("N.C.", "cz"), nil, "no choices for unparseable key")
eq(ChordPro.first_chord("{title: X}\n[*N.C.]ticho [x] [Ami]La [C]la"), "Ami", "first transposable chord")
eq(ChordPro.first_chord("bez akordu"), nil, "no chord")

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
eq(ChordPro.parse_meta("{title: A}\n{meta: notation en}").notation, "en", "parse_meta reads {meta}")
do
    local html = Render.html(ChordPro.parse("{title: A}\n{meta: notation en}\n{key: Bm}\n[Bm]x [G/B]y [Bb]z"), { notation = "cz" })
    eq(html:find("Hmi", 1, true) ~= nil and html:find("G/H", 1, true) ~= nil, true, "render converts an en song to cz")
    eq(html:find("Key: Hmi", 1, true) ~= nil, true, "render converts the key")
    local html2 = Render.html(ChordPro.parse("{title: A}\n[Ami]x [H7]y"), { notation = "en" })
    eq(html2:find("Am", 1, true) ~= nil and html2:find("B7", 1, true) ~= nil and html2:find("Ami", 1, true) == nil,
        true, "song without notation is read in the shown one, minor converted")
end
eq(ChordPro.duration("3:45"), 225, "duration m:ss")
eq(ChordPro.duration(" 225 "), 225, "duration in seconds")
eq(ChordPro.duration("1:02:03"), 3723, "duration h:mm:ss")
eq(ChordPro.duration("3 min"), nil, "duration not a time")
eq(ChordPro.duration("0:00"), nil, "zero duration")
eq(ChordPro.duration(nil), nil, "no duration")
eq(ChordPro.format_duration(225), "3:45", "format_duration")
eq(ChordPro.format_duration(65), "1:05", "format_duration pads seconds")
eq(Render.html(ChordPro.parse("{title: A}\n{tempo: 90}\n{duration: 245}\n[C]x"), {}):find("Tempo 90 · 4:05", 1, true) ~= nil,
    true, "length in the header")

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
eq(Render.truncate("Krátké", 6), "Krátké", "truncate fits")
eq(Render.truncate("Žluťoučký kůň", 6), "Žluťo…", "truncate utf8 with ellipsis")
eq(Render.width(Render.truncate("Žluťoučký kůň", 6)), 6, "truncate width")
eq(Render.truncate("ab cdef", 4), "ab…", "truncate drops trailing space")

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
local RAW = "https://raw.githubusercontent.com/u/r/"
eq(Repo.base_url("https://github.com/u/r"), RAW .. "HEAD/", "base_url repo")
eq(Repo.base_url(" https://github.com/u/r.git/ "), RAW .. "HEAD/", "base_url .git, slash, spaces")
eq(Repo.base_url("http://www.github.com/u/r?tab=readme"), RAW .. "HEAD/", "base_url www, query")
eq(Repo.base_url("https://github.com/u/r/tree/dev"), RAW .. "dev/", "base_url tree branch")
eq(Repo.base_url("https://github.com/u/r/tree/dev/songs/"), RAW .. "dev/songs/", "base_url tree subfolder")
eq(Repo.base_url("https://github.com/u/r/blob/dev/index.json"), RAW .. "dev/", "base_url blob index.json")
eq(Repo.base_url("https://github.com/u/r/blob/dev/x/index.json"), RAW .. "dev/x/", "base_url blob in subfolder")
eq(Repo.base_url(RAW .. "master/"), RAW .. "master/", "base_url raw unchanged")
eq(Repo.base_url("https://u.github.io/r/"), "https://u.github.io/r/", "base_url pages unchanged")
eq(Repo.base_url("https://github.com/u"), "https://github.com/u", "base_url user only unchanged")
eq(Repo.base_url(""), "", "base_url empty")
eq(Repo.default_name("https://github.com/u/r"), "u/r", "default_name github")
eq(Repo.default_name("https://github.com/u/r/tree/dev/songs"), "u/r (dev/songs)", "default_name github branch")
eq(Repo.default_name("https://example.com/my/songs/"), "example.com/my/songs", "default_name other")
eq(Repo.server_key("https://github.com/User/My.Songs"), "user-my.songs", "server_key github")
eq(Repo.server_key("https://github.com/u/r/tree/dev/songs"), "u-r-dev-songs", "server_key branch")
eq(Repo.server_key("https://example.com/a b/"), "example.com-a-b", "server_key other")
eq(Repo.server_key("https://github.com/u/r", { ["u-r"] = true, ["u-r-2"] = true }), "u-r-3", "server_key unique")
eq(Repo.server_key("???"), "repo", "server_key fallback")
eq(select(3, Repo.parse_index("", function() return { name = "Zpěvník", songs = {} } end)), "Zpěvník", "parse_index name")
eq(select(3, Repo.parse_index("", function() return { name = "  ", songs = {} } end)), nil, "parse_index blank name")
eq(Repo.sanitize_id("../etc/passwd"), "_etc_passwd", "sanitize traversal")
eq(Repo.sanitize_id("Pec nám spadla"), "Pec_n__m_spadla", "sanitize non-ascii")
local idx = Repo.parse_index("", function()
    return { songs = { { file = "songs/a-b.cho", title = "A" }, { title = "no file" }, { id = "x", file = "x.cho", updated = 3 } } }
end)
eq(#idx, 2, "parse_index skips entries without file")
eq(idx[1].id, "a-b", "parse_index id from file name")
eq(idx[2].updated, "3", "parse_index updated as string")
eq(select(2, Repo.parse_index("", function() error("bad") end)), "invalid index.json", "parse_index bad json")
local gh = Repo.github("https://github.com/u/r/tree/dev/my songs")
eq(gh.owner .. " " .. gh.repo .. " " .. gh.ref .. " " .. gh.path, "u r dev my songs", "github repository of a tree URL")
eq(Repo.github("https://github.com/u/r").ref .. "|" .. Repo.github("https://github.com/u/r").path, "HEAD|", "github default branch")
eq(Repo.github("https://raw.githubusercontent.com/u/r/main/").ref, "main", "github repository of a raw URL")
eq(Repo.github("https://example.com/songs/"), nil, "not a github repository")
local url, headers = Repo.request("https://github.com/u/r", "songs/píseň.cho", "ghp_x")
eq(url, "https://api.github.com/repos/u/r/contents/songs/p%C3%ADse%C5%88.cho", "request with token: API URL")
eq(headers.Authorization .. " " .. headers.Accept, "Bearer ghp_x application/vnd.github.raw+json", "request with token: headers")
eq(Repo.request("https://github.com/u/r/tree/dev/sub", "index.json", "t"), "https://api.github.com/repos/u/r/contents/sub/index.json?ref=dev",
    "request with token: branch and folder")
url, headers = Repo.request("https://github.com/u/r", "index.json")
eq(url .. " " .. tostring(headers), "https://raw.githubusercontent.com/u/r/HEAD/index.json nil", "request without token: raw URL")
url, headers = Repo.request("https://github.com/u/r", "https://cdn.example/x.cho", "t")
eq(url .. " " .. tostring(headers), "https://cdn.example/x.cho nil", "request of a full URL: no token")
url, headers = Repo.request("https://example.com/songs/", "index.json", "t")
eq(url .. " " .. tostring(headers), "https://example.com/songs/index.json nil", "request to another server: no token")
eq(#Repo.parse_index("", function() return { version = 1, songs = { { file = "a.cho" } } } end), 1, "parse_index version 1")
eq(select(2, Repo.parse_index("", function() return { version = 2, songs = { { file = "a.cho" } } } end)), Repo.ERR_NEWER,
    "parse_index newer version refused")

-- Search ----------------------------------------------------------------------
eq(Search.fold("Píseň ŽLUŤOUČKÝ kůň"), "pisen zlutoucky kun", "fold Czech")
eq(Search.fold("Straße Łódź Ærø Șțœ"), "strasse lodz aero stoe", "fold other Latin letters")
eq(Search.fold("Ёлка", function(s) return (s:gsub("Ё", "ё")) end), "ёлка", "fold leaves other scripts to lower")
eq(Search.fold(nil), "", "fold nil")
eq(Search.matches({ title = "Píseň", artist = "Lidová" }, "lidova"), true, "matches artist")
eq(Search.matches({ title = "Píseň" }, "x"), false, "matches nothing")
eq(Search.matches({ title = "Píseň" }, ""), true, "matches empty query")
local sorted = {}
for _i, s in ipairs(Search.sort({ { title = "Zima" }, { title = "Čert" }, { title = "ahoj" }, { title = "Dům" } })) do
    sorted[#sorted + 1] = s.title
end
eq(table.concat(sorted, " "), "ahoj Čert Dům Zima", "sort without regard to case and diacritics")

-- Jam server ------------------------------------------------------------------
local req = Jam.parse_request("GET /song.html?t=-2&n=en&x=a%20b+c HTTP/1.1\r\nHost: x\r\n\r\n")
eq(req.method, "GET", "jam parse method")
eq(req.path, "/song.html", "jam parse path")
eq(req.query.t, "-2", "jam parse query")
eq(req.query.x, "a b c", "jam parse url decoding")
eq(Jam.parse_request("garbage"), nil, "jam parse garbage")
eq(Jam.parse_request("GET / HTTP/1.0\r\n\r\n").path, "/", "jam parse root")
eq(Jam.json({ b = 1, a = 'say "hi"\n', c = true }), '{"a":"say \\"hi\\"\\u000a","b":1,"c":true}', "jam json")
eq(Jam.add_semitones(2, 3), 5, "jam semitones add")
eq(Jam.add_semitones(10, 3), 1, "jam semitones wrap up")
eq(Jam.add_semitones(-5, -3), 4, "jam semitones wrap down")
eq(Jam.add_semitones(nil, -2), -2, "jam semitones nil host")

local got
local ctx = {
    state = function() return { uid = "a/b", rev = "a/b@x", title = "Píseň" } end,
    song_html = function(o) got = o; return "<html>song</html>" end,
    song_cho = function() return nil end,
    labels = { waiting = "Čekám <na> píseň" },
    css = "pre{}",
}
local function handle(target) return Jam.handle(Jam.parse_request("GET " .. target .. " HTTP/1.1\r\n\r\n"), ctx) end
local resp = handle("/state.json")
eq(resp:match("^HTTP/1.1 (%d+)"), "200", "jam state status")
eq(resp:match("\r\n\r\n(.*)$"), '{"api":1,"rev":"a/b@x","title":"Píseň","uid":"a/b"}', "jam state body")
eq(resp:match("Content%-Length: (%d+)"), tostring(#resp:match("\r\n\r\n(.*)$")), "jam content length in bytes")
resp = handle("/song.html?t=30&n=xx&c=0&w=5")
eq(resp:match("\r\n\r\n(.*)$"), "<html>song</html>", "jam song body")
eq(got.shift, 11, "jam song shift clamped")
eq(got.notation, nil, "jam song bad notation ignored")
eq(got.show_chords, false, "jam song chords off")
eq(got.max_cols, 16, "jam song width clamped")
handle("/song.html")
eq(got.shift .. tostring(got.show_chords) .. tostring(got.max_cols), "0truenil", "jam song defaults")
eq(handle("/song.cho"):match("^HTTP/1.1 (%d+)"), "404", "jam no song source")
eq(handle("/nothing"):match("^HTTP/1.1 (%d+)"), "404", "jam unknown path")
eq(Jam.handle(Jam.parse_request("POST / HTTP/1.1\r\n\r\n"), ctx):match("^HTTP/1.1 (%d+)"), "405", "jam only GET")
eq(Jam.handle(nil, ctx):match("^HTTP/1.1 (%d+)"), "400", "jam bad request")
local page = handle("/"):match("\r\n\r\n(.*)$")
eq(page:find("Čekám &lt;na&gt; píseň", 1, true) ~= nil, true, "jam page escapes labels")
eq(page:find("pre{}", 1, true) ~= nil, true, "jam page has song css")
eq(page:find("%s", 1, true), nil, "jam page has no placeholders left")

-- Jam: repository endpoints and following ------------------------------------
eq(Jam.json({ songs = { { id = "a" }, { id = "b" } }, n = 1 }), '{"n":1,"songs":[{"id":"a"},{"id":"b"}]}', "jam json nested")
eq(Jam.song_id("my-repo/amazing.grace"), "my-repo_amazing.grace", "jam song id")
eq(Jam.song_id("..x/y z"), "x_y_z", "jam song id sanitized")
eq(Jam.uid_from_stem("repo~song"), "repo/song", "jam stem to uid")
eq(Jam.uid_from_stem("local-song"), "local-song", "jam stem local song")
eq(Jam.uid_from_stem("..~etc~passwd"), nil, "jam stem traversal")
eq(Jam.uid_from_stem("a~..~b"), nil, "jam stem traversal inside")
eq(Jam.uid_from_stem(".hidden"), nil, "jam stem leading dot")
eq(Jam.valid_uid("repo/song"), true, "jam valid uid")
eq(Jam.valid_uid("Pec nám spadla"), true, "jam valid uid with accents")
eq(Jam.valid_uid("a..b"), true, "jam valid uid with dots inside")
eq(Jam.valid_uid("../x"), false, "jam uid parent dir")
eq(Jam.valid_uid("a/b/c"), false, "jam uid two levels")
eq(Jam.valid_uid("/x"), false, "jam uid absolute")
eq(Jam.valid_uid("a/.."), false, "jam uid dot id")
eq(Jam.valid_uid("a\\b"), false, "jam uid backslash")
eq(Jam.valid_uid(""), false, "jam uid empty")
eq(Jam.valid_uid(nil), false, "jam uid nil")
eq(Jam.uid_from_stem("Pec nám spadla"), "Pec nám spadla", "jam stem with accents")
eq(Jam.song_path("r/Pec nám"), "songs/r~Pec%20n%C3%A1m.cho", "jam song path encoded")
eq(Jam.parse_request("GET /" .. Jam.song_path("r/Pec nám") .. " HTTP/1.1\r\n").path, "/songs/r~Pec nám.cho", "jam song path decodes back")
eq(Jam.handle(Jam.parse_request("GET /queue/add?uid=..%2F..%2Fx HTTP/1.1\r\n"), { request = function() return true end }):match("\r\n\r\n(.*)$"),
    '{"error":"missing","ok":false}', "jam request outside songs refused")
local Repo = require("songbook/repo")
local index = Jam.index({ { uid = "r/x", title = "X", updated = "5" }, { uid = "y", title = "Y" } }, "Jam")
eq(index, '{"name":"Jam","songs":[{"file":"songs/r~x.cho","id":"r_x","title":"X","uid":"r/x","updated":"5"},'
    .. '{"file":"songs/y.cho","id":"y","title":"Y","uid":"y"}],"version":1}', "jam index json")
local json_like = function(body)  -- the index uses no escapes, a Lua table literal is enough
    return loadstring("return " .. body:gsub('"(%w+)":', "%1="):gsub("%[", "{"):gsub("%]", "}"))()
end
local parsed = Repo.parse_index(index, json_like)
eq(parsed[1].id .. " " .. parsed[1].file .. " " .. parsed[1].updated, "r_x songs/r~x.cho 5", "jam index readable as repository")
eq(Jam.normalize_url("192.168.1.5", 8765), "http://192.168.1.5:8765/", "jam url ip")
eq(Jam.normalize_url(" 192.168.1.5:9000 ", 8765), "http://192.168.1.5:9000/", "jam url with port")
eq(Jam.normalize_url("http://kobo.local:8765/", 8765), "http://kobo.local:8765/", "jam url full")
eq(Jam.normalize_url("  ", 8765), nil, "jam url empty")
local function decode_table(t) return function() return t end end
local st = Jam.parse_state("", decode_table({ uid = "r/x", rev = "r/x@1", transpose = 14 }))
eq(st.uid .. " " .. st.rev .. " " .. st.transpose, "r/x r/x@1 2", "jam parse state")
st = Jam.parse_state("", decode_table({ notation = "cz" }))
eq(st and st.uid, nil, "jam parse state without song")
eq(Jam.parse_state("", function() error("bad") end), nil, "jam parse state bad json")
eq(st.api, 1, "jam parse state without api: version 1")
eq(Jam.parse_state("", decode_table({ api = 2 })).api, 2, "jam parse state api")
eq(st.name == nil and #st.peers, 0, "jam parse state from older songbooks: no name, no peers")
st = Jam.parse_state("", decode_table({ name = " Kobo\n", peers = {
    { url = "http://10.0.0.3:8765/", name = "Kindle" }, { url = "file:///etc/" }, "junk", { url = "http://[fe80::1]:80/" } } }))
eq(st.name .. " " .. #st.peers .. " " .. st.peers[1].url .. " " .. st.peers[1].name .. " " .. st.peers[2].url,
    "Kobo 2 http://10.0.0.3:8765/ Kindle http://[fe80::1]:80/", "jam parse state name and peers")

-- Jam: guests sharing their songs ----------------------------------------------
eq(Jam.query({ share = 8765, name = "Eva K", by = "" }), "?name=Eva%20K&share=8765", "jam query sorted and encoded")
eq(Jam.query({ name = nil }), "", "jam empty query")
eq(Jam.peer_url("10.0.0.3", "8765"), "http://10.0.0.3:8765/", "jam peer url")
eq(Jam.peer_url("fe80::1", 80), "http://[fe80::1]:80/", "jam peer url ipv6")
eq(Jam.peer_url("10.0.0.3", "0"), nil, "jam peer url bad port")
eq(Jam.peer_url("10.0.0.3", "1.5"), nil, "jam peer url fractional port")
eq(Jam.peer_url("evil.com/x?", 80), nil, "jam peer url only from an ip")
eq(Jam.peer_url(nil, 80), nil, "jam peer url without ip")
local joined, from
local pctx = {
    state = function(peer_url) return { asked = peer_url or "-" } end,
    join = function(peer) joined = peer end,
    request = function() return nil, "missing" end,
    request_from = function(url, uid, by) from = url .. " " .. uid .. " " .. tostring(by); return true end,
    songs = function() return {} end,
}
local function phandle(target, ip)
    local r = Jam.parse_request("GET " .. target .. " HTTP/1.1\r\n\r\n")
    r.ip = ip
    return Jam.handle(r, pctx):match("\r\n\r\n(.*)$")
end
eq(phandle("/state.json?name=Eva&share=8770", "10.0.0.3"), '{"api":1,"asked":"http://10.0.0.3:8770/"}', "jam state for a sharing guest")
eq(joined.url .. " " .. joined.name, "http://10.0.0.3:8770/ Eva", "jam guest joins with its name")
joined = nil
eq(phandle("/state.json", "10.0.0.3"), '{"api":1,"asked":"-"}', "jam state for a guest not sharing")
eq(joined, nil, "jam guest without share port doesn't join")
eq(phandle("/state.json?share=8770", nil), '{"api":1,"asked":"-"}', "jam no join without the guest's address")
eq(phandle("/queue/add?from=8770&uid=r%2Fx&by=Eva", "10.0.0.3"), '{"ok":true}', "jam request of a guest's song")
eq(from, "http://10.0.0.3:8770/ r/x Eva", "jam guest's song fetched from the asking guest")
from = nil
eq(phandle("/queue/add?from=8770&uid=..%2F..%2Fx", "10.0.0.3"), '{"error":"missing","ok":false}', "jam guest's uid checked")
eq(phandle("/queue/add?from=nope&uid=x", "10.0.0.3"), '{"error":"missing","ok":false}', "jam guest's port checked")
eq(from, nil, "jam bad guest requests not passed on")
pctx.library = true
eq(Jam.handle(Jam.parse_request("GET /state.json HTTP/1.1\r\n\r\n"), pctx):match("^HTTP/1.1 (%d+)"), "404", "jam library has no state")
eq(Jam.handle(Jam.parse_request("GET /queue/add?uid=x HTTP/1.1\r\n\r\n"), pctx):match("^HTTP/1.1 (%d+)"), "404", "jam library takes no requests")
eq(Jam.handle(Jam.parse_request("GET /index.json HTTP/1.1\r\n\r\n"), pctx):match("^HTTP/1.1 (%d+)"), "200", "jam library serves its index")

ctx.songs = function() return { { uid = "r/x", title = "X" } } end
ctx.song_file = function(uid) return uid == "r/x" and "{title: X}" or nil end
ctx.name = "Jam"
resp = handle("/index.json")
eq(resp:match("\r\n\r\n(.*)$"):find('"file":"songs/r~x.cho"', 1, true) ~= nil, true, "jam serves index")
eq(handle("/songs/r~x.cho"):match("\r\n\r\n(.*)$"), "{title: X}", "jam serves song file")
eq(handle("/songs/r~y.cho"):match("^HTTP/1.1 (%d+)"), "404", "jam missing song file")
eq(handle("/songs/..~r~x.cho"):match("^HTTP/1.1 (%d+)"), "404", "jam song file traversal")

-- Jam: playlist ----------------------------------------------------------------
eq(Jam.clean_name("  Pavel\n "), "Pavel", "jam name trimmed")
eq(Jam.clean_name("   "), nil, "jam blank name")
eq(Jam.clean_name(string.rep("ž", 40)), string.rep("ž", 29) .. "…", "jam long name shortened")
local queue, history = {}, {}
eq(Jam.add_request(queue, { uid = "a" }), true, "jam request added")
eq(select(2, Jam.add_request(queue, { uid = "a" })), "queued", "jam request duplicate")
for i = 2, Jam.MAX_QUEUE do Jam.add_request(queue, { uid = "s" .. i }) end
eq(select(2, Jam.add_request(queue, { uid = "z" })), "full", "jam queue full")
local p = { history = history, queue = queue }
eq(Jam.play(p, { uid = "a" }), true, "jam play changes playlist")
eq(#queue .. " " .. #history .. " " .. p.now.uid, (Jam.MAX_QUEUE - 1) .. " 0 a", "jam play leaves queue, now playing")
eq(Jam.play(p, { uid = "a" }), false, "jam play the song now playing again")
Jam.play(p, { uid = "b" })
eq(#history .. " " .. history[1].uid .. " " .. p.now.uid, "1 a b", "jam previous song goes to played")
eq(Jam.finish(p), true, "jam finish")
eq(#history .. " " .. history[2].uid .. " " .. tostring(p.now), "2 b nil", "jam finished song played")
eq(Jam.finish(p), false, "jam finish with nothing playing")
Jam.play(p, { uid = "a" })
Jam.finish(p)
eq(#history, 3, "jam song played again later")
for i = 1, Jam.MAX_HISTORY do Jam.play(p, { uid = "h" .. i }) end
Jam.finish(p)
eq(#history .. " " .. history[#history].uid, Jam.MAX_HISTORY .. " h" .. Jam.MAX_HISTORY, "jam history capped")
eq(Jam.json({}), "[]", "jam json empty array")
ctx.playlist = function() return { now = { uid = "r/n", title = "N" }, history = {}, queue = { { uid = "r/x", title = "X", by = "Eva" } } } end
local requested_by
ctx.request = function(uid, by) requested_by = by; return uid == "r/x" or nil, "missing" end
eq(handle("/playlist.json"):match("\r\n\r\n(.*)$"), '{"history":[],"now":{"title":"N","uid":"r/n"},"queue":[{"by":"Eva","title":"X","uid":"r/x"}]}', "jam playlist json")
eq(handle("/queue/add?uid=r%2Fx&by=%20Eva%20"):match("\r\n\r\n(.*)$"), '{"ok":true}', "jam request ok")
eq(requested_by, "Eva", "jam request name cleaned")
eq(handle("/queue/add?uid=q"):match("\r\n\r\n(.*)$"), '{"error":"missing","ok":false}', "jam request error")
eq(handle("/queue/add"):match("\r\n\r\n(.*)$"), '{"error":"missing","ok":false}', "jam request without uid")
eq(page:find("%%1", 1, true), nil, "jam page percent signs unescaped")
local pl = Jam.parse_playlist("", decode_table({ queue = { { title = "A", by = "Eva", at = "5" }, { by = "x" }, 7 } }))
eq(#pl.queue .. " " .. #pl.history .. " " .. pl.queue[1].by .. " " .. pl.queue[1].at, "1 0 Eva 5", "jam parse playlist")
eq(pl.now, nil, "jam parse playlist without now (older songbooks)")
eq(Jam.parse_playlist("", decode_table({ now = { title = "N", uid = "r/n" } })).now.uid, "r/n", "jam parse playlist now")
eq(Jam.parse_playlist("", function() error("bad") end), nil, "jam parse playlist bad json")
eq(Jam.find_id({ { uid = "a" }, { uid = "r/x" } }, "r_x"), "r/x", "jam find id")
eq(Jam.find_id({ { uid = "a" } }, "b"), nil, "jam find id missing")
requested_by = nil
local request_uid
ctx.request = function(uid) request_uid = uid; return true end
eq(handle("/queue/add?id=r_x"):match("\r\n\r\n(.*)$"), '{"ok":true}', "jam request by id")
eq(request_uid, "r/x", "jam request by id resolves uid")
eq(handle("/queue/add?id=nope"):match("\r\n\r\n(.*)$"), '{"error":"missing","ok":false}', "jam request unknown id")

local web = Render.html(ChordPro.parse("{title: W}\n[C]La"), { web = true })
eq(web:sub(1, 15), "<!DOCTYPE html>", "web render is html5")
eq(web:find("viewport", 1, true) ~= nil, true, "web render has viewport")
eq(Render.html(ChordPro.parse("{title: W}"), {}):find("prefers-color-scheme", 1, true), nil, "e-reader render has no web css")

-- Discovery ----------------------------------------------------------------
eq(Discovery.announce(8765, "Kindle\nPW"), "SONGBOOK 1 8765 Kindle PW", "announce cleans the name")
local book = Discovery.parse_announce("SONGBOOK 1 8765 Kindle PW")
eq(book.port .. " " .. book.name, "8765 Kindle PW", "announce parsed")
eq(Discovery.parse_announce("SONGBOOK 1 8765").name, "", "announce without a name")
eq(Discovery.parse_announce("SONGBOOK 2 8765 X"), nil, "other version ignored")
eq(Discovery.parse_announce("SONGBOOK 1 99999 X"), nil, "bad port ignored")
eq(Discovery.parse_announce("GAME 1 7531 X"), nil, "battleships announce ignored")
eq(Discovery.is_discover(Discovery.discover()), true, "discover recognised")
eq(Discovery.is_discover("DISCOVER 1"), false, "battleships discover ignored")
eq(Render.width(Discovery.clean_name(string.rep("ž", 40))), Discovery.MAX_NAME, "name shortened by characters")
eq(table.concat(Discovery.broadcasts("10.1.2.3"), ","), "255.255.255.255,10.1.2.255", "broadcasts")
eq(table.concat(Discovery.broadcasts(nil), ","), "255.255.255.255", "broadcasts without our address")
eq(Discovery.pick_ip({ { name = "eth0", ipv4 = "10.0.0.2" }, { name = "wlan0", ipv4 = "192.168.4.3 / 192.168.4.9", wireless = true } }),
    "192.168.4.3", "pick_ip: wireless interface first")
eq(Discovery.pick_ip({ { name = "usb0", ipv4 = "169.254.1.2" }, { name = "eth0", ipv4 = "10.0.0.2" } }), "10.0.0.2",
    "pick_ip: no link-local address")
eq(Discovery.pick_ip({ { name = "wlan0", wireless = true } }), nil, "pick_ip: no address")
eq(Discovery.pick_ip(nil), nil, "pick_ip: no interfaces")
eq(Discovery.url({ ip = "10.0.0.3", port = 8765 }), "http://10.0.0.3:8765/", "found songbook url")
eq(Jam.normalize_url("10.0.0.3", 8765), Discovery.url({ ip = "10.0.0.3", port = 8765 }), "same url as typed")

-- L10n: the plugin's own catalogs ------------------------------------------
local L10n = require("songbook/l10n")
eq(table.concat(L10n.languages("cs_CZ.UTF-8"), ","), "cs_CZ,cs", "catalog names for a locale")
eq(#L10n.languages("C"), 0, "no catalog for C")
local loaded = {}
local cat = L10n.catalog("cs_CZ", function(name) loaded[#loaded + 1] = name; return name == "cs" and { Hi = "Ahoj" } or nil end)
eq(table.concat(loaded, ",") .. " " .. cat.Hi, "cs_CZ,cs Ahoj", "catalog falls back to the base language")
local tr = L10n.wrap(function(s) return "<" .. s .. ">" end, cat)
eq(tr("Hi") .. tr("Bye"), "Ahoj<Bye>", "catalog first, then gettext")
-- every _("…") of main.lua and songbook/ui/ is translated, and the catalog has no stale entries
local used = {}
local function msgids(path)
    local src = io.open(path):read("*a")
    for lit in src:gmatch('_%(%s*(".-[^\\]")%s*%)') do used[loadstring("return " .. lit)()] = true end
    for lit in src:gmatch('_%(%s*%[%[(.-)%]%]%s*%)') do used[lit] = true end
end
msgids("main.lua")
local ui_files = io.popen("ls songbook/ui/*.lua")
local n_ui = 0
for path in ui_files:lines() do msgids(path); n_ui = n_ui + 1 end
ui_files:close()
eq(n_ui > 0, true, "UI modules found for the translation check")
local cs = require("songbook/l10n/cs")
local missing, stale = {}, {}
for id in pairs(used) do if not cs[id] then missing[#missing + 1] = id end end
for id in pairs(cs) do if not used[id] then stale[#stale + 1] = id end end
table.sort(missing); table.sort(stale)
eq(table.concat(missing, " | "), "", "all strings translated to Czech")
eq(table.concat(stale, " | "), "", "no unused Czech translations")

print(("%d passed, %d failed"):format(passed, failed))
os.exit(failed == 0 and 0 or 1)
