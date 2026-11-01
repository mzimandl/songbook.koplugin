--[[--
Songbook plugin: browse a song server, download ChordPro songs, render them
locally to HTML (chords above lyrics) and open them in the reader.

@module koplugin.Songbook
]]

-- Own modules must be required at load time: PluginLoader only adds the
-- plugin folder to package.path while main.lua is being loaded.
local ChordPro = require("songbook/chordpro")
local Jam = require("songbook/jam")
local Render = require("songbook/render")
local Repo = require("songbook/repo")

local ButtonDialog = require("ui/widget/buttondialog")
local ConfirmBox = require("ui/widget/confirmbox")
local DataStorage = require("datastorage")
local Device = require("device")
local Dispatcher = require("dispatcher")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local LuaSettings = require("luasettings")
local Menu = require("ui/widget/menu")
local NetworkMgr = require("ui/network/manager")
local Screen = Device.screen
local SpinWidget = require("ui/widget/spinwidget")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local util = require("util")
local _ = require("gettext")
local T = require("ffi/util").template

local Songbook = WidgetContainer:extend{
    name = "songbook",
    is_doc_only = false,
}

local DEFAULTS = {
    notation = "cz",
    max_cols = 42,
    show_chords = true,
    repeat_chorus = false,
    jam_port = 8765,
}

-- Song repository added on the first start (until then `servers` is unset).
local DEFAULT_SERVER_URL = "https://github.com/mzimandl/songbook-library"

-- KOReader makes a new plugin instance for every reader/file manager, so the
-- jam server and following live here and work through the newest instance
-- (jam.owner).
local jam = {}

-- Songs received from a followed songbook are kept in songs/<JAM_KEY>/.
local JAM_KEY = "jam"
-- Requests to a followed songbook block the UI, so they use short timeouts.
local FOLLOW_INTERVAL = 4         -- seconds between polls
local FOLLOW_TIMEOUT = { 2, 4 }   -- block, total seconds
local FOLLOW_MAX_FAILURES = 4

-- Helpers -------------------------------------------------------------------

