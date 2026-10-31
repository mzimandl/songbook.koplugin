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

stub("gettext", function(s) return s end)
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
stub("ui/widget/menu", class({ switchItemTable = function(self, t, items) self.item_table = items end }))
stub("ui/network/manager", { runWhenOnline = function(_, cb) cb() end, runWhenConnected = function(_, cb) cb() end })
local zmqs, standby, scheduled = {}, 0, nil
stub("ui/uimanager", {
    show = function(_, w) table.insert(shown, w) end, close = function() end, forceRePaint = function() end,
    insertZMQ = function(_, z) table.insert(zmqs, z); return z end,
    removeZMQ = function(_, z) for i = #zmqs, 1, -1 do if zmqs[i] == z then table.remove(zmqs, i) end end end,
    preventStandby = function() standby = standby + 1 end,
    scheduleIn = function(_, _s, f) scheduled = f end,
    unschedule = function(_, f) if scheduled == f then scheduled = nil end end,
    allowStandby = function() standby = standby - 1 end,
    isWidgetShown = function() return true end,
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
stub("docsettings", { open = function() return { purge = function() end } end })
local index_name = "Test repo"
local decoded = {}   -- body -> table, for bodies other than the index
stub("json", { decode = function(body)
    if decoded[body] then return decoded[body] end
    return { name = index_name, songs = { { id = "test", title = "Test", file = "songs/test.cho", updated = "1" } } }
end })
stub("socket", { skip = function(n, ...) return select(n + 1, ...) end, udp = function()
    return { setpeername = function() end, getsockname = function() return "192.168.1.5" end, close = function() end }
end })
stub("ltn12", { sink = { table = function(t) return t end } })
stub("socketutil", { set_timeout = function() end, reset_timeout = function() end })
local requested, responses = {}, {}   -- responses[url] = body, or false for 404
stub("socket.http", { request = function(req)
    table.insert(requested, req.url)
    if responses[req.url] == false then return 1, 404, {}, "HTTP/1.1 404 Not Found" end
    table.insert(req.sink, responses[req.url] or "{title: Downloaded}\n[Am]La")
    return 1, 200, {}, "HTTP/1.1 200 OK"
end })
stub("apps/reader/readerui", { showReader = function(_, path) table.insert(opened, path) end })

local passed, failed = 0, 0
local function check(cond, name)
    if cond then passed = passed + 1 else failed = failed + 1; print("FAIL " .. name) end
end

local registered
local Songbook = require("main")
local plugin = Songbook:new{ ui = { menu = { registerToMainMenu = function(_, p) registered = p end } } }
check(registered == plugin, "registered to main menu")

local items = {}
plugin:addToMainMenu(items)
check(items.songbook and #items.songbook.sub_item_table == 9, "menu built")
check(items.songbook.sub_item_table[5].enabled_func() == false, "transpose disabled outside a song")

-- empty library
plugin:onSongbookShowLocal()
check(notes[#notes]:find("No songs yet", 1, true), "empty library message")

-- add a song and open it
local f = io.open(root .. "/songbook/songs/test.cho", "w")
f:write("{title: Žluťoučký kůň}\n{artist: Lidová}\n{key: C}\n[C]Jede [G]kůň\n")
f:close()
local songs = plugin:listLocal()
check(#songs == 1 and songs[1].title == "Žluťoučký kůň", "listLocal reads meta")

plugin:openSong("test")
check(#opened == 1 and opened[1]:find("/rendered/test@t%+0%.cz%.w42%.c1%.r0%.html$"), "rendered path " .. tostring(opened[1]))
local html = io.open(opened[1]):read("*a")
check(html:find("Jede kůň", 1, true), "rendered lyrics")

-- simulate reader with that file open, transpose up twice
plugin.ui.document = { file = opened[1] }
plugin.ui.switchDocument = function(_, p) table.insert(opened, p); plugin.ui.document.file = p end
check(plugin:currentSongId() == "test", "currentSongId")
check(items.songbook.sub_item_table[5].enabled_func() == true, "transpose enabled in a song")
plugin:onSongbookTranspose(1)
plugin:onSongbookTranspose(1)
check(opened[#opened]:find("test@t%+2"), "transposed render path")
check(io.open(opened[#opened]):read("*a"):find('<span class="c">D', 1, true), "chords transposed to D")
check(items.songbook.sub_item_table[5].text_func() == "Transpose (+2)", "transpose label")
plugin:onSongbookTranspose(0)
check(opened[#opened]:find("test@t%+0"), "reset transposition")

local InputDialog = require("ui/widget/inputdialog")
InputDialog.onShowKeyboard = function() end
local input_text
InputDialog.getInputText = function() return input_text end
local function last_shown() return shown[#shown] end
local function find_button(dialog, text)
    for _, row in ipairs(dialog.buttons) do
        for _, b in ipairs(row) do
            if b.text == text then return b end
        end
    end
end

-- Jam session ------------------------------------------------------------------
local jam_menu = items.songbook.sub_item_table[8]
local tmi = { updateItems = function() end }
check(jam_menu.text_func() == "Jam session" and not jam_menu.sub_item_table[1].checked_func(), "jam off by default")
check(jam_menu.sub_item_table[2].enabled_func() == false, "no address while not sharing")
jam_menu.sub_item_table[1].callback(tmi)
check(#zmqs == 1 and zmqs[1].port == 8765 and standby == 1, "jam server started")
check(jam_menu.text_func() == "Jam session (sharing)", "jam menu label while sharing")
check(jam_menu.sub_item_table[2].text_func() == "Address: http://192.168.1.5:8765/", "jam address")
check(jam_menu.sub_item_table[3].enabled_func() == false, "port locked while sharing")
local function jam_get(target)
    sent = nil
    check(zmqs[1].receiveCallback("GET " .. target .. " HTTP/1.1\r\n\r\n", {}) == nil, "jam callback returns nothing")
    return sent and sent:match("^HTTP/1.1 (%d+)"), sent and sent:match("\r\n\r\n(.*)$")
end
local code, body = jam_get("/state.json")
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
-- reader closed: the last song stays shared
local doc = plugin.ui.document
plugin.ui.document = nil
code, body = jam_get("/state.json")
check(body:find('"uid":"test"', 1, true), "last song shared after reader closed")
plugin.ui.document = doc

-- the host's songs as a repository
code, body = jam_get("/index.json")
check(code == "200" and body:find('"file":"songs/test.cho"', 1, true) and body:find('"key":"C"', 1, true), "jam index: " .. tostring(body))
code, body = jam_get("/songs/test.cho")
check(code == "200" and body:find("Jede", 1, true), "jam song file")
code = jam_get("/songs/..~settings~x.cho")
check(code == "404", "jam song file outside songs/")

-- playlist: played songs and guests' requests
local playlist_item = jam_menu.sub_item_table[4]
local p = plugin:getPlaylist()
check(#p.history == 1 and p.history[1].uid == "test" and #p.queue == 0, "played while sharing, transposing not repeated")
check(playlist_item.text_func() == "Playlist", "playlist label")
code, body = jam_get("/queue/add?uid=test&by=%20Pavel%0A")
check(body == '{"ok":true}' and notes[#notes] == "Song request: Žluťoučký kůň (Pavel)", "request added: " .. tostring(body))
code, body = jam_get("/queue/add?uid=test")
check(body == '{"error":"queued","ok":false}', "duplicate request: " .. tostring(body))
code, body = jam_get("/queue/add?uid=nope")
check(body == '{"error":"missing","ok":false}', "request of a missing song")
code, body = jam_get("/playlist.json")
check(body:find('"queue":[{"artist":"Lidová","at":', 1, true) and body:find('"by":"Pavel"', 1, true), "playlist json: " .. tostring(body))
check(playlist_item.text_func() == "Playlist (1 requested)", "playlist label with requests")
playlist_item.callback()
local pl_menu = last_shown()
check(pl_menu.title == "Playlist" and pl_menu.item_table[3].text == "Up next (1)", "playlist menu")
local queued_item
for _, item in ipairs(pl_menu.item_table) do if item.queued then queued_item = item end end
check(queued_item and queued_item.text == "Žluťoučký kůň" and queued_item.mandatory == "Pavel", "queued song in playlist menu")
queued_item.callback()
p = plugin:getPlaylist()
check(#p.queue == 0 and #p.history == 1, "playing a requested song removes it from the queue")
input_text = "Jam test"
pl_menu.item_table[1].callback()
find_button(last_shown(), "Save").callback()
check(plugin:isInCollection("Jam test", "test"), "played songs saved as collection")
pl_menu.item_table[2].callback()
last_shown().ok_callback()
p = plugin:getPlaylist()
check(#p.history == 0 and #p.queue == 0, "playlist cleared")
plugin:deleteCollection("Jam test")

-- long-press "Request to play" while sharing adds to our own queue
local function hold_dialog(uid)
    plugin:onSongbookShowLocal()
    local list = last_shown()
    for _, item in ipairs(list.item_table) do
        if item.song and item.song.uid == uid then list.onMenuHold(list, item) end
    end
    return last_shown()
end
local hold = hold_dialog("test")
check(hold.buttons[1][1].text == "Request to play", "request button while sharing")
hold.buttons[1][1].callback()
check(#plugin:getPlaylist().queue == 1 and plugin:getPlaylist().queue[1].uid == "test", "request from long-press")
hold_dialog("test").buttons[1][1].callback()
check(notes[#notes] == "This song is already requested.", "long-press request duplicate")
plugin:savePlaylist({})

jam_menu.sub_item_table[1].callback(tmi)
check(#zmqs == 0 and standby == 0 and not jam_menu.sub_item_table[1].checked_func(), "jam server stopped")
check(hold_dialog("test").buttons[1][1].text ~= "Request to play", "no request button outside a jam session")

-- following another songbook
local host = "http://10.0.0.2:8765/"
responses[host .. "state.json"] = "S1"
responses[host .. "song.cho"] = "{title: Hostova}\n{key: C}\n[C]Hej"
decoded.S1 = { uid = "repo/song-a", rev = "1", transpose = 2, notation = "cz" }
local follow_item = jam_menu.sub_item_table[5]
check(follow_item.text_func() == "Follow another songbook…" and jam_menu.sub_item_table[6].enabled_func() == false, "not following")
input_text = " 10.0.0.2 "
local n_opened = #opened
follow_item.callback(tmi)
find_button(last_shown(), "Follow").callback()
check(follow_item.checked_func() and follow_item.text_func() == "Following 10.0.0.2:8765", "following: " .. follow_item.text_func())
check(settings_store.jam_follow_url == host and standby == 1 and scheduled ~= nil, "follow polling scheduled")
check(jam_menu.text_func() == "Jam session (following)", "jam menu label while following")
check(io.open(root .. "/songbook/songs/jam/repo_song-a.cho"), "followed song saved")
check(#opened == n_opened + 1 and opened[#opened]:find("/jam~repo_song%-a@t%+2"), "followed song opened in host key: " .. opened[#opened])
plugin.ui.document.file = opened[#opened]
local fetched = #requested
scheduled()
check(#opened == n_opened + 1 and #requested == fetched + 1, "same state: nothing reopened or downloaded")
decoded.S2 = { uid = "repo/song-a", rev = "2", transpose = 2 }
responses[host .. "state.json"] = "S2"
scheduled()
check(#opened == n_opened + 1, "other host option change: not reopened")
decoded.S3 = { uid = "repo/song-a", rev = "3", transpose = 0 }
responses[host .. "state.json"] = "S3"
scheduled()
check(#opened == n_opened + 2 and opened[#opened]:find("@t%+0") and requested[#requested] == host .. "state.json",
    "host transposition followed without download")
local jam_song
for _, song in ipairs(plugin:listLocal()) do if song.uid == "jam/repo_song-a" then jam_song = song end end
check(jam_song == nil, "followed song not in my songs")
check(plugin:currentSongId() == "jam/repo_song-a" and not items.songbook.sub_item_table[6].enabled_func()
    and not items.songbook.sub_item_table[7].enabled_func(), "followed song can't be favorited or collected")
-- "Request to play" while following asks the followed songbook
responses[host .. "queue/add?id=repo_song-a"] = "R1"
decoded.R1 = { ok = true }
plugin:requestFromFollowed({ uid = "jam/repo_song-a", title = "Hostova" })
check(requested[#requested] == host .. "queue/add?id=repo_song-a" and notes[#notes] == "Requested: Hostova",
    "request sent to followed songbook: " .. requested[#requested])
responses[host .. "queue/add?id=test"] = "R2"
decoded.R2 = { ok = false, error = "queued" }
hold_dialog("test").buttons[1][1].callback()
check(notes[#notes] == "This song is already requested.", "followed songbook refuses request")
check(plugin:getPlaylist().queue[1] == nil, "request while following does not touch our queue")
-- the playlist shows the followed songbook's
responses[host .. "playlist.json"] = "PL1"
decoded.PL1 = { history = { { uid = "repo/song-a", title = "Hostova", at = 0 } },
                queue = { { uid = "repo/b", title = "Druhá", by = "Eva" }, "junk" } }
check(jam_menu.sub_item_table[4].text_func() == "Playlist of the jam session", "playlist label while following")
jam_menu.sub_item_table[4].callback()
local remote_pl = last_shown()
check(remote_pl.title == "Playlist of 10.0.0.2:8765" and remote_pl.item_table[1].text == "Up next (1)"
    and remote_pl.item_table[2].text == "Druhá" and remote_pl.item_table[2].mandatory == "Eva"
    and remote_pl.item_table[2].callback == nil and remote_pl.item_table[3].text == "Played (1)",
    "followed songbook's playlist, read-only")
local switched = 0
remote_pl.switchItemTable = function(self, t, items) switched = switched + 1; self.item_table = items end
scheduled()
check(switched == 0, "unchanged followed playlist is not redrawn")
decoded.PL2 = { history = {}, queue = {} }
responses[host .. "playlist.json"] = "PL2"
scheduled()
check(switched == 1 and remote_pl.item_table[1].text == "Up next (0)", "followed playlist refreshed on poll")
responses[host .. "state.json"] = false
for _i = 1, 4 do if scheduled then scheduled() end end
check(not follow_item.checked_func() and standby == 0 and notes[#notes]:find("Lost connection", 1, true), "following stops when host is gone")
-- opening a song of our own stops following
responses[host .. "state.json"] = "S3"
follow_item.callback(tmi)
find_button(last_shown(), "Follow").callback()
check(follow_item.checked_func() and io.open(root .. "/songbook/songs/jam/repo_song-a.cho"), "following again")
plugin:onSongbookTranspose(1)
check(follow_item.checked_func(), "transposing the followed song keeps following")
plugin:onSongbookTranspose(0)
plugin:openSong("test")
check(not follow_item.checked_func() and standby == 0 and notes[#notes] == "Stopped following the jam session.",
    "opening our own song stops following")
responses[host .. "state.json"] = nil
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
menu.item_table[2].callback()
check(io.open(root .. "/songbook/songs/example.com-songs/test.cho"), "downloaded into repository folder")
check(plugin:getMap("downloaded")["example.com-songs/test"] == "1", "downloaded map keyed by uid")
check(opened[#opened]:find("/rendered/example.com%-songs~test@t%+0"), "rendered name uses ~: " .. opened[#opened])
plugin.ui.document.file = opened[#opened]
check(plugin:currentSongId() == "example.com-songs/test", "currentSongId returns uid")
plugin:onSongbookTranspose(1)
check(plugin:getMap("transpose")["example.com-songs/test"] == 1, "transpose stored per uid")
check(plugin:getMap("transpose")["test"] == nil, "local song with same id unaffected")

-- second repository: browsing shows a picker, github url fetched from raw
plugin:addServer("https://github.com/user/songs")
plugin:browseOnline()
local picker = last_shown()
check(#picker.item_table == 3 and picker.item_table[3].text == "All repositories", "repository picker")
picker.item_table[2].callback()
check(requested[#requested] == "https://raw.githubusercontent.com/user/songs/HEAD/index.json",
    "github url -> raw: " .. tostring(requested[#requested]))
plugin:browseOnline()
last_shown().item_table[3].callback()
menu = last_shown()
check(menu.title == "All repositories" and #menu.item_table == 3, "all repositories list")
check(menu.item_table[2].mandatory:find("Test repo", 1, true), "merged list shows repository name")

-- My songs lists songs from everywhere with their source
local all = plugin:listLocal()
check(#all == 2, "my songs: local + downloaded: " .. #all)
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

-- settings submenu: add, rename, remove
local repos_item = items.songbook.sub_item_table[9].sub_item_table[1]
check(repos_item.text_func() == "Song repositories (2)", "repositories item label")
local tm = { updateItems = function() end }
tm.item_table = repos_item.sub_item_table_func()
check(#tm.item_table == 3 and tm.item_table[3].text == "Add repository…", "repositories submenu")
input_text = "https://github.com/other/repo/tree/dev"
tm.item_table[3].callback(tm)
last_shown().buttons[1][2].callback()
check(#tm.item_table == 4 and tm.item_table[3].text_func() == "other/repo (dev)", "submenu refreshed after add")

tm.item_table[1].callback(tm)
input_text = "Moje písně"
find_button(last_shown(), "Rename").callback()
last_shown().buttons[1][2].callback()
check(tm.item_table[1].text_func() == "Moje písně", "renamed repository")
tm.item_table[1].callback(tm)
input_text = ""
find_button(last_shown(), "Rename").callback()
last_shown().buttons[1][2].callback()
check(tm.item_table[1].text_func() == "Test repo", "empty name falls back to index name")

tm.item_table[1].callback(tm)
find_button(last_shown(), "Remove").callback()
find_button(last_shown(), "Remove and delete its songs").callback()
check(#plugin:getServers() == 2 and #tm.item_table == 3, "repository removed")
check(not io.open(root .. "/songbook/songs/example.com-songs/test.cho"), "its songs deleted")
check(plugin:getMap("downloaded")["example.com-songs/test"] == nil, "downloaded entry removed")
check(plugin:getMap("transpose")["example.com-songs/test"] == nil, "transpose entry removed")
check(io.open(root .. "/songbook/songs/test.cho"), "local song kept")

-- "Download all songs" keeps the menu open and reports per repository
local download_all
for _, item in ipairs(items.songbook.sub_item_table[9].sub_item_table) do
    if item.text == "Download all songs" then download_all = item end
end
check(download_all and download_all.keep_menu_open, "download all keeps menu open")
download_all.callback()
check(notes[#notes]:find("Downloaded: 1", 1, true) and select(2, notes[#notes]:gsub("Downloaded:", "")) == 2,
    "download all summary per repository: " .. notes[#notes])

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
check(not plugin:isFavorite("test") and list.item_table[2].text == "No songs", "favorite removed, list refreshed")

-- reader menu item and gesture toggle the open song
local fav_item = items.songbook.sub_item_table[6]
plugin:openSong("user-songs/test")
check(fav_item.enabled_func() and not fav_item.checked_func(), "favorite item enabled in a song")
fav_item.callback()
check(fav_item.checked_func() and plugin:isFavorite("user-songs/test"), "favorite from reader menu")
plugin:onSongbookToggleFavorite()
check(not plugin:isFavorite("user-songs/test"), "gesture toggles favorite off")

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
check(notes[#notes]:find("This collection is empty", 1, true), "empty collection message")

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

-- reader menu: add the open song to a collection
local coll_item = items.songbook.sub_item_table[7]
plugin:openSong("user-songs/test")
check(coll_item.enabled_func() and coll_item.keep_menu_open, "add to collection enabled in a song")
coll_item.callback()
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

-- Migration from the single server_url setting --------------------------------
os.execute("rm -rf '" .. root .. "'")
root = root .. "-migrate"
os.execute("mkdir -p '" .. root .. "/settings' '" .. root .. "/songbook/songs' '" .. root .. "/songbook/rendered'")
for _, name in ipairs({ "old", "mine" }) do
    local fh = io.open(root .. "/songbook/songs/" .. name .. ".cho", "w")
    fh:write("{title: " .. name .. "}\n")
    fh:close()
end
io.open(root .. "/songbook/rendered/old@t+2.cz.w42.c1.r0.html", "w"):close()
for k in pairs(settings_store) do settings_store[k] = nil end
settings_store.server_url = "https://github.com/user/songs"
settings_store.downloaded = { old = "abc" }
settings_store.transpose = { old = 2, mine = 1 }
local migrated = Songbook:new{ ui = { menu = { registerToMainMenu = function() end } } }
servers = migrated:getServers()
check(#servers == 1 and servers[1].key == "user-songs" and servers[1].url == "https://github.com/user/songs",
    "migrated server_url to servers")
check(settings_store.server_url == nil, "server_url removed")
check(io.open(root .. "/songbook/songs/user-songs/old.cho") and not io.open(root .. "/songbook/songs/old.cho"),
    "downloaded song moved to repository folder")
check(io.open(root .. "/songbook/songs/mine.cho"), "local song stays")
check(settings_store.downloaded["user-songs/old"] == "abc" and settings_store.downloaded.old == nil, "downloaded map migrated")
check(settings_store.transpose["user-songs/old"] == 2 and settings_store.transpose.mine == 1, "transpose map migrated")
check(not io.open(root .. "/songbook/rendered/old@t+2.cz.w42.c1.r0.html"), "old renders removed")

settings_store.server_url = ""
settings_store.servers = nil
migrated = Songbook:new{ ui = { menu = { registerToMainMenu = function() end } } }
check(#migrated:getServers() == 0 and settings_store.server_url == nil, "empty server_url migrates to no servers")

os.execute("rm -rf '" .. root .. "'")
print(("%d passed, %d failed"):format(passed, failed))
os.exit(failed == 0 and 0 or 1)
