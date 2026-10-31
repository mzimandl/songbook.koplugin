--[[--
Song repository client.

The server is any static HTTP(S) location (GitHub raw, GitHub Pages, ...):

    <base>/index.json
    <base>/songs/<file>.cho

index.json:
    { "version": 1,
      "songs": [ { "id": "amazing-grace", "title": "Amazing Grace",
                   "artist": "John Newton", "key": "G",
                   "file": "songs/amazing-grace.cho", "updated": "2026-10-31" } ] }

Pure helpers (join, sanitize_id, parse_index) have no KOReader dependencies;
fetch() uses KOReader's LuaSocket/LuaSec and is only called on-device.
]]

local M = {}

function M.join(base, path)
    if path:match("^https?://") then return path end
    base = base or ""
    if base ~= "" and base:sub(-1) ~= "/" then base = base .. "/" end
    return base .. path:gsub("^/+", "")
end

--- Make an id safe to use as a file name.
function M.sanitize_id(id)
    id = tostring(id or ""):gsub("[^%w%-_%.]", "_"):gsub("^%.+", "")
    return id ~= "" and id or nil
end

local function basename_noext(path)
    return (path:match("([^/]+)$") or path):gsub("%.[^%.]*$", "")
end

--- Decode index.json text into a list of song entries.
-- decode: a JSON decode function (KOReader: require("json").decode)
function M.parse_index(body, decode)
    local ok, data = pcall(decode, body)
    if not ok or type(data) ~= "table" then
        return nil, "invalid index.json"
    end
    local list = data.songs or data
    if type(list) ~= "table" then return nil, "index.json has no songs" end
    local songs = {}
    for _, e in ipairs(list) do
        if type(e) == "table" and type(e.file) == "string" then
            local id = M.sanitize_id(e.id or basename_noext(e.file))
            if id then
                table.insert(songs, {
                    id = id,
                    title = type(e.title) == "string" and e.title or id,
                    artist = type(e.artist) == "string" and e.artist or nil,
                    key = type(e.key) == "string" and e.key or nil,
                    file = e.file,
                    updated = e.updated and tostring(e.updated) or nil,
                })
            end
        end
    end
    return songs
end

--- HTTP GET. Returns body or nil, error message. On-device only.
function M.fetch(url)
    local http = require("socket.http")
    local ltn12 = require("ltn12")
    local socket = require("socket")
    local socketutil = require("socketutil")

    local sink = {}
    socketutil:set_timeout(socketutil.LARGE_BLOCK_TIMEOUT, socketutil.LARGE_TOTAL_TIMEOUT)
    local code, _, status = socket.skip(1, http.request{
        url = url,
        method = "GET",
        sink = ltn12.sink.table(sink),
        headers = { ["User-Agent"] = "KOReader-Songbook", ["Cache-Control"] = "no-cache" },
    })
    socketutil:reset_timeout()
    if code ~= 200 then
        return nil, tostring(status or code)
    end
    return table.concat(sink)
end

return M
