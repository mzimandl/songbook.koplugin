--[[--
Songbook plugin: browse a song server, download ChordPro songs, render them
locally to HTML (chords above lyrics) and open them in the reader.

@module koplugin.Songbook
]]

-- Own modules must be required at load time: PluginLoader only adds the
-- plugin folder to package.path while main.lua is being loaded.
local ChordPro = require("songbook/chordpro")
local Render = require("songbook/render")
local Repo = require("songbook/repo")

local ButtonDialog = require("ui/widget/buttondialog")
local ConfirmBox = require("ui/widget/confirmbox")
local DataStorage = require("datastorage")
local Dispatcher = require("dispatcher")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local LuaSettings = require("luasettings")
local Menu = require("ui/widget/menu")
local NetworkMgr = require("ui/network/manager")
local Screen = require("device").screen
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
}

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
    self:migrateSingleServer()
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

--- One-time upgrade from the single `server_url` setting to the `servers` list.
-- Songs downloaded from that server move from songs/ to songs/<key>/.
function Songbook:migrateSingleServer()
    local url = self.settings:readSetting("server_url")
    if url == nil then return end
    if self.settings:readSetting("servers") == nil then
        local servers = {}
        if url ~= "" then
            local key = Repo.server_key(url)
            servers[1] = { key = key, url = url }
            util.makePath(self.songs_dir .. "/" .. key)
            local downloaded, transpose = self:getMap("downloaded"), self:getMap("transpose")
            local new_downloaded = {}
            for id, version in pairs(downloaded) do
                local uid = make_uid(key, id)
                os.rename(self:songPath(id), self:songPath(uid))
                new_downloaded[uid] = version
                if transpose[id] then
                    transpose[uid], transpose[id] = transpose[id], nil
                end
                self:removeStaleRenders(id, nil)
            end
            self.settings:saveSetting("downloaded", new_downloaded)
            self.settings:saveSetting("transpose", transpose)
        end
        self.settings:saveSetting("servers", servers)
    end
    self.settings:delSetting("server_url")
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

--- Render song `uid` with current settings. Returns html path or nil, err.
function Songbook:render(uid)
    local _key, id = split_uid(uid)
    local text = read_file(self:songPath(uid))
    if not text then return nil, T(_("Song file not found: %1"), id) end

    local ok, song = pcall(ChordPro.parse, text)
    if not ok then
        logger.warn("Songbook: parse error", uid, song)
        return nil, T(_("Cannot parse song: %1"), id)
    end

    local html = Render.html(song, {
        transpose = self:getMap("transpose")[uid] or 0,
        notation = self:get("notation"),
        max_cols = self:get("max_cols"),
        show_chords = self:get("show_chords"),
        repeat_chorus = self:get("repeat_chorus"),
        fallback_title = id,
        labels = {
            key = _("Key"), capo = _("Capo"), transposed = _("Transposed"),
            chorus = _("Ref."), tempo = _("Tempo"),
        },
    })

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
-- folder (also of servers that were removed with their songs kept).
function Songbook:listLocal()
    local songs = {}
    local function add(key, dir, name)
        local id = song_file_id(name)
        if not id then return end
        local meta = ChordPro.parse_meta(read_file(dir .. "/" .. name) or "")
        local uid = make_uid(key, id)
        table.insert(songs, { uid = uid, id = id, title = meta.title or id, artist = meta.artist,
                              source = self:sourceName(uid) })
    end
    for name in lfs.dir(self.songs_dir) do
        local path = self.songs_dir .. "/" .. name
        if name:sub(1, 1) ~= "." and lfs.attributes(path, "mode") == "directory" then
            for sub in lfs.dir(path) do add(name, path, sub) end
        else
            add(nil, self.songs_dir, name)
        end
    end
    table.sort(songs, function(a, b) return lower(a.title) < lower(b.title) end)
    return songs
end

--- "Artist · Repository" for the right-hand side of list items.
local function details(...)
    local parts = {}
    for i = 1, select("#", ...) do
        local v = select(i, ...)
        if v and v ~= "" then parts[#parts + 1] = v end
    end
    return table.concat(parts, " · ")
end

local function matches(song, query)
    if not query or query == "" then return true end
    query = lower(query)
    return lower(song.title):find(query, 1, true)
        or (song.artist and lower(song.artist):find(query, 1, true))
end

--- Generic searchable song list. make_item(song) -> menu item.
function Songbook:showList(title, songs, make_item, on_hold)
    local menu
    local function build(query)
        local items = {
            {
                text = query and T(_("Search: %1"), query) or _("Search…"),
                bold = true,
                callback = function()
                    self:askSearch(query, function(q)
                        menu:switchItemTable(title, build(q ~= "" and q or nil))
                    end)
                end,
            },
        }
        for _, song in ipairs(songs) do
            if matches(song, query) then
                local item = make_item(song)
                item.song = song
                table.insert(items, item)
            end
        end
        if #items == 1 then
            table.insert(items, { text = _("No songs"), select_enabled = false })
        end
        return items
    end

    menu = Menu:new{
        title = title,
        item_table = build(nil),
        covers_fullscreen = true,
        is_borderless = true,
        is_popout = false,
        width = Screen:getWidth(),
        height = Screen:getHeight(),
        onMenuHold = function(_menu, item)
            if item.song and on_hold then on_hold(item.song, menu) end
            return true
        end,
    }
    -- The search callback must not close the list; song callbacks do.
    menu.close_callback = nil
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

function Songbook:closeList()
    if self.list_menu then
        UIManager:close(self.list_menu)
        self.list_menu = nil
    end
end

function Songbook:deleteSong(uid)
    os.remove(self:songPath(uid))
    self:setMapValue("downloaded", uid, nil)
    self:setMapValue("transpose", uid, nil)
    self:removeStaleRenders(uid, nil)
end

function Songbook:onSongbookShowLocal()
    local songs = self:listLocal()
    if #songs == 0 then
        notify(T(_("No songs yet. Download some via \"Browse online\", or copy .cho files to:\n%1"),
            self.songs_dir))
        return true
    end
    self:showList(_("My songs"), songs, function(song)
        return {
            text = song.title,
            mandatory = details(song.artist, song.source),
            callback = function()
                self:closeList()
                self:openSong(song.uid)
            end,
        }
    end, function(song, menu)
        UIManager:show(ConfirmBox:new{
            text = T(_("Delete \"%1\"?"), song.title),
            ok_text = _("Delete"),
            ok_callback = function()
                self:deleteSong(song.uid)
                UIManager:close(menu)
                self.list_menu = nil
                self:onSongbookShowLocal()
            end,
        })
    end)
    return true
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
                callback = function()
                    UIManager:close(picker)
                    self:showOnlineSongs({ server })
                end,
            })
        end
        table.insert(items, {
            text = _("All repositories"),
            bold = true,
            callback = function()
                UIManager:close(picker)
                self:showOnlineSongs(servers)
            end,
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
    self:showList(title, songs, function(song)
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
    end, function(song)
        local dialog
        dialog = ButtonDialog:new{
            title = song.title,
            buttons = {{
                { text = _("Download again"), callback = function()
                    UIManager:close(dialog)
                    local msg = busy(T(_("Downloading %1…"), song.title))
                    local ok, derr = self:download(song)
                    UIManager:close(msg)
                    notify(ok and _("Downloaded.") or T(_("Download failed: %1"), derr))
                end },
            }},
        }
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
                callback = function() self:browseOnline() end,
            },
            {
                text = _("My songs"),
                callback = function() self:onSongbookShowLocal() end,
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
                separator = true,
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
