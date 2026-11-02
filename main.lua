--[[--
Songbook plugin: browse a song server, download ChordPro songs, render them
locally to HTML (chords above lyrics) and open them in the reader.

@module koplugin.Songbook
]]

-- Own modules must be required at load time: PluginLoader only adds the
-- plugin folder to package.path while main.lua is being loaded.
local ChordPro = require("songbook/chordpro")
local Jam = require("songbook/jam")
local L10n = require("songbook/l10n")
local Render = require("songbook/render")
local Repo = require("songbook/repo")
local Transpose = require("songbook/transpose")

local ButtonDialog = require("ui/widget/buttondialog")
local ConfirmBox = require("ui/widget/confirmbox")
local DataStorage = require("datastorage")
local DoubleSpinWidget = require("ui/widget/doublespinwidget")
local Device = require("device")
local Dispatcher = require("dispatcher")
local Event = require("ui/event")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local LuaSettings = require("luasettings")
local Menu = require("ui/widget/menu")
local NetworkMgr = require("ui/network/manager")
local Notification = require("ui/widget/notification")
local Screen = Device.screen
local SpinWidget = require("ui/widget/spinwidget")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local time = require("ui/time")
local util = require("util")
local gettext = require("gettext")
-- The plugin's strings are not in KOReader's catalog: its own catalog for
-- KOReader's language first (songbook/l10n/<lang>.lua, required now, see above).
local _ = L10n.wrap(gettext, L10n.catalog(gettext.current_lang, function(name)
    local ok, catalog = pcall(require, "songbook/l10n/" .. name)
    return ok and catalog or nil
end))
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
    playlist_hide_added = true,
    autoscroll = false,
    autoscroll_step = 8,   -- scroll mode moves 1/8 of the screen
    scroll_mode = true,
    song_button = true,
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
    if jam.follow and split_uid(uid) ~= JAM_KEY then
        self:stopFollowing()
        notify(_("Stopped following the jam session."))
    end
    -- while following, the followed songbook's playlist is used
    if not jam.follow then self:playlistPlayed(uid) end
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

--- Transposition wrapped to -11..11.
local function wrap_shift(t)
    if t > 11 then return t - 12 elseif t < -11 then return t + 12 end
    return t
end

function Songbook:onSongbookTranspose(delta)
    local uid = self:currentSongId()
    if not uid then return end
    local t = 0
    if delta ~= 0 then t = wrap_shift((self:getMap("transpose")[uid] or 0) + delta) end
    self:setMapValue("transpose", uid, t ~= 0 and t or nil)
    self:openSong(uid)
    return true
end

--- Transposition dialog of the current song: ±1 semitone, original key and
-- the keys to choose from (from {key}, else its first chord). The steps only
-- change the key shown in the dialog; Apply re-renders the song. With chords
-- hidden it offers to show them instead.
function Songbook:showKeyDialog()
    local uid = self:currentSongId()
    if not uid then return end
    if not self:get("show_chords") then
        UIManager:show(ConfirmBox:new{
            text = _("Chords are hidden. Show them?"),
            ok_text = _("Show chords"),
            ok_callback = function() self:setAndRefresh("show_chords", true) end,
        })
        return true
    end
    local text = read_file(self:songPath(uid)) or ""
    local choices = Transpose.key_choices(ChordPro.parse_meta(text).key or ChordPro.first_chord(text),
        self:get("notation"))
    local saved = self:getMap("transpose")[uid] or 0
    local dialog
    local function show(t)
        local current = t
        if current > 6 then current = current - 12 elseif current < -5 then current = current + 12 end
        local function step(new_t)
            return function()
                UIManager:close(dialog)
                show(wrap_shift(new_t))
            end
        end
        local buttons = {{
            { text = "−1", callback = step(t - 1) },
            { text = _("Original key"), enabled = t ~= 0, callback = step(0) },
            { text = "+1", callback = step(t + 1) },
        }}
        local key
        local row = {}
        for _i, c in ipairs(choices or {}) do
            if c.shift == current then key = c.name end
            table.insert(row, { text = c.name, font_bold = c.shift == current, callback = step(c.shift) })
            if #row == 4 then table.insert(buttons, row); row = {} end
        end
        if #row > 0 then table.insert(buttons, row) end
        table.insert(buttons, {
            { text = _("Cancel"), callback = function() UIManager:close(dialog) end },
            { text = _("Apply"), enabled = t ~= saved, callback = function()
                UIManager:close(dialog)
                self:setMapValue("transpose", uid, t ~= 0 and t or nil)
                self:openSong(uid)
            end },
        })
        local shift = t ~= 0 and string.format("%+d", t) or _("original key")
        dialog = ButtonDialog:new{
            title = key and T(_("Key: %1 (%2)"), key, shift) or T(_("Transpose: %1"), shift),
            buttons = buttons,
        }
        UIManager:show(dialog)
    end
    show(saved)
    return true
end

Songbook.onSongbookShowKeyDialog = Songbook.showKeyDialog

--- Re-render the currently open song after a settings change.
function Songbook:refreshCurrent()
    local uid = self:currentSongId()
    if uid then self:openSong(uid) end
end

-- Autoscroll ------------------------------------------------------------------
--
-- The song's length is spread evenly over the document height, which gives
-- the line being played. Once it gets `trigger` screens below the top of the
-- view, the view moves by `step` screens (1/`autoscroll_step` of the screen
-- in scroll mode, keeping AUTOSCROLL_PLAYED screens of played lines visible;
-- a whole page in page mode). A manual move re-anchors the timing at the new
-- position.

local AUTOSCROLL_PAGE = { step = 1, trigger = 0.9, page = true }
local AUTOSCROLL_PLAYED = 0.25
local AUTOSCROLL_MIN_WAIT = 0.5   -- seconds

local function now()
    return time.to_s(time.now())
end

--- Length of song `uid` in seconds: set on the device, else {duration} in the file.
function Songbook:songDuration(uid)
    local own = self:getMap("duration")[uid]
    if own then return own end
    local meta = ChordPro.parse_meta(read_file(self:songPath(uid)) or "")
    return ChordPro.duration(meta.duration)
