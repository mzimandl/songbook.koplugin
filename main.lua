--[[--
Songbook plugin: browse a song server, download ChordPro songs, render them
locally to HTML (chords above lyrics) and open them in the reader.

This file has the core (lifecycle, settings, migrations, songs and servers,
rendering); the UI is split into songbook/ui/ (see common.lua there), each
module adding its methods to the plugin class.

@module koplugin.Songbook
]]

-- Own modules must be required at load time: PluginLoader only adds the
-- plugin folder to package.path while main.lua is being loaded. That holds
-- for the modules songbook/ui/ requires too.
local C = require("songbook/ui/common")
require("songbook/ui/reader")
require("songbook/ui/lists")
require("songbook/ui/collections")
require("songbook/ui/online")
require("songbook/ui/playlist")
require("songbook/ui/jam")
require("songbook/ui/menu")

local ChordPro = require("songbook/chordpro")
local Render = require("songbook/render")
local Repo = require("songbook/repo")

local DataStorage = require("datastorage")
local Device = require("device")
local Dispatcher = require("dispatcher")
local LuaSettings = require("luasettings")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local util = require("util")

local Songbook = C.Songbook
local _, T = C._, C.T
local DEFAULTS = C.DEFAULTS
local JAM_KEY = C.JAM_KEY
local jam = C.jam
local read_file = C.read_file
local song_meta = C.song_meta
local write_file = C.write_file
local notify = C.notify
local split_uid = C.split_uid
local make_uid = C.make_uid
local song_file_id = C.song_file_id
local sort_songs = C.sort_songs

-- Song repository added on the first start (until then `servers` is unset).
local DEFAULT_SERVER_URL = "https://github.com/mzimandl/songbook-library"

-- Lifecycle -------------------------------------------------------------------

-- Rendered songs ("songbook/rendered/<stem>@<options>.html") are kept out of
-- KOReader's reading history, so it only lists books.
local function is_song_file(file)
    return file and file:match("/songbook/rendered/[^/]+@[^/]+%.html$") ~= nil
end

--- Wrap ReadHistory once: ReaderUI adds every opened document with addItem()
-- and bumps the first entry with updateLastBookTime() when it closes.
local function hide_songs_from_history()
    local ReadHistory = require("readhistory")
    if ReadHistory.songbook_hidden then return end
    ReadHistory.songbook_hidden = true
    local addItem, updateLastBookTime = ReadHistory.addItem, ReadHistory.updateLastBookTime
    function ReadHistory:addItem(file, ...)
        if is_song_file(file) then return end
        return addItem(self, file, ...)
    end
    function ReadHistory:updateLastBookTime(...)
        local ReaderUI = package.loaded["apps/reader/readerui"]
        local doc = ReaderUI and ReaderUI.instance and ReaderUI.instance.document
        if doc and is_song_file(doc.file) then return end
        return updateLastBookTime(self, ...)
    end
end

function Songbook:init()
    self.data_dir = DataStorage:getDataDir() .. "/songbook"
    self.songs_dir = self.data_dir .. "/songs"
    self.render_dir = self.data_dir .. "/rendered"
    util.makePath(self.songs_dir)
    util.makePath(self.render_dir)

    self.settings = LuaSettings:open(DataStorage:getSettingsDir() .. "/songbook.lua")
    jam.owner = self
    hide_songs_from_history()
    self:migrate()
    self:restorePlaylist()
    if self.settings:readSetting("servers") == nil then
        self:saveServers({ { key = Repo.server_key(DEFAULT_SERVER_URL), url = DEFAULT_SERVER_URL } })
    end
    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)
end

function Songbook:get(key)
    local v = self.settings:readSetting(key)
    if v == nil then return DEFAULTS[key] end
    return v
end

function Songbook:set(key, value)
    self.settings:saveSetting(key, value)
    self.settings:flush()
end

function Songbook:getMap(key)
    return self.settings:readSetting(key) or {}
end

function Songbook:setMapValue(key, id, value)
    local map = self:getMap(key)
    map[id] = value
    self:set(key, map)
end

