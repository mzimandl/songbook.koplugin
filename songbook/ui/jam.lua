--[[--
Jam session: sharing the song now playing (web server, UDP answers), following
another songbook, finding shared songbooks and the Jam session menu.
]]

local C = require("songbook/ui/common")
local Discovery = require("songbook/discovery")
local Jam = require("songbook/jam")
local Render = require("songbook/render")
local Repo = require("songbook/repo")

local Device = require("device")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local NetworkMgr = require("ui/network/manager")
local Notification = require("ui/widget/notification")
local Screen = Device.screen
local SpinWidget = require("ui/widget/spinwidget")
local UIManager = require("ui/uimanager")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local util = require("util")

local Songbook = C.Songbook
local _, T = C._, C.T
local DEFAULTS = C.DEFAULTS
local JAM_KEY = C.JAM_KEY
local FOLLOW_TIMEOUT = C.FOLLOW_TIMEOUT
local jam = C.jam
local read_file = C.read_file
local song_meta = C.song_meta
local write_file = C.write_file
local notify = C.notify
local split_uid = C.split_uid
local make_uid = C.make_uid
local now = C.now
local song_file_id = C.song_file_id
local list_menu = C.list_menu
local follow_name = C.follow_name

local FOLLOW_INTERVAL = 4         -- seconds between polls
local FOLLOW_MAX_FAILURES = 4
local SEARCH_INTERVAL = 1         -- seconds between searches for shared songbooks
local SEARCH_EXPIRE = 5           -- seconds: songbooks not heard of leave the list
-- seconds: a following songbook that stopped polling leaves the shared sources
local PEER_EXPIRE = 3 * FOLLOW_INTERVAL + 3

-- Jam session -------------------------------------------------------------------
--
-- Shares the song now playing as a web page on the local network (see
-- songbook/jam.lua); songs that are only open are not shared.

-- Address of the network interface used for outgoing traffic; connecting a UDP
-- socket sends nothing. Without a default route (a Wi-Fi without internet, e.g.
-- a travel router) there is no such interface: then the address of a network
-- interface, from KOReader's ffi/netinfo (getifaddrs; missing on older KOReaders).
local function local_ip()
    local ok, ip = pcall(function()
        local udp = require("socket").udp()
        udp:setpeername("8.8.8.8", 80)
        local addr = udp:getsockname()
        udp:close()
        return addr
    end)
    if ok and ip and ip ~= "0.0.0.0" then return ip end
    ok, ip = pcall(function()
        local ni = require("ffi/netinfo"):new()
        local got, ifaces = pcall(ni.retrieve, ni)
        ni:free()
        if not got then error(ifaces) end
        return Discovery.pick_ip(ifaces)
    end)
    if ok then return ip end
    logger.warn("Songbook: no local address", ip)
end

-- Kindle firewall rules for sharing on `port` (and answering searches) and for
-- searching.
local function http_rules(port)
    return {
        string.format("INPUT -p tcp --dport %d -m conntrack --ctstate NEW,ESTABLISHED -j ACCEPT", port),
        string.format("OUTPUT -p tcp --sport %d -m conntrack --ctstate ESTABLISHED -j ACCEPT", port),
    }
end

local function jam_rules(port)
    local rules = http_rules(port)
    table.insert(rules, string.format("INPUT -p udp --dport %d -j ACCEPT", Discovery.DISCOVERY_PORT))
    table.insert(rules, string.format("OUTPUT -p udp --sport %d -j ACCEPT", Discovery.DISCOVERY_PORT))
    return rules
end

local function search_rules()
    return {
        string.format("INPUT -p udp --dport %d -j ACCEPT", Discovery.SEARCH_PORT),
        string.format("OUTPUT -p udp --sport %d -j ACCEPT", Discovery.SEARCH_PORT),
        string.format("OUTPUT -p udp --dport %d -j ACCEPT", Discovery.DISCOVERY_PORT),
    }
end