end

function Songbook:isAutoscrolling()
    return self.autoscroll ~= nil
end

--- pos, document height, screen height and mode of the open song.
function Songbook:autoscrollView()
    local doc = self.ui.document
    local mode = AUTOSCROLL_PAGE
    if self.ui.view.view_mode ~= "page" then
        local step = 1 / self:get("autoscroll_step")
        mode = { step = step, trigger = AUTOSCROLL_PLAYED + step }
    end
    return doc:getCurrentPos(), doc.info.doc_height, self.ui.dimen.h, mode
end

--- Set the start time so that the played line matches the view: the top of
-- the song at its start, else where a step would have left it.
function Songbook:anchorAutoscroll()
    local a = self.autoscroll
    local pos, height, h, mode = self:autoscrollView()
    local played = pos > 0 and pos + (mode.trigger - mode.step) * h or 0
    a.start = now() - math.max(played, 0) / height * a.duration
end

function Songbook:scheduleAutoscroll()
    local a = self.autoscroll
    local pos, height, h, mode = self:autoscrollView()
    local due = (pos + mode.trigger * h) / height * a.duration
    UIManager:unschedule(a.task)
    UIManager:scheduleIn(math.max(due - (now() - a.start), AUTOSCROLL_MIN_WAIT), a.task)
end

function Songbook:autoscrollStep()
    local a = self.autoscroll
    if not a then return end
    local doc = self.ui.document
    local pos, height, h, mode = self:autoscrollView()
    local at_end
    if mode.page then
        at_end = doc:getCurrentPage() >= doc:getPageCount()
    else
        at_end = pos + h >= height
    end
    if at_end then
        self:stopAutoscroll()
        return
    end
    local played = (now() - a.start) / a.duration * height
    if played >= pos + mode.trigger * h then
        a.moving = true
        self.ui:handleEvent(Event:new("GotoViewRel", mode.step))
        a.moving = false
    end
    self:scheduleAutoscroll()
end

function Songbook:startAutoscroll(quiet)
    local uid = self:currentSongId()
    if not uid or self.autoscroll then return end
    local duration = self:songDuration(uid)
    if not duration then
        if not quiet then notify(_("This song has no length. Set it with Song length in the song's options.")) end
        return
    end
    self.autoscroll = { uid = uid, duration = duration }
    self.autoscroll.task = function() self:autoscrollStep() end
    self:anchorAutoscroll()
    UIManager:preventStandby()
    self:scheduleAutoscroll()
    Notification:notify(T(_("Autoscroll: %1"), ChordPro.format_duration(duration)))
end

function Songbook:stopAutoscroll()
    local a = self.autoscroll
    if not a then return end
    self.autoscroll = nil
    UIManager:unschedule(a.task)
    UIManager:allowStandby()
end

function Songbook:onSongbookAutoscroll()
    if self.autoscroll then
        self:stopAutoscroll()
        Notification:notify(_("Autoscroll stopped"))
    else
        self:startAutoscroll()
    end
    return true
end

--- Make the running autoscroll faster (factor < 1) or slower; the new length
-- is kept for the song (not for songs received while following).
function Songbook:onSongbookAutoscrollSpeed(factor)
    local a = self.autoscroll
    if not a then return true end
    a.duration = math.max(30, math.floor(a.duration * factor / 5 + 0.5) * 5)
    self:anchorAutoscroll()
    self:scheduleAutoscroll()
    if a.uid == self:currentOwnSongId() then self:setMapValue("duration", a.uid, a.duration) end
    Notification:notify(T(_("Autoscroll: %1"), ChordPro.format_duration(a.duration)))
    return true
end

function Songbook:showDurationDialog(touchmenu_instance)
    local uid = self:currentOwnSongId()
    if not uid then return end
    local function save(secs)
        self:setMapValue("duration", uid, secs)
        local a = self.autoscroll
        if a then
            a.duration = self:songDuration(uid) or a.duration
            self:anchorAutoscroll()
            self:scheduleAutoscroll()
        end
        if touchmenu_instance then touchmenu_instance:updateItems() end
    end
    local duration = self:songDuration(uid) or 180
    local meta = ChordPro.parse_meta(read_file(self:songPath(uid)) or "")
    local file_duration = ChordPro.duration(meta.duration)
    UIManager:show(DoubleSpinWidget:new{
        title_text = _("Song length"),
        info_text = file_duration and T(_("In the song file: %1"), ChordPro.format_duration(file_duration))
            or _("The song file has no {duration}."),
        left_text = _("Minutes"),
        left_min = 0, left_max = 59,
        left_value = math.floor(duration / 60),
        right_text = _("Seconds"),
        right_min = 0, right_max = 59,
        right_value = duration % 60,
        ok_always_enabled = true,
        extra_text = _("Use the song file"),
        extra_callback = function() save(nil) end,
        callback = function(min, sec)
            local secs = min * 60 + sec
            save(secs > 0 and secs or nil)
        end,
    })
end

function Songbook:onReaderReady()
    local uid = self:currentSongId()
    if not uid then return end
    if self:get("song_button") then self:addSongButton() end
    self:showScrollProgress()
    if self:get("autoscroll") then self:startAutoscroll(true) end
end

-- Corner of the screen the song button's tap zone covers; taps there that
-- miss the button go on to the reader (page turns, corner gestures).
local SONG_BUTTON_ZONE = { ratio_x = 0.75, ratio_y = 0.75, ratio_w = 0.25, ratio_h = 0.25 }

