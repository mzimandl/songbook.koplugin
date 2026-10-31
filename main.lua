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
    server_url = "",
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

-- Rendering -------------------------------------------------------------------

function Songbook:songPath(id)
    return self.songs_dir .. "/" .. id .. ".cho"
end

-- Every option combination gets its own file name, so the reader's
-- document cache never shows a stale rendering.
function Songbook:renderSignature(id)
    local t = self:getMap("transpose")[id] or 0
    return string.format("t%+d.%s.w%d.c%d.r%d", t, self:get("notation"), self:get("max_cols"),
        self:get("show_chords") and 1 or 0, self:get("repeat_chorus") and 1 or 0)
end

function Songbook:idFromRenderedPath(path)
    if not path or path:sub(1, #self.render_dir + 1) ~= self.render_dir .. "/" then return nil end
    return path:match("([^/]+)@[^/@]+%.html$")
end

function Songbook:currentSongId()
    local doc = self.ui and self.ui.document
    return doc and self:idFromRenderedPath(doc.file)
end

function Songbook:removeStaleRenders(id, keep)
    local prefix = id .. "@"
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

--- Render song `id` with current settings. Returns html path or nil, err.
function Songbook:render(id)
    local text = read_file(self:songPath(id))
    if not text then return nil, T(_("Song file not found: %1"), id) end

    local ok, song = pcall(ChordPro.parse, text)
    if not ok then
        logger.warn("Songbook: parse error", id, song)
        return nil, T(_("Cannot parse song: %1"), id)
    end

    local html = Render.html(song, {
        transpose = self:getMap("transpose")[id] or 0,
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

    local path = self.render_dir .. "/" .. id .. "@" .. self:renderSignature(id) .. ".html"
    local written, err = write_file(path, html)
    if not written then return nil, err end
    self:removeStaleRenders(id, path)
    return path
end

function Songbook:openSong(id)
    local path, err = self:render(id)
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
    local id = self:currentSongId()
    if not id then return end
    local t = 0
    if delta ~= 0 then t = (self:getMap("transpose")[id] or 0) + delta end
    if t > 11 then t = t - 12 elseif t < -11 then t = t + 12 end
    self:setMapValue("transpose", id, t ~= 0 and t or nil)
    self:openSong(id)
    return true
end

--- Re-render the currently open song after a settings change.
function Songbook:refreshCurrent()
    local id = self:currentSongId()
    if id then self:openSong(id) end
end

-- Local songs -------------------------------------------------------------------

function Songbook:listLocal()
    local songs = {}
    for name in lfs.dir(self.songs_dir) do
        local id = name:match("^(.+)%.cho$") or name:match("^(.+)%.chopro$")
        if id then
            local meta = ChordPro.parse_meta(read_file(self.songs_dir .. "/" .. name) or "")
            table.insert(songs, { id = id, title = meta.title or id, artist = meta.artist })
        end
    end
    table.sort(songs, function(a, b) return lower(a.title) < lower(b.title) end)
    return songs
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
            mandatory = song.artist,
            callback = function()
                self:closeList()
                self:openSong(song.id)
            end,
        }
    end, function(song, menu)
        UIManager:show(ConfirmBox:new{
            text = T(_("Delete \"%1\"?"), song.title),
            ok_text = _("Delete"),
            ok_callback = function()
                os.remove(self:songPath(song.id))
                self:setMapValue("downloaded", song.id, nil)
                self:setMapValue("transpose", song.id, nil)
                self:removeStaleRenders(song.id, nil)
                UIManager:close(menu)
                self.list_menu = nil
                self:onSongbookShowLocal()
            end,
        })
    end)
    return true
end

-- Online -------------------------------------------------------------------

function Songbook:serverBase()
    return Repo.base_url(self:get("server_url"))
end

function Songbook:fetchIndex()
    local base = self:serverBase()
    local msg = busy(_("Loading song list…"))
    local body, err = Repo.fetch(Repo.join(base, "index.json"))
    UIManager:close(msg)
    if not body then return nil, T(_("Cannot load song list: %1"), err) end
    local songs, perr = Repo.parse_index(body, require("json").decode)
    if not songs then return nil, perr end
    table.sort(songs, function(a, b) return lower(a.title) < lower(b.title) end)
    return songs
end

function Songbook:isUpToDate(song)
    if lfs.attributes(self:songPath(song.id), "mode") ~= "file" then return false end
    local have = self:getMap("downloaded")[song.id]
    return song.updated == nil or have == song.updated
end

function Songbook:download(song)
    local body, err = Repo.fetch(Repo.join(self:serverBase(), song.file))
    if not body then return nil, err end
    local ok, werr = write_file(self:songPath(song.id), body)
    if not ok then return nil, werr end
    self:setMapValue("downloaded", song.id, song.updated or true)
    return true
end

function Songbook:withServer(cb)
    if self:get("server_url") == "" then
        self:askServerUrl(function() self:withServer(cb) end)
        return
    end
    NetworkMgr:runWhenOnline(cb)
end

function Songbook:browseOnline()
    self:withServer(function()
        local songs, err = self:fetchIndex()
        if not songs then
            notify(err)
            return
        end
        local function status(song)
            if lfs.attributes(self:songPath(song.id), "mode") ~= "file" then return "" end
            return self:isUpToDate(song) and _("saved") or _("update")
        end
        self:showList(_("Online songs"), songs, function(song)
            local right = status(song)
            if song.artist then right = song.artist .. (right ~= "" and "  " .. right or "") end
            return {
                text = song.title,
                mandatory = right,
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
                    self:openSong(song.id)
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
    end)
end

function Songbook:downloadAll()
    self:withServer(function()
        local songs, err = self:fetchIndex()
        if not songs then
            notify(err)
            return
        end
        local done, failed, skipped = 0, 0, 0
        for i, song in ipairs(songs) do
            if self:isUpToDate(song) then
                skipped = skipped + 1
            else
                local msg = busy(T(_("Downloading %1 / %2…"), i, #songs))
                local ok = self:download(song)
                UIManager:close(msg)
                if ok then done = done + 1 else failed = failed + 1 end
            end
        end
        notify(T(_("Downloaded: %1\nUp to date: %2\nFailed: %3"), done, skipped, failed))
    end)
end

-- Settings -------------------------------------------------------------------

function Songbook:askServerUrl(on_saved)
    local dialog
    dialog = InputDialog:new{
        title = _("Song server URL"),
        description = _("GitHub repository address, or any web folder containing index.json."),
        input = self:get("server_url"),
        input_hint = "https://github.com/user/songs",
        buttons = {{
            { text = _("Cancel"), id = "close", callback = function() UIManager:close(dialog) end },
            { text = _("Save"), is_enter_default = true, callback = function()
                local url = util.trim(dialog:getInputText())
                UIManager:close(dialog)
                self:set("server_url", url)
                if url ~= "" and on_saved then on_saved() end
            end },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
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
                            local url = self:get("server_url")
                            return T(_("Server: %1"), url ~= "" and url or _("not set"))
                        end,
                        keep_menu_open = true,
                        callback = function() self:askServerUrl() end,
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