-- Opens (op "-A") or closes ("-D") ports in the Kindle firewall (as httpinspector does).
-- A rule is added only when missing (-C), so rules left by a crash aren't doubled
-- and one -D removes it.
local function kindle_firewall(op, rules)
    if not rules or not Device:isKindle() then return end
    for _i, rule in ipairs(rules) do
        if op == "-A" then
            os.execute("iptables -C " .. rule .. " 2>/dev/null || iptables -A " .. rule)
        else
            os.execute("iptables " .. op .. " " .. rule)
        end
    end
end

-- UIManager calls a ZMQ's waitEvent() about every 50 ms; it must return nil
-- (anything else is treated as an input event).
local function poller(fn, name)
    return UIManager:insertZMQ({ waitEvent = function()
        local ok, err = pcall(fn)
        if not ok then logger.warn("Songbook:", name, err) end
        return nil
    end })
end

-- SimpleTCPServer on `port` answering with Jam.handle() and get_context().
-- Its callback must send the response and return nothing (UIManager would
-- treat a return value as an input event).
local function jam_http_server(port, get_context)
    local server
    server = require("ui/message/simpletcpserver"):new{
        host = "*",
        port = port,
        receiveCallback = function(data, client)
            local ok, resp = pcall(function()
                local req = Jam.parse_request(data)
                if req and client.getpeername then req.ip = client:getpeername() end
                return Jam.handle(req, get_context())
            end)
            if not ok then
                logger.warn("Songbook: jam request failed", resp)
                resp = Jam.response(500, "text/plain", "Internal error")
            end
            server:send(resp, client)
        end,
    }
    return server
end

function Songbook:jamSong()
    local uid = self:nowPlayingUid()
    if uid and not lfs.attributes(self:songPath(uid), "mode") then uid = nil end
    return uid
end

