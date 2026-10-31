-- Smoke test of main.lua against stubbed KOReader modules.
-- Run from the repo root:  luajit tests/smoke.lua
package.path = "songbook.koplugin/?.lua;" .. package.path

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
stub("device", { screen = { getWidth = function() return 600 end, getHeight = function() return 800 end } })
stub("ui/widget/container/widgetcontainer", class())
stub("ui/widget/infomessage", class({ init = function(self) table.insert(notes, self.text) end }))
stub("ui/widget/buttondialog", class())
stub("ui/widget/confirmbox", class())
stub("ui/widget/inputdialog", class())
stub("ui/widget/spinwidget", class())
stub("ui/widget/menu", class({ switchItemTable = function(self, t, items) self.item_table = items end }))
stub("ui/network/manager", { runWhenOnline = function(_, cb) cb() end })
stub("ui/uimanager", { show = function(_, w) table.insert(shown, w) end, close = function() end, forceRePaint = function() end })
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
        flush = function() end,
    }
end })
stub("docsettings", { open = function() return { purge = function() end } end })
stub("json", { decode = function()
    return { songs = { { id = "test", title = "Test", file = "songs/test.cho", updated = "1" } } }
end })
stub("socket", { skip = function(n, ...) return select(n + 1, ...) end })
stub("ltn12", { sink = { table = function(t) return t end } })
stub("socketutil", { set_timeout = function() end, reset_timeout = function() end })
stub("socket.http", { request = function(req)
    table.insert(req.sink, "{}")
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
check(items.songbook and #items.songbook.sub_item_table == 4, "menu built")
check(items.songbook.sub_item_table[3].enabled_func() == false, "transpose disabled outside a song")

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
check(items.songbook.sub_item_table[3].enabled_func() == true, "transpose enabled in a song")
plugin:onSongbookTranspose(1)
plugin:onSongbookTranspose(1)
check(opened[#opened]:find("test@t%+2"), "transposed render path")
check(io.open(opened[#opened]):read("*a"):find('<span class="c">D', 1, true), "chords transposed to D")
check(items.songbook.sub_item_table[3].text_func() == "Transpose (+2)", "transpose label")
plugin:onSongbookTranspose(0)
check(opened[#opened]:find("test@t%+0"), "reset transposition")

-- online list builds items
plugin:set("server_url", "https://example.com/songs")
plugin:browseOnline()
local menu = shown[#shown]
check(menu.item_table and menu.item_table[2].text == "Test", "online list item")
check(menu.item_table[2].mandatory == "update", "file present but not from server -> update: " .. tostring(menu.item_table[2].mandatory))

os.execute("rm -rf '" .. root .. "'")
print(("%d passed, %d failed"):format(passed, failed))
os.exit(failed == 0 and 0 or 1)
