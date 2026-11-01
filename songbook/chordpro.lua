--[[--
ChordPro parser (pure Lua 5.1 / LuaJIT, no KOReader dependencies).

Parses ChordPro text into a song table:

    song = {
      meta   = { title=, subtitle=, artist=, key=, capo=, tempo=, ... },
      blocks = {
        { type = "verse"|"chorus"|"bridge"|"tab"|"grid"|"plain",
          label = "Ref." or nil,
          lines = {
            { type = "lyrics",  segments = { {chord="Am", text="Ahoj "}, ... } },
            { type = "comment", text = "...", style = "normal"|"italic"|"box" },
            { type = "raw",     text = "..." },   -- tab / grid lines, verbatim
            { type = "empty" },
          } },
        { type = "chorus_ref", label = "Ref." },  -- {chorus} = "repeat chorus here"
      },
    }

Chord annotations like [*N.C.] get `annotation = true` and are never transposed.
]]

local M = {}

-- Short directive names -> canonical names
local ALIASES = {
    t = "title", st = "subtitle",
    c = "comment", ci = "comment_italic", cb = "comment_box",
    highlight = "comment",
    soc = "start_of_chorus", eoc = "end_of_chorus",
    sov = "start_of_verse",  eov = "end_of_verse",
    sob = "start_of_bridge", eob = "end_of_bridge",
    sot = "start_of_tab",    eot = "end_of_tab",
    sog = "start_of_grid",   eog = "end_of_grid",
}

local META_KEYS = {
    title = true, subtitle = true, artist = true, composer = true,
    lyricist = true, album = true, year = true, key = true, capo = true,
    tempo = true, time = true, duration = true, copyright = true,
}

local COMMENT_STYLES = {
    comment = "normal", comment_italic = "italic", comment_box = "box",
}

local function trim(s)
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

-- "{name: value}" / "{name value}" / "{name}" -> name, value
local function parse_directive(line)
    local inner = line:match("^%s*{(.*)}%s*$")
    if not inner then return nil end
    inner = trim(inner)
    local name, value = inner:match("^([%w_%-]+)%s*:%s*(.*)$")
    if not name then
        name, value = inner:match("^([%w_%-]+)%s+(.*)$")
    end
    if not name then
        name, value = inner, ""
    end
    name = name:lower()
    return ALIASES[name] or name, trim(value or "")
end

-- Section label: {soc: Ref.} or {start_of_chorus: label="Ref."}
local function parse_label(value)
    if value == nil or value == "" then return nil end
    local quoted = value:match('label%s*=%s*"(.-)"')
    return quoted or value
end

--- Split a lyrics line into chord/text segments.
function M.parse_lyrics(line)
    local segments = {}
    local pos = 1
    local pending_chord, pending_annot = nil, false
    while true do
        local s, e, chord = line:find("%[([^%]]*)%]", pos)
        local text = line:sub(pos, (s or 0) - 1)
        if not s then text = line:sub(pos) end
        if pending_chord or text ~= "" then
            table.insert(segments, {
                chord = pending_chord,
                annotation = pending_annot or nil,
                text = text,
            })
        end
        if not s then break end
        chord = trim(chord)
        pending_annot = chord:sub(1, 1) == "*"
        if pending_annot then chord = chord:sub(2) end
        pending_chord = chord ~= "" and chord or nil
        if not pending_chord then pending_annot = false end
        pos = e + 1
    end
    return segments
end

function M.parse(text)
    text = text:gsub("^\239\187\191", "")      -- UTF-8 BOM
    text = text:gsub("\r\n?", "\n")

    local song = { meta = {}, blocks = {} }
    local current = nil          -- block being filled
    local explicit = false       -- inside {start_of_*}?

    local function new_block(btype, label, is_explicit)
        current = { type = btype, label = label, lines = {} }
        explicit = is_explicit
        table.insert(song.blocks, current)
        return current
    end

    local function close_block()
        if current then
            -- drop trailing empty lines
            while #current.lines > 0 and current.lines[#current.lines].type == "empty" do
                table.remove(current.lines)
            end
            if #current.lines == 0 and current.type ~= "chorus_ref" then
                for i = #song.blocks, 1, -1 do
                    if song.blocks[i] == current then table.remove(song.blocks, i) break end
                end
            end
        end
        current, explicit = nil, false
    end

    local function add_line(l)
        if not current then new_block("plain", nil, false) end
        table.insert(current.lines, l)
    end

    for line in (text .. "\n"):gmatch("(.-)\n") do
        local name, value = parse_directive(line)
        local is_tab = current and explicit and (current.type == "tab" or current.type == "grid")

        if name and is_tab and not name:match("^end_of_") then
            -- inside tab: directive-looking text stays raw
            add_line({ type = "raw", text = line })
        elseif name then
            local start_type = name:match("^start_of_(%w+)$")
            local end_type = name:match("^end_of_(%w+)$")
            if META_KEYS[name] then
                if song.meta[name] == nil then song.meta[name] = value end
            elseif name == "meta" then
                local k, v = value:match("^(%S+)%s+(.*)$")
                if k then song.meta[k:lower()] = song.meta[k:lower()] or trim(v) end
            elseif COMMENT_STYLES[name] then
                add_line({ type = "comment", text = value, style = COMMENT_STYLES[name] })
            elseif start_type then
                close_block()
                new_block(start_type, parse_label(value), true)
            elseif end_type then
                close_block()
            elseif name == "chorus" then
                close_block()
                table.insert(song.blocks, { type = "chorus_ref", label = parse_label(value), lines = {} })
            end
            -- unknown directives (x_*, new_page, ...) are ignored
        elseif line:match("^#") and not is_tab then
            -- ChordPro comment line, ignore
        elseif is_tab then
            add_line({ type = "raw", text = line })
        elseif trim(line) == "" then
            if explicit then
                if current and #current.lines > 0 then add_line({ type = "empty" }) end
            else
                close_block()       -- blank line ends an implicit paragraph
            end
        else
            add_line({ type = "lyrics", segments = M.parse_lyrics(line) })
        end
    end
    close_block()
    return song
end

--- Fast metadata-only parse (for song lists).
function M.parse_meta(text)
    local meta = {}
    text = text:gsub("^\239\187\191", "")
    for line in (text .. "\n"):gmatch("(.-)\r?\n") do
        local name, value = parse_directive(line)
        if name and META_KEYS[name] and meta[name] == nil then
            meta[name] = value
        end
    end
    return meta
end

--- Seconds of a {duration} value ("225", "3:45" or "1:02:03"), or nil.
function M.duration(value)
    if not value then return nil end
    local secs = 0
    local parts = 0
    for part in (trim(value) .. ":"):gmatch("(.-):") do
        if not part:match("^%d+$") then return nil end
        secs = secs * 60 + tonumber(part)
        parts = parts + 1
    end
    if parts == 0 or parts > 3 or secs == 0 then return nil end
    return secs
end

--- "3:45" for 225 seconds.
function M.format_duration(secs)
    secs = math.floor(secs + 0.5)
    return string.format("%d:%02d", math.floor(secs / 60), secs % 60)
end

--- First chord of the song that can be transposed (skips [*...] and N.C.), or nil.
function M.first_chord(text)
    for chord in text:gmatch("%[([^%]]*)%]") do
        if chord:match("^[A-H]") then return chord end
    end
end

return M