--- Guests sharing their songs ({ url, name }), without those that stopped polling.
function Songbook:jamPeers()
    local peers, t = {}, now()
    for url, peer in pairs(jam.peers or {}) do
        if t - peer.seen > PEER_EXPIRE then
            jam.peers[url] = nil
        else
            peers[#peers + 1] = { url = url, name = peer.name }
        end
    end
    table.sort(peers, function(a, b) return a.url < b.url end)
    return peers
end

function Songbook:jamJoin(peer)
    jam.peers = jam.peers or {}
    jam.peers[peer.url] = { name = peer.name, seen = now() }
end

--- State for /state.json; `peer_url` (the asking guest) is left out of the peers.
function Songbook:jamState(peer_url)
    local uid = self:jamSong()
    local peers = {}
    for _i, peer in ipairs(self:jamPeers()) do
        if peer.url ~= peer_url then peers[#peers + 1] = peer end
    end
    local state = { notation = self:get("notation"), name = self:deviceName(), peers = peers }
    if uid then
        local _key, id = split_uid(uid)
        local meta = song_meta(self:songPath(uid))
        state.uid = uid
        state.rev = uid .. "@" .. self:renderSignature(uid)
        state.title = meta.title or id
        state.artist = meta.artist
        state.transpose = self:getMap("transpose")[uid] or 0
        -- the host's autoscroll of this song, for the guests' pages to follow
        local a = jam.autoscroll
        if a and a.uid == uid and a.start then
            local progress = math.min(math.max((now() - a.start) / a.duration, 0), 1)
            state.scroll = { progress = math.floor(progress * 10000 + 0.5) / 10000, duration = a.duration }
        end
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

--- Request of a guest's own song (`remote_uid` on the guest at `url`): it is
-- downloaded and queued once the request is answered (the guest serves its
-- songs only after its request returns).
function Songbook:jamRequestFrom(url, remote_uid, by)
    local peer = jam.peers and jam.peers[url]
    if not peer then return nil, "missing" end
    local server = self:jamServer(url, peer.name)
    local uid = make_uid(server.key, Jam.song_id(remote_uid))
    if self:isQueued(uid) then return nil, "queued" end
    if #self:getPlaylist().queue >= Jam.MAX_QUEUE then return nil, "full" end
    UIManager:nextTick(function()
        local ok, err = self:download({ uid = uid, server = server, file = Jam.song_path(remote_uid) })
        if not ok then
            logger.warn("Songbook: cannot download a guest's song", url, remote_uid, err)
            return
        end
        self:jamRequest(uid, by)
    end)
    return true
end

function Songbook:jamSongHtml(opts)
    local uid = self:jamSong()
    if not uid then return nil end
    return (self:songHtml(uid, {
        transpose = Jam.add_semitones(self:getMap("transpose")[uid], opts.shift),
        notation = opts.notation,
        show_chords = opts.show_chords,
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
    local rules = jam_rules(port)
    kindle_firewall("-A", rules)
    local server = jam_http_server(port, function() return jam.context end)
    local ok, err = server:start()
    if not ok then
        kindle_firewall("-D", rules)
        UIManager:show(InfoMessage:new{
            text = T(_("Cannot start the jam session on port %1."), port) .. "\n\n" .. tostring(err),
        })
        return false
    end
    jam.server, jam.port, jam.rules, jam.peers = server, port, rules, {}
    jam.context = {
        state = function(peer_url) return jam.owner:jamState(peer_url) end,
        join = function(peer) jam.owner:jamJoin(peer) end,
        request_from = function(url, uid, by) return jam.owner:jamRequestFrom(url, uid, by) end,
        song_html = function(opts) return jam.owner:jamSongHtml(opts) end,
        song_cho = function()
            local uid = jam.owner:jamSong()
            return uid and read_file(jam.owner:songPath(uid))
        end,
        songs = function() return jam.owner:jamSongs() end,
        playlist = function() return jam.owner:getPlaylist() end,
        request = function(uid, by) return jam.owner:jamRequest(uid, by) end,
        song_file = function(uid) return read_file(jam.owner:songPath(uid)) end,
        name = self:deviceName(),
        labels = {
            title = self:deviceName(), waiting = _("Waiting for a song…"),
            offline = _("Connection lost"), chords = _("Chords"),
            song = _("Song"), playlist = _("Playlist"), now_playing = _("Now playing"),
            up_next = _("Up next"), played = _("Played"),
            request = _("Request a song"), your_name = _("Your name"), search = _("Search"),
            nothing = _("Nothing yet"), requested = _("Requested: %1"),
            queued = _("This song is already requested."), full = _("Too many requests, try again later."),
            missing = _("This song is not available."), follow = _("Scroll with the host"),
        },
        css = Render.css(nil, true),
    }
    jam.queue = UIManager:insertZMQ(server)
    -- optional: without it the songbook can still be followed by address
    local responder, rerr = Discovery.responder(require("socket"), port, function() return jam.owner:deviceName() end)
    if responder then
        jam.responder = responder
        jam.responder_zmq = poller(function() responder:poll() end, "discovery")
    else
        logger.warn("Songbook: no discovery answers", rerr)
    end
    C.keep_awake(true)
    return true
end

function Songbook:stopJam()
    if not jam.server then return end
    UIManager:removeZMQ(jam.queue)
    jam.server:stop()
    if jam.responder then
        UIManager:removeZMQ(jam.responder_zmq)
        jam.responder:close()
    end
    kindle_firewall("-D", jam.rules)
    C.keep_awake(false)
    jam.server, jam.queue, jam.context, jam.rules, jam.peers = nil, nil, nil, nil, nil
    jam.responder, jam.responder_zmq = nil, nil
end

-- While following, our own songs are shared with the session (setting
-- `jam_share_songs`): only /index.json and /songs/, on the jam port. The
-- followed songbook lists us among its sources while we keep polling.
function Songbook:startLibrary()
    if jam.library or not self:get("jam_share_songs") then return end
    local port = self:get("jam_port")
    local rules = http_rules(port)
    kindle_firewall("-A", rules)
    local server = jam_http_server(port, function() return jam.library and jam.library.context end)
    local ok, err = server:start()
    if not ok then
        kindle_firewall("-D", rules)
        logger.warn("Songbook: cannot share songs while following", err)
        return
    end
    jam.library = {
        server = server, port = port, rules = rules,
        zmq = UIManager:insertZMQ(server),
        context = {
            library = true,
            songs = function() return jam.owner:jamSongs() end,
            song_file = function(uid) return read_file(jam.owner:songPath(uid)) end,
            name = self:deviceName(),
        },
    }
end

function Songbook:stopLibrary()
    local lib = jam.library
    if not lib then return end
    UIManager:removeZMQ(lib.zmq)
    lib.server:stop()
    kindle_firewall("-D", lib.rules)
    jam.library = nil
end

-- Following another songbook: poll its /state.json and open each song it
-- plays (saved to songs/jam/) in the host's key. While another song is open
-- (browsing), a new song is only announced; Open now playing goes to it.
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
    local query = Jam.query({ name = jam.library and self:deviceName(), share = jam.library and jam.library.port })
    local body = Repo.fetch(f.url .. "state.json" .. query, FOLLOW_TIMEOUT[1], FOLLOW_TIMEOUT[2])
    local state = body and Jam.parse_state(body, require("json").decode)
    if not state then return self:followFailed() end
    if state.api > Jam.API_VERSION then
        self:stopFollowing()
        UIManager:show(InfoMessage:new{
            text = _("The other songbook has a newer version of the Songbook plugin. Update it here to follow it."),
        })
        return
    end
    f.name, f.peers = state.name, state.peers
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
    local new_song = state.uid ~= f.uid
    local same = not new_song and state.transpose == f.transpose
    local open = self:currentSongId()
    -- the first song after following starts opens too
    local following_open = open == nil or f.uid == nil or open == self:nowPlayingUid()
    f.failures, f.rev, f.uid, f.transpose = 0, state.rev, state.uid, state.transpose
    if same then return end
    self:setMapValue("transpose", uid, state.transpose ~= 0 and state.transpose or nil)
    if following_open then
        self:openSong(uid)
    elseif new_song then
        Notification:notify(T(_("Now playing: %1"), self:nowPlayingTitle()))
    end
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
        local uids = {}
        for name in lfs.dir(dir) do
            local id = song_file_id(name)
            local uid = id and make_uid(JAM_KEY, id)
            if uid and uid ~= current then uids[#uids + 1] = uid end
        end
        self:deleteSongs(uids)
    end
    -- the followed songbook's playlist is used instead of ours, which is put
    -- aside until following stops (also over a crash: see restorePlaylist())
    if self.settings:readSetting("playlist_aside") == nil then
        self:set("playlist_aside", self:getPlaylist())
    end
    self:savePlaylist({})
    jam.follow = { url = url, failures = 0 }
    C.keep_awake(true)
    self:startLibrary()
    follow_poll()
end

function Songbook:stopFollowing()
    if not jam.follow then return end
    UIManager:unschedule(follow_poll)
    C.keep_awake(false)
    self:stopLibrary()
    jam.follow = nil
    self:restorePlaylist()
end

--- Bring back our playlist put aside while following (startFollowing()).
-- init() calls it too, for a KOReader that quit while following.
function Songbook:restorePlaylist()
    local p = self.settings:readSetting("playlist_aside")
    if p == nil or jam.follow then return end
    self.settings:delSetting("playlist_aside")
    self:savePlaylist(p)
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

-- Finding shared songbooks: { search, menu, zmq, last_sent, rules } while the list is open.
local finder = {}

local function stop_finder()
    if finder.zmq then UIManager:removeZMQ(finder.zmq) end
    if finder.search then finder.search:close() end
    kindle_firewall("-D", finder.rules)
    finder = {}
end

function Songbook:finderItems(on_url)
    local items = {}
    for _i, f in ipairs(finder.search and finder.search.found or {}) do
        items[#items + 1] = {
            text = f.name ~= "" and f.name or f.ip,
            mandatory = f.ip,
            callback = function()
                local url = Discovery.url(f)
                UIManager:close(finder.menu)
                self:set("jam_follow_url", url)
                on_url(url)
            end,
        }
    end
    if #items == 0 then
        items[1] = { text = _("Searching for shared songbooks…"), dim = true, callback = function() end }
    end
    items[#items].separator = true
    items[#items + 1] = { text = _("Enter address…"), callback = function()
        UIManager:close(finder.menu)
        self:askFollowUrl(on_url)
    end }
    return items
end

local function poll_finder(plugin, on_url)
    local t = now()
    if t - finder.last_sent >= SEARCH_INTERVAL then
        finder.last_sent = t
        finder.search:send()
    end
    local changed = finder.search:poll(t)
    changed = finder.search:expire(t, SEARCH_EXPIRE) or changed
    if changed and finder.menu then
        finder.menu:switchItemTable(nil, plugin:finderItems(on_url))
    end
end

--- Lists songbooks shared on the network (and Enter address…); on_url(url)
-- gets the chosen one. Without UDP only the address can be entered.
function Songbook:findSongbooks(on_url)
    stop_finder()
    local socket = require("socket")
    local search, err = Discovery.search(socket, local_ip())
    if not search then
        logger.warn("Songbook: cannot search for songbooks", err)
        return self:askFollowUrl(on_url)
    end
    finder = { search = search, last_sent = 0, rules = search_rules() }
    kindle_firewall("-A", finder.rules)
    local menu = list_menu(_("Follow another songbook"), self:finderItems(on_url))
    local on_close = menu.onCloseWidget
    menu.onCloseWidget = function(m)
        stop_finder()
        if on_close then return on_close(m) end
    end
    finder.menu = menu
    finder.zmq = poller(function() poll_finder(self, on_url) end, "search")
    UIManager:show(menu)
end

function Songbook:onExit()
    stop_finder()
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
            help_text = _("Guests on the same Wi-Fi open the address in a web browser and see the song you are playing. Each guest can transpose it for themselves, and see your playlist and ask for songs. Not while following another songbook."),
            keep_menu_open = true,
            -- a songbook either shares or follows (following itself doesn't work)
            enabled_func = function() return not self:isFollowing() end,
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
            text_func = function() return T(_("Device name: %1"), self:deviceName()) end,
            help_text = _("Names this device in the jam session: other songbooks see it in the list of shared songbooks and as the source of your songs."),
            enabled_func = function() return not self:isJamRunning() and not self:isFollowing() end,
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                self:askDeviceName(function() touchmenu_instance:updateItems() end)
            end,
            separator = true,
        },
        {
            text_func = function()
                if not self:isFollowing() then return _("Follow another songbook…") end
                return T(_("Following %1"), follow_name())
            end,
            help_text = _("Open the songs another device is playing, as they change, in the other player's key; you can still transpose them. The other songbook's playlist is used instead of yours, which comes back when you stop following. Not while sharing."),
            keep_menu_open = true,
            enabled_func = function() return not self:isJamRunning() end,
            checked_func = function() return self:isFollowing() end,
            callback = function(touchmenu_instance)
                if self:isFollowing() then
                    self:stopFollowing()
                    touchmenu_instance:updateItems()
                    return
                end
                NetworkMgr:runWhenConnected(function()
                    self:findSongbooks(function(url)
                        self:startFollowing(url)
                        touchmenu_instance:updateItems()
                    end)
                end)
            end,
        },
        {
            text = _("Share my songs while following"),
            help_text = _("The followed songbook and its other guests see your songs as a repository while you follow, and the songs you request are played even if the other songbook doesn't have them."),
            keep_menu_open = true,
            checked_func = function() return self:get("jam_share_songs") end,
            callback = function(touchmenu_instance)
                self:set("jam_share_songs", not self:get("jam_share_songs"))
                if not self:isFollowing() then return touchmenu_instance:updateItems() end
                if self:get("jam_share_songs") then
                    NetworkMgr:runWhenConnected(function()
                        self:startLibrary()
                        touchmenu_instance:updateItems()
                    end)
                else
                    self:stopLibrary()
                    touchmenu_instance:updateItems()
                end
            end,
        },
    }
end

function Songbook:askDeviceName(on_saved)
    local dialog
    dialog = InputDialog:new{
        title = _("Device name"),
        input = self:get("device_name") or "",
        input_hint = Device.model or _("Songbook"),
        buttons = {{
            { text = _("Cancel"), id = "close", callback = function() UIManager:close(dialog) end },
            { text = _("Save"), is_enter_default = true, callback = function()
                local name = Jam.clean_name(dialog:getInputText()) or ""
                UIManager:close(dialog)
                self:set("device_name", name ~= "" and name or nil)
                on_saved()
            end },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end