function Songbook:onDispatcherRegisterActions()
    Dispatcher:registerAction("songbook_transpose_up",
        { category = "none", event = "SongbookTranspose", arg = 1,
          title = _("Songbook: transpose up"), reader = true })
    Dispatcher:registerAction("songbook_transpose_down",
        { category = "none", event = "SongbookTranspose", arg = -1,
          title = _("Songbook: transpose down"), reader = true })
    Dispatcher:registerAction("songbook_my_songs",
        { category = "none", event = "SongbookShowLocal",
          title = _("Songbook: my songs"), general = true })
    Dispatcher:registerAction("songbook_favorites",
        { category = "none", event = "SongbookShowFavorites",
          title = _("Songbook: favorites"), general = true })
    Dispatcher:registerAction("songbook_collections",
        { category = "none", event = "SongbookShowCollections",
          title = _("Songbook: collections"), general = true })
    Dispatcher:registerAction("songbook_key",
        { category = "none", event = "SongbookShowKeyDialog",
          title = _("Songbook: transpose / choose key"), reader = true })
    Dispatcher:registerAction("songbook_song_dialog",
        { category = "none", event = "SongbookSongDialog",
          title = _("Songbook: song options"), reader = true })
    Dispatcher:registerAction("songbook_last_list",
        { category = "none", event = "SongbookLastList",
          title = _("Songbook: last song list"), general = true })
    Dispatcher:registerAction("songbook_toggle_favorite",
        { category = "none", event = "SongbookToggleFavorite",
          title = _("Songbook: add/remove favorite"), reader = true })
    Dispatcher:registerAction("songbook_playlist",
        { category = "none", event = "SongbookShowPlaylist",
          title = _("Songbook: playlist"), general = true })
    Dispatcher:registerAction("songbook_now_playing",
        { category = "none", event = "SongbookOpenNowPlaying",
          title = _("Songbook: open the song now playing"), general = true })
    Dispatcher:registerAction("songbook_next_song",
        { category = "none", event = "SongbookNextSong",
          title = _("Songbook: next song in the playlist"), general = true })
    Dispatcher:registerAction("songbook_autoscroll",
        { category = "none", event = "SongbookAutoscroll",
          title = _("Songbook: start/stop autoscroll"), reader = true })
    Dispatcher:registerAction("songbook_autoscroll_faster",
        { category = "none", event = "SongbookAutoscrollSpeed", arg = 0.9,
          title = _("Songbook: autoscroll faster"), reader = true })
    Dispatcher:registerAction("songbook_autoscroll_slower",
        { category = "none", event = "SongbookAutoscrollSpeed", arg = 1.1,
          title = _("Songbook: autoscroll slower"), reader = true })
end

-- Songs and servers -------------------------------------------------------------
--
-- A song is identified by its uid: "<server key>/<id>" for songs downloaded
-- from a server (stored in songs/<key>/<id>.cho), or just "<id>" for .cho
-- files copied straight into songs/. Server keys and ids only contain
-- [%w-_.], so "/" and "~" are safe separators (split_uid(), make_uid()).

--- File of song `uid`: "<uid>.cho", or a copied "<uid>.chopro" when there is
-- no .cho (new files are always .cho).
function Songbook:songPath(uid)
    local base = self.songs_dir .. "/" .. uid
    if lfs.attributes(base .. ".cho", "mode") ~= "file"
            and lfs.attributes(base .. ".chopro", "mode") == "file" then
        return base .. ".chopro"
    end
    return base .. ".cho"
end

function Songbook:getServers()
    return self.settings:readSetting("servers") or {}
end

function Songbook:saveServers(servers)
    self:set("servers", servers)
end

--- Name of this device in the jam session: setting `device_name`, else the model.
function Songbook:deviceName()
    local name = self:get("device_name")
    if name and name ~= "" then return name end
    return Device.model or _("Songbook")
end

--- A songbook of the jam session as a song repository. It is not saved in
-- `servers`: it is a source only while connected. Its songs keep one folder
-- per address: setting `jam_servers` = { [url] = key }; `jam_names` =
-- { [key] = name } names the folder after the session.
function Songbook:jamServer(url, name)
    local keys = self.settings:readSetting("jam_servers") or {}
    if not keys[url] then
        keys[url] = Repo.server_key(url, self:takenKeys())
        self:set("jam_servers", keys)
    end
    local key = keys[url]
    if name and name ~= "" then
        local names = self.settings:readSetting("jam_names") or {}
        if names[key] ~= name then
            names[key] = name
            self:set("jam_names", names)
        end
    else
        name = nil
    end
    return { key = key, url = url, name = name or _("Jam session"), jam = true }
end

--- The followed songbook as a song repository (in Browse online), or nil
-- while not following.
function Songbook:followedServer()
    local f = jam.follow
    return f and self:jamServer(f.url, f.name)
end

