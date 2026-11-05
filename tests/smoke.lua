-- Smoke test of main.lua against stubbed KOReader modules.
-- Run from the repo root:  luajit tests/smoke.lua
package.path = "./?.lua;" .. package.path

local tmp = os.getenv("TMPDIR") or "/tmp"
local root = tmp .. "/songbook-smoke-" .. os.time()
os.execute("mkdir -p " .. root .. "/settings")

local shown, notes, opened = {}, {}, {}
local function stub(name, mod) package.preload[name] = function() return mod end end
local function class(t)
    t = t or {}
    t.extend = function(self, o) o = o or {}; setmetatable(o, { __index = self }); return o end
    t.new = function(self, o) o = o or {}; setmetatable(o, { __index = self }); if o.init then o:init() end return o end
    return t
end

stub("gettext", setmetatable({ current_lang = "C" }, { __call = function(_, s) return s end }))
stub("ffi/util", { template = function(s, ...)
    local a = { ... }
    return (s:gsub("%%(%d)", function(i) return tostring(a[tonumber(i)]) end))
end })
stub("datastorage", { getDataDir = function() return root end, getSettingsDir = function() return root .. "/settings" end })
stub("dispatcher", { registerAction = function() end })
stub("logger", { warn = print, info = function() end, dbg = function() end })
stub("device", { isKindle = function() return false end,
    screen = { getWidth = function() return 600 end, getHeight = function() return 800 end } })