--- Button in the bottom right corner of an open song, above the footer: a
-- tap opens showSongDialog(). Drawn as a view module, so on every repaint.
function Songbook:addSongButton()
    local Blitbuffer = require("ffi/blitbuffer")
    local FrameContainer = require("ui/widget/container/framecontainer")
    local Geom = require("ui/geometry")
    local IconWidget = require("ui/widget/iconwidget")
    local Size = require("ui/size")
    local Screen = Device.screen
    local size = math.ceil(math.min(Screen:getWidth(), Screen:getHeight()) / 16)
    local frame = FrameContainer:new{
        bordersize = Size.border.button,
        radius = Size.radius.button,
        padding = Size.padding.small,
        background = Blitbuffer.COLOR_WHITE,
        IconWidget:new{ icon = "appbar.menu", width = size, height = size },
    }
    local view = self.ui.view
    local button = {}
    function button:paintTo(bb, x, y)
        local frame_size = frame:getSize()
        local footer_h = view.footer_visible and view.footer:getHeight() or 0
        local margin = Size.margin.default * 2
        self.rect = Geom:new{
            x = x + Screen:getWidth() - frame_size.w - margin,
            y = y + Screen:getHeight() - footer_h - frame_size.h - margin,
            w = frame_size.w,
            h = frame_size.h,
        }
        frame:paintTo(bb, self.rect.x, self.rect.y)
    end
    view:registerViewModule("songbook_button", button)
    self.ui:registerTouchZones({{
        id = "songbook_button",
        ges = "tap",
        screen_zone = SONG_BUTTON_ZONE,
        overrides = { "tap_link", "readerhighlight_tap", "readerfooter_tap", "readerconfigmenu_ext_tap",
            "readerconfigmenu_tap", "tap_forward", "tap_backward", "tap_right_bottom_corner" },
        handler = function(ges)
            if not (button.rect and ges.pos:intersectWith(button.rect)) then return end
            self:showSongDialog()
            return true
        end,
    }})
end

--- The footer's progress is page / page count, which hardly moves for a song
-- of a few pages in scroll mode: there it shows the scrolled part instead.
function Songbook:showScrollProgress()
    local footer = self.ui.view.footer
    local page_progress = footer.getBookProgress
    footer.getBookProgress = function(this)
        local doc = self.ui.document
        if self.ui.view.view_mode == "page" or doc:hasHiddenFlows() then return page_progress(this) end
        local scrollable = doc.info.doc_height - self.ui.dimen.h
        if scrollable <= 0 then return 1 end
        return math.min(math.max(doc:getCurrentPos() / scrollable, 0), 1)
    end
end

-- A move the autoscroll didn't make (page turn, pan, re-rendering).
function Songbook:onPosUpdate()
    local a = self.autoscroll
    if a and not a.moving then
        self:anchorAutoscroll()
        self:scheduleAutoscroll()
    end
end
Songbook.onPageUpdate = Songbook.onPosUpdate

function Songbook:onCloseDocument()
    self:stopAutoscroll()
end
Songbook.onSuspend = Songbook.onCloseDocument

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

--- Dialog with one button per action: { text, callback, enabled }.
-- The dialog closes before the callback runs.
local function show_actions(title, actions)
    local dialog
    local buttons = {}
    for _i, a in ipairs(actions) do
        table.insert(buttons, {{
            text = a.text,
            enabled = a.enabled ~= false,
            callback = function()
                UIManager:close(dialog)
                a.callback()
            end,
        }})
    end
    dialog = ButtonDialog:new{ title = title, buttons = buttons }
    UIManager:show(dialog)
    return dialog
end

--- Full-screen Menu; with `actions` (function -> list for show_actions) the
-- title bar gets a menu button with them.
local function list_menu(title, item_table, actions, fields)
    local menu = Menu:new{
        title = title,
        item_table = item_table,
        covers_fullscreen = true,
        is_borderless = true,
        is_popout = false,
        width = Screen:getWidth(),
        height = Screen:getHeight(),
        title_bar_left_icon = actions and "appbar.menu" or nil,
        onLeftButtonTap = actions and function() show_actions(title, actions()) end or nil,
    }
    for k, v in pairs(fields or {}) do menu[k] = v end
    return menu
end

-- The song list opened last, to open it again with the gesture "last song
-- list": { kind = "local" | "favorites" | "collection" | "online" | "playlist",
-- arg, query, page }. Module-level like `jam`: the song opens in a new
-- plugin instance.
local last_list
-- Set while the last list is being opened again: its query and page.
local restoring

--- Generic searchable song list.
-- get_songs() -> songs; make_item(song, refresh) -> menu item.
-- on_hold(song, refresh): refresh() rebuilds the list (keeping the search).
-- on_close(): called when the list is closed with × (not when a song is opened).
-- actions(refresh): optional, -> actions of the title bar menu (see show_actions).
-- opts: optional { last = last_list entry to keep the search and page in,
--   empty = { text, action = { text, callback(refresh) } } shown when there are no songs }.
function Songbook:showList(title, get_songs, make_item, on_hold, on_close, actions, opts)
    opts = opts or {}
    local last = opts.last
    local menu, refresh
    local query = restoring and restoring.query
    local function build()
        local items = {
            {
                text = query and T(_("Search: %1"), query) or _("Search…"),
                bold = true,
                callback = function()
                    self:askSearch(query, function(q)
                        query = q ~= "" and q or nil
                        if last then last.query = query end
                        menu:switchItemTable(title, build())
                    end)
                end,
            },
        }
        local first = #items
        local favorites = self:getMap("favorites")
        for _i, song in ipairs(get_songs()) do
            if matches(song, query) then
                local item = make_item(song, refresh)
                item.song = song
                if favorites[song.uid] then item.text = "★ " .. item.text end
                table.insert(items, item)
            end
        end
        if #items == first then
            local empty = not query and opts.empty
            table.insert(items, { text = empty and empty.text or _("No songs"), dim = true, select_enabled = false })
            if empty and empty.action then
                table.insert(items, { text = empty.action.text, bold = true,
                    callback = function() empty.action.callback(refresh) end })
            end
        end
        return items
    end
    refresh = function()
        menu:switchItemTable(title, build())
    end

    menu = list_menu(title, build(), actions and function() return actions(refresh) end, {
        onMenuHold = function(_menu, item)
            if item.song and on_hold then on_hold(item.song, refresh) end
            return true
        end,
    })
    menu.last = last
    if last then
        last.query = query
        last_list = last
    end
    if restoring and restoring.page and menu.onGotoPage then menu:onGotoPage(restoring.page) end
    restoring = nil
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
    self:trackList(menu)
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

