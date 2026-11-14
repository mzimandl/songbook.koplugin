--[[--
Shared by main.lua and the songbook/ui/ modules: the plugin class, translations,
settings defaults, state that outlives plugin instances and small helpers.

KOReader makes a new plugin instance for every reader and file manager, so
state that must survive switching between them (the jam session, the last
song list, cached song metadata) lives here, at module level.
Requires KOReader (unlike the pure modules in songbook/).
]]

local ChordPro = require("songbook/chordpro")
local L10n = require("songbook/l10n")
local Render = require("songbook/render")
local Search = require("songbook/search")

local ButtonDialog = require("ui/widget/buttondialog")
local InfoMessage = require("ui/widget/infomessage")
local Menu = require("ui/widget/menu")
local Screen = require("device").screen
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local lfs = require("libs/libkoreader-lfs")
local time = require("ui/time")
local util = require("util")
local gettext = require("gettext")
-- The plugin's strings are not in KOReader's catalog: its own catalog for
-- KOReader's language first (songbook/l10n/<lang>.lua, required now: the
-- plugin folder is in package.path only while main.lua is being loaded).
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
    show_chords = true,
    repeat_chorus = false,
    jam_port = 8765,
    playlist_hide_added = true,
    autoscroll = false,
    autoscroll_step = 8,   -- scroll mode moves 1/8 of the screen
    scroll_mode = true,
    song_button = true,
    play_on_open = false,
    jam_share_songs = true,
    jam_follow_scroll = true,
}

-- The jam session's server and following work through the newest plugin
-- instance (jam.owner); see songbook/ui/jam.lua.
local jam = {}

-- Songs received from a followed songbook are kept in songs/<JAM_KEY>/.
local JAM_KEY = "jam"
-- Requests to a followed songbook block the UI, so they use short timeouts.
local FOLLOW_TIMEOUT = { 2, 4 }   -- block, total seconds

-- The song list opened last, to open it again with the gesture "last song
-- list": `last` = { kind = "local" | "favorites" | "collection" | "online" |
-- "playlist", arg, query, page }; `restoring` is set while the last list is
-- being opened again (its query and page). The song opens in a new plugin instance.
local song_lists = {}

-- A song that is opened again while it is open (transposed, other options,
-- the followed songbook changed its key) is a new document in a new plugin
-- instance: `reopen` = { uid, percent, autoscroll } carries where it was (and
-- a running autoscroll) over to onReaderReady().
local reopen = {}


