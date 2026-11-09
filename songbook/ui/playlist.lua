--[[--
Playlist: Now playing, Up next and Played; while following, the followed
songbook's playlist and requests to it.
]]

local C = require("songbook/ui/common")
local ChordPro = require("songbook/chordpro")
local Jam = require("songbook/jam")
local Render = require("songbook/render")
local Repo = require("songbook/repo")

local ConfirmBox = require("ui/widget/confirmbox")
local UIManager = require("ui/uimanager")
local lfs = require("libs/libkoreader-lfs")

local Songbook = C.Songbook
local _, T = C._, C.T
local JAM_KEY = C.JAM_KEY
local FOLLOW_TIMEOUT = C.FOLLOW_TIMEOUT
local jam = C.jam
local song_lists = C.song_lists
local read_file = C.read_file
local song_meta = C.song_meta
local sort_songs = C.sort_songs
local notify = C.notify
local split_uid = C.split_uid
local make_uid = C.make_uid
local now = C.now
local details = C.details
local show_actions = C.show_actions
local list_menu = C.list_menu
local follow_name = C.follow_name
local count_keys = C.count_keys
local MAX_SOURCE = C.MAX_SOURCE

-- Playlist -------------------------------------------------------------------
--
-- Now playing, Up next (queue) and played songs (history), kept in the
-- settings until cleared: { now = entry, history = { entry... }, queue =
-- { entry... } }, entry = { uid, title, artist, by, at }. Opening a song only
-- shows it; Play now (or opening with setting `play_on_open`) makes it the
-- song now playing, which the jam session shares. While sharing, guests see
-- the playlist and add requests; while following, the followed songbook's
-- playlist is used instead (our own is cleared).

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

--- Make `uid` the song now playing (without opening it).
function Songbook:playlistPlay(uid)
    if split_uid(uid) == JAM_KEY then return end
    local entry = self:playlistEntry(uid)
    if not entry then return end
    local p = self:getPlaylist()
    if Jam.play(p, entry) then self:savePlaylist(p) end
end

--- uid of the song now playing: ours, or while following the followed
-- songbook's (as saved in songs/jam/). nil when nothing is playing.
function Songbook:nowPlayingUid()
    if jam.follow then
        return jam.follow.uid and make_uid(JAM_KEY, Jam.song_id(jam.follow.uid))
    end
    local now = self:getPlaylist().now
    return now and now.uid
end

--- Play `uid` now: it becomes the song now playing and opens (when it isn't
-- open already; then autoscroll starts as for a song that opens).
function Songbook:playSong(uid)
    self:playlistPlay(uid)
    if self:currentSongId() ~= uid then return self:openSong(uid) end
    if self:get("autoscroll") and not self:isAutoscrolling() then self:startAutoscroll(true) end
    self:repaintSongButton()
end

--- The song now playing has finished: it goes to Played.
function Songbook:finishPlaying()
    local p = self:getPlaylist()
    local uid = p.now and p.now.uid
    if not Jam.finish(p) then return end
    self:savePlaylist(p)
    if uid == self:currentSongId() then self:stopAutoscroll() end
    self:repaintSongButton()
end

--- Title of the song now playing, or nil.
function Songbook:nowPlayingTitle()
    if not jam.follow then
        local now = self:getPlaylist().now
        return now and now.title
    end
    local uid = self:nowPlayingUid()
    if not uid then return nil end
    local _key, id = split_uid(uid)
    return song_meta(self:songPath(uid)).title or id
end

function Songbook:onSongbookOpenNowPlaying()
    local uid = self:nowPlayingUid()
    if uid and lfs.attributes(self:songPath(uid), "mode") == "file" then
        if self:currentSongId() ~= uid then self:openSong(uid) end
    else
        notify(_("No song is playing."))
    end
    return true
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

--- Add the songs of `uids` to Up next (no limit), those not queued and not
-- playing. Returns how many were added; the playlist is saved once.
function Songbook:addSongsToPlaylist(uids)
    local p = self:getPlaylist()
    local playing = p.now and p.now.uid
    local added = 0
    for _i, uid in ipairs(uids) do
        local entry = uid ~= playing and split_uid(uid) ~= JAM_KEY and self:playlistEntry(uid)
        if entry and Jam.add_request(p.queue, entry, math.huge) then added = added + 1 end
    end
    if added > 0 then self:savePlaylist(p) end
    return added
end

