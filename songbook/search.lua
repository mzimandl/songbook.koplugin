--[[--
Searching and sorting song lists without regard to case and diacritics
(pure Lua 5.1 / LuaJIT): "pisen" finds "Píseň", "Čert" sorts among the C's.
Latin letters with diacritics (Latin-1 Supplement, Latin Extended-A, Romanian
ș ț) are folded to ASCII; other characters stay as they are, so main.lua
lowercases them first with KOReader's util.stringLower (`lower` below).
]]

local M = {}

local FOLD = {
    ["À"]="a", ["Á"]="a", ["Â"]="a", ["Ã"]="a", ["Ä"]="a", ["Å"]="a", ["Æ"]="ae", ["Ç"]="c",
    ["È"]="e", ["É"]="e", ["Ê"]="e", ["Ë"]="e", ["Ì"]="i", ["Í"]="i", ["Î"]="i", ["Ï"]="i",
    ["Ð"]="d", ["Ñ"]="n", ["Ò"]="o", ["Ó"]="o", ["Ô"]="o", ["Õ"]="o", ["Ö"]="o", ["Ø"]="o",
    ["Ù"]="u", ["Ú"]="u", ["Û"]="u", ["Ü"]="u", ["Ý"]="y", ["Þ"]="th", ["ß"]="ss", ["à"]="a",
    ["á"]="a", ["â"]="a", ["ã"]="a", ["ä"]="a", ["å"]="a", ["æ"]="ae", ["ç"]="c", ["è"]="e",
    ["é"]="e", ["ê"]="e", ["ë"]="e", ["ì"]="i", ["í"]="i", ["î"]="i", ["ï"]="i", ["ð"]="d",
    ["ñ"]="n", ["ò"]="o", ["ó"]="o", ["ô"]="o", ["õ"]="o", ["ö"]="o", ["ø"]="o", ["ù"]="u",
    ["ú"]="u", ["û"]="u", ["ü"]="u", ["ý"]="y", ["þ"]="th", ["ÿ"]="y", ["Ā"]="a", ["ā"]="a",
    ["Ă"]="a", ["ă"]="a", ["Ą"]="a", ["ą"]="a", ["Ć"]="c", ["ć"]="c", ["Ĉ"]="c", ["ĉ"]="c",
    ["Ċ"]="c", ["ċ"]="c", ["Č"]="c", ["č"]="c", ["Ď"]="d", ["ď"]="d", ["Đ"]="d", ["đ"]="d",
    ["Ē"]="e", ["ē"]="e", ["Ĕ"]="e", ["ĕ"]="e", ["Ė"]="e", ["ė"]="e", ["Ę"]="e", ["ę"]="e",
    ["Ě"]="e", ["ě"]="e", ["Ĝ"]="g", ["ĝ"]="g", ["Ğ"]="g", ["ğ"]="g", ["Ġ"]="g", ["ġ"]="g",
    ["Ģ"]="g", ["ģ"]="g", ["Ĥ"]="h", ["ĥ"]="h", ["Ħ"]="h", ["ħ"]="h", ["Ĩ"]="i", ["ĩ"]="i",
    ["Ī"]="i", ["ī"]="i", ["Ĭ"]="i", ["ĭ"]="i", ["Į"]="i", ["į"]="i", ["İ"]="i", ["ı"]="i",
    ["Ĵ"]="j", ["ĵ"]="j", ["Ķ"]="k", ["ķ"]="k", ["ĸ"]="k", ["Ĺ"]="l", ["ĺ"]="l", ["Ļ"]="l",
    ["ļ"]="l", ["Ľ"]="l", ["ľ"]="l", ["Ŀ"]="l", ["ŀ"]="l", ["Ł"]="l", ["ł"]="l", ["Ń"]="n",
    ["ń"]="n", ["Ņ"]="n", ["ņ"]="n", ["Ň"]="n", ["ň"]="n", ["ŉ"]="n", ["Ō"]="o", ["ō"]="o",
    ["Ŏ"]="o", ["ŏ"]="o", ["Ő"]="o", ["ő"]="o", ["Œ"]="oe", ["œ"]="oe", ["Ŕ"]="r", ["ŕ"]="r",
    ["Ŗ"]="r", ["ŗ"]="r", ["Ř"]="r", ["ř"]="r", ["Ś"]="s", ["ś"]="s", ["Ŝ"]="s", ["ŝ"]="s",
    ["Ş"]="s", ["ş"]="s", ["Š"]="s", ["š"]="s", ["Ţ"]="t", ["ţ"]="t", ["Ť"]="t", ["ť"]="t",
    ["Ŧ"]="t", ["ŧ"]="t", ["Ũ"]="u", ["ũ"]="u", ["Ū"]="u", ["ū"]="u", ["Ŭ"]="u", ["ŭ"]="u",
    ["Ů"]="u", ["ů"]="u", ["Ű"]="u", ["ű"]="u", ["Ų"]="u", ["ų"]="u", ["Ŵ"]="w", ["ŵ"]="w",
    ["Ŷ"]="y", ["ŷ"]="y", ["Ÿ"]="y", ["Ź"]="z", ["ź"]="z", ["Ż"]="z", ["ż"]="z", ["Ž"]="z",
    ["ž"]="z",
    ["Ș"]="s", ["ș"]="s", ["Ț"]="t", ["ț"]="t",
}

--- `s` lowercased and without diacritics. `lower` (optional) lowercases
-- the remaining non-ASCII letters, e.g. KOReader's util.stringLower.
function M.fold(s, lower)
    s = tostring(s or "")
    s = s:gsub("[\195-\197\200][\128-\191]", FOLD):lower()
    if lower and s:find("[\128-\255]") then s = lower(s) end
    return s
end

--- Does song { title, artist } match `query` (already folded, may be empty)?
function M.matches(song, query, lower)
    if not query or query == "" then return true end
    return M.fold(song.title, lower):find(query, 1, true) ~= nil
        or (song.artist ~= nil and M.fold(song.artist, lower):find(query, 1, true) ~= nil)
end

--- Sort songs by title (folded, then as written), in place.
function M.sort(songs, lower)
    local keys = {}
    for _i, song in ipairs(songs) do keys[song] = M.fold(song.title, lower) end
    table.sort(songs, function(a, b)
        if keys[a] ~= keys[b] then return keys[a] < keys[b] end
        return (a.title or "") < (b.title or "")
    end)
    return songs
end

return M