local function read_file(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local data = f:read("*a")
    f:close()
    return data
end

-- Metadata of song files by path: { stamp = "<mtime>:<size>", meta }. Lists
-- (and the jam session's /index.json) read every song, which is slow on
-- e-readers with hundreds of them. Module-level: it outlives plugin instances.
local meta_cache = {}

--- ChordPro.parse_meta() of the file at `path` ({} when it is missing), cached
-- until the file changes. The table is shared: don't change it.
local function song_meta(path)
    local attr = lfs.attributes(path)
    local stamp = type(attr) == "table" and attr.mode == "file"
        and tostring(attr.modification) .. ":" .. tostring(attr.size) or nil
    local hit = meta_cache[path]
    if hit and stamp and hit.stamp == stamp then return hit.meta end
    local meta = ChordPro.parse_meta(read_file(path) or "")
    meta_cache[path] = stamp and { stamp = stamp, meta = meta } or nil
    return meta
end

--- Write through a temporary file, so a failed or interrupted write (full
-- disk, battery) leaves the old file as it was.
local function write_file(path, data)
    meta_cache[path] = nil   -- a rewrite within the same second keeps mtime and maybe size
    local tmp = path .. ".part"
    local f, err = io.open(tmp, "wb")
    if not f then return nil, err end
    local ok, werr = f:write(data)
    local closed, cerr = f:close()
    if not ok or not closed then
        os.remove(tmp)
        return nil, werr or cerr
    end
    local renamed, rerr = os.rename(tmp, path)
    if not renamed then
        os.remove(tmp)
        return nil, rerr
    end
    return true
end

local function lower(s)
    return util.stringLower and util.stringLower(s) or s:lower()
end

-- Search ignores case and diacritics ("pisen" finds "Píseň").
local function matches(song, query)
    return Search.matches(song, query and Search.fold(query, lower), lower)
end

local function sort_songs(songs)
    return Search.sort(songs, lower)
end

--- Put `uid` into collection table `c` (at the end of its order) or take it out.
local function collection_set(c, uid, on)
    c.order = c.order or {}
    for i = #c.order, 1, -1 do
        if c.order[i] == uid then table.remove(c.order, i) end
    end
    if on then table.insert(c.order, uid) end
    c.songs[uid] = on and true or nil
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

local function now()
    return time.to_s(time.now())
end

-- Song lists ----------------------------------------------------------------------

local function song_file_id(name)
    return name:match("^(.+)%.cho$") or name:match("^(.+)%.chopro$")
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

--- Dialog with one button per action: { text, callback, enabled, row, short }.
-- Consecutive actions with the same `row` (any value) are put side by side,
-- labelled `short` when they have one. The dialog closes before the callback runs.
local function show_actions(title, actions)
    local dialog
    -- consecutive actions with the same `row` share a row
    local rows = {}
    for _i, a in ipairs(actions) do
        local prev = rows[#rows]
        if a.row and prev and prev[1].row == a.row then
            table.insert(prev, a)
        else
            table.insert(rows, { a })
        end
    end
    local buttons = {}
    for _i, row in ipairs(rows) do
        local line = {}
        for _j, a in ipairs(row) do
            table.insert(line, {
                -- `short`: the label beside other buttons
                text = #row > 1 and a.short or a.text,
                enabled = a.enabled ~= false,
                callback = function()
                    UIManager:close(dialog)
                    a.callback()
                end,
            })
        end
        table.insert(buttons, line)
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

--- Display name of the followed songbook: its name, else its address.
local function follow_name()
    if jam.follow.name and jam.follow.name ~= "" then return jam.follow.name end
    return (jam.follow.url:gsub("^%a+://", ""):gsub("/$", ""))
end

-- Sharing, following and autoscroll must keep the reader awake with nobody
-- touching it: UIManager:preventStandby() only stops the short standby, the
-- auto-suspend after some idle minutes is paused with PluginShare (as the
-- autoturn plugin does). Counted, as they can run together; the flag another
-- plugin set before is put back.
local awake = { count = 0 }
local function keep_awake(on)
    local PluginShare = require("pluginshare")
    if on then
        UIManager:preventStandby()
        if awake.count == 0 then awake.before = PluginShare.pause_auto_suspend end
        awake.count = awake.count + 1
        PluginShare.pause_auto_suspend = true
    elseif awake.count > 0 then
        UIManager:allowStandby()
        awake.count = awake.count - 1
        if awake.count == 0 then PluginShare.pause_auto_suspend = awake.before end
    end
end

local function count_keys(t)
    local n = 0
    for _k in pairs(t) do n = n + 1 end
    return n
end

return {
    Songbook = Songbook,
    _ = _,
    T = T,
    DEFAULTS = DEFAULTS,
    jam = jam,
    JAM_KEY = JAM_KEY,
    FOLLOW_TIMEOUT = FOLLOW_TIMEOUT,
    song_lists = song_lists,
    reopen = reopen,
    MAX_ARTIST = MAX_ARTIST,
    MAX_SOURCE = MAX_SOURCE,
    read_file = read_file,
    song_meta = song_meta,
    write_file = write_file,
    lower = lower,
    matches = matches,
    sort_songs = sort_songs,
    collection_set = collection_set,
    busy = busy,
    notify = notify,
    split_uid = split_uid,
    make_uid = make_uid,
    now = now,
    song_file_id = song_file_id,
    details = details,
    show_actions = show_actions,
    list_menu = list_menu,
    follow_name = follow_name,
    count_keys = count_keys,
    keep_awake = keep_awake,
}