--- Title bar action of a song list: its songs (`songs`, as listed after the
-- search) that aren't in the playlist yet go to Up next. Not while following:
-- the followed songbook's playlist is used then.
function Songbook:addListToPlaylistAction(songs)
    local playing = self:nowPlayingUid()
    local uids = {}
    for _i, song in ipairs(songs) do
        if song.uid ~= playing and not self:isQueued(song.uid) then uids[#uids + 1] = song.uid end
    end
    return {
        text = #uids > 0 and T(_("Add to playlist (%1)"), #uids) or _("All in the playlist"),
        enabled = #uids > 0 and not self:isFollowing(),
        callback = function()
            notify(T(_("Songs added to the playlist: %1"), self:addSongsToPlaylist(uids)))
        end,
    }
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
        self:playSong(e.uid)
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
        -- Songs of online lists have `server`. The followed songbook has its
        -- own songs; others it gets from us, so they must be on the device:
        -- songs of the session's other songbooks are downloaded first (`before`),
        -- songs of internet repositories have to be downloaded by hand.
        local server = song.server
        local followed = server and Repo.base_url(server.url) == Repo.base_url(jam.follow.url)
        local on_device = not server or followed or self:isDownloaded(song)
        return {
            text = _("Request to play"),
            enabled = on_device or (server.jam and before ~= nil) or false,
            callback = function()
                close()
                if not on_device and not before() then return end
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

--- "Play now" for a song's long-press dialog (not while following: the
-- followed songbook chooses the songs then). `before` as in favoriteButton().
function Songbook:playNowButton(song, close, before)
    return {
        text = _("Play now"),
        enabled = not self:isFollowing(),
        callback = function()
            close()
            if before and not before() then return end
            self:closeList()
            self:playSong(song.uid)
        end,
    }
end

--- Ask the followed songbook to queue its song with index id `remote_id`.
-- Returns true, or nil and an error message.
function Songbook:requestFollowed(remote_id)
    return self:sendFollowedRequest({ id = remote_id })
end

--- /queue/add on the followed songbook with `params` (and our name).
function Songbook:sendFollowedRequest(params)
    params.by = self:deviceName()
    local body = Repo.fetch(jam.follow.url .. "queue/add" .. Jam.query(params), FOLLOW_TIMEOUT[1], FOLLOW_TIMEOUT[2])
    local ok, data = pcall(require("json").decode, body or "")
    if not body or not ok or type(data) ~= "table" then
        return nil, _("Cannot reach the other songbook.")
    end
    if not data.ok then return nil, request_error(data.error) end
    return true
end

--- Ask the followed songbook to play `song`. Songs received from it or
-- downloaded from it as a repository use its own ids. Other songs it gets
-- from us while we share our songs; otherwise they are matched by uid, which
-- works when both have them from the same repository.
function Songbook:requestFromFollowed(song)
    local f = jam.follow
    local key, id = split_uid(song.uid)
    local server = key and self:findServer(key)
    local same_source = key == JAM_KEY or (server and Repo.base_url(server.url) == Repo.base_url(f.url))
    local ok, err
    if same_source then
        ok, err = self:requestFollowed(id)
    elseif jam.library then
        ok, err = self:sendFollowedRequest({ uid = song.uid, from = jam.library.port })
    else
        ok, err = self:requestFollowed(Jam.song_id(song.uid))
    end
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
    sort_songs(songs)
    return songs
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
        table.insert(items, { text = _("Now playing"), bold = true, select_enabled = false })
        if p.now then
            -- while following, the song now playing is on this device (songs/jam/)
            table.insert(items, {
                text = "▶ " .. p.now.title,
                mandatory = p.now.at and os.date("%H:%M", p.now.at) or "",
                entry = p.now,
                now = true,
                callback = function()
                    self:closeList()
                    self:onSongbookOpenNowPlaying()
                end,
            })
        else
            table.insert(items, { text = _("Nothing is playing"), dim = true, select_enabled = false })
        end
        table.insert(items, { text = T(_("Up next (%1)"), #p.queue), bold = true, select_enabled = false })
        -- a tap plays a song of Up next and opens a played one; the other
        -- songbook's songs may not be on this device
        local function add(entry, mandatory, queued)
            local item = { text = entry.title, mandatory = mandatory, entry = entry, queued = queued,
                           played = not queued }
            if not remote then
                item.callback = function()
                    self:closeList()
                    if queued then self:playSong(entry.uid) else self:openSong(entry.uid) end
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
            if item.now then
                show_actions(item.entry.title, {
                    { text = _("Finished"), callback = function() self:finishPlaying() end },
                })
                return true
            end
            local play_now = { text = _("Play now"), callback = function()
                self:closeList()
                self:playSong(uid)
            end }
            if item.played then
                show_actions(item.entry.title, {
                    play_now,
                    { text = _("Add to Up next"), enabled = not self:isQueued(uid), callback = function()
                        local entry, err = self:addToPlaylist(uid)
                        if not entry then notify(request_error(err)) end
                    end },
                })
                return true
            end
            show_actions(item.entry.title, {
                play_now,
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
        menu:switchItemTable(title, build(), -1)
    end
    if not remote then song_lists.last = { kind = "playlist" } end
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
        if p.now and p.now.uid then played[entry_key(p.now)] = true end
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
    local p = self:getPlaylist()
    local history = { unpack(p.history) }
    if p.now then table.insert(history, p.now) end
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
            if lfs.attributes(self:songPath(e.uid), "mode") then C.collection_set(c, e.uid, true) end
        end
        c.sort = "added"   -- in the order they were played
        self:saveCollections(collections)
        notify(T(_("Saved %1 songs to \"%2\"."), count_keys(c.songs), name))
    end)
end
