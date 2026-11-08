--[[--
Chord transposition (pure Lua 5.1 / LuaJIT).

Notation:
  "cz" (default) : H = B natural, B = B flat, minor "mi" (Ami). Accepts Fis, Es, As, Cis...
  "en"           : B = B natural, Bb = B flat, minor "m" (Am); H still accepted as B natural.

Chords are read in the song's notation (opts.from, default opts.notation) and
written in opts.notation, also without a shift: the root (H <-> B, B <-> Bb)
and the minor suffix (Ami <-> Am) are converted.

Sharp vs flat spelling is chosen from the transposed song key when known,
otherwise from the original chord's accidental, otherwise from the direction.
]]

local M = {}

local BASE_EN = { C = 0, D = 2, E = 4, F = 5, G = 7, A = 9, B = 11, H = 11 }
local BASE_CZ = { C = 0, D = 2, E = 4, F = 5, G = 7, A = 9, B = 10, H = 11 }

local NAMES = {
    en = {
        sharp = { "C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B" },
        flat  = { "C", "Db", "D", "Eb", "E", "F", "Gb", "G", "Ab", "A", "Bb", "B" },
    },
    cz = {
        sharp = { "C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "B", "H" },
        flat  = { "C", "Db", "D", "Eb", "E", "F", "Gb", "G", "Ab", "A", "B", "H" },
    },
    cz_german = {
        sharp = { "C", "Cis", "D", "Dis", "E", "F", "Fis", "G", "Gis", "A", "B", "H" },
        flat  = { "C", "Des", "D", "Es", "E", "F", "Ges", "G", "As", "A", "B", "H" },
    },
}

-- Major keys conventionally spelled with flats (semitone of the tonic)
local FLAT_MAJOR_KEYS = { [1] = true, [3] = true, [5] = true, [8] = true, [10] = true }

--- Parse a note at the start of `s`.
-- Returns semitone, rest_of_string, accidental ("sharp"|"flat"|nil), style ("sym"|"german")
function M.parse_note(s, notation)
    local letter = s:sub(1, 1):upper()
    local base = (notation == "en" and BASE_EN or BASE_CZ)[letter]
    if not base then return nil end
    local rest = s:sub(2)
    local acc, style = nil, "sym"

    if rest:sub(1, 1) == "#" then
        acc, rest = "sharp", rest:sub(2)
    elseif rest:sub(1, 1) == "b" then
        acc, rest = "flat", rest:sub(2)
    elseif rest:sub(1, 2) == "is" then
        acc, style, rest = "sharp", "german", rest:sub(3)
    elseif (letter ~= "A" and letter ~= "E") and rest:sub(1, 2) == "es" and rest:sub(3, 4) ~= "us" then
        acc, style, rest = "flat", "german", rest:sub(3)
    elseif (letter == "A" or letter == "E") and rest:sub(1, 1) == "s" and rest:sub(2, 3) ~= "us" then
        acc, style, rest = "flat", "german", rest:sub(2)   -- As, Es (but not Asus, Esus)
    end

    local semi = base
    if acc == "sharp" then
        semi = semi + 1
    elseif acc == "flat" then
        -- Czech "B" already is B flat; treat "Bb"/"Bes" as B flat, not A
        if not (notation ~= "en" and letter == "B") then semi = semi - 1 end
    end
    return semi % 12, rest, acc, style
end

local function note_name(semi, flats, style, notation)
    local tbl
    if notation == "en" then
        tbl = NAMES.en
    elseif style == "german" then
        tbl = NAMES.cz_german
    else
        tbl = NAMES.cz
    end
    return (flats and tbl.flat or tbl.sharp)[semi % 12 + 1]
end

local function is_minor(suffix)
    return suffix:match("^m") ~= nil and suffix:match("^maj") == nil
end

--- Decide flat spelling from the (original) song key, in the song's notation `from`, and the shift.
-- Returns true/false, or nil when the key doesn't decide (C / Am, or unknown).
function M.key_prefers_flats(key, n, from)
    if not key or key == "" then return nil end
    local semi, suffix = M.parse_note(key, from)
    if not semi then return nil end
    local major = (semi + (n or 0) + (is_minor(suffix) and 3 or 0)) % 12
    if major == 0 then return nil end
    return FLAT_MAJOR_KEYS[major] == true
end

local function transpose_note(s, n, opts)
    local semi, rest, acc, style = M.parse_note(s, opts.from or opts.notation)
    if not semi then return nil end
    local flats = opts.flats
    if n % 12 == 0 then
        flats = acc ~= "sharp"        -- unshifted: keep the spelling (Czech B -> Bb)
    elseif flats == nil then
        if acc == "flat" then flats = true
        elseif acc == "sharp" then flats = false
        else flats = n < 0 end
    end
    return note_name(semi + n, flats, style, opts.notation), rest
end

--- The notation a song declares with {meta: notation cz|en}, or nil.
function M.song_notation(meta)
    local v = meta and meta.notation and meta.notation:lower()
    if v == "cz" or v == "en" then return v end
end

--- The chord suffix with its minor mark in `notation`: "mi" (cz) or "m" (en).
-- "maj", "ma7" (major seventh) and "min" are left as they are.
function M.suffix(rest, notation)
    if notation == "en" then
        if rest:match("^mi") and not rest:match("^min") then return "m" .. rest:sub(3) end
    elseif rest:match("^m") and not rest:match("^maj") and not rest:match("^ma%d")
            and not rest:match("^mi") then
        return "mi" .. rest:sub(2)
    end
    return rest
end

--- Transpose one chord symbol by n semitones and write it in opts.notation.
-- opts = { notation = "cz"|"en", from = notation of the song (default notation),
--          flats = true|false|nil }
-- Unparseable chords (N.C., x, %) are returned unchanged.
function M.chord(chord, n, opts)
    opts = opts or {}
    n = n or 0
    if not chord or chord == "" then return chord end

    local prefix, body = chord:match("^([^A-H]*)(.*)$")
    if prefix:match("%w") then return chord end   -- "N.C.", "x2", ...
    local root, rest = transpose_note(body, n, opts)
    if not root then return chord end
    rest = M.suffix(rest, opts.notation)

    -- slash chord bass: "/H", "/F#" (but not "6/9")
    local before, bass = rest:match("^(.-)/([A-H].*)$")
    if before then
        local b_name, b_rest = transpose_note(bass, n, opts)
        if b_name then
            return prefix .. root .. before .. "/" .. b_name .. b_rest
        end
    end
    return prefix .. root .. rest
end

--- Transpose a key string (for the header), same rules as chords.
function M.key(key, n, opts)
    return M.chord(key, n, opts)
end

--- The 12 keys `key` (in notation `from`, default `notation`) can be transposed
-- to, from C up, written in `notation`: list of
-- { name = transposed key, shift = semitones in -5..6 }. nil for an unparseable key.
function M.key_choices(key, notation, from)
    from = from or notation
    local semi = key and M.parse_note(key, from)
    if not semi then return nil end
    local choices = {}
    for target = 0, 11 do
        local n = (target - semi) % 12
        if n > 6 then n = n - 12 end
        local flats = M.key_prefers_flats(key, n, from)
        choices[#choices + 1] = { name = M.key(key, n, { notation = notation, from = from, flats = flats }),
            shift = n }
    end
    return choices
end

return M
