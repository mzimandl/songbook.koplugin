--[[--
Song table -> HTML renderer (pure Lua 5.1 / LuaJIT).

Each chord is stacked over its syllable in an inline block (see line_html()),
so chords stay aligned in any font and long lines wrap between words.

opts = {
  transpose     = 0,          -- semitones
  notation      = "cz",       -- shown notation: "cz" (H/B, Ami) or "en" (B/Bb, Am);
                              -- songs are read in their {meta: notation}, else this one
  show_chords   = true,       -- false = lyrics only
  repeat_chorus = false,      -- {chorus} replays the last chorus instead of a label
  font_size     = nil,        -- CSS size of the song lines (default 1em)
  web           = false,      -- HTML5 page for phone browsers (jam session) instead of e-reader XHTML
  labels        = { key=, capo=, transposed=, chorus= },
}
]]

local ChordPro = require("songbook/chordpro")
local Transpose = require("songbook/transpose")

local M = {}

local DEFAULT_LABELS = {
    key = "Key", capo = "Capo", transposed = "Transposed",
    chorus = "Ref.", tempo = "Tempo",
}

--- Number of UTF-8 characters in s.
function M.width(s)
    local n = 0
    for i = 1, #s do
        local b = s:byte(i)
        if b < 0x80 or b >= 0xC0 then n = n + 1 end
    end
    return n
end
local width = M.width

--- Shorten s to at most n UTF-8 characters, ending with "…" when cut.
function M.truncate(s, n)
    if width(s) <= n then return s end
    local count, cut = 0, #s + 1
    for i = 1, #s do
        local b = s:byte(i)
        if b < 0x80 or b >= 0xC0 then
            count = count + 1
            if count == n then cut = i break end   -- start of the n-th char: "…" goes here
        end
    end
    return (s:sub(1, cut - 1):gsub("%s+$", "")) .. "…"
end

local function rtrim(s) return (s:gsub("%s+$", "")) end