-- Lists are opened with the Songbook menu kept open (and one list over
-- another, e.g. a collection over the collections), so closing a list with ×
-- goes back. Opening a song closes them all.
function Songbook:trackList(menu)
    self.lists = self.lists or {}
    table.insert(self.lists, menu)
end

function Songbook:closeList()
    for _i, menu in ipairs(self.lists or {}) do
        if menu.last then menu.last.page = menu.page end
        if UIManager:isWidgetShown(menu) then UIManager:close(menu) end
    end
    self.lists = nil
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
    self:setMapValue("duration", uid, nil)
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
    menu = list_menu(_("Collections"), build(), nil, {
        onMenuHold = function(_menu, item)
            if not item.collection then return true end
            local name = item.collection
            show_actions(name, {
                { text = _("Rename"), callback = function()
                    self:askCollectionName(_("Rename collection"), name, function(new)
                        local ok, err = self:renameCollection(name, new)
                        if not ok then notify(err) return end
                        menu:switchItemTable(nil, build())
                    end)
                end },
                { text = _("Delete"), callback = function()
                    UIManager:show(ConfirmBox:new{
                        text = T(_("Delete collection \"%1\"?\nThe songs stay on the device."), name),
                        ok_text = _("Delete"),
                        ok_callback = function()
                            self:deleteCollection(name)
                            menu:switchItemTable(nil, build())
                        end,
                    })
                end },
            })
            return true
        end,
    })
    self:trackList(menu)
    UIManager:show(menu)
    return true
end

function Songbook:showCollection(name, on_close)
    return self:showLocal(name, function(song) return self:isInCollection(name, song.uid) end, {
        text = _("This collection is empty"),
        help = _("Long-press a song in a list and choose \"Collections…\", or use the song button while a song is open."),
        action = { text = _("Add songs…"), callback = function(refresh) self:showCollectionPicker(name, refresh) end },
    }, on_close, { kind = "collection", arg = name }, name)
end

--- Songs on the device to put into collection `name`: a tap adds or removes
-- a song. on_close(): called when the picker is closed.
function Songbook:showCollectionPicker(name, on_close)
    self:showList(T(_("Add to \"%1\""), name), function() return self:listLocal() end, function(song, refresh)
        local on = self:isInCollection(name, song.uid)
        return {
            text = song.title,
            mandatory = details(song.artist, song.source, on and "✓" or nil),
            callback = function()
                self:setInCollection(name, song.uid, not on)
                refresh()
            end,
        }
    end, nil, on_close)
end

-- Song lists on the device -----------------------------------------------------

--- List of songs on the device. filter(song) limits the list (nil = all).
-- empty = { text, help, action } for an empty list: `text` is shown in it,
-- `help` once as a message, `action` (see showList()) below the text.
-- on_close as in showList(); last: see last_list; collection: name of the
-- collection the list shows (its songs can be removed from it).
function Songbook:showLocal(title, filter, empty, on_close, last, collection)
    local function load()
        local songs = self:listLocal()
        if not filter then return songs end
        local out = {}
        for _i, song in ipairs(songs) do
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
    if #first == 0 and empty.help then notify(empty.help) end
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
            { self:playlistButton(song, close) },
            { self:favoriteButton(song, close, refresh) },
            { self:collectionsButton(song, close, refresh) },
        }
        if collection then
            table.insert(buttons, {{ text = T(_("Remove from \"%1\""), collection), callback = function()
                close()
                self:setInCollection(collection, song.uid, false)
                refresh()
            end }})
        end
        table.insert(buttons, {{ text = _("Delete from device"), callback = function()
            close()
            UIManager:show(ConfirmBox:new{
                text = T(_("Delete \"%1\"?"), song.title),
                ok_text = _("Delete"),
                ok_callback = function()
                    self:deleteSong(song.uid)
                    refresh()
                end,
            })
        end }})
        dialog = ButtonDialog:new{ title = song.title, buttons = buttons }
        UIManager:show(dialog)
    end, on_close, collection and function(refresh)
        return {{ text = _("Add songs…"), callback = function() self:showCollectionPicker(collection, refresh) end }}
    end, { last = last, empty = empty })
    return true
end

function Songbook:onSongbookShowLocal()
    return self:showLocal(_("My songs"), nil, {
        text = _("No songs yet"),
        help = T(_("No songs yet. Download some via \"Browse online\", or copy .cho files to:\n%1"), self.songs_dir),
        action = { text = _("Browse online"), callback = function() self:browseOnline() end },
    }, nil, { kind = "local" })
end

function Songbook:onSongbookShowFavorites()
    return self:showLocal(_("Favorites"), function(song) return self:isFavorite(song.uid) end, {
        text = _("No favorites yet"),
        help = _("No favorites yet. Long-press a song in a list to add it, or use the song button while a song is open."),
        action = { text = _("My songs"), callback = function() self:onSongbookShowLocal() end },
    }, nil, { kind = "favorites" })
end