stub("ui/widget/container/widgetcontainer", class())
stub("ui/widget/infomessage", class({ init = function(self) table.insert(notes, self.text) end }))
stub("ui/widget/buttondialog", class())
stub("ui/widget/confirmbox", class())
stub("ui/widget/inputdialog", class())
stub("ui/widget/spinwidget", class())
stub("ui/widget/doublespinwidget", class())
local toasts = {}
stub("ui/widget/notification", { notify = function(_, text) table.insert(toasts, text) end })
stub("ui/event", { new = function(_, name, arg) return { name = name, arg = arg } end })
local clock = 0
stub("ui/time", { now = function() return clock end, to_s = function(t) return t end })
stub("ui/widget/menu", class({ switchItemTable = function(self, t, items) self.item_table = items end }))
stub("ui/network/manager", { runWhenOnline = function(_, cb) cb() end, runWhenConnected = function(_, cb) cb() end })
local zmqs, standby, scheduled, scheduled_in, ticks = {}, 0, nil, nil, {}
stub("ui/uimanager", {
    show = function(_, w) table.insert(shown, w) end, close = function() end, forceRePaint = function() end,
    insertZMQ = function(_, z) table.insert(zmqs, z); return z end,
    removeZMQ = function(_, z) for i = #zmqs, 1, -1 do if zmqs[i] == z then table.remove(zmqs, i) end end end,
    preventStandby = function() standby = standby + 1 end,
    scheduleIn = function(_, secs, f) scheduled, scheduled_in = f, secs end,
    nextTick = function(_, f) table.insert(ticks, f) end,
    unschedule = function(_, f) if scheduled == f then scheduled = nil end end,
    allowStandby = function() standby = standby - 1 end,
    isWidgetShown = function() return true end,
    setDirty = function() end,
})
local sent
stub("ui/message/simpletcpserver", class({
    start = function(self) self.started = true; return true end,
    stop = function(self) self.started = false end,
    send = function(_, data) sent = data end,
}))
stub("ui/widget/qrmessage", class())
stub("util", {
    makePath = function(p) os.execute("mkdir -p '" .. p .. "'") end,
    trim = function(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end,
})
stub("libs/libkoreader-lfs", {
    dir = function(p)
        local h = io.popen("ls -a '" .. p .. "'")
        local list = {}
        for l in h:lines() do list[#list + 1] = l end
        h:close()
        local i = 0
        return function() i = i + 1; return list[i] end
    end,
    attributes = function(p, what)
        local r = os.execute("test -d '" .. p .. "'")
        if r == 0 or r == true then return "directory" end
        local f = io.open(p, "rb")
        if f then f:close(); return "file" end
        return nil
    end,
})
local settings_store = {}
stub("luasettings", { open = function()
    return {
        readSetting = function(_, k) return settings_store[k] end,
        saveSetting = function(_, k, v) settings_store[k] = v end,
        delSetting = function(_, k) settings_store[k] = nil end,
        flush = function() end,
    }
end })
local doc_store = {}   -- path -> doc settings
stub("docsettings", { open = function(_, path)
    doc_store[path] = doc_store[path] or {}
    local data = doc_store[path]
    return {
        purge = function() doc_store[path] = nil end,
        readSetting = function(_, k) return data[k] end,
        saveSetting = function(_, k, v) data[k] = v end,
        flush = function() end,
    }
end })
local index_name = "Test repo"
local decoded = {}   -- body -> table, for bodies other than the index
stub("json", { decode = function(body)
    if decoded[body] then return decoded[body] end
    return { name = index_name, songs = { { id = "test", title = "Test", file = "songs/test.cho", updated = "1" } } }
end })
local udps = {}   -- fake UDP sockets; inbox = { { msg, ip, port } }, outbox = { { msg, ip, port } }
local taken_ports = {}
stub("socket", { skip = function(n, ...) return select(n + 1, ...) end, udp = function()
    local u = { inbox = {}, outbox = {} }
    function u.setpeername() end
    function u.getsockname() return "192.168.1.5" end
    function u.close(self) self.closed = true; if self.port then taken_ports[self.port] = nil end end
    function u.setsockname(self, _, port)
        if taken_ports[port] then return nil, "address already in use" end
        self.port = port
        if port ~= 0 then taken_ports[port] = true end
        return 1
    end
    function u.settimeout() end
    function u.setoption(self, k, v) self[k] = v end
    function u.sendto(self, msg, ip, port) table.insert(self.outbox, { msg, ip, port }) end
    function u.receivefrom(self)
        local m = table.remove(self.inbox, 1)
        if not m then return nil, "timeout" end
        return m[1], m[2], m[3]
    end
    table.insert(udps, u)
    return u
end })
local function udp_on(port)
    for i = #udps, 1, -1 do if udps[i].port == port and not udps[i].closed then return udps[i] end end
end
stub("ltn12", { sink = { table = function(t) return t end } })
stub("socketutil", { set_timeout = function() end, reset_timeout = function() end })
local requested, responses = {}, {}   -- responses[url] = body, or false for 404
stub("socket.http", { request = function(req)
    table.insert(requested, req.url)
    if responses[req.url] == false then return 1, 404, {}, "HTTP/1.1 404 Not Found" end
    table.insert(req.sink, responses[req.url] or "{title: Downloaded}\n[Am]La")
    return 1, 200, {}, "HTTP/1.1 200 OK"
end })
stub("ffi/blitbuffer", { COLOR_WHITE = 0 })
stub("ui/geometry", { new = function(_, o) return o end })
stub("ui/size", { border = { button = 1 }, radius = { button = 2 }, padding = { small = 2 }, margin = { default = 5 } })
stub("ui/widget/iconwidget", class())
stub("ui/widget/container/framecontainer", class({ getSize = function() return { w = 50, h = 50 } end,
    paintTo = function() end }))
local ReaderUI = { showReader = function(_, path) table.insert(opened, path) end }
stub("apps/reader/readerui", ReaderUI)
local ReadHistory = { hist = { { file = "/books/book.epub", time = 1 } } }
function ReadHistory:addItem(file) table.insert(self.hist, 1, { file = file, time = 3 }) end
function ReadHistory:updateLastBookTime() self.hist[1].time = 4 end
stub("readhistory", ReadHistory)

local passed, failed = 0, 0
local function check(cond, name)
    if cond then passed = passed + 1 else failed = failed + 1; print("FAIL " .. name) end
end

local registered
local Songbook = require("main")
local plugin = Songbook:new{ ui = { menu = { registerToMainMenu = function(_, p) registered = p end } } }
check(registered == plugin, "registered to main menu")
local defaults = plugin:getServers()
check(#defaults == 1 and defaults[1].url == "https://github.com/mzimandl/songbook-library"
    and defaults[1].key == "mzimandl-songbook-library", "default repository on first start")
plugin:saveServers({})
plugin:init()
check(#plugin:getServers() == 0, "removed default repository is not added again")
check(settings_store.schema == 1, "fresh install gets the current schema")

-- migration 1: the jam session's playlist became the general one
settings_store.schema = nil
settings_store.jam_playlist = { history = { { uid = "x", title = "X" } }, queue = {} }
plugin:init()
check(settings_store.jam_playlist == nil and settings_store.playlist.history[1].uid == "x"
    and settings_store.schema == 1, "jam_playlist migrated to playlist")
plugin:savePlaylist({})

local items = {}
plugin:addToMainMenu(items)
-- The Songbook menu is built when it opens; items are found by `songbook_item`.
local function menu_item(name)
    for _i, item in ipairs(items.songbook.sub_item_table_func()) do
        if item.songbook_item == name then return item end
    end
end
check(#items.songbook.sub_item_table_func() == 8 and menu_item("my_songs") and menu_item("settings"), "menu built")
-- items of the Playlist submenu
local function playlist_entry(name)
    for _i, item in ipairs(menu_item("playlist").sub_item_table_func()) do
        if item.songbook_item == name then return item end
    end
end
-- actions of the open song (song button / song options dialog), found by `id`
local function song_action(id)
    for _i, a in ipairs(plugin:songActions()) do
        if a.id == id then return a end
    end
end
check(#plugin:songActions() == 0 and not playlist_entry("next").enabled_func()
    and playlist_entry("next").text_func() == "Next song", "no song actions outside a song")
check(not menu_item("song").enabled_func() and #menu_item("song").sub_item_table_func() == 0,
    "song options disabled outside a song")

-- empty library: the list opens with a hint and a way to get songs
local function last_shown() return shown[#shown] end
plugin:onSongbookShowLocal()
check(notes[#notes]:find("No songs yet", 1, true), "empty library message")
check(last_shown().item_table[2].text == "No songs yet" and last_shown().item_table[3].text == "Browse online",
    "empty library list")
plugin:closeList()

-- add a song and open it
local f = io.open(root .. "/songbook/songs/test.cho", "w")
f:write("{title: Žluťoučký kůň}\n{artist: Lidová}\n{key: C}\n[C]Jede [G]kůň\n")
f:close()
local songs = plugin:listLocal()
check(#songs == 1 and songs[1].title == "Žluťoučký kůň", "listLocal reads meta")

plugin:openSong("test")
check(#opened == 1 and opened[1]:find("/rendered/test@t%+0%.cz%.w42%.c1%.r0%.html$"), "rendered path " .. tostring(opened[1]))
check(doc_store[opened[1]].copt_view_mode == 1, "songs open in scroll mode")
local html = io.open(opened[1]):read("*a")
check(html:find("Jede kůň", 1, true), "rendered lyrics")
ReadHistory:addItem(opened[1])
ReaderUI.instance = { document = { file = opened[1] } }
ReadHistory:updateLastBookTime()
check(#ReadHistory.hist == 1 and ReadHistory.hist[1].time == 1, "songs are kept out of the reading history")
ReadHistory:addItem("/books/other.epub")
ReaderUI.instance.document.file = "/books/other.epub"
ReadHistory:updateLastBookTime()
check(#ReadHistory.hist == 2 and ReadHistory.hist[1].time == 4, "books still go to the reading history")
ReaderUI.instance = nil

-- simulate reader with that file open, transpose up twice
plugin.ui.document = { file = opened[1] }
plugin.ui.switchDocument = function(_, p) table.insert(opened, p); plugin.ui.document.file = p end
check(plugin:currentSongId() == "test", "currentSongId")
check(#items.songbook.sub_item_table_func() == 8 and menu_item("transpose") == nil, "no song items in the menu")
local song_menu = menu_item("song")
check(song_menu.enabled_func() and #song_menu.sub_item_table_func() == #plugin:songActions() - 2
    and song_menu.sub_item_table_func()[1].text == song_action("transpose").text, "song options in the menu")
for _i, sub in ipairs(song_menu.sub_item_table_func()) do
    check(sub.text ~= "Next song" and sub.text ~= "Playlist", "no playlist items in the menu's song options")
end
-- the song button: bottom right, above the footer; taps elsewhere in its zone go on
local zones, modules = {}, {}
plugin.ui.registerTouchZones = function(_, z) for _i, zone in ipairs(z) do zones[zone.id] = zone end end
plugin.ui.view = { footer_visible = true, footer = { getHeight = function() return 20 end },
    registerViewModule = function(_, name, m) modules[name] = m end }
plugin:onReaderReady()
local song_button = modules.songbook_button
song_button:paintTo(nil, 0, 0)
check(song_button.rect.x == 600 - 50 - 10 and song_button.rect.y == 800 - 20 - 50 - 10, "song button above the footer")
local function point(x, y) return { intersectWith = function(_, r) return x >= r.x and x < r.x + r.w and y >= r.y and y < r.y + r.h end } end
local n_shown = #shown
check(not zones.songbook_button.handler({ pos = point(460, 700) }) and #shown == n_shown, "tap beside the song button goes on")
check(zones.songbook_button.handler({ pos = point(560, 730) }) and shown[#shown].title == "Žluťoučký kůň – Lidová" and #shown == n_shown + 1,
    "song button opens the song dialog: " .. tostring(shown[#shown].title))
check(shown[#shown].buttons[1][1].text == "Transpose" and shown[#shown].buttons[2][1].text == "Start autoscroll",
    "song dialog actions")
settings_store.song_button = false
modules = {}
plugin:onReaderReady()
check(modules.songbook_button == nil, "song button can be turned off")
settings_store.song_button = nil
plugin.ui.view = nil
plugin:onSongbookTranspose(1)
plugin:onSongbookTranspose(1)
check(opened[#opened]:find("test@t%+2"), "transposed render path")
check(io.open(opened[#opened]):read("*a"):find('<span class="c">D', 1, true), "chords transposed to D")
check(song_action("transpose").text == "Transpose (+2)", "transpose label")
plugin:onSongbookTranspose(0)
check(opened[#opened]:find("test@t%+0"), "reset transposition")
-- the key dialog: test.cho is in C
song_action("transpose").callback()
local key_dialog = shown[#shown]
check(key_dialog.title == "Key: C (original key)" and #key_dialog.buttons == 5
    and key_dialog.buttons[1][3].text == "+1" and not key_dialog.buttons[1][2].enabled
    and key_dialog.buttons[2][1].text == "C" and key_dialog.buttons[2][1].font_bold,
    "key dialog marks the current key")
check(key_dialog.buttons[5][2].text == "Apply" and not key_dialog.buttons[5][2].enabled, "Apply disabled until the key changes")
local n_opened = #opened
key_dialog.buttons[4][2].callback()   -- A
key_dialog = shown[#shown]
check(#opened == n_opened and key_dialog.title == "Key: A (-3)" and key_dialog.buttons[1][2].enabled
    and key_dialog.buttons[4][2].font_bold, "a step only changes the dialog")
key_dialog.buttons[1][3].callback()   -- +1
key_dialog = shown[#shown]
check(#opened == n_opened and key_dialog.title == "Key: B (-2)", "dialog +1: " .. key_dialog.title)
key_dialog.buttons[5][2].callback()   -- Apply
check(#opened == n_opened + 1 and opened[#opened]:find("test@t%-2"), "Apply renders the chosen key")
song_action("transpose").callback()
key_dialog = shown[#shown]
check(key_dialog.title == "Key: B (-2)", "dialog opens with the saved key")
key_dialog.buttons[1][2].callback()   -- Original key
shown[#shown].buttons[5][1].callback()   -- Cancel
check(#opened == n_opened + 1 and plugin:getMap("transpose").test == -2, "Cancel keeps the key")
song_action("transpose").callback()
shown[#shown].buttons[1][2].callback()
shown[#shown].buttons[5][2].callback()
check(opened[#opened]:find("test@t%+0"), "key dialog original key")
plugin.ui.view = nil
settings_store.show_chords = false
check(song_action("transpose").text == "Transpose (chords hidden)", "transpose label without chords")
song_action("transpose").callback()
last_shown().ok_callback()
check(settings_store.show_chords == true and opened[#opened]:find("%.c1%."), "transpose offers to show chords")
doc_store[opened[#opened]].copt_view_mode = 0
plugin:openSong("test")
check(doc_store[opened[#opened]].copt_view_mode == 0, "chosen view mode is kept")
settings_store.scroll_mode = false
plugin:onSongbookTranspose(1)
check(doc_store[opened[#opened]] == nil or doc_store[opened[#opened]].copt_view_mode == nil,
    "scroll mode not forced when turned off")
plugin:onSongbookTranspose(0)
settings_store.scroll_mode = nil

-- autoscroll: 3200 px song on an 800 px screen in scroll mode
local doc = plugin.ui.document
local pos = 0
doc.info = { doc_height = 3200 }
doc.getCurrentPos = function() return pos end
doc.hasHiddenFlows = function() return false end
plugin.ui.view = { view_mode = "scroll", footer = { getBookProgress = function() return 0.5 end },
    registerViewModule = function() end }
settings_store.autoscroll_step = 4
plugin.ui.dimen = { h = 800 }
plugin.ui.handleEvent = function(_, ev)
    if ev.name == "GotoViewRel" then
        pos = math.min(pos + ev.arg * 800, 2400)
        plugin:onPosUpdate(pos)
    end
end
check(song_action("autoscroll").text == "Start autoscroll"
    and song_action("duration").text == "Song length", "no song length")
song_action("autoscroll").callback()
check(not plugin:isAutoscrolling() and notes[#notes]:find("no length", 1, true), "no autoscroll without a length")
song_action("duration").callback()
check(shown[#shown].ok_always_enabled and shown[#shown].left_value == 3 and shown[#shown].right_value == 0,
    "the default length can be applied as it is")
shown[#shown].callback(3, 0)
check(settings_store.duration.test == 180 and song_action("duration").text == "Song length: 3:00",
    "song length set")
clock = 100
song_action("autoscroll").callback()
check(plugin:isAutoscrolling() and standby == 1 and toasts[#toasts] == "Autoscroll: 3:00"
    and song_action("autoscroll").text == "Stop autoscroll"
    and scheduled_in == 22.5, "autoscroll waits until the played line is half way down: " .. tostring(scheduled_in))
clock = 122.5
scheduled()
check(pos == 200 and scheduled_in == 11.25, "autoscroll moves a quarter screen: " .. pos .. " " .. tostring(scheduled_in))
clock = 125
pos = 1000
plugin:onPosUpdate(pos)
check(scheduled_in == 11.25, "manual move re-anchors the timing: " .. tostring(scheduled_in))
plugin:onSongbookAutoscrollSpeed(1.1)
check(settings_store.duration.test == 200 and toasts[#toasts] == "Autoscroll: 3:20", "slower autoscroll keeps the length")
pos = 2400
scheduled()
check(not plugin:isAutoscrolling() and standby == 0 and scheduled == nil, "autoscroll stops at the end")
settings_store.autoscroll = true
pos = 0
plugin:onReaderReady()
check(not plugin:isAutoscrolling(), "no autoscroll for a song that is only open")
local n_opened = #opened
plugin:playSong("test")
check(plugin:isAutoscrolling() and standby == 1 and #opened == n_opened and plugin:nowPlayingUid() == "test",
    "Play now on the open song: playing without reopening, autoscroll starts")
plugin:onCloseDocument()
check(not plugin:isAutoscrolling() and standby == 0 and scheduled == nil, "autoscroll stops with the song")
plugin:onReaderReady()
check(plugin:isAutoscrolling(), "autoscroll starts when the song now playing opens")
plugin:onCloseDocument()
settings_store.autoscroll = nil
-- the footer shows the scrolled part in scroll mode, page progress in page mode
local footer = plugin.ui.view.footer
pos = 600
check(footer:getBookProgress() == 0.25, "footer progress follows the scroll position")
plugin.ui.view.view_mode = "page"
check(footer:getBookProgress() == 0.5, "footer progress by pages in page mode")
plugin.ui.view.view_mode = "scroll"
-- the default step is an eighth of the screen, keeping a quarter screen of played lines
settings_store.autoscroll_step = nil
clock, pos = 300, 0
plugin:startAutoscroll()
check(scheduled_in == 18.75, "eighth-screen step waits for the played line at 3/8: " .. tostring(scheduled_in))
clock = 318.75
scheduled()
check(pos == 100 and scheduled_in == 6.25, "autoscroll moves an eighth of the screen: " .. pos .. " " .. tostring(scheduled_in))
plugin:stopAutoscroll()

local InputDialog = require("ui/widget/inputdialog")
InputDialog.onShowKeyboard = function() end
local input_text
InputDialog.getInputText = function() return input_text end
local function find_button(dialog, text)
    for _, row in ipairs(dialog.buttons) do
        for _, b in ipairs(row) do
            if b.text == text then return b end
        end
    end
end

-- Jam session ------------------------------------------------------------------
local jam_menu = menu_item("jam")
local tmi = { updateItems = function() end }
check(jam_menu.text_func() == "Jam session" and not jam_menu.sub_item_table[1].checked_func(), "jam off by default")
check(jam_menu.sub_item_table[2].enabled_func() == false, "no address while not sharing")
local name_item = jam_menu.sub_item_table[4]
check(name_item.text_func() == "Device name: Songbook", "device model as the default name")
input_text = " Kytara\n"
name_item.callback(tmi)
find_button(last_shown(), "Save").callback()
check(settings_store.device_name == "Kytara" and name_item.text_func() == "Device name: Kytara", "device named")
input_text = " "
name_item.callback(tmi)
find_button(last_shown(), "Save").callback()
check(settings_store.device_name == nil and plugin:deviceName() == "Songbook", "empty name: the model again")
jam_menu.sub_item_table[1].callback(tmi)
check(#zmqs == 2 and zmqs[1].port == 8765 and standby == 1, "jam server started")
-- searches are answered with our port and the device name
local answers = udp_on(8766)
check(answers ~= nil, "discovery socket bound")
table.insert(answers.inbox, { "SONGBOOK-DISCOVER 1", "192.168.1.9", 8767 })
table.insert(answers.inbox, { "SONGBOOK-DISCOVER 2", "192.168.1.9", 8767 })
table.insert(answers.inbox, { "junk", "192.168.1.9", 8767 })
check(zmqs[2].waitEvent() == nil, "discovery poll returns nothing")
check(#answers.outbox == 1 and answers.outbox[1][1] == "SONGBOOK 1 8765 Songbook"
    and answers.outbox[1][2] == "192.168.1.9" and answers.outbox[1][3] == 8767, "search answered once")
check(jam_menu.text_func() == "Jam session (sharing)", "jam menu label while sharing")
check(jam_menu.sub_item_table[2].text_func() == "Address: http://192.168.1.5:8765/", "jam address")
check(jam_menu.sub_item_table[3].enabled_func() == false, "port locked while sharing")
check(jam_menu.sub_item_table[4].enabled_func() == false, "no following while sharing")
local function jam_get(target)
    sent = nil
    check(zmqs[1].receiveCallback("GET " .. target .. " HTTP/1.1\r\n\r\n", {}) == nil, "jam callback returns nothing")
    return sent and sent:match("^HTTP/1.1 (%d+)"), sent and sent:match("\r\n\r\n(.*)$")
end
plugin:finishPlaying()
local code, body = jam_get("/state.json")
check(code == "200" and not body:find('"uid"', 1, true), "nothing shared while no song is playing: " .. tostring(body))
plugin:playSong("test")
code, body = jam_get("/state.json")
check(code == "200" and body:find('"uid":"test"', 1, true) and body:find('"title":"Žluťoučký kůň"', 1, true), "jam state: " .. tostring(body))
local rev = body:match('"rev":"([^"]*)"')
code, body = jam_get("/song.html?t=2&n=en")
check(code == "200" and body:find("<!DOCTYPE html>", 1, true) and body:find('<span class="c">D', 1, true), "jam song transposed for guest")
code, body = jam_get("/song.cho")
check(code == "200" and body:find("[C]Jede", 1, true), "jam song source")
plugin:onSongbookTranspose(1)
code, body = jam_get("/state.json")
check(body:match('"rev":"([^"]*)"') ~= rev, "host transposition changes rev")
code, body = jam_get("/song.html")
check(body:find('<span class="c">D', 1, true), "guest gets host transposition")
plugin:onSongbookTranspose(0)
-- reader closed: the song now playing stays shared
local doc = plugin.ui.document
plugin.ui.document = nil
code, body = jam_get("/state.json")
check(body:find('"uid":"test"', 1, true), "song now playing shared after reader closed")
plugin.ui.document = doc

-- the host's songs as a repository
code, body = jam_get("/index.json")
check(code == "200" and body:find('"file":"songs/test.cho"', 1, true) and body:find('"key":"C"', 1, true), "jam index: " .. tostring(body))
code, body = jam_get("/songs/test.cho")
check(code == "200" and body:find("Jede", 1, true), "jam song file")
code = jam_get("/songs/..~settings~x.cho")
check(code == "404", "jam song file outside songs/")

-- playlist: played songs and guests' requests
local playlist_menu = menu_item("playlist")
local playlist_item = playlist_entry("show_playlist")
local p = plugin:getPlaylist()
check(p.now.uid == "test" and #p.history == 1 and p.history[1].uid == "test" and #p.queue == 0,
    "now playing and finished song, transposing not repeated")
check(playlist_menu.text_func() == "Playlist", "playlist label")
code, body = jam_get("/queue/add?uid=test&by=%20Pavel%0A")
check(body == '{"ok":true}' and notes[#notes] == "Song request: Žluťoučký kůň (Pavel)", "request added: " .. tostring(body))
code, body = jam_get("/queue/add?uid=test")
check(body == '{"error":"queued","ok":false}', "duplicate request: " .. tostring(body))
code, body = jam_get("/queue/add?uid=..%2F..%2Fsettings%2Fsongbook")
check(body == '{"error":"missing","ok":false}', "request outside the songs folder refused")
check(select(2, plugin:jamRequest("jam/x")) == "missing", "followed songs can't be requested")
code, body = jam_get("/queue/add?uid=nope")
check(body == '{"error":"missing","ok":false}', "request of a missing song")
code, body = jam_get("/playlist.json")
check(body:find('"queue":[{"artist":"Lidová","at":', 1, true) and body:find('"by":"Pavel"', 1, true)
    and body:find('"now":{', 1, true), "playlist json: " .. tostring(body))
check(playlist_menu.text_func() == "Playlist (1 up next)", "playlist label with requests")
playlist_item.callback()
local pl_menu = last_shown()
check(pl_menu.title == "Playlist" and pl_menu.item_table[2].text == "Now playing"
    and pl_menu.item_table[3].text == "▶ Žluťoučký kůň" and pl_menu.item_table[4].text == "Up next (1)", "playlist menu")
pl_menu.onMenuHold(pl_menu, pl_menu.item_table[3])
check(find_button(last_shown(), "Finished"), "song now playing can be finished")
local queued_item
for _, item in ipairs(pl_menu.item_table) do if item.queued then queued_item = item end end
check(queued_item and queued_item.text == "Žluťoučký kůň" and queued_item.mandatory == "Pavel", "queued song in playlist menu")
queued_item.callback()
p = plugin:getPlaylist()
check(#p.queue == 0 and #p.history == 1, "playing a requested song removes it from the queue")
local played_item
for _, item in ipairs(pl_menu.item_table) do if item.played then played_item = item end end
pl_menu.onMenuHold(pl_menu, played_item)
check(find_button(last_shown(), "Add to Up next") and find_button(last_shown(), "Play now"), "played song can be queued again")
input_text = "Jam test"
pl_menu:onLeftButtonTap()
find_button(last_shown(), "Save played songs as collection…").callback()
find_button(last_shown(), "Save").callback()
check(plugin:isInCollection("Jam test", "test"), "played songs saved as collection")
pl_menu:onLeftButtonTap()
find_button(last_shown(), "Clear playlist").callback()
last_shown().ok_callback()
p = plugin:getPlaylist()
check(#p.history == 0 and #p.queue == 0 and p.now == nil, "playlist cleared")
plugin:deleteCollection("Jam test")

-- adding songs to the playlist; songs already in it are hidden by default
f = io.open(root .. "/songbook/songs/second.cho", "w")
f:write("{title: Druhá}\n[G]La\n")
f:close()
pl_menu.item_table[1].callback()
local picker_list = last_shown()
local function picker_item(uid)
    for _, item in ipairs(picker_list.item_table) do
        if item.song and item.song.uid == uid then return item end
    end
end
local function toggle_hidden(list)
    (list or picker_list):onLeftButtonTap()
    local dialog = last_shown()
    local b = find_button(dialog, "Show songs already in the playlist")
        or find_button(dialog, "Hide songs already in the playlist")
    b.callback()
    return b.text
end
check(picker_list.title == "Add to playlist" and picker_list.item_table[2].text == "Druhá"
    and picker_list.item_table[3].text == "Žluťoučký kůň", "playlist picker")
picker_item("second").callback()
p = plugin:getPlaylist()
check(#p.queue == 1 and p.queue[1].uid == "second" and picker_item("second") == nil, "picked song added and hidden")
check(pl_menu.item_table[3].text == "Nothing is playing" and pl_menu.item_table[4].text == "Up next (1)",
    "open playlist refreshed after adding")
check(toggle_hidden() == "Show songs already in the playlist" and plugin:get("playlist_hide_added") == false
    and picker_item("second").mandatory == "up next", "songs in the playlist shown again")
picker_item("second").callback()
check(#plugin:getPlaylist().queue == 0 and picker_item("second").mandatory == "", "tapping a queued song removes it")
toggle_hidden()

-- next song from the playlist
check(not playlist_entry("next").enabled_func(), "no next song")
plugin:addToPlaylist("second")
plugin:addToPlaylist("test")
local next_item = playlist_entry("next")
check(next_item and next_item.enabled_func() and next_item.text_func() == "Next song: Druhá", "next song label")
playlist_item.callback()
pl_menu = last_shown()
local test_item
for _, item in ipairs(pl_menu.item_table) do if item.queued and item.entry.uid == "test" then test_item = item end end
pl_menu.onMenuHold(pl_menu, test_item)
find_button(last_shown(), "Play next").callback()
check(plugin:getPlaylist().queue[1].uid == "test", "play next moves a song to the top")
next_item.callback()
p = plugin:getPlaylist()
check(opened[#opened]:find("/test@") and #p.queue == 1 and p.now.uid == "test", "next song played")
plugin:onSongbookNextSong()
p = plugin:getPlaylist()
check(opened[#opened]:find("/second@") and #p.queue == 0 and p.now.uid == "second" and p.history[#p.history].uid == "test",
    "next song via gesture")
-- browsing: opening a song doesn't play it; Open now playing goes back
plugin:openSong("test")
plugin.ui.document.file = opened[#opened]
check(plugin:nowPlayingUid() == "second" and song_action("play").text == "Play now"
    and song_action("now_playing").text == "Open now playing: Druhá", "opened song is only shown")
check(playlist_entry("now_playing").enabled_func() and playlist_entry("now_playing").text_func() == "Now playing: Druhá",
    "now playing in the menu")
song_action("now_playing").callback()
check(opened[#opened]:find("/second@"), "open now playing")
plugin.ui.document.file = opened[#opened]
check(song_action("play").text == "Finished" and song_action("now_playing") == nil, "song now playing can be finished")
song_action("play").callback()
check(plugin:getPlaylist().now == nil and not playlist_entry("now_playing").enabled_func()
    and playlist_entry("now_playing").text_func() == "Nothing is playing", "finished")
plugin:onSongbookOpenNowPlaying()
check(notes[#notes] == "No song is playing.", "nothing to open")
-- with "Opening a song plays it" the old behaviour
settings_store.play_on_open = true
plugin:openSong("second")
check(plugin:nowPlayingUid() == "second", "opening plays with play_on_open")
settings_store.play_on_open = nil
plugin:onSongbookNextSong()
check(notes[#notes] == "There is no next song in the playlist.", "no next song left")
plugin:openSong("test")
plugin:deleteSong("second")
plugin:savePlaylist({})

-- long-press "Add to playlist" adds to our own queue, also while sharing
local function hold_dialog(uid)
    plugin:onSongbookShowLocal()
    local list = last_shown()
    for _, item in ipairs(list.item_table) do
        if item.song and item.song.uid == uid then list.onMenuHold(list, item) end
    end
    return last_shown()
end
local hold = hold_dialog("test")
check(hold.buttons[1][1].text == "Play now" and hold.buttons[2][1].text == "Add to playlist", "playlist button while sharing")
hold.buttons[2][1].callback()
check(#plugin:getPlaylist().queue == 1 and plugin:getPlaylist().queue[1].uid == "test"
    and notes[#notes] == "Added to playlist: Žluťoučký kůň", "added from long-press")
hold = hold_dialog("test")
check(hold.buttons[2][1].text == "Remove from playlist", "queued song can be removed from long-press")
hold.buttons[2][1].callback()
check(#plugin:getPlaylist().queue == 0, "removed from long-press")
plugin:savePlaylist({})

-- guests sharing their songs are repositories while they keep polling
local function jam_get_from(target, ip)
    sent = nil
    zmqs[1].receiveCallback("GET " .. target .. " HTTP/1.1\r\n\r\n", { getpeername = function() return ip, 50000 end })
    return sent and sent:match("\r\n\r\n(.*)$")
end
body = jam_get_from("/state.json?name=Eva&share=8770", "10.0.0.7")
check(body:find('"name":"Songbook"', 1, true) and body:find('"peers":[]', 1, true),
    "host name, the asking guest not among the peers: " .. body)
jam_get_from("/state.json?name=Petr&share=8765", "10.0.0.8")
body = jam_get_from("/state.json", "10.0.0.9")
check(body:find('"peers":[{"name":"Eva","url":"http://10.0.0.7:8770/"},{"name":"Petr","url":"http://10.0.0.8:8765/"}]', 1, true),
    "sharing guests listed: " .. body)
local eva
for _i, s in ipairs(plugin:onlineServers()) do if s.url == "http://10.0.0.7:8770/" then eva = s end end
check(eva and eva.jam and eva.name == "Eva" and eva.key == "10.0.0.7-8770", "sharing guest among the repositories")
for _i, s in ipairs(plugin:getServers()) do check(not s.jam, "sharing guest not saved as a repository") end
-- a guest's own song: downloaded once the request is answered, then queued
responses["http://10.0.0.7:8770/songs/r~moje.cho"] = "{title: Evina}\n[C]La"
body = jam_get_from("/queue/add?from=8770&uid=r%2Fmoje&by=Eva", "10.0.0.7")
check(body == '{"ok":true}' and #ticks == 1 and #plugin:getPlaylist().queue == 0, "guest's song requested, downloaded later")
table.remove(ticks, 1)()
local q = plugin:getPlaylist().queue
check(requested[#requested] == "http://10.0.0.7:8770/songs/r~moje.cho" and #q == 1 and q[1].uid == "10.0.0.7-8770/r_moje"
    and q[1].title == "Evina" and q[1].by == "Eva", "guest's song downloaded and queued")
check(plugin:sourceName(q[1].uid) == "Eva", "guest's song comes from the guest")
body = jam_get_from("/queue/add?from=8770&uid=r%2Fmoje", "10.0.0.7")
check(body == '{"error":"queued","ok":false}', "guest's song not requested twice")
body = jam_get_from("/queue/add?from=8770&uid=x", "10.0.0.99")
check(body == '{"error":"missing","ok":false}' and #ticks == 0, "only guests sharing their songs")
clock = clock + 20
check(#plugin:jamServers() == 0, "silent guests leave the repositories")
check(plugin:sourceName(q[1].uid) == "Eva", "source name stays after the guest left")
plugin:deleteSong(q[1].uid)
plugin:savePlaylist({})

jam_menu.sub_item_table[1].callback(tmi)
check(#zmqs == 0 and standby == 0 and not jam_menu.sub_item_table[1].checked_func() and answers.closed, "jam server stopped")
check(hold_dialog("test").buttons[2][1].text == "Add to playlist", "playlist button outside a jam session")

-- following another songbook
local host = "http://10.0.0.2:8765/"
local state_url = host .. "state.json?name=Songbook&share=8765"
responses[state_url] = "S1"
responses[host .. "songs/repo~song-a.cho"] = "{title: Hostova}\n{key: C}\n[C]Hej"
decoded.S1 = { uid = "repo/song-a", rev = "1", transpose = 2, notation = "cz" }
local follow_item = jam_menu.sub_item_table[5]
check(follow_item.text_func() == "Follow another songbook…", "not following")
input_text = " 10.0.0.2 "
local n_opened = #opened
plugin:addToPlaylist("test")
follow_item.callback(tmi)
check(last_shown().ok_text == "Follow", "following asks before replacing our playlist")
last_shown().ok_callback()
-- the songbooks found on the network, and Enter address…
local finder_menu = last_shown()
local search = udp_on(8767)
check(finder_menu.title == "Follow another songbook" and #zmqs == 1 and search and search.broadcast,
    "searching for songbooks")
check(finder_menu.item_table[1].text == "Searching for shared songbooks…" and finder_menu.item_table[2].text == "Enter address…",
    "nothing found yet")
clock = clock + 1
zmqs[1].waitEvent()
check(#search.outbox == 2 and search.outbox[1][1] == "SONGBOOK-DISCOVER 1" and search.outbox[1][2] == "255.255.255.255"
    and search.outbox[2][2] == "192.168.1.255" and search.outbox[2][3] == 8766, "search broadcast")
table.insert(search.inbox, { "SONGBOOK 1 8765 Kindle", "10.0.0.3", 8766 })
table.insert(search.inbox, { "SONGBOOK 9 8765 Future", "10.0.0.4", 8766 })
zmqs[1].waitEvent()
check(#finder_menu.item_table == 2 and finder_menu.item_table[1].text == "Kindle"
    and finder_menu.item_table[1].mandatory == "10.0.0.3", "found songbook listed")
clock = clock + 6
zmqs[1].waitEvent()
check(#finder_menu.item_table == 2 and finder_menu.item_table[1].text == "Searching for shared songbooks…",
    "silent songbook dropped from the list")
finder_menu.item_table[2].callback()
finder_menu:onCloseWidget()
check(#zmqs == 0 and search.closed, "search stopped when the list closes")
check(jam_menu.sub_item_table[1].enabled_func() == true, "sharing possible before following")
find_button(last_shown(), "Follow").callback()
check(#plugin:getPlaylist().queue == 0 and #plugin:getPlaylist().history == 0, "following clears our playlist")
check(follow_item.checked_func() and follow_item.text_func() == "Following 10.0.0.2:8765", "following: " .. follow_item.text_func())
check(settings_store.jam_follow_url == host and standby == 1 and scheduled ~= nil, "follow polling scheduled")
check(jam_menu.text_func() == "Jam session (following)", "jam menu label while following")
check(jam_menu.sub_item_table[1].enabled_func() == false and follow_item.enabled_func() == true,
    "no sharing while following, following can be stopped")
check(requested[#requested] == host .. "songs/repo~song-a.cho"
    and io.open(root .. "/songbook/songs/jam/repo_song-a.cho"):read("*a"):find("Hostova", 1, true), "followed song saved")
check(#opened == n_opened + 1 and opened[#opened]:find("/jam~repo_song%-a@t%+2"), "followed song opened in host key: " .. opened[#opened])
plugin.ui.document.file = opened[#opened]
-- the followed songbook is a repository to browse only while following
local jam_server = plugin:onlineServers()[#plugin:onlineServers()]
check(jam_server and jam_server.jam and jam_server.name == "Jam session" and jam_server.url == host
    and jam_server.key == "10.0.0.2-8765", "followed songbook among the repositories")
for _i, s in ipairs(plugin:getServers()) do check(s.url ~= host, "followed songbook not saved as a repository") end
check(plugin:findServer(jam_server.key) ~= nil and settings_store.jam_servers[host] == "10.0.0.2-8765", "its key is kept")
plugin:browseOnline()
check(last_shown().title == "Jam session", "Browse online lists the followed songbook: " .. tostring(last_shown().title))
plugin:saveServers({ { key = "saved", url = "https://example.com/saved" } })
plugin:browseOnline()
local repo_items = last_shown().item_table
check(#repo_items == 4 and repo_items[2].text == "example.com/saved" and repo_items[2].separator
    and repo_items[3].text == "Jam session" and repo_items[3].select_enabled == false
    and repo_items[4].text == "Jam session" and repo_items[4].callback,
    "jam session's songbooks under their own heading in Browse online")
plugin:saveServers({})
-- Request to play from online lists: the followed songbook gets other songs from us
local web = { key = "saved", url = "https://example.com/saved" }
local function request_button(song, before) return plugin:playlistButton(song, function() end, before) end
local downloads = 0
local function fake_download() downloads = downloads + 1; return false end
check(request_button({ uid = "saved/x", title = "X", server = web }, fake_download).enabled == false,
    "no request of an internet song not on the device")
check(request_button({ uid = "test", title = "Test" }).enabled == true, "request of an own song")
check(request_button({ uid = jam_server.key .. "/x", title = "X", server = plugin:followedServer() }, fake_download).enabled == true,
    "request of the followed songbook's song without download")
local eva_song = { uid = "10.0.0.7-8770/x", title = "X", server = plugin:jamServer("http://10.0.0.7:8770/", "Eva") }
local eva_button = request_button(eva_song, fake_download)
local n_req = #requested
eva_button.callback()
check(eva_button.enabled == true and downloads == 1 and #requested == n_req,
    "another guest's song is downloaded before the request (failed download: no request)")
-- the host's name and its other guests sharing their songs
decoded.S1N = { uid = "repo/song-a", rev = "1", transpose = 2, name = "Kobo",
                peers = { { url = "http://10.0.0.7:8770/", name = "Eva" } } }
responses[state_url] = "S1N"
scheduled()
local names = {}
for _i, s in ipairs(plugin:jamServers()) do names[#names + 1] = s.name .. "=" .. s.url end
check(follow_item.text_func() == "Following Kobo" and table.concat(names, " ") == "Kobo=" .. host .. " Eva=http://10.0.0.7:8770/",
    "followed songbook and its guests as repositories: " .. table.concat(names, " "))
responses[state_url] = "S1"
scheduled()
check(#plugin:jamServers() == 1, "guests gone from the followed songbook are gone here too")
-- our songs are shared on the jam port: the index and song files only
local library = zmqs[#zmqs]
check(library.port == 8765 and library.started, "own songs shared while following")
sent = nil
library.receiveCallback("GET /index.json HTTP/1.1\r\n\r\n", {})
check(sent:find("^HTTP/1.1 200") and sent:find('"uid":"test"', 1, true), "own songs listed")
library.receiveCallback("GET /state.json HTTP/1.1\r\n\r\n", {})
check(sent:find("^HTTP/1.1 404"), "follower's library has no jam state")
local share_item = jam_menu.sub_item_table[6]
check(name_item.enabled_func() == false, "no renaming while following")
share_item.callback(tmi)
check(not share_item.checked_func() and not library.started and zmqs[#zmqs] ~= library, "own songs no longer shared")
responses[host .. "state.json"] = "S1"
scheduled()
check(requested[#requested] == host .. "state.json", "polling without sharing")
share_item.callback(tmi)
check(share_item.checked_func() and zmqs[#zmqs].port == 8765 and zmqs[#zmqs].started, "own songs shared again")
responses[host .. "state.json"] = nil
local fetched = #requested
scheduled()
check(#opened == n_opened + 1 and #requested == fetched + 1, "same state: nothing reopened or downloaded")
decoded.S2 = { uid = "repo/song-a", rev = "2", transpose = 2 }
responses[state_url] = "S2"
scheduled()
check(#opened == n_opened + 1, "other host option change: not reopened")
decoded.S3 = { uid = "repo/song-a", rev = "3", transpose = 0 }
responses[state_url] = "S3"
scheduled()
check(#opened == n_opened + 2 and opened[#opened]:find("@t%+0") and requested[#requested] == state_url,
    "host transposition followed without download")
local jam_song
for _, song in ipairs(plugin:listLocal()) do if song.uid == "jam/repo_song-a" then jam_song = song end end
check(jam_song == nil, "followed song not in my songs")
check(plugin:currentSongId() == "jam/repo_song-a" and song_action("transpose") and not song_action("favorite")
    and not song_action("collections") and not song_action("playlist"),
    "followed song can't be favorited, collected or queued")
-- "Request to play" while following asks the followed songbook
responses[host .. "queue/add?by=Songbook&id=repo_song-a"] = "R1"
decoded.R1 = { ok = true }
plugin:requestFromFollowed({ uid = "jam/repo_song-a", title = "Hostova" })
check(requested[#requested] == host .. "queue/add?by=Songbook&id=repo_song-a" and notes[#notes] == "Requested: Hostova",
    "request sent to followed songbook: " .. requested[#requested])
responses[host .. "queue/add?by=Songbook&from=8765&uid=test"] = "R2"
decoded.R2 = { ok = false, error = "queued" }
hold = hold_dialog("test")
check(hold.buttons[1][1].text == "Play now" and hold.buttons[1][1].enabled == false, "no Play now while following")
hold.buttons[2][1].callback()
check(notes[#notes] == "This song is already requested.", "followed songbook refuses request")
check(plugin:getPlaylist().queue[1] == nil, "request while following does not touch our queue")
-- the playlist shows the followed songbook's
responses[host .. "playlist.json"] = "PL1"
decoded.PL1 = { history = { { uid = "repo/song-a", title = "Hostova", at = 0 } },
                queue = { { uid = "repo/b", title = "Druhá", by = "Eva" }, "junk" } }
check(playlist_menu.text_func() == "Playlist (jam session)", "playlist label while following")
playlist_item.callback()
local remote_pl = last_shown()
check(remote_pl.title == "Playlist of 10.0.0.2:8765" and remote_pl.item_table[4].text == "Up next (1)"
    and remote_pl.item_table[5].text == "Druhá" and remote_pl.item_table[5].mandatory == "Eva"
    and remote_pl.item_table[5].callback == nil and remote_pl.item_table[6].text == "Played (1)",
    "followed songbook's playlist, read-only")
-- requesting from the followed songbook's songs, without those in its playlist
responses[host .. "index.json"] = "IX"
decoded.IX = { songs = { { id = "repo_song-a", title = "Hostova", file = "songs/repo~song-a.cho" },
                         { id = "repo_b", title = "Druhá", file = "songs/repo~b.cho" },
                         { id = "c", title = "Cizí", file = "songs/c.cho" } } }
remote_pl.item_table[1].callback()
local rpick = last_shown()
check(rpick.title == "Request from 10.0.0.2:8765" and #rpick.item_table == 2 and rpick.item_table[2].text == "Cizí",
    "followed songbook's songs not in its playlist")
responses[host .. "queue/add?by=Songbook&id=c"] = "R3"
decoded.R3 = { ok = true }
rpick.item_table[2].callback()
check(requested[#requested - 1] == host .. "queue/add?by=Songbook&id=c" and requested[#requested] == host .. "playlist.json",
    "picked song requested from the followed songbook")
toggle_hidden(rpick)
check(#rpick.item_table == 4 and rpick.item_table[3].text == "Druhá" and rpick.item_table[3].mandatory == "up next"
    and rpick.item_table[4].mandatory == "played", "followed songbook's playlist marked")
local n_requested = #requested
rpick.item_table[3].callback()
check(notes[#notes] == "This song is already requested." and requested[n_requested + 1] ~= host .. "queue/add?by=Songbook&id=repo_b",
    "queued song not requested again")
toggle_hidden(rpick)
check(not playlist_entry("next").enabled_func(), "no next song while following")
local switched = 0
remote_pl.switchItemTable = function(self, t, items) switched = switched + 1; self.item_table = items end
scheduled()
check(switched == 0, "unchanged followed playlist is not redrawn")
decoded.PL2 = { history = {}, queue = {} }
responses[host .. "playlist.json"] = "PL2"
scheduled()
check(switched == 1 and remote_pl.item_table[4].text == "Up next (0)", "followed playlist refreshed on poll")
responses[state_url] = false
for _i = 1, 4 do if scheduled then scheduled() end end
check(not follow_item.checked_func() and standby == 0 and notes[#notes]:find("Lost connection", 1, true), "following stops when host is gone")
-- following again drops songs of the last session, except the open one
io.open(root .. "/songbook/songs/jam/old.cho", "w"):close()
responses[state_url] = false
follow_item.callback(tmi)
finder_menu = last_shown()
settings_store.jam_follow_url = nil
table.insert(udp_on(8767).inbox, { "SONGBOOK 1 8765 Host", "10.0.0.2", 8766 })
clock = clock + 1
zmqs[1].waitEvent()
finder_menu.item_table[1].callback()
finder_menu:onCloseWidget()
check(settings_store.jam_follow_url == host and #zmqs == 1 and zmqs[1].port == 8765, "following a found songbook, sharing our songs")
check(follow_item.checked_func() and not io.open(root .. "/songbook/songs/jam/old.cho")
    and io.open(root .. "/songbook/songs/jam/repo_song-a.cho"), "following again keeps only the open song")
-- browsing our own songs keeps following; new songs are only announced
responses[state_url] = "S3"
scheduled()
plugin:onSongbookTranspose(1)
check(follow_item.checked_func(), "transposing the followed song keeps following")
plugin:onSongbookTranspose(0)
plugin:openSong("test")
plugin.ui.document.file = opened[#opened]
check(follow_item.checked_func() and song_action("now_playing").text == "Open now playing: Hostova"
    and song_action("play") == nil, "browsing while following")
responses[host .. "songs/repo~song-b.cho"] = "{title: Další}\n[C]Hej"
decoded.S4 = { uid = "repo/song-b", rev = "4", transpose = 0 }
responses[state_url] = "S4"
local n_open = #opened
scheduled()
check(#opened == n_open and toasts[#toasts] == "Now playing: Další", "new followed song announced while browsing")
song_action("now_playing").callback()
check(#opened == n_open + 1 and opened[#opened]:find("/jam~repo_song%-b@"), "open the followed song now playing")
plugin.ui.document.file = opened[#opened]
follow_item.callback(tmi)
check(not follow_item.checked_func() and standby == 0, "following stopped from the menu")
for _i, s in ipairs(plugin:onlineServers()) do check(not s.jam, "followed songbook gone from the repositories") end
plugin:deleteSong("jam/repo_song-b")
responses[state_url] = nil
plugin.ui.document.file = opened[n_opened]
plugin:deleteSong("jam/repo_song-a")

-- Song repositories ----------------------------------------------------------

-- no repository yet: browsing asks for one first
input_text = " https://example.com/songs "
plugin:browseOnline()
last_shown().buttons[1][2].callback()
local servers = plugin:getServers()
check(#servers == 1 and servers[1].url == "https://example.com/songs" and servers[1].key == "example.com-songs",
    "first repository added: " .. tostring(servers[1] and servers[1].key))
check(requested[#requested] == "https://example.com/songs/index.json", "plain server url used as is")
local menu = last_shown()
check(menu.title == "Test repo", "single repository list titled by index name: " .. tostring(menu.title))
check(menu.item_table[2].text == "Test", "online list item")
check(menu.item_table[2].mandatory == "", "local song with same id is not 'saved': " .. tostring(menu.item_table[2].mandatory))

-- tap downloads into songs/<key>/ and opens it
menu.page = 1
menu.item_table[2].callback()
check(io.open(root .. "/songbook/songs/example.com-songs/test.cho"), "downloaded into repository folder")
check(plugin:getMap("downloaded")["example.com-songs/test"] == "1", "downloaded map keyed by uid")
check(opened[#opened]:find("/rendered/example.com%-songs~test@t%+0"), "rendered name uses ~: " .. opened[#opened])
plugin.ui.document.file = opened[#opened]
check(plugin:currentSongId() == "example.com-songs/test", "currentSongId returns uid")
plugin:onSongbookTranspose(1)
check(plugin:getMap("transpose")["example.com-songs/test"] == 1, "transpose stored per uid")
check(plugin:getMap("transpose")["test"] == nil, "local song with same id unaffected")
-- the gesture "last song list" opens that list again
plugin:onSongbookLastList()
check(last_shown().title == "Test repo" and last_shown() ~= menu, "last song list opened again")
plugin:closeList()

-- second repository: browsing shows a picker, github url fetched from raw
plugin:addServer("https://github.com/user/songs")
plugin:browseOnline()
local picker = last_shown()
check(#picker.item_table == 3 and picker.item_table[1].text == "All repositories", "repository picker")
picker.item_table[3].callback()
check(requested[#requested] == "https://raw.githubusercontent.com/user/songs/HEAD/index.json",
    "github url -> raw: " .. tostring(requested[#requested]))
plugin:browseOnline()
last_shown().item_table[1].callback()
menu = last_shown()
check(menu.title == "All repositories" and #menu.item_table == 3, "all repositories list")
check(menu.item_table[2].mandatory:find("Test repo", 1, true), "merged list shows repository name")
-- "Download all" (title bar menu) downloads the missing songs of the listed repositories
menu:onLeftButtonTap()
find_button(last_shown(), "Download all (1)").callback()
check(notes[#notes] == "Downloaded: 1, up to date: 1, failed: 0", "download all summary: " .. notes[#notes])
menu:onLeftButtonTap()
check(find_button(last_shown(), "All songs downloaded").enabled == false, "nothing left to download")

-- My songs lists songs from everywhere with their source
local all = plugin:listLocal()
check(#all == 3, "my songs: local + downloaded from both repositories: " .. #all)
local sources = {}
for _, song in ipairs(all) do sources[song.uid] = song.source or "local" end
check(sources["test"] == "local" and sources["example.com-songs/test"] == "Test repo", "my songs sources")

-- long repository names are shortened so the song title stays readable
index_name = "Velmi dlouhý název repozitáře písní"
plugin:showOnlineSongs({ (plugin:findServer("example.com-songs")) })   -- picks up the new name
check(last_shown().item_table[2].mandatory == "saved", "single repository list shows no repository name")
plugin:onSongbookShowLocal()
local long_item
for _, item in ipairs(last_shown().item_table) do
    if item.song and item.song.uid == "example.com-songs/test" then long_item = item end
end
check(long_item and long_item.mandatory == "Velmi dlouh…", "long repository name shortened: " .. tostring(long_item and long_item.mandatory))
index_name = "Test repo"
plugin:showOnlineSongs({ (plugin:findServer("example.com-songs")) })

-- repository list (Settings, or the title bar menu of online lists): add, rename, remove
local repos_item = menu_item("settings").sub_item_table[1]
local setting_names = {}
for _i, item in ipairs(menu_item("settings").sub_item_table) do table.insert(setting_names, item.text or "") end
check(table.concat(setting_names, ", ") == ", Songs folder, Formatting, Scrolling, Quick menu, Opening a song plays it",
    "settings order: " .. table.concat(setting_names, ", "))
check(repos_item.text_func() == "Song repositories (2)", "repositories item label")
repos_item.callback()
local tm = last_shown()
check(tm.title == "Song repositories" and #tm.item_table == 3 and tm.item_table[3].text == "Add repository…",
    "repository list")
input_text = "https://github.com/other/repo/tree/dev"
responses["https://raw.githubusercontent.com/other/repo/dev/index.json"] = false
tm.item_table[3].callback()
last_shown().buttons[1][2].callback()
check(#tm.item_table == 4 and tm.item_table[3].text == "other/repo (dev)", "list refreshed after add")
check(requested[#requested] == "https://raw.githubusercontent.com/other/repo/dev/index.json",
    "added repository's index loaded for its name")
check(notes[#notes]:find("Cannot load song list", 1, true), "failed index reported")
responses["https://raw.githubusercontent.com/other/repo/dev/index.json"] = nil
input_text = "https://example.com/named"
responses["https://example.com/named/index.json"] = "named index"
decoded["named index"] = { name = "Named songs", songs = {} }
tm.item_table[4].callback()
last_shown().buttons[1][2].callback()
check(#tm.item_table == 5 and tm.item_table[4].text == "Named songs", "added repository shows its name at once")
tm.item_table[4].callback()
find_button(last_shown(), "Remove").callback()
find_button(last_shown(), "Remove and delete its songs").callback()
check(#tm.item_table == 4, "named repository removed")
local updated_items = 0
plugin:closeList()
repos_item.callback({ updateItems = function() updated_items = updated_items + 1 end })
tm = last_shown()
tm:onClose()
check(updated_items == 1, "settings item updated when the repository list closes")

tm.item_table[1].callback()
input_text = "Moje písně"
find_button(last_shown(), "Rename").callback()
last_shown().buttons[1][2].callback()
check(tm.item_table[1].text == "Moje písně", "renamed repository")
tm.item_table[1].callback()
input_text = ""
find_button(last_shown(), "Rename").callback()
last_shown().buttons[1][2].callback()
check(tm.item_table[1].text == "Test repo", "empty name falls back to index name")

tm.item_table[1].callback()
find_button(last_shown(), "Remove").callback()
find_button(last_shown(), "Remove and delete its songs").callback()
check(#plugin:getServers() == 2 and #tm.item_table == 3, "repository removed")
check(not io.open(root .. "/songbook/songs/example.com-songs/test.cho"), "its songs deleted")
check(plugin:getMap("downloaded")["example.com-songs/test"] == nil, "downloaded entry removed")
check(plugin:getMap("transpose")["example.com-songs/test"] == nil, "transpose entry removed")
check(io.open(root .. "/songbook/songs/test.cho"), "local song kept")

-- Favorites ---------------------------------------------------------------------
local function item_for(list, uid)
    for _, item in ipairs(list.item_table) do
        if item.song and item.song.uid == uid then return item end
    end
end
local function hold(list, uid)
    list.onMenuHold(list, item_for(list, uid))
    return last_shown()
end

plugin:onSongbookShowFavorites()
check(notes[#notes]:find("No favorites yet", 1, true), "empty favorites message")

plugin:onSongbookShowLocal()
local list = last_shown()
find_button(hold(list, "test"), "Add to favorites").callback()
check(plugin:isFavorite("test"), "favorite added from My songs")
check(item_for(list, "test").text == "★ Žluťoučký kůň", "list refreshed with star: " .. item_for(list, "test").text)
check(item_for(list, "user-songs/test").text == "Downloaded", "other songs without star")

plugin:onSongbookShowFavorites()
list = last_shown()
check(list.title == "Favorites" and #list.item_table == 2 and item_for(list, "test"), "favorites list")
find_button(hold(list, "test"), "Remove from favorites").callback()
check(not plugin:isFavorite("test") and list.item_table[2].text == "No favorites yet", "favorite removed, list refreshed")

-- song dialog and gesture toggle the open song
plugin:openSong("user-songs/test")
check(song_action("favorite").text == "Add to favorites", "favorite action in a song")
song_action("favorite").callback()
check(song_action("favorite").text == "Remove from favorites" and plugin:isFavorite("user-songs/test"),
    "favorite from the song dialog")
plugin:onSongbookToggleFavorite()
check(not plugin:isFavorite("user-songs/test"), "gesture toggles favorite off")
check(song_action("playlist").text == "Add to playlist", "playlist action in a song")
check(song_action("collections").text == "Add to collection", "add to collection action in a song")
-- the dialog puts related actions side by side, with short labels
plugin:showSongDialog()
local rows = {}
for _i, row in ipairs(last_shown().buttons) do
    local texts = {}
    for _j, b in ipairs(row) do table.insert(texts, b.text) end
    table.insert(rows, table.concat(texts, " | "))
end
check(rows[2] == "Start autoscroll | Song length" and rows[3] == "+ Favorites | + Collection | + Playlist"
    and rows[#rows - 1] == "Playlist" and rows[#rows] == "Play now | Next song",
    "song dialog rows: " .. table.concat(rows, " / "))
local saved_playlist = settings_store.playlist
plugin:savePlaylist({})
check(song_action("next").text == "Next song" and song_action("next").enabled == false, "next song disabled with empty Up next")
plugin:addToPlaylist("test")
check(song_action("next").text == "Next song: Žluťoučký kůň" and song_action("next").enabled,
    "next song in the song dialog: " .. song_action("next").text)
plugin:showSongDialog()
local last_row = last_shown().buttons[#last_shown().buttons]
check(last_row[2].text == "Next: Žluťoučký kůň", "short next song label: " .. tostring(last_row[2].text))
local n_opened = #opened
song_action("next").callback()
check(#opened == n_opened + 1 and opened[#opened]:find("/test@") and plugin:getPlaylist().now.uid == "test",
    "next song from the song dialog plays it")
local n_shown = #shown
song_action("show_playlist").callback()
check(#shown == n_shown + 1 and last_shown().item_table, "playlist from the song dialog")
plugin:closeList()
settings_store.playlist = saved_playlist
plugin:openSong("user-songs/test")

-- online list: favoriting a song that isn't on the device downloads it first
plugin:deleteSong("other-repo-dev/test")
plugin:showOnlineSongs({ (plugin:findServer("other-repo-dev")) })
list = last_shown()
find_button(hold(list, "other-repo-dev/test"), "Add to favorites").callback()
check(io.open(root .. "/songbook/songs/other-repo-dev/test.cho") and plugin:isFavorite("other-repo-dev/test"),
    "online favorite downloads the song")
check(item_for(list, "other-repo-dev/test").text == "★ Test", "online list refreshed with star")
plugin:deleteSong("other-repo-dev/test")
check(not plugin:isFavorite("other-repo-dev/test"), "deleting a song removes the favorite")

-- Collections -------------------------------------------------------------------
local function texts(dialog)
    local t = {}
    for _, row in ipairs(dialog.buttons) do
        for _, b in ipairs(row) do t[#t + 1] = b.text end
    end
    return table.concat(t, "|")
end

plugin:onSongbookShowCollections()
local picker = last_shown()
check(picker.title == "Collections" and #picker.item_table == 1 and picker.item_table[1].text == "New collection…",
    "empty collections list")
input_text = " Táborák "
picker.item_table[1].callback()
last_shown().buttons[1][2].callback()
check(#picker.item_table == 2 and picker.item_table[1].text == "Táborák" and picker.item_table[1].mandatory == "0",
    "collection created, list refreshed")
picker.item_table[2].callback()
last_shown().buttons[1][2].callback()
check(notes[#notes]:find("already exists", 1, true) and #plugin:getCollections() == 1, "duplicate name rejected")

-- add a song from My songs, and create a second collection from the song dialog
plugin:onSongbookShowLocal()
list = last_shown()
find_button(hold(list, "test"), "Collections…").callback()
find_button(last_shown(), "Táborák").callback()
check(plugin:isInCollection("Táborák", "test"), "song added to collection")
check(texts(last_shown()) == "✓ Táborák|New collection…|Close", "dialog reopened with check: " .. texts(last_shown()))
input_text = "Vánoce"
find_button(last_shown(), "New collection…").callback()
last_shown().buttons[1][2].callback()
check(plugin:isInCollection("Vánoce", "test"), "new collection from song dialog contains the song")
check(texts(last_shown()) == "✓ Táborák|✓ Vánoce|New collection…|Close", "collections sorted by name")
find_button(last_shown(), "✓ Vánoce").callback()
check(not plugin:isInCollection("Vánoce", "test"), "song removed from collection")

-- open a collection from the list
plugin:onSongbookShowCollections()
picker = last_shown()
picker.item_table[1].callback()
list = last_shown()
check(list.title == "Táborák" and #list.item_table == 2 and item_for(list, "test"), "collection song list")
plugin:showCollection("Vánoce")
local empty_list = last_shown()
check(notes[#notes]:find("Long-press a song", 1, true) and empty_list.item_table[2].text == "This collection is empty",
    "empty collection message")
-- "Add songs…" picks songs into the collection, and the collection list shows them
empty_list.item_table[3].callback()
local coll_picker = last_shown()
check(coll_picker.title == 'Add to "Vánoce"', "collection picker")
item_for(coll_picker, "test").callback()
check(plugin:isInCollection("Vánoce", "test") and item_for(coll_picker, "test").mandatory:find("✓", 1, true),
    "song picked into the collection")
coll_picker:onClose()
check(item_for(empty_list, "test"), "collection list refreshed after picking")
find_button(hold(empty_list, "test"), 'Remove from "Vánoce"').callback()
check(not plugin:isInCollection("Vánoce", "test") and not item_for(empty_list, "test"), "song removed from this collection")

-- rename and delete
plugin:onSongbookShowCollections()
picker = last_shown()
picker.onMenuHold(picker, picker.item_table[1])
input_text = "Vánoce"
find_button(last_shown(), "Rename").callback()
last_shown().buttons[1][2].callback()
check(notes[#notes]:find("already exists", 1, true), "rename to existing name rejected")
picker.onMenuHold(picker, picker.item_table[1])
input_text = "Oheň"
find_button(last_shown(), "Rename").callback()
last_shown().buttons[1][2].callback()
check(picker.item_table[1].text == "Oheň" and plugin:isInCollection("Oheň", "test"), "collection renamed, songs kept")
picker.onMenuHold(picker, picker.item_table[2])
find_button(last_shown(), "Delete").callback()
last_shown().ok_callback()
check(#plugin:getCollections() == 1 and #picker.item_table == 2, "collection deleted")

-- song dialog: add the open song to a collection
plugin:openSong("user-songs/test")
song_action("collections").callback()
check(last_shown().title == "Collections: Downloaded", "collections dialog for open song: " .. tostring(last_shown().title))
find_button(last_shown(), "Oheň").callback()
check(plugin:isInCollection("Oheň", "user-songs/test"), "open song added to collection")

-- online list: adding to a collection downloads first; deleting removes it
plugin:showOnlineSongs({ (plugin:findServer("other-repo-dev")) })
list = last_shown()
find_button(hold(list, "other-repo-dev/test"), "Collections…").callback()
find_button(last_shown(), "Oheň").callback()
check(io.open(root .. "/songbook/songs/other-repo-dev/test.cho") and plugin:isInCollection("Oheň", "other-repo-dev/test"),
    "online song downloaded and added to collection")
plugin:deleteSong("other-repo-dev/test")
check(not plugin:isInCollection("Oheň", "other-repo-dev/test"), "deleting a song removes it from collections")

-- lists open over the Songbook menu; opening a song closes them and the menu
check(menu_item("my_songs").keep_menu_open and menu_item("favorites").keep_menu_open
    and menu_item("collections_list").keep_menu_open and menu_item("online").keep_menu_open
    and playlist_entry("show_playlist").keep_menu_open, "lists keep the songbook menu open")
local UIManager = require("ui/uimanager")
local closed, menu_closed = {}, false
local old_close = UIManager.close
UIManager.close = function(_, w) closed[w] = true end
plugin.ui.menu.onCloseReaderMenu = function() menu_closed = true end
plugin:createCollection("Večer")
plugin:setInCollection("Večer", "test", true)
plugin:onSongbookShowCollections()
local coll_menu = last_shown()
for _, item in ipairs(coll_menu.item_table) do if item.collection == "Večer" then item.callback() end end
local coll_list = last_shown()
check(coll_list ~= coll_menu and not closed[coll_menu] and coll_list.item_table[2].text == "Žluťoučký kůň",
    "collection list opens over the collections")
plugin:setInCollection("Večer", "test", false)
coll_list:onClose()
local count
for _, item in ipairs(coll_menu.item_table) do if item.collection == "Večer" then count = item.mandatory end end
check(count == "0", "collection counts refreshed when the list is closed: " .. tostring(count))
plugin:setInCollection("Večer", "test", true)
for _, item in ipairs(coll_menu.item_table) do if item.collection == "Večer" then item.callback() end end
coll_list = last_shown()
coll_list.item_table[2].callback()
check(closed[coll_list] and closed[coll_menu] and menu_closed, "opening a song closes lists and menu")
UIManager.close = old_close
plugin.ui.menu.onCloseReaderMenu = nil

os.execute("rm -rf '" .. root .. "'")
print(("%d passed, %d failed"):format(passed, failed))
os.exit(failed == 0 and 0 or 1)