local function escape(s)
    return (s:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"):gsub('"', "&quot;"))
end

--- Split one lyrics line (already-transposed segments) into words.
-- Returns a list of words { chord = true|nil, gap = spaces before it, cells =
-- { { chord =, text = }, ... } }: a cell is a chord with the text under it, up
-- to the next chord or space. A chord standing on a space (or alone, "[G] [D]")
-- gets a word of its own. `gap` keeps how many spaces the song has there, so
-- "[Am]    [G]" can space chords (rhythm without words).
function M.words(segments)
    local words, cur, gap = {}, nil, 0
    local function add(chord, text)
        if not cur then
            cur = { cells = {}, gap = gap }
            words[#words + 1] = cur
            gap = 0
        end
        cur.cells[#cur.cells + 1] = { chord = chord, text = text }
        if chord then cur.chord = true end
    end
    for _, seg in ipairs(segments) do
        local chord, text = seg.chord, seg.text or ""
        if text == "" then
            if chord then add(chord, "") end
        else
            if chord and text:match("^%s") then
                cur = nil
                add(chord, "")
                chord = nil
            end
            for space, word in text:gmatch("(%s*)(%S*)") do
                if space ~= "" then
                    cur = nil
                    gap = gap + #space
                end
                if word ~= "" then
                    add(chord, word)
                    chord = nil
                end
            end
        end
    end
    return words
end

local function transpose_segments(segments, opts, flats)
    local out = {}
    for i, seg in ipairs(segments) do
        local chord = seg.chord
        if chord and not seg.annotation then
            chord = Transpose.chord(chord, opts.transpose,
                { notation = opts.notation, from = opts.from, flats = flats })
        end
        out[i] = { chord = chord, text = seg.text }
    end
    return out
end

local function lyrics_text(segments)
    local t = {}
    for _, seg in ipairs(segments) do t[#t + 1] = seg.text or "" end
    return rtrim(table.concat(t))
end

local CSS = [[
body { margin: 0; }
h1 { font-size: 1.4em; margin: 0 0 0.15em 0; text-align: left; hyphens: none; }
.artist { font-style: italic; margin: 0; text-indent: 0; }
.info { font-size: 0.8em; margin: 0.2em 0 0.9em 0; text-indent: 0; }
.blk { margin: 0 0 0.9em 0; page-break-inside: avoid; }
.l { margin: 0; text-indent: -1em; padding-left: 1em; text-align: left; hyphens: none;
     line-height: 1.15; font-size: %s; }
.w { display: inline-block; white-space: nowrap; text-indent: 0; }
.s { display: inline-block; text-indent: 0; }
.s > span { display: block; text-indent: 0; white-space: pre; }
.c { font-weight: bold; padding-right: 0.3em; }
pre { font-family: "Droid Sans Mono", "DejaVu Sans Mono", "Noto Sans Mono", monospace;
      white-space: pre; margin: 0; }
.cm { font-style: italic; }
.chorus { margin-left: 0.6em; padding-left: 0.6em; border-left: 0.15em solid black; }
.label { font-weight: bold; margin: 0 0 0.2em 0; text-indent: 0; }
.ly { margin: 0; text-indent: 0; }
.lyblock { margin: 0 0 0.9em 0; page-break-inside: avoid; }
.grid { border-collapse: collapse; margin: 0; }
.grid td { padding: 0 0.45em 0 0; text-align: left; vertical-align: baseline; line-height: 1.3; }
.grid td.gc { width: 1.6em; }
.grid td.gb { padding: 0 0.25em; text-align: center; }
.grid td.gt { padding-left: 0.4em; }
.grid .c { padding-right: 0; }
]]

-- Added after CSS for browsers: readable on a phone, follows the dark mode.
local WEB_CSS = [[
body { margin: 0.8em; font-family: sans-serif; background: #fff; color: #111; }
.c { color: #b03000; }
.chorus { border-left-color: currentColor; }
@media (prefers-color-scheme: dark) {
  body { background: #121212; color: #e8e8e8; }
  .c { color: #ffab70; }
}
]]

--- Stylesheet of a rendered song; `web` adds the browser rules.
function M.css(font_size, web)
    return CSS:format(font_size or "1em") .. (web and WEB_CSS or "")
end

-- A chord over its text, stacked; empty parts keep their row with a no-break space.
local function cell_html(cell)
    local chord = cell.chord and escape(cell.chord) or "&#160;"
    local text = cell.text ~= "" and escape(cell.text) or "&#160;"
    return '<span class="s"><span class="c">' .. chord .. '</span><span class="t">' .. text .. "</span></span>"
end

-- One lyrics line: words without a chord stay plain text (on the lyrics'
-- baseline); words with chords become inline blocks that never break inside, so
-- every chord stays over its syllable in any font and the line wraps between words.
local function line_html(segments)
    local parts = {}
    for i, word in ipairs(M.words(segments)) do
        -- spaces beyond the one between words keep their width (en spaces)
        local extra = word.gap - (i > 1 and 1 or 0)
        local pad = extra > 0 and string.rep("&#8194;", extra) or ""
        if not word.chord then
            local t = {}
            for _i, cell in ipairs(word.cells) do t[#t + 1] = escape(cell.text) end
            parts[#parts + 1] = pad .. table.concat(t)
        elseif #word.cells == 1 then
            parts[#parts + 1] = pad .. cell_html(word.cells[1])
        else
            local t = {}
            for _i, cell in ipairs(word.cells) do t[#t + 1] = cell_html(cell) end
            parts[#parts + 1] = pad .. '<span class="w">' .. table.concat(t) .. "</span>"
        end
    end
    if #parts == 0 then return "&#160;" end
    return table.concat(parts, " ")
end

-- Lyrics-only mode: does the block hold chords without words and no words
-- at all (an interlude, "[Am] [G]")? Then nothing of it is shown.
local function chords_only(block)
    local chords = false
    for _, line in ipairs(block.lines or {}) do
        if line.type == "lyrics" then
            if lyrics_text(line.segments) ~= "" then return false end
            chords = true
        end
    end
    return chords
end

-- Chord grids ({start_of_grid}): a line is cells separated by spaces, as in
-- ChordPro: bar lines ("|", "||", "|.", "|:", ":|", ":|:", "|2"), "." for a
-- beat on which the chord goes on, "%" / "%%" repeating the bar(s) before, and
-- chords, "~" joining chords played on one beat ("G~Am"). Text before the
-- first bar line is the margin, after the last one a comment. A grid is a
-- table, so beats line up from row to row and have the same width in any font.
local function grid_bar(tok)
    return tok:find("|", 1, true) ~= nil and tok:match("^[|:%.%d>]+$") ~= nil
end

local function grid_cells(text)
    local toks = {}
    for tok in text:gmatch("%S+") do toks[#toks + 1] = tok end
    local first, last
    for i, tok in ipairs(toks) do
        if grid_bar(tok) then
            first = first or i
            last = i
        end
    end
    local cells = {}
    if first and first > 1 then
        cells[1] = { kind = "margin", text = table.concat(toks, " ", 1, first - 1) }
    end
    for i = first or 1, last or #toks do
        local tok = toks[i]
        if grid_bar(tok) then
            cells[#cells + 1] = { kind = "bar", text = tok }
        elseif tok == "." then
            cells[#cells + 1] = { kind = "beat" }
        elseif tok == "%" or tok == "%%" or tok == "/" then
            cells[#cells + 1] = { kind = "mark", text = tok }
        else
            cells[#cells + 1] = { kind = "chord", text = tok }
        end
    end
    if last and last < #toks then
        cells[#cells + 1] = { kind = "comment", text = table.concat(toks, " ", last + 1) }
    end
    return cells
end

local function render_grid(block, opts, flats, out)
    out[#out + 1] = '<table class="grid">'
    for _, line in ipairs(block.lines) do
        if line.type == "raw" and line.text:match("%S") then
            local tds = {}
            for _i, cell in ipairs(grid_cells(line.text)) do
                if cell.kind == "chord" then
                    local chords = {}
                    for chord in cell.text:gmatch("[^~]+") do
                        chords[#chords + 1] = escape(Transpose.chord(chord, opts.transpose,
                            { notation = opts.notation, from = opts.from, flats = flats }))
                    end
                    tds[#tds + 1] = '<td class="gc"><span class="c">' .. table.concat(chords, " ") .. "</span></td>"
                elseif cell.kind == "beat" then
                    tds[#tds + 1] = '<td class="gc">·</td>'
                elseif cell.kind == "bar" then
                    tds[#tds + 1] = '<td class="gb">' .. escape(cell.text) .. "</td>"
                elseif cell.kind == "mark" then
                    tds[#tds + 1] = '<td class="gc">' .. escape(cell.text) .. "</td>"
                else
                    tds[#tds + 1] = '<td class="gt cm">' .. escape(cell.text) .. "</td>"
                end
            end
            out[#out + 1] = "<tr>" .. table.concat(tds) .. "</tr>"
        elseif line.type == "comment" then
            out[#out + 1] = '<tr><td class="gt cm" colspan="40">' .. escape(line.text) .. "</td></tr>"
        end
    end
    out[#out + 1] = "</table>"
end

local function render_block_lines(block, opts, flats, out)
    if not opts.show_chords then
        out[#out + 1] = '<div class="lyblock">'
        for _, line in ipairs(block.lines) do
            if line.type == "lyrics" then
                -- a line of chords alone leaves no empty line
                local text = lyrics_text(line.segments)
                if text ~= "" then out[#out + 1] = '<p class="ly">' .. escape(text) .. "</p>" end
            elseif line.type == "comment" then
                out[#out + 1] = '<p class="ly cm">' .. escape(line.text) .. "</p>"
            elseif line.type == "empty" then
                out[#out + 1] = '<p class="ly">&#160;</p>'
            end
            -- raw (tab) lines are skipped in lyrics-only mode
        end
        out[#out + 1] = "</div>"
        return
    end

    out[#out + 1] = '<div class="blk">'
    if block.type == "grid" then
        render_grid(block, opts, flats, out)
        out[#out + 1] = "</div>"
        return
    end
    for _, line in ipairs(block.lines) do
        if line.type == "lyrics" then
            out[#out + 1] = '<p class="l">' .. line_html(transpose_segments(line.segments, opts, flats)) .. "</p>"
        elseif line.type == "comment" then
            out[#out + 1] = '<p class="l cm">' .. escape(line.text) .. "</p>"
        elseif line.type == "raw" then
            out[#out + 1] = "<pre>" .. escape(line.text) .. "</pre>"
        elseif line.type == "empty" then
            out[#out + 1] = '<p class="l">&#160;</p>'
        end
    end
    out[#out + 1] = "</div>"
end

local function render_block(block, opts, flats, out)
    -- lyrics only: nothing of a grid or of chords without words
    if not opts.show_chords and (block.type == "grid" or chords_only(block)) then return end
    local is_chorus = block.type == "chorus"
    if is_chorus then out[#out + 1] = '<div class="chorus">' end
    local label = block.label
    if is_chorus and not label then label = opts.labels.chorus end
    if label then out[#out + 1] = '<p class="label">' .. escape(label) .. "</p>" end
    render_block_lines(block, opts, flats, out)
    if is_chorus then out[#out + 1] = "</div>" end
end

--- Render a parsed song to a complete HTML document string.
function M.html(song, opts)
    opts = opts or {}
    opts.transpose = opts.transpose or 0
    opts.notation = opts.notation or "cz"
    if opts.show_chords == nil then opts.show_chords = true end
    local labels = {}
    for k, v in pairs(DEFAULT_LABELS) do labels[k] = (opts.labels and opts.labels[k]) or v end
    opts.labels = labels

    local meta = song.meta or {}
    opts.from = Transpose.song_notation(meta) or opts.notation
    local flats = Transpose.key_prefers_flats(meta.key, opts.transpose, opts.from)
    local title = meta.title or opts.fallback_title or "?"

    local out = {}
    if opts.web then
        out[#out + 1] = '<!DOCTYPE html>'
        out[#out + 1] = '<html><head><meta charset="utf-8"/>'
        out[#out + 1] = '<meta name="viewport" content="width=device-width, initial-scale=1"/>'
    else
        out[#out + 1] = '<?xml version="1.0" encoding="UTF-8"?>'
        out[#out + 1] = '<html xmlns="http://www.w3.org/1999/xhtml"><head>'
        out[#out + 1] = '<meta http-equiv="Content-Type" content="text/html; charset=UTF-8"/>'
    end
    out[#out + 1] = "<title>" .. escape(title) .. "</title>"
    if meta.artist then
        out[#out + 1] = '<meta name="author" content="' .. escape(meta.artist) .. '"/>'
    end
    out[#out + 1] = "<style>" .. M.css(opts.font_size, opts.web) .. "</style>"
    out[#out + 1] = "</head><body>"
    out[#out + 1] = "<h1>" .. escape(title) .. "</h1>"
    if meta.subtitle then out[#out + 1] = '<p class="artist">' .. escape(meta.subtitle) .. "</p>" end
    if meta.artist then out[#out + 1] = '<p class="artist">' .. escape(meta.artist) .. "</p>" end

    local info = {}
    if meta.key and opts.show_chords then
        local k = Transpose.key(meta.key, opts.transpose, { notation = opts.notation, from = opts.from, flats = flats })
        info[#info + 1] = labels.key .. ": " .. k
    end
    if meta.capo and meta.capo ~= "" and meta.capo ~= "0" and opts.show_chords then
        info[#info + 1] = labels.capo .. " " .. meta.capo
    end
    if opts.transpose % 12 ~= 0 and opts.show_chords then
        info[#info + 1] = string.format("%s %+d", labels.transposed, opts.transpose)
    end
    if meta.tempo then info[#info + 1] = labels.tempo .. " " .. meta.tempo end
    local duration = ChordPro.duration(meta.duration)
    if duration then info[#info + 1] = ChordPro.format_duration(duration) end
    if #info > 0 then
        out[#out + 1] = '<p class="info">' .. escape(table.concat(info, " · ")) .. "</p>"
    end

    local last_chorus
    for _, block in ipairs(song.blocks or {}) do
        if block.type == "chorus_ref" then
            if opts.repeat_chorus and last_chorus then
                render_block(last_chorus, opts, flats, out)
            else
                out[#out + 1] = '<p class="label">' .. escape(block.label or labels.chorus) .. "</p>"
            end
        else
            if block.type == "chorus" then last_chorus = block end
            render_block(block, opts, flats, out)
        end
    end

    out[#out + 1] = "</body></html>"
    return table.concat(out, "\n")
end

return M