--- Open the song list opened last again, with its search and page.
function Songbook:onSongbookLastList()
    local last = last_list
    if not last then return self:onSongbookShowLocal() end
    restoring = last
    if last.kind == "favorites" then
        self:onSongbookShowFavorites()
    elseif last.kind == "collection" and self:findCollection(last.arg) then
        self:showCollection(last.arg)
    elseif last.kind == "online" then
        local servers = {}
        for _i, key in ipairs(last.arg) do
            local server = self:findServer(key)
            if server then table.insert(servers, server) end
        end
        if #servers > 0 then
            -- runWhenOnline() may wait for Wi-Fi, so restore the list in its callback
            NetworkMgr:runWhenOnline(function()
                restoring = last
                self:showOnlineSongs(servers)
                restoring = nil
            end)
        else
            restoring = nil
            self:browseOnline()
        end
    elseif last.kind == "playlist" then
        restoring = nil
        self:onSongbookShowPlaylist()
    else
        self:onSongbookShowLocal()
    end
    restoring = nil
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
        local items = {{
            text = _("All repositories"),
            bold = true,
            callback = function() self:showOnlineSongs(servers) end,
        }}
        for _i, server in ipairs(servers) do
            table.insert(items, {
                text = self:serverName(server),
                callback = function() self:showOnlineSongs({ server }) end,
            })
        end
        picker = list_menu(_("Song repositories"), items, function()
            return {{ text = _("Manage repositories…"), callback = function()
                -- the picker would show the old list
                UIManager:close(picker)
                self:showRepositories()
            end }}
        end)
        self:trackList(picker)
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
    local function actions(refresh)
        local n = 0
        for _i, song in ipairs(songs) do
            if not self:isUpToDate(song) then n = n + 1 end
        end
        return {
            {
                text = n > 0 and T(_("Download all (%1)"), n) or _("All songs downloaded"),
                enabled = n > 0,
                callback = function()
                    self:downloadSongs(songs)
                    refresh()
                end,
            },
            { text = _("Manage repositories…"), callback = function() self:showRepositories() end },
        }
    end
    local keys = {}
    for _i, server in ipairs(servers) do table.insert(keys, server.key) end
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
            { self:playlistButton(song, close, ensure_downloaded) },
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
        dialog = ButtonDialog:new{ title = song.title, buttons = buttons }
        UIManager:show(dialog)
    end, nil, actions, { last = { kind = "online", arg = keys } })
end