local function read_file(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local data = f:read("*a")
    f:close()
    return data
end

local function write_file(path, data)
    local f, err = io.open(path, "wb")
    if not f then return nil, err end
    f:write(data)
    f:close()
    return true
end

local function lower(s)
    return util.stringLower and util.stringLower(s) or s:lower()
end

local function busy(text)
    local msg = InfoMessage:new{ text = text }
    UIManager:show(msg)
    UIManager:forceRePaint()
    return msg
end

local function notify(text)
    UIManager:show(InfoMessage:new{ text = text, timeout = 3 })
end

-- Lifecycle -------------------------------------------------------------------

function Songbook:init()
    self.data_dir = DataStorage:getDataDir() .. "/songbook"
    self.songs_dir = self.data_dir .. "/songs"
    self.render_dir = self.data_dir .. "/rendered"
    util.makePath(self.songs_dir)
    util.makePath(self.render_dir)

    self.settings = LuaSettings:open(DataStorage:getSettingsDir() .. "/songbook.lua")
    jam.owner = self
    self:migrate()
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
    Dispatcher:registerAction("songbook_toggle_favorite",
        { category = "none", event = "SongbookToggleFavorite",
          title = _("Songbook: add/remove favorite"), reader = true })
end

-- Songs and servers -------------------------------------------------------------
--
-- A song is identified by its uid: "<server key>/<id>" for songs downloaded
-- from a server (stored in songs/<key>/<id>.cho), or just "<id>" for .cho
-- files copied straight into songs/. Server keys and ids only contain
-- [%w-_.], so "/" and "~" are safe separators.

local function split_uid(uid)
    local key, id = uid:match("^([^/]+)/(.+)$")
    if key then return key, id end
    return nil, uid
end

local function make_uid(key, id)
    return key and key .. "/" .. id or id
end

function Songbook:songPath(uid)
    return self.songs_dir .. "/" .. uid .. ".cho"
end

function Songbook:getServers()
    return self.settings:readSetting("servers") or {}
end

function Songbook:saveServers(servers)
    self:set("servers", servers)
end

function Songbook:findServer(key)
    for i, server in ipairs(self:getServers()) do
        if server.key == key then return server, i end
    end
end

function Songbook:serverName(server)
    return server.name or server.index_name or Repo.default_name(server.url)
end

--- Name of the server a song came from, or nil for local songs.
function Songbook:sourceName(uid)
    local key = split_uid(uid)
    if not key then return nil end
    local server = self:findServer(key)
    return server and self:serverName(server) or key
end

--- Settings migrations: MIGRATIONS[n] upgrades the settings from schema n - 1
-- to n. Installs without a `schema` setting are schema 0 (also fresh ones, so
-- steps must cope with empty settings). Append steps; never change released ones.
local MIGRATIONS = {}

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
    return string.format("t%+d.%s.w%d.c%d.r%d", t, self:get("notation"), self:get("max_cols"),
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

--- Like currentSongId(), but nil for a song received while following a jam
-- session: those are not listed, so they can't be kept in favorites or collections.
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
-- (transpose, notation, max_cols, show_chords, web). Returns html or nil, err.
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
        max_cols = opts.max_cols or self:get("max_cols"),
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
    if jam.server then self:jamPlayed(uid) end
    if jam.follow and split_uid(uid) ~= JAM_KEY then
        self:stopFollowing()
        notify(_("Stopped following the jam session."))
    end
    if self.ui.document then
        self.ui:switchDocument(path)
    else
        require("apps/reader/readerui"):showReader(path)
    end
end

function Songbook:onSongbookTranspose(delta)
    local uid = self:currentSongId()
    if not uid then return end
    local t = 0
    if delta ~= 0 then t = (self:getMap("transpose")[uid] or 0) + delta end
    if t > 11 then t = t - 12 elseif t < -11 then t = t + 12 end
    self:setMapValue("transpose", uid, t ~= 0 and t or nil)
    self:openSong(uid)
    return true
end

--- Re-render the currently open song after a settings change.
function Songbook:refreshCurrent()
    local uid = self:currentSongId()
    if uid then self:openSong(uid) end
end

-- Local songs -------------------------------------------------------------------

local function song_file_id(name)
    return name:match("^(.+)%.cho$") or name:match("^(.+)%.chopro$")
end

--- All songs on the device: local .cho files in songs/ and every songs/<key>/
-- folder (also of servers that were removed with their songs kept), except
-- songs received while following a jam session.
function Songbook:listLocal()
    local songs = {}
    local function add(key, dir, name)
        local id = song_file_id(name)
        if not id then return end
        local meta = ChordPro.parse_meta(read_file(dir .. "/" .. name) or "")
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
    table.sort(songs, function(a, b) return lower(a.title) < lower(b.title) end)
    return songs
end

-- KOReader's Menu gives the right-hand text all the width it needs and cuts the
-- song title instead, so long artist or repository names are shortened.
local MAX_ARTIST, MAX_SOURCE = 16, 12

--- "Artist · Repository · status" for the right-hand side of list items.
local function details(artist, source, status)
    local parts = {}
    if artist and artist ~= "" then parts[#parts + 1] = Render.truncate(artist, MAX_ARTIST) end
    if source and source ~= "" then parts[#parts + 1] = Render.truncate(source, MAX_SOURCE) end
    if status and status ~= "" then parts[#parts + 1] = status end
    return table.concat(parts, " · ")
end

local function matches(song, query)
    if not query or query == "" then return true end
    query = lower(query)
    return lower(song.title):find(query, 1, true)
        or (song.artist and lower(song.artist):find(query, 1, true))
end

--- Generic searchable song list.
-- get_songs() -> songs; make_item(song) -> menu item.
-- on_hold(song, refresh): refresh() rebuilds the list (keeping the search).
-- on_close(): called when the list is closed with × (not when a song is opened).
function Songbook:showList(title, get_songs, make_item, on_hold, on_close)
    local menu, query
    local function build()
        local items = {
            {
                text = query and T(_("Search: %1"), query) or _("Search…"),
                bold = true,
                callback = function()
                    self:askSearch(query, function(q)
                        query = q ~= "" and q or nil
                        menu:switchItemTable(title, build())
                    end)
                end,
            },
        }
        local favorites = self:getMap("favorites")
        for _, song in ipairs(get_songs()) do
            if matches(song, query) then
                local item = make_item(song)
                item.song = song
                if favorites[song.uid] then item.text = "★ " .. item.text end
                table.insert(items, item)
            end
        end
        if #items == 1 then
            table.insert(items, { text = _("No songs"), select_enabled = false })
        end
        return items
    end
    local function refresh()
        menu:switchItemTable(title, build())
    end

    menu = Menu:new{
        title = title,
        item_table = build(),
        covers_fullscreen = true,
        is_borderless = true,
        is_popout = false,
        width = Screen:getWidth(),
        height = Screen:getHeight(),
        onMenuHold = function(_menu, item)
            if item.song and on_hold then on_hold(item.song, refresh) end
            return true
        end,
    }
    -- The search callback must not close the list; song callbacks do.
    menu.close_callback = nil
    if on_close then
        local close = menu.onClose
        menu.onClose = function(m)
            local handled = close and close(m)
            on_close()
            return handled
        end
    end
    self.list_menu = menu
    UIManager:show(menu)
    return menu
end

function Songbook:askSearch(current, cb)
    local dialog
    dialog = InputDialog:new{
        title = _("Search songs"),
        input = current or "",
        input_hint = _("Title or artist"),
        buttons = {{
            { text = _("Cancel"), id = "close", callback = function() UIManager:close(dialog) end },
            { text = _("Search"), is_enter_default = true, callback = function()
                local q = dialog:getInputText()
                UIManager:close(dialog)
                cb(q)
            end },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

-- Lists are opened with the Songbook menu kept open (and the collection or
-- repository picker under a song list), so closing a list with × goes back.
-- Opening a song closes them all.
function Songbook:setParentList(menu)
    self.parent_list = menu
end

function Songbook:closeList()
    if self.list_menu then
        UIManager:close(self.list_menu)
        self.list_menu = nil
    end
    if self.parent_list then
        UIManager:close(self.parent_list)
        self.parent_list = nil
    end
    local menu = self.ui and self.ui.menu
    if menu and menu.onCloseReaderMenu then
        menu:onCloseReaderMenu()
    elseif menu and menu.onCloseFileManagerMenu then
        menu:onCloseFileManagerMenu()
    end
end

function Songbook:deleteSong(uid)
    os.remove(self:songPath(uid))
    self:setMapValue("downloaded", uid, nil)
    self:setMapValue("transpose", uid, nil)
    self:setMapValue("favorites", uid, nil)
    local collections = self:getCollections()
    for _, c in ipairs(collections) do c.songs[uid] = nil end
    self:saveCollections(collections)
    self:removeStaleRenders(uid, nil)
end

-- Favorites -------------------------------------------------------------------

function Songbook:isFavorite(uid)
    return self:getMap("favorites")[uid] == true
end

function Songbook:setFavorite(uid, on)
    self:setMapValue("favorites", uid, on and true or nil)
end

function Songbook:onSongbookToggleFavorite()
    local uid = self:currentOwnSongId()
    if not uid then return end
    local on = not self:isFavorite(uid)
    self:setFavorite(uid, on)
    notify(on and _("Added to favorites.") or _("Removed from favorites."))
    return true
end

--- Favorite toggle button for a song's long-press dialog.
-- before(): optional step that must succeed first (e.g. download); returns ok.
function Songbook:favoriteButton(song, close, refresh, before)
    local on = self:isFavorite(song.uid)
    return {
        text = on and _("Remove from favorites") or _("Add to favorites"),
        callback = function()
            close()
            if before and not before() then return end
            self:setFavorite(song.uid, not on)
            refresh()
        end,
    }
end

-- Collections -------------------------------------------------------------------
--
-- Named song lists made on the device: { { name = "...", songs = { [uid] = true } } }.
-- Names are unique, so they identify a collection.

function Songbook:getCollections()
    local collections = self.settings:readSetting("collections") or {}
    table.sort(collections, function(a, b) return lower(a.name) < lower(b.name) end)
    return collections
end

function Songbook:saveCollections(collections)
    self:set("collections", collections)
end

function Songbook:findCollection(name, collections)
    for i, c in ipairs(collections or self:getCollections()) do
        if c.name == name then return c, i end
    end
end

local function count_keys(t)
    local n = 0
    for _k in pairs(t) do n = n + 1 end
    return n
end

--- Create a collection. Returns true, or nil and an error message.
function Songbook:createCollection(name)
    if self:findCollection(name) then
        return nil, T(_("A collection named \"%1\" already exists."), name)
    end
    local collections = self:getCollections()
    table.insert(collections, { name = name, songs = {} })
    self:saveCollections(collections)
    return true
end

function Songbook:renameCollection(old, new)
    if old == new then return true end
    if self:findCollection(new) then
        return nil, T(_("A collection named \"%1\" already exists."), new)
    end
    local collections = self:getCollections()
    local c = self:findCollection(old, collections)
    if c then c.name = new end
    self:saveCollections(collections)
    return true
end

function Songbook:deleteCollection(name)
    local collections = self:getCollections()
    local _c, i = self:findCollection(name, collections)
    if i then table.remove(collections, i) end
    self:saveCollections(collections)
end

function Songbook:isInCollection(name, uid)
    local c = self:findCollection(name)
    return c ~= nil and c.songs[uid] == true
end

function Songbook:setInCollection(name, uid, on)
    local collections = self:getCollections()
    local c = self:findCollection(name, collections)
    if not c then return end
    c.songs[uid] = on and true or nil
    self:saveCollections(collections)
end

--- Ask for a collection name. on_saved(name) gets a non-empty name.
function Songbook:askCollectionName(title, current, on_saved)
    local dialog
    dialog = InputDialog:new{
        title = title,
        input = current or "",
        input_hint = _("Collection name"),
        buttons = {{
            { text = _("Cancel"), id = "close", callback = function() UIManager:close(dialog) end },
            { text = _("Save"), is_enter_default = true, callback = function()
                local name = util.trim(dialog:getInputText())
                UIManager:close(dialog)
                if name ~= "" then on_saved(name) end
            end },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

--- Dialog with a check button per collection for one song.
-- on_changed(): called after every change; before(): see favoriteButton.
function Songbook:showSongCollections(song, on_changed, before)
    local dialog
    local function reopen()
        on_changed()
        self:showSongCollections(song, on_changed, before)
    end
    local function change(fn)
        return function()
            UIManager:close(dialog)
            if before and not before() then return end
            fn()
        end
    end
    local buttons = {}
    for _i, c in ipairs(self:getCollections()) do
        local on = c.songs[song.uid] == true
        table.insert(buttons, {{
            text = (on and "✓ " or "") .. c.name,
            callback = change(function()
                self:setInCollection(c.name, song.uid, not on)
                reopen()
            end),
        }})
    end
    table.insert(buttons, {
        { text = _("New collection…"), callback = change(function()
            self:askCollectionName(_("New collection"), "", function(name)
                local ok, err = self:createCollection(name)
                if not ok then notify(err) return end
                self:setInCollection(name, song.uid, true)
                reopen()
            end)
        end) },
        { text = _("Close"), callback = function() UIManager:close(dialog) end },
    })
    dialog = ButtonDialog:new{
        title = T(_("Collections: %1"), song.title),
        buttons = buttons,
    }
    UIManager:show(dialog)
end

function Songbook:collectionsButton(song, close, refresh, before)
    return {
        text = _("Collections…"),
        callback = function()
            close()
            self:showSongCollections(song, refresh, before)
        end,
    }
end

function Songbook:onSongbookShowCollections()
    local menu
    local function build()
        local items = {}
        for _i, c in ipairs(self:getCollections()) do
            table.insert(items, {
                text = c.name,
                mandatory = tostring(count_keys(c.songs)),
                collection = c.name,
                callback = function()
                    -- songs may be removed from the collection meanwhile: update the counts
                    self:showCollection(c.name, function() menu:switchItemTable(nil, build()) end)
                end,
            })
        end
        table.insert(items, {
            text = _("New collection…"),
            bold = true,
            callback = function()
                self:askCollectionName(_("New collection"), "", function(name)
                    local ok, err = self:createCollection(name)
                    if not ok then notify(err) return end
                    menu:switchItemTable(nil, build())
                end)
            end,
        })
        return items
    end
    menu = Menu:new{
        title = _("Collections"),
        item_table = build(),
        covers_fullscreen = true,
        is_borderless = true,
        is_popout = false,
        width = Screen:getWidth(),
        height = Screen:getHeight(),
        onMenuHold = function(_menu, item)
            if not item.collection then return true end
            local name = item.collection
            local dialog
            dialog = ButtonDialog:new{
                title = name,
                buttons = {{
                    { text = _("Rename"), callback = function()
                        UIManager:close(dialog)
                        self:askCollectionName(_("Rename collection"), name, function(new)
                            local ok, err = self:renameCollection(name, new)
                            if not ok then notify(err) return end
                            menu:switchItemTable(nil, build())
                        end)
                    end },
                    { text = _("Delete"), callback = function()
                        UIManager:close(dialog)
                        UIManager:show(ConfirmBox:new{
                            text = T(_("Delete collection \"%1\"?\nThe songs stay on the device."), name),
                            ok_text = _("Delete"),
                            ok_callback = function()
                                self:deleteCollection(name)
                                menu:switchItemTable(nil, build())
                            end,
                        })
                    end },
                }},
            }
            UIManager:show(dialog)
            return true
        end,
    }
    self:setParentList(menu)
    UIManager:show(menu)
    return true
end

function Songbook:showCollection(name, on_close)
    return self:showLocal(name, function(song) return self:isInCollection(name, song.uid) end,
        _("This collection is empty. Long-press a song in a list and choose \"Collections…\", or use the Songbook menu while a song is open."),
        on_close)
end

-- Song lists on the device -----------------------------------------------------

--- List of songs on the device. filter(song) limits the list (nil = all);
-- empty_text is shown instead of an empty list; on_close as in showList().
function Songbook:showLocal(title, filter, empty_text, on_close)
    local function load()
        local songs = self:listLocal()
        if not filter then return songs end
        local out = {}
        for _, song in ipairs(songs) do
            if filter(song) then table.insert(out, song) end
        end
        return out
    end
    -- the first build reuses this list; refreshes read the folder again
    local first = load()
    local function get_songs()
        local songs = first or load()
        first = nil
        return songs
    end
    if #first == 0 then
        notify(empty_text)
        return true
    end
    self:showList(title, get_songs, function(song)
        return {
            text = song.title,
            mandatory = details(song.artist, song.source),
            callback = function()
                self:closeList()
                self:openSong(song.uid)
            end,
        }
    end, function(song, refresh)
        local dialog
        local function close() UIManager:close(dialog) end
        local buttons = {
            { self:favoriteButton(song, close, refresh) },
            { self:collectionsButton(song, close, refresh) },
            {{ text = _("Delete"), callback = function()
                close()
                UIManager:show(ConfirmBox:new{
                    text = T(_("Delete \"%1\"?"), song.title),
                    ok_text = _("Delete"),
                    ok_callback = function()
                        self:deleteSong(song.uid)
                        refresh()
                    end,
                })
            end }},
        }
        local request = self:requestButton(song, close)
        if request then table.insert(buttons, 1, { request }) end
        dialog = ButtonDialog:new{ title = song.title, buttons = buttons }
        UIManager:show(dialog)
    end, on_close)
    return true
end

function Songbook:onSongbookShowLocal()
    return self:showLocal(_("My songs"), nil,
        T(_("No songs yet. Download some via \"Browse online\", or copy .cho files to:\n%1"), self.songs_dir))
end

function Songbook:onSongbookShowFavorites()
    return self:showLocal(_("Favorites"), function(song) return self:isFavorite(song.uid) end,
        _("No favorites yet. Long-press a song in a list to add it, or use the Songbook menu while a song is open."))
end

-- Online -------------------------------------------------------------------

--- Load a server's index. Songs get `uid` and `server` fields.
function Songbook:fetchIndex(server)
    local msg = busy(T(_("Loading song list: %1…"), self:serverName(server)))
    local body, err = Repo.fetch(Repo.join(Repo.base_url(server.url), "index.json"))
    UIManager:close(msg)
    if not body then return nil, T(_("Cannot load song list: %1"), err) end
    local songs, perr, name = Repo.parse_index(body, require("json").decode)
    if not songs then return nil, perr end
    if name ~= server.index_name then
        local servers = self:getServers()
        for _, s in ipairs(servers) do
            if s.key == server.key then s.index_name = name end
        end
        self:saveServers(servers)
        server.index_name = name
    end
    for _, song in ipairs(songs) do
        song.uid = make_uid(server.key, song.id)
        song.server = server
    end
    table.sort(songs, function(a, b) return lower(a.title) < lower(b.title) end)
    return songs
end

function Songbook:isDownloaded(song)
    return lfs.attributes(self:songPath(song.uid), "mode") == "file"
end

function Songbook:isUpToDate(song)
    if not self:isDownloaded(song) then return false end
    local have = self:getMap("downloaded")[song.uid]
    return song.updated == nil or have == song.updated
end

function Songbook:download(song)
    local body, err = Repo.fetch(Repo.join(Repo.base_url(song.server.url), song.file))
    if not body then return nil, err end
    util.makePath(self.songs_dir .. "/" .. song.server.key)
    local ok, werr = write_file(self:songPath(song.uid), body)
    if not ok then return nil, werr end
    self:setMapValue("downloaded", song.uid, song.updated or true)
    return true
end

--- Run cb() online, asking for a first server when none is set up.
function Songbook:withServers(cb)
    if #self:getServers() == 0 then
        self:askServerUrl(_("Add song repository"), "", function(url)
            self:addServer(url)
            self:withServers(cb)
        end)
        return
    end
    NetworkMgr:runWhenOnline(cb)
end

function Songbook:browseOnline()
    self:withServers(function()
        local servers = self:getServers()
        if #servers == 1 then
            self:showOnlineSongs({ servers[1] })
            return
        end
        local picker
        local items = {}
        for _, server in ipairs(servers) do
            table.insert(items, {
                text = self:serverName(server),
                callback = function() self:showOnlineSongs({ server }) end,
            })
        end
        table.insert(items, {
            text = _("All repositories"),
            bold = true,
            callback = function() self:showOnlineSongs(servers) end,
        })
        picker = Menu:new{
            title = _("Song repositories"),
            item_table = items,
            covers_fullscreen = true,
            is_borderless = true,
            is_popout = false,
            width = Screen:getWidth(),
            height = Screen:getHeight(),
        }
        self:setParentList(picker)
        UIManager:show(picker)
    end)
end

--- Load the indexes of `servers` and show their songs in one list.
-- Servers that fail are reported; the others are still shown.
function Songbook:showOnlineSongs(servers)
    local songs, errors = {}, {}
    for _, server in ipairs(servers) do
        local list, err = self:fetchIndex(server)
        if list then
            for _, song in ipairs(list) do table.insert(songs, song) end
        else
            table.insert(errors, self:serverName(server) .. ": " .. err)
        end
    end
    if #errors > 0 then notify(table.concat(errors, "\n")) end
    if #songs == 0 and #errors > 0 then return end
    local multi = #servers > 1
    if multi then
        table.sort(songs, function(a, b) return lower(a.title) < lower(b.title) end)
    end

    local function status(song)
        if not self:isDownloaded(song) then return nil end
        return self:isUpToDate(song) and _("saved") or _("update")
    end
    local title = multi and _("All repositories") or self:serverName(servers[1])
    self:showList(title, function() return songs end, function(song)
        return {
            text = song.title,
            mandatory = details(song.artist, multi and self:serverName(song.server) or nil, status(song)),
            callback = function()
                if not self:isUpToDate(song) then
                    local msg = busy(T(_("Downloading %1…"), song.title))
                    local ok, derr = self:download(song)
                    UIManager:close(msg)
                    if not ok then
                        notify(T(_("Download failed: %1"), derr))
                        return
                    end
                end
                self:closeList()
                self:openSong(song.uid)
            end,
        }
    end, function(song, refresh)
        local dialog
        local function close() UIManager:close(dialog) end
        local function download()
            local msg = busy(T(_("Downloading %1…"), song.title))
            local ok, derr = self:download(song)
            UIManager:close(msg)
            if not ok then notify(T(_("Download failed: %1"), derr)) end
            return ok
        end
        local function ensure_downloaded()
            return self:isDownloaded(song) or download()
        end
        local buttons = {
            -- favorites, collections and our playlist hold songs on the device, so download first
            { self:favoriteButton(song, close, refresh, ensure_downloaded) },
            { self:collectionsButton(song, close, refresh, ensure_downloaded) },
            {{ text = _("Download again"), callback = function()
                close()
                if download() then
                    notify(_("Downloaded."))
                    refresh()
                end
            end }},
        }
        local request = self:requestButton(song, close, ensure_downloaded)
        if request then table.insert(buttons, 1, { request }) end
        dialog = ButtonDialog:new{ title = song.title, buttons = buttons }
        UIManager:show(dialog)
    end)
end

function Songbook:downloadAll()
    self:withServers(function()
        local lines = {}
        for _i, server in ipairs(self:getServers()) do
            local name = self:serverName(server)
            local songs, err = self:fetchIndex(server)
            if not songs then
                table.insert(lines, name .. ": " .. err)
            else
                local done, failed, skipped = 0, 0, 0
                for i, song in ipairs(songs) do
                    if self:isUpToDate(song) then
                        skipped = skipped + 1
                    else
                        local msg = busy(T(_("%1: downloading %2 / %3…"), name, i, #songs))
                        local ok = self:download(song)
                        UIManager:close(msg)
                        if ok then done = done + 1 else failed = failed + 1 end
                    end
                end
                table.insert(lines, T(_("%1\nDownloaded: %2, up to date: %3, failed: %4"),
                    name, done, skipped, failed))
            end
        end
        notify(table.concat(lines, "\n\n"))
    end)
end

-- Settings -------------------------------------------------------------------

--- Ask for a server URL. on_saved(url) is called with a non-empty URL.
function Songbook:askServerUrl(title, current, on_saved)
    local dialog
    dialog = InputDialog:new{
        title = title,
        description = _("GitHub repository address, or any web folder containing index.json."),
        input = current or "",
        input_hint = "https://github.com/user/songs",
        buttons = {{
            { text = _("Cancel"), id = "close", callback = function() UIManager:close(dialog) end },
            { text = _("Save"), is_enter_default = true, callback = function()
                local url = util.trim(dialog:getInputText())
                UIManager:close(dialog)
                if url ~= "" then on_saved(url) end
            end },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function Songbook:addServer(url)
    local servers = self:getServers()
    local taken = {}
    for _, server in ipairs(servers) do taken[server.key] = true end
    taken[JAM_KEY] = true
    -- also avoid folders left behind by removed servers
    for name in lfs.dir(self.songs_dir) do taken[name] = true end
    local server = { key = Repo.server_key(url, taken), url = url }
    table.insert(servers, server)
    self:saveServers(servers)
    util.makePath(self.songs_dir .. "/" .. server.key)
    return server
end

--- Update fields of the server with `key` (nil values clear a field).
function Songbook:updateServer(key, fields)
    local servers = self:getServers()
    for _, server in ipairs(servers) do
        if server.key == key then
            for k, v in pairs(fields) do server[k] = v end
        end
    end
    self:saveServers(servers)
end

--- Remove a server; with delete_songs also its downloaded songs.
function Songbook:removeServer(key, delete_songs)
    local servers = self:getServers()
    for i = #servers, 1, -1 do
        if servers[i].key == key then table.remove(servers, i) end
    end
    self:saveServers(servers)
    if not delete_songs then return end
    local dir = self.songs_dir .. "/" .. key
    if lfs.attributes(dir, "mode") ~= "directory" then return end
    for name in lfs.dir(dir) do
        local id = song_file_id(name)
        if id then
            self:deleteSong(make_uid(key, id))
        elseif name ~= "." and name ~= ".." then
            os.remove(dir .. "/" .. name)
        end
    end
    os.remove(dir)
end

--- Items of the "Song repositories" settings submenu.
function Songbook:serversMenu()
    -- Rebuild the open submenu after a change, so it shows the current list.
    local function refresh(touchmenu_instance)
        if touchmenu_instance then
            touchmenu_instance.item_table = self:serversMenu()
            touchmenu_instance:updateItems()
        end
    end
    local items = {}
    for _, server in ipairs(self:getServers()) do
        table.insert(items, {
            text_func = function() return self:serverName(server) end,
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                self:showServerActions(server, function() refresh(touchmenu_instance) end)
            end,
        })
    end
    table.insert(items, {
        text = _("Add repository…"),
        keep_menu_open = true,
        separator = #items > 0 or nil,
        callback = function(touchmenu_instance)
            self:askServerUrl(_("Add song repository"), "", function(url)
                self:addServer(url)
                refresh(touchmenu_instance)
            end)
        end,
    })
    return items
end

function Songbook:showServerActions(server, on_changed)
    local dialog
    local function close_then(fn)
        return function()
            UIManager:close(dialog)
            fn()
        end
    end
    dialog = ButtonDialog:new{
        title = self:serverName(server) .. "\n" .. server.url,
        buttons = {
            {
                { text = _("Edit URL"), callback = close_then(function()
                    self:askServerUrl(_("Song repository URL"), server.url, function(url)
                        self:updateServer(server.key, { url = url, index_name = false })
                        on_changed()
                    end)
                end) },
                { text = _("Rename"), callback = close_then(function()
                    self:askServerName(server, on_changed)
                end) },
            },
            {
                { text = _("Remove"), callback = close_then(function()
                    self:askRemoveServer(server, on_changed)
                end) },
            },
        },
    }
    UIManager:show(dialog)
end

function Songbook:askServerName(server, on_changed)
    local dialog
    dialog = InputDialog:new{
        title = _("Repository name"),
        description = _("Leave empty to use the name from the repository."),
        input = server.name or "",
        input_hint = server.index_name or Repo.default_name(server.url),
        buttons = {{
            { text = _("Cancel"), id = "close", callback = function() UIManager:close(dialog) end },
            { text = _("Save"), is_enter_default = true, callback = function()
                local name = util.trim(dialog:getInputText())
                UIManager:close(dialog)
                self:updateServer(server.key, { name = name ~= "" and name or false })
                on_changed()
            end },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function Songbook:askRemoveServer(server, on_changed)
    local dialog
    local function remove(delete_songs)
        return function()
            UIManager:close(dialog)
            self:removeServer(server.key, delete_songs)
            on_changed()
        end
    end
    dialog = ButtonDialog:new{
        title = T(_("Remove repository \"%1\"?"), self:serverName(server)),
        buttons = {
            {{ text = _("Remove and delete its songs"), callback = remove(true) }},
            {{ text = _("Remove, keep downloaded songs"), callback = remove(false) }},
            {{ text = _("Cancel"), callback = function() UIManager:close(dialog) end }},
        },
    }
    UIManager:show(dialog)
end

-- Jam session -------------------------------------------------------------------
--
-- Shares the song being played as a web page on the local network (see
-- songbook/jam.lua). The shared song is the open one, or the last one opened
-- when the reader is closed.

-- Address of the network interface used for outgoing traffic; connecting a UDP
-- socket sends nothing.
local function local_ip()
    local ok, ip = pcall(function()
        local udp = require("socket").udp()
        udp:setpeername("8.8.8.8", 80)
        local addr = udp:getsockname()
        udp:close()
        return addr
    end)
    if ok and ip and ip ~= "0.0.0.0" then return ip end
end

-- Open/close the port in the Kindle firewall (as httpinspector does).
local function kindle_firewall(op, port)
    if not Device:isKindle() then return end
    os.execute(string.format("iptables %s INPUT -p tcp --dport %d -m conntrack --ctstate NEW,ESTABLISHED -j ACCEPT", op, port))
    os.execute(string.format("iptables %s OUTPUT -p tcp --sport %d -m conntrack --ctstate ESTABLISHED -j ACCEPT", op, port))
end

-- SimpleTCPServer callback: must send the response and return nothing
-- (UIManager would treat a return value as an input event).
local function serve_jam(data, client)
    local ok, resp = pcall(function() return Jam.handle(Jam.parse_request(data), jam.context) end)
    if not ok then
        logger.warn("Songbook: jam request failed", resp)
        resp = Jam.response(500, "text/plain", "Internal error")
    end
    jam.server:send(resp, client)
end

function Songbook:jamSong()
    local uid = self:currentSongId() or jam.uid
    if uid and not lfs.attributes(self:songPath(uid), "mode") then uid = nil end
    jam.uid = uid
    return uid
end

function Songbook:jamState()
    local uid = self:jamSong()
    local state = { notation = self:get("notation") }
    if uid then
        local _key, id = split_uid(uid)
        local meta = ChordPro.parse_meta(read_file(self:songPath(uid)) or "")
        state.uid = uid
        state.rev = uid .. "@" .. self:renderSignature(uid)
        state.title = meta.title or id
        state.artist = meta.artist
        state.transpose = self:getMap("transpose")[uid] or 0
    end
    return state
end

function Songbook:jamSongs()
    local songs = {}
    for _i, song in ipairs(self:listLocal()) do
        local mtime = lfs.attributes(self:songPath(song.uid), "modification")
        songs[#songs + 1] = {
            uid = song.uid, title = song.title, artist = song.artist, key = song.key,
            updated = mtime and tostring(mtime),
        }
    end
    return songs
end

-- Playlist: songs played while sharing and guests' requests, kept in the
-- settings until cleared.
function Songbook:getPlaylist()
    local p = self.settings:readSetting("jam_playlist") or {}
    p.history, p.queue = p.history or {}, p.queue or {}
    return p
end

function Songbook:savePlaylist(p)
    self:set("jam_playlist", p)
    if jam.playlist_refresh then jam.playlist_refresh() end
end

function Songbook:playlistEntry(uid, by)
    local text = read_file(self:songPath(uid))
    if not text then return nil end
    local _key, id = split_uid(uid)
    local meta = ChordPro.parse_meta(text)
    return { uid = uid, title = meta.title or id, artist = meta.artist, by = by, at = os.time() }
end

function Songbook:jamPlayed(uid)
    local entry = self:playlistEntry(uid)
    if not entry then return end
    local p = self:getPlaylist()
    if Jam.played(p.history, p.queue, entry) then self:savePlaylist(p) end
end

function Songbook:jamRequest(uid, by)
    if split_uid(uid) == JAM_KEY then return nil, "missing" end   -- not listed, so not requestable
    local entry = self:playlistEntry(uid, by)
    if not entry then return nil, "missing" end
    local p = self:getPlaylist()
    local ok, err = Jam.add_request(p.queue, entry)
    if not ok then return nil, err end
    self:savePlaylist(p)
    notify(by and T(_("Song request: %1 (%2)"), entry.title, by) or T(_("Song request: %1"), entry.title))
    return true
end

local function request_error(code)
    if code == "queued" then return _("This song is already requested.") end
    if code == "full" then return _("Too many requests, try again later.") end
    return _("This song is not available.")
end

--- Ask the followed songbook to play `song`. Songs received from it or
-- downloaded from it as a repository use its own ids; other songs are matched
-- by uid, which works when both have them from the same repository.
function Songbook:requestFromFollowed(song)
    local f = jam.follow
    local key, id = split_uid(song.uid)
    local server = key and self:findServer(key)
    local same_source = key == JAM_KEY or (server and Repo.base_url(server.url) == Repo.base_url(f.url))
    local remote_id = same_source and id or Jam.song_id(song.uid)
    local body = Repo.fetch(f.url .. "queue/add?id=" .. remote_id, FOLLOW_TIMEOUT[1], FOLLOW_TIMEOUT[2])
    local ok, data = pcall(require("json").decode, body or "")
    if not body or not ok or type(data) ~= "table" then
        return notify(_("Cannot reach the other songbook."))
    end
    notify(data.ok and T(_("Requested: %1"), song.title) or request_error(data.error))
end

--- "Request to play" for a song's long-press dialog, or nil when not in a
-- jam session. While following, the request goes to the followed songbook;
-- while sharing, to our own playlist. `before` as in favoriteButton().
function Songbook:requestButton(song, close, before)
    if not (self:isFollowing() or self:isJamRunning()) then return nil end
    return {
        text = _("Request to play"),
        callback = function()
            close()
            if self:isFollowing() then return self:requestFromFollowed(song) end
            if before and not before() then return end
            local ok, err = self:jamRequest(song.uid)
            if not ok then notify(request_error(err)) end
        end,
    }
end

--- Playlist of the followed songbook: p, raw body (nil, nil when unreachable).
function Songbook:fetchFollowedPlaylist()
    local body = Repo.fetch(jam.follow.url .. "playlist.json", FOLLOW_TIMEOUT[1], FOLLOW_TIMEOUT[2])
    local p = body and Jam.parse_playlist(body, require("json").decode)
    if p then return p, body end
end

--- Our playlist, or while following the followed songbook's (read-only).
function Songbook:showPlaylist()
    local remote = self:isFollowing()
    local p, body
    if remote then
        p, body = self:fetchFollowedPlaylist()
        if not p then return notify(_("Cannot reach the other songbook.")) end
    end
    local title = remote and T(_("Playlist of %1"), (jam.follow.url:gsub("^%a+://", ""):gsub("/$", "")))
        or _("Playlist")
    local menu
    local function build()
        if not remote then p = self:getPlaylist() end
        local items = {}
        if not remote then
            table.insert(items, {
                text = _("Save played songs as collection…"),
                bold = true,
                callback = function() self:savePlaylistAsCollection() end,
            })
            table.insert(items, {
                text = _("Clear playlist"),
                bold = true,
                callback = function()
                    UIManager:show(ConfirmBox:new{
                        text = _("Clear the list of played and requested songs?"),
                        ok_text = _("Clear"),
                        ok_callback = function() self:savePlaylist({}) end,
                    })
                end,
            })
        end
        table.insert(items, { text = T(_("Up next (%1)"), #p.queue), bold = true, select_enabled = false })
        local function add(entry, mandatory, queued)
            local item = { text = entry.title, mandatory = mandatory, entry = entry, queued = queued }
            -- the other songbook's songs may not be on this device
            if not remote then
                item.callback = function()
                    UIManager:close(menu)
                    self:openSong(entry.uid)
                end
            end
            table.insert(items, item)
        end
        for _i, e in ipairs(p.queue) do add(e, e.by and Render.truncate(e.by, MAX_SOURCE) or "", true) end
        if #p.queue == 0 then table.insert(items, { text = _("No requests"), dim = true, select_enabled = false }) end
        table.insert(items, { text = T(_("Played (%1)"), #p.history), bold = true, select_enabled = false })
        for i = #p.history, 1, -1 do
            local at = p.history[i].at
            add(p.history[i], at and os.date("%H:%M", at) or "")
        end
        return items
    end
    menu = Menu:new{
        title = title,
        item_table = build(),
        covers_fullscreen = true,
        is_borderless = true,
        is_popout = false,
        width = Screen:getWidth(),
        height = Screen:getHeight(),
        onMenuHold = function(_menu, item)
            if remote or not item.queued then return true end
            local dialog
            dialog = ButtonDialog:new{
                title = item.entry.title,
                buttons = {{{ text = _("Remove from queue"), callback = function()
                    UIManager:close(dialog)
                    local list = self:getPlaylist()
                    for i = #list.queue, 1, -1 do
                        if list.queue[i].uid == item.entry.uid then table.remove(list.queue, i) end
                    end
                    self:savePlaylist(list)
                end }}},
            }
            UIManager:show(dialog)
            return true
        end,
    }
    -- Menu calls close_callback after every tap; song items close the list themselves.
    menu.close_callback = nil
    -- Called after our playlist changes, and on every poll while following.
    jam.playlist_refresh = function()
        if not UIManager:isWidgetShown(menu) or remote ~= self:isFollowing() then
            jam.playlist_refresh = nil
            return
        end
        if remote then
            local new_p, new_body = self:fetchFollowedPlaylist()
            if not new_p or new_body == body then return end   -- no redraw when nothing changed
            p, body = new_p, new_body
        end
        menu:switchItemTable(title, build())
    end
    UIManager:show(menu)
end

function Songbook:savePlaylistAsCollection()
    local history = self:getPlaylist().history
    if #history == 0 then
        notify(_("No songs have been played yet."))
        return
    end
    self:askCollectionName(_("Save played songs as collection"), os.date(_("Jam %Y-%m-%d")), function(name)
        local ok, err = self:createCollection(name)
        if not ok then return notify(err) end
        local collections = self:getCollections()
        local c = self:findCollection(name, collections)
        for _i, e in ipairs(history) do
            if lfs.attributes(self:songPath(e.uid), "mode") then c.songs[e.uid] = true end
        end
        self:saveCollections(collections)
        notify(T(_("Saved %1 songs to \"%2\"."), count_keys(c.songs), name))
    end)
end

function Songbook:jamSongHtml(opts)
    local uid = self:jamSong()
    if not uid then return nil end
    return (self:songHtml(uid, {
        transpose = Jam.add_semitones(self:getMap("transpose")[uid], opts.shift),
        notation = opts.notation,
        show_chords = opts.show_chords,
        max_cols = opts.max_cols,
        web = true,
    }))
end

function Songbook:isJamRunning()
    return jam.server ~= nil
end

function Songbook:jamUrl()
    local ip = jam.server and local_ip()
    return ip and string.format("http://%s:%d/", ip, jam.port)
end

function Songbook:startJam()
    if jam.server then return true end
    local port = self:get("jam_port")
    kindle_firewall("-A", port)
    local server = require("ui/message/simpletcpserver"):new{
        host = "*",
        port = port,
        receiveCallback = serve_jam,
    }
    local ok, err = server:start()
    if not ok then
        kindle_firewall("-D", port)
        UIManager:show(InfoMessage:new{
            text = T(_("Cannot start the jam session on port %1."), port) .. "\n\n" .. tostring(err),
        })
        return false
    end
    jam.server, jam.port = server, port
    jam.context = {
        state = function() return jam.owner:jamState() end,
        song_html = function(opts) return jam.owner:jamSongHtml(opts) end,
        song_cho = function()
            local uid = jam.owner:jamSong()
            return uid and read_file(jam.owner:songPath(uid))
        end,
        songs = function() return jam.owner:jamSongs() end,
        playlist = function() return jam.owner:getPlaylist() end,
        request = function(uid, by) return jam.owner:jamRequest(uid, by) end,
        song_file = function(uid) return read_file(jam.owner:songPath(uid)) end,
        name = _("Jam session"),
        labels = {
            title = _("Songbook"), waiting = _("Waiting for a song…"),
            offline = _("Connection lost"), chords = _("Chords"),
            song = _("Song"), playlist = _("Playlist"), up_next = _("Up next"), played = _("Played"),
            request = _("Request a song"), your_name = _("Your name"), search = _("Search"),
            nothing = _("Nothing yet"), requested = _("Requested: %1"),
            queued = _("This song is already requested."), full = _("Too many requests, try again later."),
            missing = _("This song is not available."),
        },
        css = Render.css(nil, true),
    }
    jam.queue = UIManager:insertZMQ(server)
    UIManager:preventStandby()
    return true
end

function Songbook:stopJam()
    if not jam.server then return end
    UIManager:removeZMQ(jam.queue)
    jam.server:stop()
    kindle_firewall("-D", jam.port)
    UIManager:allowStandby()
    jam.server, jam.queue, jam.context = nil, nil, nil
end

-- Following another songbook: poll its /state.json and open each new song
-- (saved to songs/jam/) in the host's key.
local follow_poll

function Songbook:isFollowing()
    return jam.follow ~= nil
end

function Songbook:followFailed()
    local f = jam.follow
    f.failures = f.failures + 1
    if f.failures >= FOLLOW_MAX_FAILURES then
        self:stopFollowing()
        UIManager:show(InfoMessage:new{
            text = T(_("Lost connection to the songbook at %1. Stopped following."), f.url),
        })
    end
end

function Songbook:followStep()
    local f = jam.follow
    local body = Repo.fetch(f.url .. "state.json", FOLLOW_TIMEOUT[1], FOLLOW_TIMEOUT[2])
    local state = body and Jam.parse_state(body, require("json").decode)
    if not state then return self:followFailed() end
    if not state.uid or state.rev == f.rev then
        f.failures = 0
        return
    end
    local uid = make_uid(JAM_KEY, Jam.song_id(state.uid))
    if state.uid ~= f.uid then
        -- by uid, not /song.cho: the host may have switched songs since state.json
        local cho = Repo.fetch(f.url .. Jam.song_path(state.uid), FOLLOW_TIMEOUT[1], FOLLOW_TIMEOUT[2])
        if not cho then return self:followFailed() end
        util.makePath(self.songs_dir .. "/" .. JAM_KEY)
        if not write_file(self:songPath(uid), cho) then return self:followFailed() end
    end
    -- Other changes of the host's options don't concern us.
    local same = state.uid == f.uid and state.transpose == f.transpose
    f.failures, f.rev, f.uid, f.transpose = 0, state.rev, state.uid, state.transpose
    if same then return end
    self:setMapValue("transpose", uid, state.transpose ~= 0 and state.transpose or nil)
    self:openSong(uid)
end

follow_poll = function()
    if not jam.follow then return end
    local ok, err = pcall(jam.owner.followStep, jam.owner)
    if not ok then
        logger.warn("Songbook: following failed", err)
        if jam.follow then jam.owner:followFailed() end
    end
    if jam.follow then
        if jam.playlist_refresh then pcall(jam.playlist_refresh) end
        UIManager:scheduleIn(FOLLOW_INTERVAL, follow_poll)
    end
end

function Songbook:startFollowing(url)
    self:stopFollowing()
    -- songs from an earlier session are not listed anywhere, so drop them
    -- (except the open one, which still needs its file to transpose)
    local dir = self.songs_dir .. "/" .. JAM_KEY
    if lfs.attributes(dir, "mode") == "directory" then
        local current = self:currentSongId()
        for name in lfs.dir(dir) do
            local id = song_file_id(name)
            local uid = id and make_uid(JAM_KEY, id)
            if uid and uid ~= current then self:deleteSong(uid) end
        end
    end
    jam.follow = { url = url, failures = 0 }
    UIManager:preventStandby()
    follow_poll()
end

function Songbook:stopFollowing()
    if not jam.follow then return end
    UIManager:unschedule(follow_poll)
    UIManager:allowStandby()
    jam.follow = nil
end

function Songbook:askFollowUrl(on_saved)
    local dialog
    dialog = InputDialog:new{
        title = _("Follow another songbook"),
        description = _("Address shown on the other device under Jam session."),
        input = self:get("jam_follow_url") or "",
        input_hint = "192.168.1.5:8765",
        buttons = {{
            { text = _("Cancel"), id = "close", callback = function() UIManager:close(dialog) end },
            { text = _("Follow"), is_enter_default = true, callback = function()
                local url = Jam.normalize_url(dialog:getInputText(), DEFAULTS.jam_port)
                UIManager:close(dialog)
                if url then
                    self:set("jam_follow_url", url)
                    on_saved(url)
                end
            end },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

--- Add the followed songbook as a song repository (once) and browse it.
function Songbook:browseFollowed()
    local url = jam.follow and jam.follow.url
    if not url then return end
    local server
    for _i, s in ipairs(self:getServers()) do
        if Repo.base_url(s.url) == Repo.base_url(url) then server = s end
    end
    server = server or self:addServer(url)
    NetworkMgr:runWhenConnected(function() self:showOnlineSongs({ server }) end)
end

function Songbook:onExit()
    self:stopJam()
    self:stopFollowing()
end

function Songbook:showJamQR()
    local url = self:jamUrl()
    if not url then return end
    UIManager:show(require("ui/widget/qrmessage"):new{
        text = url,
        width = Screen:getWidth(),
        height = Screen:getHeight(),
    })
end

function Songbook:jamMenu()
    return {
        {
            text = _("Share songs on the network"),
            help_text = _("Guests on the same Wi-Fi open the address in a web browser and see the song you are playing. Each guest can transpose it for themselves."),
            keep_menu_open = true,
            checked_func = function() return self:isJamRunning() end,
            callback = function(touchmenu_instance)
                if self:isJamRunning() then
                    self:stopJam()
                    touchmenu_instance:updateItems()
                    return
                end
                NetworkMgr:runWhenConnected(function()
                    if self:startJam() then
                        notify(T(_("Guests can open:\n%1"), self:jamUrl() or _("unknown address")))
                    end
                    touchmenu_instance:updateItems()
                end)
            end,
        },
        {
            text_func = function()
                if not self:isJamRunning() then return _("Address: not sharing") end
                return T(_("Address: %1"), self:jamUrl() or _("unknown"))
            end,
            help_text = _("Tap to show the address as a QR code."),
            enabled_func = function() return self:jamUrl() ~= nil end,
            keep_menu_open = true,
            callback = function() self:showJamQR() end,
        },
        {
            text_func = function() return T(_("Port: %1"), self:get("jam_port")) end,
            enabled_func = function() return not self:isJamRunning() end,
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                UIManager:show(SpinWidget:new{
                    title_text = _("Port"),
                    value = self:get("jam_port"),
                    value_min = 1024,
                    value_max = 65535,
                    default_value = DEFAULTS.jam_port,
                    callback = function(spin)
                        self:set("jam_port", spin.value)
                        touchmenu_instance:updateItems()
                    end,
                })
            end,
        },
        {
            text_func = function()
                if self:isFollowing() then return _("Playlist of the jam session") end
                local n = #self:getPlaylist().queue
                return n > 0 and T(_("Playlist (%1 requested)"), n) or _("Playlist")
            end,
            help_text = _("Songs played while sharing, and songs guests asked for on the web page. While following another songbook, its playlist."),
            keep_menu_open = true,
            callback = function() self:showPlaylist() end,
            separator = true,
        },
        {
            text_func = function()
                if not self:isFollowing() then return _("Follow another songbook…") end
                return T(_("Following %1"), (jam.follow.url:gsub("^%a+://", ""):gsub("/$", "")))
            end,
            help_text = _("Open the songs another device is playing, as they change. They are saved to My songs (Jam session) and shown in the other player's key; you can still transpose them."),
            keep_menu_open = true,
            checked_func = function() return self:isFollowing() end,
            callback = function(touchmenu_instance)
                if self:isFollowing() then
                    self:stopFollowing()
                    touchmenu_instance:updateItems()
                    return
                end
                self:askFollowUrl(function(url)
                    NetworkMgr:runWhenConnected(function()
                        self:startFollowing(url)
                        touchmenu_instance:updateItems()
                    end)
                end)
            end,
        },
        {
            text = _("Browse their songs"),
            help_text = _("Adds the followed songbook as a song repository, so you can download any of its songs."),
            enabled_func = function() return self:isFollowing() end,
            callback = function() self:browseFollowed() end,
        },
    }
end

function Songbook:setAndRefresh(key, value)
    self:set(key, value)
    self:refreshCurrent()
end

function Songbook:addToMainMenu(menu_items)
    menu_items.songbook = {
        text = _("Songbook"),
        sorting_hint = "tools",
        sub_item_table = {
            {
                text = _("Browse online"),
                keep_menu_open = true,
                callback = function() self:browseOnline() end,
            },
            {
                text = _("My songs"),
                keep_menu_open = true,
                callback = function() self:onSongbookShowLocal() end,
            },
            {
                text = _("Favorites"),
                keep_menu_open = true,
                callback = function() self:onSongbookShowFavorites() end,
            },
            {
                text = _("Collections"),
                keep_menu_open = true,
                callback = function() self:onSongbookShowCollections() end,
            },
            {
                text_func = function()
                    local id = self:currentSongId()
                    local t = id and self:getMap("transpose")[id] or 0
                    return t ~= 0 and T(_("Transpose (%1)"), string.format("%+d", t)) or _("Transpose")
                end,
                enabled_func = function() return self:currentSongId() ~= nil and self:get("show_chords") end,
                sub_item_table = {
                    { text = _("Up a semitone"), callback = function() self:onSongbookTranspose(1) end },
                    { text = _("Down a semitone"), callback = function() self:onSongbookTranspose(-1) end },
                    { text = _("Original key"), callback = function() self:onSongbookTranspose(0) end },
                },
            },
            {
                text = _("Favorite"),
                enabled_func = function() return self:currentOwnSongId() ~= nil end,
                checked_func = function()
                    local uid = self:currentOwnSongId()
                    return uid ~= nil and self:isFavorite(uid)
                end,
                callback = function()
                    local uid = self:currentOwnSongId()
                    if uid then self:setFavorite(uid, not self:isFavorite(uid)) end
                end,
            },
            {
                text = _("Add to collection…"),
                enabled_func = function() return self:currentOwnSongId() ~= nil end,
                keep_menu_open = true,
                callback = function()
                    local uid = self:currentOwnSongId()
                    if not uid then return end
                    local _key, id = split_uid(uid)
                    local meta = ChordPro.parse_meta(read_file(self:songPath(uid)) or "")
                    self:showSongCollections({ uid = uid, title = meta.title or id }, function() end)
                end,
                separator = true,
            },
            {
                text_func = function()
                    if self:isJamRunning() then return _("Jam session (sharing)") end
                    return self:isFollowing() and _("Jam session (following)") or _("Jam session")
                end,
                sub_item_table = self:jamMenu(),
            },
            {
                text = _("Settings"),
                sub_item_table = {
                    {
                        text_func = function()
                            return T(_("Song repositories (%1)"), #self:getServers())
                        end,
                        sub_item_table_func = function() return self:serversMenu() end,
                    },
                    {
                        text = _("Chord notation"),
                        sub_item_table = {
                            {
                                text = _("Czech/German (H, B = Bb)"),
                                radio = true,
                                checked_func = function() return self:get("notation") == "cz" end,
                                callback = function() self:setAndRefresh("notation", "cz") end,
                            },
                            {
                                text = _("English (B, Bb)"),
                                radio = true,
                                checked_func = function() return self:get("notation") == "en" end,
                                callback = function() self:setAndRefresh("notation", "en") end,
                            },
                        },
                    },
                    {
                        text_func = function()
                            return T(_("Line width: %1 characters"), self:get("max_cols"))
                        end,
                        keep_menu_open = true,
                        callback = function(touchmenu_instance)
                            UIManager:show(SpinWidget:new{
                                title_text = _("Line width"),
                                info_text = _("Lines with chords wrap at word boundaries above this width. Lower it if lines are cut off at the right edge."),
                                value = self:get("max_cols"),
                                value_min = 16,
                                value_max = 160,
                                default_value = DEFAULTS.max_cols,
                                callback = function(spin)
                                    self:setAndRefresh("max_cols", spin.value)
                                    if touchmenu_instance then touchmenu_instance:updateItems() end
                                end,
                            })
                        end,
                    },
                    {
                        text = _("Show chords"),
                        checked_func = function() return self:get("show_chords") end,
                        callback = function() self:setAndRefresh("show_chords", not self:get("show_chords")) end,
                    },
                    {
                        text = _("Repeat chorus text"),
                        help_text = _("Print the whole chorus where the song says {chorus}, instead of just a label."),
                        checked_func = function() return self:get("repeat_chorus") end,
                        callback = function() self:setAndRefresh("repeat_chorus", not self:get("repeat_chorus")) end,
                        separator = true,
                    },
                    {
                        text = _("Download all songs"),
                        keep_menu_open = true,
                        callback = function() self:downloadAll() end,
                    },
                    {
                        text = _("Songs folder"),
                        keep_menu_open = true,
                        callback = function()
                            UIManager:show(InfoMessage:new{
                                text = T(_("Downloaded songs are stored in:\n%1\n\nYou can also copy your own .cho files there."),
                                    self.songs_dir),
                            })
                        end,
                    },
                },
            },
        },
    }
end

return Songbook