--- Songbooks of the jam session sharing their songs: while following the
-- followed one and its other guests, while sharing our guests.
function Songbook:jamServers()
    local servers = {}
    if jam.follow then
        servers[1] = self:followedServer()
        for _i, peer in ipairs(jam.follow.peers or {}) do
            servers[#servers + 1] = self:jamServer(peer.url, peer.name)
        end
    elseif jam.server then
        for _i, peer in ipairs(self:jamPeers()) do
            servers[#servers + 1] = self:jamServer(peer.url, peer.name)
        end
    end
    return servers
end

--- Repositories to browse: the saved ones and the jam session's songbooks
-- (unless saved too).
function Songbook:onlineServers()
    local servers, seen = {}, {}   -- a copy: getServers() is the saved table
    for i, s in ipairs(self:getServers()) do
        servers[i] = s
        seen[Repo.base_url(s.url)] = true
    end
    for _i, s in ipairs(self:jamServers()) do
        if not seen[Repo.base_url(s.url)] then
            servers[#servers + 1] = s
            seen[Repo.base_url(s.url)] = true
        end
    end
    return servers
end

function Songbook:findServer(key)
    for i, server in ipairs(self:onlineServers()) do
        if server.key == key then return server, i end
    end
end

--- Whether `key` is the folder of songs downloaded from a followed songbook.
function Songbook:isJamServerKey(key)
    for _url, k in pairs(self.settings:readSetting("jam_servers") or {}) do
        if k == key then return true end
    end
    return false
end

function Songbook:serverName(server)
    return server.name or server.index_name or Repo.default_name(server.url)
end

--- Name of the server a song came from, or nil for local songs.
function Songbook:sourceName(uid)
    local key = split_uid(uid)
    if not key then return nil end
    local server = self:findServer(key)
    if server then return self:serverName(server) end
    if not self:isJamServerKey(key) then return key end
    return (self.settings:readSetting("jam_names") or {})[key] or _("Jam session")
end

--- Settings migrations: MIGRATIONS[n] upgrades the settings from schema n - 1
-- to n. Installs without a `schema` setting are schema 0 (also fresh ones, so
-- steps must cope with empty settings). Append steps; never change released ones.
local MIGRATIONS = {}

-- 1: the playlist is no longer tied to the jam session ("jam_playlist" -> "playlist").
MIGRATIONS[1] = function(self)
    local p = self.settings:readSetting("jam_playlist")
    if p == nil then return end
    self.settings:saveSetting("playlist", p)
    self.settings:delSetting("jam_playlist")
end

function Songbook:migrate()
    local schema = self.settings:readSetting("schema") or 0
    if schema >= #MIGRATIONS then return end
    for n = schema + 1, #MIGRATIONS do
        MIGRATIONS[n](self)
    end
    self.settings:saveSetting("schema", #MIGRATIONS)
    self.settings:flush()
end

-- Rendering -------------------------------------------------------------------

-- Rendered files are named "<uid with / as ~>@<options>.html".
local function render_stem(uid)
    return (uid:gsub("/", "~"))
end

-- Every option combination gets its own file name, so the reader's
-- document cache never shows a stale rendering.
function Songbook:renderSignature(uid)
    local t = self:getMap("transpose")[uid] or 0
    return string.format("t%+d.%s.c%d.r%d", t, self:get("notation"),
        self:get("show_chords") and 1 or 0, self:get("repeat_chorus") and 1 or 0)
end

function Songbook:idFromRenderedPath(path)
    if not path or path:sub(1, #self.render_dir + 1) ~= self.render_dir .. "/" then return nil end
    local stem = path:match("([^/]+)@[^/@]+%.html$")
    return stem and (stem:gsub("~", "/"))
end

function Songbook:currentSongId()
    local doc = self.ui and self.ui.document
    return doc and self:idFromRenderedPath(doc.file)
end

--- uid under which song `uid` is favorited or collected: own songs as they
-- are; a followed song (jam/) as a song of the followed songbook's repository
-- (its /index.json ids are Jam.song_id() too), where keepFollowedSong()
-- copies it. nil for a followed song after following stopped.
function Songbook:collectableUid(uid)
    if split_uid(uid) ~= JAM_KEY then return uid end
    local server = self:followedServer()
    if not server then return nil end
    local _key, id = split_uid(uid)
    return make_uid(server.key, id)
end

--- Copies a followed song to the followed songbook's folder (see
-- collectableUid()), so it stays among our songs. Returns that uid, or nil.
function Songbook:keepFollowedSong(uid)
    local kept = self:collectableUid(uid)
    if kept and kept ~= uid and lfs.attributes(self:songPath(kept), "mode") ~= "file" then
        local text = read_file(self:songPath(uid))
        if not text then return nil end
        util.makePath(self.songs_dir .. "/" .. split_uid(kept))
        if not write_file(self:songPath(kept), text) then return nil end
        self:setMapValue("downloaded", kept, true)
    end
    return kept
end

--- Like currentSongId(), but nil for a song received while following a jam
-- session (jam/): its length and other per-song settings aren't kept.
function Songbook:currentOwnSongId()
    local uid = self:currentSongId()
    if uid and split_uid(uid) ~= JAM_KEY then return uid end
end

function Songbook:removeStaleRenders(uid, keep)
    local prefix = render_stem(uid) .. "@"
    for name in lfs.dir(self.render_dir) do
        local path = self.render_dir .. "/" .. name
        if name:sub(1, #prefix) == prefix and name:match("%.html$") and path ~= keep
                and not (self.ui.document and self.ui.document.file == path) then
            os.remove(path)
            pcall(function()
                require("docsettings"):open(path):purge()
            end)
        end
    end
end

--- HTML of song `uid`; fields of `opts` override the settings
-- (transpose, notation, show_chords, web). Returns html or nil, err.
function Songbook:songHtml(uid, opts)
    opts = opts or {}
    local _key, id = split_uid(uid)
    local text = read_file(self:songPath(uid))
    if not text then return nil, T(_("Song file not found: %1"), id) end

    local ok, song = pcall(ChordPro.parse, text)
    if not ok then
        logger.warn("Songbook: parse error", uid, song)
        return nil, T(_("Cannot parse song: %1"), id)
    end

    local show_chords = opts.show_chords
    if show_chords == nil then show_chords = self:get("show_chords") end
    return Render.html(song, {
        transpose = opts.transpose or self:getMap("transpose")[uid] or 0,
        notation = opts.notation or self:get("notation"),
        show_chords = show_chords,
        repeat_chorus = self:get("repeat_chorus"),
        web = opts.web,
        fallback_title = id,
        labels = {
            key = _("Key"), capo = _("Capo"), transposed = _("Transposed"),
            chorus = _("Ref."), tempo = _("Tempo"),
        },
    })
end

--- Render song `uid` with current settings. Returns html path or nil, err.
function Songbook:render(uid)
    local html, err = self:songHtml(uid)
    if not html then return nil, err end

    local path = self.render_dir .. "/" .. render_stem(uid) .. "@" .. self:renderSignature(uid) .. ".html"
    local written, err = write_file(path, html)
    if not written then return nil, err end
    self:removeStaleRenders(uid, path)
    return path
end

function Songbook:openSong(uid)
    local path, err = self:render(uid)
    if not path then
        notify(err)
        return
    end
    -- while following, the followed songbook's playlist is used
    if not jam.follow and self:get("play_on_open") then self:playlistPlay(uid) end
    if self:get("scroll_mode") then self:preferScrollMode(path) end
    if self.ui.document then
        self.ui:switchDocument(path)
    else
        require("apps/reader/readerui"):showReader(path)
    end
end

--- Open the rendered song in continuous (scroll) mode, unless its view mode
-- was already chosen: ReaderConfig loads "copt_view_mode" from the
-- document's settings before rendering.
function Songbook:preferScrollMode(path)
    local doc_settings = require("docsettings"):open(path)
    if doc_settings:readSetting("copt_view_mode") == nil then
        doc_settings:saveSetting("copt_view_mode", 1)
        doc_settings:flush()
    end
end

--- Re-render the currently open song after a settings change.
function Songbook:refreshCurrent()
    local uid = self:currentSongId()
    if uid then self:openSong(uid) end
end

-- Songs on the device ---------------------------------------------------------

--- All songs on the device: local .cho files in songs/ and every songs/<key>/
-- folder (also of servers that were removed with their songs kept), except
-- songs received while following a jam session.
function Songbook:listLocal()
    local songs = {}
    local function add(key, dir, name)
        local id = song_file_id(name)
        if not id then return end
        -- "x.chopro" beside "x.cho" is the same song: the .cho is listed
        if name:match("%.chopro$") and lfs.attributes(dir .. "/" .. id .. ".cho", "mode") == "file" then return end
        local meta = song_meta(dir .. "/" .. name)
        local uid = make_uid(key, id)
        table.insert(songs, { uid = uid, id = id, title = meta.title or id, artist = meta.artist,
                              key = meta.key, source = self:sourceName(uid) })
    end
    for name in lfs.dir(self.songs_dir) do
        local path = self.songs_dir .. "/" .. name
        if name:sub(1, 1) ~= "." and lfs.attributes(path, "mode") == "directory" then
            if name ~= JAM_KEY then
                for sub in lfs.dir(path) do add(name, path, sub) end
            end
        else
            add(nil, self.songs_dir, name)
        end
    end
    sort_songs(songs)
    return songs
end

function Songbook:deleteSong(uid)
    os.remove(self:songPath(uid))
    self:setMapValue("downloaded", uid, nil)
    self:setMapValue("transpose", uid, nil)
    self:setMapValue("favorites", uid, nil)
    self:setMapValue("duration", uid, nil)
    local collections = self:getCollections()
    for _, c in ipairs(collections) do C.collection_set(c, uid, false) end
    self:saveCollections(collections)
    self:removeStaleRenders(uid, nil)
end

function Songbook:setAndRefresh(key, value)
    self:set(key, value)
    self:refreshCurrent()
end

return Songbook