--- Download the songs of `songs` that aren't up to date and report how it went.
function Songbook:downloadSongs(songs)
    local missing = {}
    for _i, song in ipairs(songs) do
        if not self:isUpToDate(song) then table.insert(missing, song) end
    end
    local done, failed = 0, 0
    for i, song in ipairs(missing) do
        local msg = busy(T(_("Downloading %1 / %2…"), i, #missing))
        local ok = self:download(song)
        UIManager:close(msg)
        if ok then done = done + 1 else failed = failed + 1 end
    end
    notify(T(_("Downloaded: %1, up to date: %2, failed: %3"), done, #songs - #missing, failed))
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

--- List of the song repositories: tap one to edit or remove it.
function Songbook:showRepositories()
    local menu
    local function build()
        local items = {}
        for _i, server in ipairs(self:getServers()) do
            table.insert(items, {
                text = self:serverName(server),
                callback = function()
                    self:showServerActions(server, function() menu:switchItemTable(nil, build()) end)
                end,
            })
        end
        table.insert(items, {
            text = _("Add repository…"),
            bold = true,
            callback = function()
                self:askServerUrl(_("Add song repository"), "", function(url)
                    self:addServer(url)
                    menu:switchItemTable(nil, build())
                end)
            end,
        })
        return items
    end
    menu = list_menu(_("Song repositories"), build())
    self:trackList(menu)
    UIManager:show(menu)
    return true
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

-- Playlist -------------------------------------------------------------------
--
-- Up next (queue) and played songs (history), kept in the settings until
-- cleared: { history = { entry... }, queue = { entry... } }, entry =
-- { uid, title, artist, by, at }. Every song opened is recorded as played.
-- While sharing, guests see it and add requests; while following, the
-- followed songbook's playlist is used instead (our own is cleared).

function Songbook:getPlaylist()
    local p = self.settings:readSetting("playlist") or {}
    p.history, p.queue = p.history or {}, p.queue or {}
    return p
end

function Songbook:savePlaylist(p)
    self:set("playlist", p)
    if jam.playlist_refresh then jam.playlist_refresh() end
end

function Songbook:playlistEntry(uid, by)
    local text = read_file(self:songPath(uid))
    if not text then return nil end
    local _key, id = split_uid(uid)
    local meta = ChordPro.parse_meta(text)
    return { uid = uid, title = meta.title or id, artist = meta.artist, by = by, at = os.time() }
end

function Songbook:playlistPlayed(uid)
    if split_uid(uid) == JAM_KEY then return end
    local entry = self:playlistEntry(uid)
    if not entry then return end
    local p = self:getPlaylist()
    if Jam.played(p.history, p.queue, entry) then self:savePlaylist(p) end
end

function Songbook:isQueued(uid)
    for _i, e in ipairs(self:getPlaylist().queue) do
        if e.uid == uid then return true end
    end
    return false
end

--- Add a song to Up next; `max` limits the queue (guests' requests).
-- Returns the entry, or nil and "queued" / "full" / "missing".
function Songbook:addToPlaylist(uid, by, max)
    if split_uid(uid) == JAM_KEY then return nil, "missing" end   -- not listed, so not requestable
    local entry = self:playlistEntry(uid, by)
    if not entry then return nil, "missing" end
    local p = self:getPlaylist()
    local ok, err = Jam.add_request(p.queue, entry, max or math.huge)
    if not ok then return nil, err end
    self:savePlaylist(p)
    return entry
end

function Songbook:removeFromPlaylist(uid)
    local p = self:getPlaylist()
    for i = #p.queue, 1, -1 do
        if p.queue[i].uid == uid then table.remove(p.queue, i) end
    end
    self:savePlaylist(p)
end

--- Move a queued song to the top of Up next.
function Songbook:playNextInPlaylist(uid)
    local p = self:getPlaylist()
    for i, e in ipairs(p.queue) do
        if e.uid == uid then
            table.remove(p.queue, i)
            table.insert(p.queue, 1, e)
            break
        end
    end
    self:savePlaylist(p)
end

--- Request from a jam session guest.
function Songbook:jamRequest(uid, by)
    local entry, err = self:addToPlaylist(uid, by, Jam.MAX_QUEUE)
    if not entry then return nil, err end
    notify(by and T(_("Song request: %1 (%2)"), entry.title, by) or T(_("Song request: %1"), entry.title))
    return true
end

local function request_error(code)
    if code == "queued" then return _("This song is already requested.") end
    if code == "full" then return _("Too many requests, try again later.") end
    return _("This song is not available.")
end

--- First song of Up next that is on the device, or nil (also while following:
-- the followed songbook chooses the songs then).
function Songbook:nextInPlaylist()
    if self:isFollowing() then return nil end
    for _i, e in ipairs(self:getPlaylist().queue) do
        if lfs.attributes(self:songPath(e.uid), "mode") == "file" then return e end
    end
end

function Songbook:onSongbookNextSong()
    local e = self:nextInPlaylist()
    if e then
        self:openSong(e.uid)
    elseif self:isFollowing() then
        notify(_("While following, the other songbook chooses the songs."))
    else
        notify(_("There is no next song in the playlist."))
    end
    return true
end

--- "Add to playlist" / "Remove from playlist" for a song's long-press dialog;
-- while following, "Request to play" asks the followed songbook.
-- `before` as in favoriteButton().
function Songbook:playlistButton(song, close, before)
    if self:isFollowing() then
        return {
            text = _("Request to play"),
            callback = function()
                close()
                self:requestFromFollowed(song)
            end,
        }
    end
    local queued = self:isQueued(song.uid)
    return {
        text = queued and _("Remove from playlist") or _("Add to playlist"),
        callback = function()
            close()
            if queued then
                self:removeFromPlaylist(song.uid)
                return notify(T(_("Removed from playlist: %1"), song.title))
            end
            if before and not before() then return end
            local entry, err = self:addToPlaylist(song.uid)
            notify(entry and T(_("Added to playlist: %1"), entry.title) or request_error(err))
        end,
    }
end

--- Ask the followed songbook to queue its song with index id `remote_id`.
-- Returns true, or nil and an error message.
function Songbook:requestFollowed(remote_id)
    local body = Repo.fetch(jam.follow.url .. "queue/add?id=" .. remote_id, FOLLOW_TIMEOUT[1], FOLLOW_TIMEOUT[2])
    local ok, data = pcall(require("json").decode, body or "")
    if not body or not ok or type(data) ~= "table" then
        return nil, _("Cannot reach the other songbook.")
    end
    if not data.ok then return nil, request_error(data.error) end
    return true
end

--- Ask the followed songbook to play `song`. Songs received from it or
-- downloaded from it as a repository use its own ids; other songs are matched
-- by uid, which works when both have them from the same repository.
function Songbook:requestFromFollowed(song)
    local f = jam.follow
    local key, id = split_uid(song.uid)
    local server = key and self:findServer(key)
    local same_source = key == JAM_KEY or (server and Repo.base_url(server.url) == Repo.base_url(f.url))
    local ok, err = self:requestFollowed(same_source and id or Jam.song_id(song.uid))
    notify(ok and T(_("Requested: %1"), song.title) or err)
end

--- Playlist of the followed songbook: p, raw body (nil, nil when unreachable).
function Songbook:fetchFollowedPlaylist()
    local body = Repo.fetch(jam.follow.url .. "playlist.json", FOLLOW_TIMEOUT[1], FOLLOW_TIMEOUT[2])
    local p = body and Jam.parse_playlist(body, require("json").decode)
    if p then return p, body end
end

--- Songs of the followed songbook (its /index.json; ids as it knows them), or nil.
function Songbook:fetchFollowedSongs()
    local body = Repo.fetch(jam.follow.url .. "index.json", FOLLOW_TIMEOUT[1], FOLLOW_TIMEOUT[2])
    local songs = body and Repo.parse_index(body, require("json").decode)
    if not songs then return nil end
    table.sort(songs, function(a, b) return lower(a.title) < lower(b.title) end)
    return songs
end

local function follow_name()
    return (jam.follow.url:gsub("^%a+://", ""):gsub("/$", ""))
end

--- Our playlist, or while following the followed songbook's (read-only).
function Songbook:onSongbookShowPlaylist()
    local remote = self:isFollowing()
    local p, body
    if remote then
        p, body = self:fetchFollowedPlaylist()
        if not p then
            notify(_("Cannot reach the other songbook."))
            return true
        end
    end
    local title = remote and T(_("Playlist of %1"), follow_name()) or _("Playlist")
    local menu
    local function build()
        if not remote then p = self:getPlaylist() end
        local items = {
            {
                text = remote and _("Request songs…") or _("Add songs…"),
                bold = true,
                callback = function() self:showPlaylistPicker() end,
            },
        }
        table.insert(items, { text = T(_("Up next (%1)"), #p.queue), bold = true, select_enabled = false })
        local function add(entry, mandatory, queued)
            local item = { text = entry.title, mandatory = mandatory, entry = entry, queued = queued,
                           played = not queued }
            -- the other songbook's songs may not be on this device
            if not remote then
                item.callback = function()
                    self:closeList()
                    self:openSong(entry.uid)
                end
            end
            table.insert(items, item)
        end
        for _i, e in ipairs(p.queue) do add(e, e.by and Render.truncate(e.by, MAX_SOURCE) or "", true) end
        if #p.queue == 0 then table.insert(items, { text = _("No songs"), dim = true, select_enabled = false }) end
        table.insert(items, { text = T(_("Played (%1)"), #p.history), bold = true, select_enabled = false })
        for i = #p.history, 1, -1 do
            local at = p.history[i].at
            add(p.history[i], at and os.date("%H:%M", at) or "")
        end
        return items
    end
    local actions = not remote and function()
        return {
            { text = _("Save played songs as collection…"), callback = function() self:savePlaylistAsCollection() end },
            { text = _("Clear playlist"), callback = function()
                UIManager:show(ConfirmBox:new{
                    text = _("Clear the list of played and requested songs?"),
                    ok_text = _("Clear"),
                    ok_callback = function() self:savePlaylist({}) end,
                })
            end },
        }
    end or nil
    menu = list_menu(title, build(), actions, {
        onMenuHold = function(_menu, item)
            if remote or not item.entry then return true end
            local uid = item.entry.uid
            if item.played then
                if self:isQueued(uid) then return true end
                show_actions(item.entry.title, {
                    { text = _("Add to Up next"), callback = function()
                        local entry, err = self:addToPlaylist(uid)
                        if not entry then notify(request_error(err)) end
                    end },
                })
                return true
            end
            show_actions(item.entry.title, {
                { text = _("Play next"), callback = function() self:playNextInPlaylist(uid) end },
                { text = _("Remove from playlist"), callback = function() self:removeFromPlaylist(uid) end },
            })
            return true
        end,
    })
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
    if not remote then last_list = { kind = "playlist" } end
    self:trackList(menu)
    UIManager:show(menu)
    return true
end

--- Song list for building the playlist: a tap adds the song to Up next and
-- another tap removes it. Songs already in the playlist (up next or played)
-- can be hidden. While following, lists the followed songbook's songs and
-- requests them there.
function Songbook:showPlaylistPicker()
    local remote = self:isFollowing()
    local all
    if remote then all = self:fetchFollowedSongs() else all = self:listLocal() end
    if not all then return notify(_("Cannot reach the other songbook.")) end
    -- playlist entries are matched by the ids of the songbook that keeps the playlist
    local function song_key(song) return remote and song.id or song.uid end
    local function entry_key(e) return remote and e.uid and Jam.song_id(e.uid) or e.uid end
    local queued, played
    local function get_songs()
        local p
        if remote then
            p = self:fetchFollowedPlaylist() or { queue = {}, history = {} }
        else
            p = self:getPlaylist()
        end
        queued, played = {}, {}
        for _i, e in ipairs(p.queue) do if e.uid then queued[entry_key(e)] = true end end
        for _i, e in ipairs(p.history) do if e.uid then played[entry_key(e)] = true end end
        if not self:get("playlist_hide_added") then return all end
        local songs = {}
        for _i, song in ipairs(all) do
            local k = song_key(song)
            if not (queued[k] or played[k]) then songs[#songs + 1] = song end
        end
        return songs
    end
    local title = remote and T(_("Request from %1"), follow_name()) or _("Add to playlist")
    self:showList(title, get_songs, function(song, refresh)
        local k = song_key(song)
        local status = queued[k] and _("up next") or played[k] and _("played") or nil
        return {
            text = song.title,
            mandatory = details(song.artist, not remote and song.source or nil, status),
            callback = function()
                if remote then
                    if queued[k] then return notify(_("This song is already requested.")) end
                    local ok, err = self:requestFollowed(song.id)
                    if not ok then notify(err) end
                elseif queued[k] then
                    self:removeFromPlaylist(song.uid)
                else
                    local entry, err = self:addToPlaylist(song.uid)
                    if not entry then notify(request_error(err)) end
                end
                refresh()
            end,
        }
    end, nil, nil, function(refresh)
        local hide = self:get("playlist_hide_added")
        return {{
            text = hide and _("Show songs already in the playlist") or _("Hide songs already in the playlist"),
            callback = function()
                self:set("playlist_hide_added", not hide)
                refresh()
            end,
        }}
    end)
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
    -- the followed songbook's playlist is used instead of ours
    self:savePlaylist({})
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
            help_text = _("Guests on the same Wi-Fi open the address in a web browser and see the song you are playing. Each guest can transpose it for themselves, and see your playlist and ask for songs."),
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
            separator = true,
        },
        {
            text_func = function()
                if not self:isFollowing() then return _("Follow another songbook…") end
                return T(_("Following %1"), follow_name())
            end,
            help_text = _("Open the songs another device is playing, as they change, in the other player's key; you can still transpose them. Your playlist is cleared and the other songbook's playlist is used instead."),
            keep_menu_open = true,
            checked_func = function() return self:isFollowing() end,
            callback = function(touchmenu_instance)
                if self:isFollowing() then
                    self:stopFollowing()
                    touchmenu_instance:updateItems()
                    return
                end
                local function ask()
                    self:askFollowUrl(function(url)
                        NetworkMgr:runWhenConnected(function()
                            self:startFollowing(url)
                            touchmenu_instance:updateItems()
                        end)
                    end)
                end
                local p = self:getPlaylist()
                if #p.queue + #p.history == 0 then return ask() end
                UIManager:show(ConfirmBox:new{
                    text = _("Following another songbook clears your playlist and uses theirs instead."),
                    ok_text = _("Follow"),
                    ok_callback = ask,
                })
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

--- Actions for the song that is open (for show_actions(), each with an `id`):
-- transposition, autoscroll, song length, favorite, collections, playlist and
-- next song. Songs received while following are not kept in favorites,
-- collections or the playlist.
function Songbook:songActions()
    local uid = self:currentSongId()
    if not uid then return {} end
    local own = self:currentOwnSongId()
    local t = self:getMap("transpose")[uid] or 0
    local secs = self:songDuration(uid)
    local actions = {
        {
            id = "transpose",
            text = not self:get("show_chords") and _("Transpose (chords hidden)")
                or t ~= 0 and T(_("Transpose (%1)"), string.format("%+d", t)) or _("Transpose"),
            callback = function() self:showKeyDialog() end,
        },
        {
            id = "autoscroll",
            text = self:isAutoscrolling() and _("Stop autoscroll") or _("Start autoscroll"),
            callback = function() self:onSongbookAutoscroll() end,
        },
        {
            id = "duration",
            text = secs and T(_("Song length: %1"), ChordPro.format_duration(secs)) or _("Song length"),
            enabled = own ~= nil,
            callback = function() self:showDurationDialog() end,
        },
    }
    if own then
        local _key, id = split_uid(own)
        local meta = ChordPro.parse_meta(read_file(self:songPath(own)) or "")
        local song = { uid = own, title = meta.title or id }
        table.insert(actions, {
            id = "favorite",
            text = self:isFavorite(own) and _("Remove from favorites") or _("Add to favorites"),
            callback = function() self:onSongbookToggleFavorite() end,
        })
        table.insert(actions, {
            id = "collections",
            text = _("Collections…"),
            callback = function() self:showSongCollections(song, function() end) end,
        })
        if not self:isFollowing() then
            local playlist = self:playlistButton(song, function() end)
            table.insert(actions, { id = "playlist", text = playlist.text, callback = playlist.callback })
        end
    end
    local next_song = self:nextInPlaylist()
    if next_song and next_song.uid ~= uid then
        table.insert(actions, {
            id = "next",
            text = T(_("Next song: %1"), next_song.title),
            callback = function() self:openSong(next_song.uid) end,
        })
    end
    return actions
end

--- Dialog of the open song (song button, gesture "song options").
function Songbook:showSongDialog()
    local uid = self:currentSongId()
    if not uid then return end
    local _key, id = split_uid(uid)
    local meta = ChordPro.parse_meta(read_file(self:songPath(uid)) or "")
    local title = meta.title or id
    if meta.artist then title = title .. " – " .. meta.artist end
    show_actions(title, self:songActions())
    return true
end

Songbook.onSongbookSongDialog = Songbook.showSongDialog

--- Items of the song library: the song lists, playlist and next song.
function Songbook:libraryMenu()
    local items = {
        {
            songbook_item = "my_songs",
            text = _("My songs"),
            keep_menu_open = true,
            callback = function() self:onSongbookShowLocal() end,
        },
        {
            songbook_item = "favorites",
            text = _("Favorites"),
            keep_menu_open = true,
            callback = function() self:onSongbookShowFavorites() end,
        },
        {
            songbook_item = "collections_list",
            text = _("Collections"),
            keep_menu_open = true,
            callback = function() self:onSongbookShowCollections() end,
        },
        {
            songbook_item = "online",
            text = _("Browse online"),
            keep_menu_open = true,
            callback = function() self:browseOnline() end,
            separator = true,
        },
        {
            songbook_item = "playlist",
            text_func = function()
                if self:isFollowing() then return _("Playlist (jam session)") end
                local n = #self:getPlaylist().queue
                return n > 0 and T(_("Playlist (%1 up next)"), n) or _("Playlist")
            end,
            keep_menu_open = true,
            callback = function() self:onSongbookShowPlaylist() end,
        },
    }
    -- only while there is one: the playlist item shows how many are queued
    if self:nextInPlaylist() then
        table.insert(items, {
            songbook_item = "next",
            text_func = function()
                local e = self:nextInPlaylist()
                return e and T(_("Next song: %1"), Render.truncate(e.title, 24)) or _("Next song")
            end,
            enabled_func = function() return self:nextInPlaylist() ~= nil end,
            callback = function() self:onSongbookNextSong() end,
        })
    end
    items[#items].separator = true
    return items
end

function Songbook:settingsMenu()
    return {
        {
            text_func = function()
                return T(_("Song repositories (%1)"), #self:getServers())
            end,
            keep_menu_open = true,
            callback = function() self:showRepositories() end,
        },
        {
            text = _("Display"),
            sub_item_table = {
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
                    text = _("Song button"),
                    help_text = _("A button in the bottom right corner of an open song opens the song's options: transposition, autoscroll, favorites, collections and playlist. They are also available as the gesture action \"Songbook: song options\"."),
                    checked_func = function() return self:get("song_button") end,
                    callback = function() self:setAndRefresh("song_button", not self:get("song_button")) end,
                },
                {
                    text = _("Repeat chorus text"),
                    help_text = _("Print the whole chorus where the song says {chorus}, instead of just a label."),
                    checked_func = function() return self:get("repeat_chorus") end,
                    callback = function() self:setAndRefresh("repeat_chorus", not self:get("repeat_chorus")) end,
                },
            },
        },
        {
            text = _("Scrolling"),
            sub_item_table = {
                {
                    text = _("Continuous scroll mode"),
                    help_text = _("Open songs in continuous (scroll) mode, which autoscroll moves by a part of the screen. Turn it off to use the reader's own view mode."),
                    checked_func = function() return self:get("scroll_mode") end,
                    callback = function() self:set("scroll_mode", not self:get("scroll_mode")) end,
                },
                {
                    text = _("Autoscroll when a song opens"),
                    help_text = _("Scroll songs that have a length ({duration} in the song file, or set with Song length in the song's options) so that they end with the song. Gestures can start/stop autoscroll and make it faster or slower; the changed length is kept for the song."),
                    checked_func = function() return self:get("autoscroll") end,
                    callback = function() self:set("autoscroll", not self:get("autoscroll")) end,
                },
                {
                    text_func = function()
                        return T(_("Autoscroll step: 1/%1 screen"), self:get("autoscroll_step"))
                    end,
                    keep_menu_open = true,
                    callback = function(touchmenu_instance)
                        UIManager:show(SpinWidget:new{
                            title_text = _("Autoscroll step"),
                            info_text = _("In continuous scroll mode, autoscroll moves this part of the screen at a time. Smaller steps scroll more smoothly but refresh the screen more often."),
                            value = self:get("autoscroll_step"),
                            value_min = 2,
                            value_max = 16,
                            default_value = DEFAULTS.autoscroll_step,
                            callback = function(spin)
                                self:set("autoscroll_step", spin.value)
                                if touchmenu_instance then touchmenu_instance:updateItems() end
                            end,
                        })
                    end,
                },
            },
            separator = true,
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
    }
end

--- The Songbook menu: the library, jam session and settings (the open song's
-- actions are in showSongDialog()). Built when it opens, so Next song shows
-- only while a song is queued.
function Songbook:mainMenu()
    local items = self:libraryMenu()
    table.insert(items, {
        songbook_item = "jam",
        text_func = function()
            if self:isJamRunning() then return _("Jam session (sharing)") end
            return self:isFollowing() and _("Jam session (following)") or _("Jam session")
        end,
        sub_item_table = self:jamMenu(),
    })
    table.insert(items, {
        songbook_item = "settings",
        text = _("Settings"),
        sub_item_table = self:settingsMenu(),
    })
    return items
end

function Songbook:addToMainMenu(menu_items)
    menu_items.songbook = {
        text = _("Songbook"),
        sorting_hint = "tools",
        sub_item_table_func = function() return self:mainMenu() end,
    }
end

return Songbook
