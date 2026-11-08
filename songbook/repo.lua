--[[--
Song repository client.

The server is any static HTTP(S) location (GitHub raw, GitHub Pages, ...):

    <base>/index.json
    <base>/songs/<file>.cho

index.json ("name" is optional, shown as the repository name):
    { "version": 1, "name": "My songs",
      "songs": [ { "id": "amazing-grace", "title": "Amazing Grace",
                   "artist": "John Newton", "key": "G",
                   "file": "songs/amazing-grace.cho", "updated": "2026-10-31" } ] }

Private GitHub repositories are read through the GitHub REST API with an
access token (request()); the token is sent only to api.github.com.

Pure helpers (join, base_url, github, request, server_key, sanitize_id,
parse_index) have no KOReader dependencies; fetch() uses KOReader's
LuaSocket/LuaSec and is only called on-device.
]]

local M = {}

--- Newest index.json format this plugin reads. A server raises "version"
-- only for changes older plugins would misread; new optional fields keep it.
M.INDEX_VERSION = 1
--- parse_index() error for an index of a newer format.
M.ERR_NEWER = "newer index.json version"

function M.join(base, path)
    if path:match("^https?://") then return path end
    base = base or ""
    if base ~= "" and base:sub(-1) ~= "/" then base = base .. "/" end
    return base .. path:gsub("^/+", "")
end

--- Turn a github.com repository URL into its raw.githubusercontent.com base.
-- "https://github.com/u/r"                -> ".../u/r/HEAD/" (default branch)
-- "https://github.com/u/r/tree/dev/songs" -> ".../u/r/dev/songs/"
-- "https://github.com/u/r/blob/dev/index.json" -> ".../u/r/dev/"
-- Other URLs are returned unchanged.
function M.base_url(url)
    url = (url or ""):gsub("^%s+", ""):gsub("%s+$", "")
    local path = url:match("^https?://www%.github%.com/(.*)$") or url:match("^https?://github%.com/(.*)$")
    if not path then return url end
    path = path:gsub("[?#].*$", ""):gsub("/+$", "")
    local user, repo, rest = path:match("^([^/]+)/([^/]+)(.*)$")
    if not user then return url end
    repo = repo:gsub("%.git$", "")
    local ref, sub = rest:match("^/tree/([^/]+)(.*)$")
    if not ref then
        ref, sub = rest:match("^/blob/([^/]+)(.*)$")
        if sub then sub = sub:gsub("/[^/]*$", "") end
    end
    if not ref then ref, sub = "HEAD", "" end
    return "https://raw.githubusercontent.com/" .. user .. "/" .. repo .. "/" .. ref .. sub .. "/"
end

--- The GitHub repository of a server URL (github.com or raw.githubusercontent.com):
-- { owner, repo, ref ("HEAD" = default branch), path (folder, "" for the root) }, or nil.
function M.github(url)
    local owner, repo, ref, path = M.base_url(url):match("^https://raw%.githubusercontent%.com/([^/]+)/([^/]+)/([^/]+)/?(.-)/*$")
    if not owner then return nil end
    return { owner = owner, repo = repo, ref = ref, path = path }
end

local function encode_path(path)
    return (path:gsub("[^%w%-_%.~/]", function(c) return string.format("%%%02X", c:byte()) end))
end

--- URL and request headers (or nil) for `path` of the repository at `url`:
-- a path relative to its folder ("index.json", "songs/x.cho") or a full URL.
-- With an access `token`, a relative path of a GitHub repository goes to the
-- REST API (contents endpoint, raw media type), which serves private
-- repositories too; full URLs and other servers never get the token.
function M.request(url, path, token)
    local gh = token and token ~= "" and not path:match("^https?://") and M.github(url)
    if not gh then return M.join(M.base_url(url), path), nil end
    local file = path:gsub("^/+", "")
    if gh.path ~= "" then file = gh.path .. "/" .. file end
    local api = "https://api.github.com/repos/" .. gh.owner .. "/" .. gh.repo .. "/contents/" .. encode_path(file)
    if gh.ref ~= "HEAD" then api = api .. "?ref=" .. encode_path(gh.ref) end
    return api, {
        ["Authorization"] = "Bearer " .. token,
        ["Accept"] = "application/vnd.github.raw+json",
        ["X-GitHub-Api-Version"] = "2022-11-28",
    }
end

--- Short display name derived from a server URL ("user/repo", or host/path).
function M.default_name(url)
    local base = M.base_url(url)
    local user, repo, ref, sub = base:match("^https://raw%.githubusercontent%.com/([^/]+)/([^/]+)/([^/]+)(.-)/?$")
    if user then
        local name = user .. "/" .. repo
        if ref ~= "HEAD" then name = name .. " (" .. ref .. sub .. ")" end
        return name
    end
    return (base:gsub("^%a+://", ""):gsub("/+$", ""))
end

--- Stable folder-safe key for a server URL, unique among `taken` (a set).
-- The key is created once when a server is added and never changes, so
-- downloaded songs stay in songs/<key>/ even if the URL or name is edited.
function M.server_key(url, taken)
    local key = M.default_name(url):lower():gsub("[^%w%-_%.]+", "-"):gsub("%-+", "-")
    key = key:gsub("^[%-%.]+", ""):gsub("%-+$", ""):sub(1, 60)
    if key == "" then key = "repo" end
    taken = taken or {}
    local candidate, n = key, 1
    while taken[candidate] do
        n = n + 1
        candidate = key .. "-" .. n
    end
    return candidate
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
-- Returns songs, nil, repository name (or nil) / nil, error message.
function M.parse_index(body, decode)
    local ok, data = pcall(decode, body)
    if not ok or type(data) ~= "table" then
        return nil, "invalid index.json"
    end
    if type(data.version) == "number" and data.version > M.INDEX_VERSION then
        return nil, M.ERR_NEWER
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
    local name = type(data.name) == "string" and data.name:match("%S") and data.name or nil
    return songs, nil, name
end

--- HTTP GET. Returns body or nil, error message, HTTP status code (nil when
-- there was no answer). On-device only.
-- Timeouts in seconds default to socketutil's LARGE ones. `headers` (from
-- request()) are added; a request with Authorization follows no redirects,
-- as LuaSocket would send the token to the new address too.
function M.fetch(url, block_timeout, total_timeout, headers)
    local http = require("socket.http")
    local ltn12 = require("ltn12")
    local socket = require("socket")
    local socketutil = require("socketutil")

    local sink = {}
    local all = { ["User-Agent"] = "KOReader-Songbook", ["Cache-Control"] = "no-cache" }
    for k, v in pairs(headers or {}) do all[k] = v end
    socketutil:set_timeout(block_timeout or socketutil.LARGE_BLOCK_TIMEOUT,
        total_timeout or socketutil.LARGE_TOTAL_TIMEOUT)
    local code, _, status = socket.skip(1, http.request{
        url = url,
        method = "GET",
        sink = ltn12.sink.table(sink),
        headers = all,
        redirect = all["Authorization"] == nil,
    })
    socketutil:reset_timeout()
    if code ~= 200 then
        return nil, tostring(status or code), tonumber(code)
    end
    return table.concat(sink)
end

return M
