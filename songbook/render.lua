--[[--
Song table -> HTML renderer (pure Lua 5.1 / LuaJIT).

Chords are placed above lyrics in a monospace <pre>. Alignment is computed in
UTF-8 characters (Lua's # counts bytes, which would break "ř", "č", ...).
Long lines wrap only at word boundaries, keeping every chord over its syllable.

opts = {
  transpose     = 0,          -- semitones
  notation      = "cz",       -- "cz" (H/B) or "en"
  max_cols      = 42,         -- wrap width in characters
  show_chords   = true,       -- false = lyrics only
  repeat_chorus = false,      -- {chorus} replays the last chorus instead of a label
  font_size     = nil,        -- CSS size for <pre>, e.g. "0.9em"
  labels        = { key=, capo=, transposed=, chorus= },
}
]]

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

local function pad(s, cols, fill)
    local w = width(s)
    if w >= cols then return s end
    return s .. string.rep(fill or " ", cols - w)
end

local function escape(s)
    return (s:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"):gsub('"', "&quot;"))
end

-- Split segments into word pieces so lines can wrap between words.
local function to_pieces(segments)
    local pieces = {}
    for _, seg in ipairs(segments) do
        local first = true
        local text = seg.text or ""
        if text == "" then
            table.insert(pieces, { chord = seg.chord, text = "" })
        else
            for word in text:gmatch("%S*%s*") do
                if word ~= "" then
                    table.insert(pieces, { chord = first and seg.chord or nil, text = word })
                    first = false
                end
            end
        end
    end
    return pieces
end

-- Lay out a run of pieces into one chord row + one lyric row.
local function layout_group(pieces)
    local chords, lyrics = "", ""
    for _, p in ipairs(pieces) do
        if p.chord then
            local col = width(lyrics)
            local need = width(chords)
            if need > col then
                local last = lyrics:sub(-1)
                local mid_word = last ~= "" and not last:match("%s")
                    and p.text ~= "" and not p.text:sub(1, 1):match("%s")
                lyrics = pad(lyrics, need, mid_word and "-" or " ")
                col = need
            end
            chords = pad(chords, col) .. p.chord .. " "
        end
        lyrics = lyrics .. p.text
    end
    return rtrim(chords), rtrim(lyrics)
end

local function group_width(pieces)
    local c, l = layout_group(pieces)
    return math.max(width(c), width(l))
end

--- Lay out one lyrics line (already-transposed segments).
-- Returns a list of { chords = "...", lyrics = "..." } rows (either may be "").
function M.layout_line(segments, max_cols)
    max_cols = max_cols or 1000
    local pieces = to_pieces(segments)
    local rows, group = {}, {}

    local function emit()
        if #group == 0 then return end
        local c, l = layout_group(group)
        table.insert(rows, { chords = c, lyrics = l })
        group = {}
    end

    for _, p in ipairs(pieces) do
        table.insert(group, p)
        if #group > 1 and group_width(group) > max_cols then
            table.remove(group)
            emit()
            -- don't start a continuation row with whitespace
            local stripped = { chord = p.chord, text = (p.text:gsub("^%s+", "")) }
            if stripped.chord or stripped.text ~= "" then group = { stripped } end
        end
    end
    emit()
    return rows
end

local function transpose_segments(segments, opts, flats)
    local out = {}
    for i, seg in ipairs(segments) do
        local chord = seg.chord
        if chord and not seg.annotation then
            chord = Transpose.chord(chord, opts.transpose, { notation = opts.notation, flats = flats })
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
pre { font-family: "Droid Sans Mono", "DejaVu Sans Mono", "Noto Sans Mono", monospace;
      font-size: %s; white-space: pre; line-height: 1.2; margin: 0 0 0.9em 0;
      page-break-inside: avoid; }
.c { font-weight: bold; }
.cm { font-style: italic; }
.chorus { margin-left: 0.6em; padding-left: 0.6em; border-left: 0.15em solid black; }
.label { font-weight: bold; margin: 0 0 0.2em 0; text-indent: 0; }
.ly { margin: 0; text-indent: 0; }
.lyblock { margin: 0 0 0.9em 0; page-break-inside: avoid; }
]]

local function render_block_lines(block, opts, flats, out)
    if not opts.show_chords then
        out[#out + 1] = '<div class="lyblock">'
        for _, line in ipairs(block.lines) do
            if line.type == "lyrics" then
                out[#out + 1] = '<p class="ly">' .. escape(lyrics_text(line.segments)) .. "</p>"
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

    local rows = {}
    for _, line in ipairs(block.lines) do
        if line.type == "lyrics" then
            for _, r in ipairs(M.layout_line(transpose_segments(line.segments, opts, flats), opts.max_cols)) do
                if r.chords ~= "" then rows[#rows + 1] = '<span class="c">' .. escape(r.chords) .. "</span>" end
                if r.lyrics ~= "" then rows[#rows + 1] = escape(r.lyrics) end
            end
        elseif line.type == "comment" then
            rows[#rows + 1] = '<span class="cm">' .. escape(line.text) .. "</span>"
        elseif line.type == "raw" then
            rows[#rows + 1] = escape(line.text)
        elseif line.type == "empty" then
            rows[#rows + 1] = ""
        end
    end
    out[#out + 1] = "<pre>" .. table.concat(rows, "\n") .. "</pre>"
end

local function render_block(block, opts, flats, out)
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
    opts.max_cols = opts.max_cols or 42
    if opts.show_chords == nil then opts.show_chords = true end
    local labels = {}
    for k, v in pairs(DEFAULT_LABELS) do labels[k] = (opts.labels and opts.labels[k]) or v end
    opts.labels = labels

    local meta = song.meta or {}
    local flats = Transpose.key_prefers_flats(meta.key, opts.transpose, opts.notation)
    local title = meta.title or opts.fallback_title or "?"

    local out = {}
    out[#out + 1] = '<?xml version="1.0" encoding="UTF-8"?>'
    out[#out + 1] = '<html xmlns="http://www.w3.org/1999/xhtml"><head>'
    out[#out + 1] = '<meta http-equiv="Content-Type" content="text/html; charset=UTF-8"/>'
    out[#out + 1] = "<title>" .. escape(title) .. "</title>"
    if meta.artist then
        out[#out + 1] = '<meta name="author" content="' .. escape(meta.artist) .. '"/>'
    end
    out[#out + 1] = "<style>" .. CSS:format(opts.font_size or "0.9em") .. "</style>"
    out[#out + 1] = "</head><body>"
    out[#out + 1] = "<h1>" .. escape(title) .. "</h1>"
    if meta.subtitle then out[#out + 1] = '<p class="artist">' .. escape(meta.subtitle) .. "</p>" end
    if meta.artist then out[#out + 1] = '<p class="artist">' .. escape(meta.artist) .. "</p>" end

    local info = {}
    if meta.key and opts.show_chords then
        local k = Transpose.key(meta.key, opts.transpose, { notation = opts.notation, flats = flats })
        info[#info + 1] = labels.key .. ": " .. k
    end
    if meta.capo and meta.capo ~= "" and meta.capo ~= "0" and opts.show_chords then
        info[#info + 1] = labels.capo .. " " .. meta.capo
    end
    if opts.transpose % 12 ~= 0 and opts.show_chords then
        info[#info + 1] = string.format("%s %+d", labels.transposed, opts.transpose)
    end
    if meta.tempo then info[#info + 1] = labels.tempo .. " " .. meta.tempo end
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
