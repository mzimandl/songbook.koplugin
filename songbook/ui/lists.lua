--[[--
Song lists: the searchable list (showList()), My songs, favorites and the
gesture "last song list".
]]

local C = require("songbook/ui/common")

local ButtonDialog = require("ui/widget/buttondialog")
local ConfirmBox = require("ui/widget/confirmbox")
local InputDialog = require("ui/widget/inputdialog")
local NetworkMgr = require("ui/network/manager")
local UIManager = require("ui/uimanager")

local Songbook = C.Songbook
local _, T = C._, C.T
local song_lists = C.song_lists
local matches = C.matches
local notify = C.notify
local details = C.details
local list_menu = C.list_menu

--- Generic searchable song list.
-- get_songs() -> songs; make_item(song, refresh) -> menu item.
-- on_hold(song, refresh): refresh() rebuilds the list (keeping the search).
-- on_close(): called when the list is closed with × (not when a song is opened).
-- actions(refresh, shown): optional, -> actions of the title bar menu (see
--   show_actions()); `shown` = the songs listed now (after the search).
-- opts: optional { last = song_lists.last entry to keep the search and page in,
--   empty = { text, action = { text, callback(refresh) } } shown when there are no songs }.
function Songbook:showList(title, get_songs, make_item, on_hold, on_close, actions, opts)
    opts = opts or {}
    local last = opts.last
    local menu, refresh
    local query = song_lists.restoring and song_lists.restoring.query
    local shown = {}
    local function build()
        shown = {}
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
                table.insert(shown, song)
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

    menu = list_menu(title, build(), actions and function() return actions(refresh, shown) end, {
        onMenuHold = function(_menu, item)
            if item.song and on_hold then on_hold(item.song, refresh) end
            return true
        end,
    })
    menu.last = last
    if last then
        last.query = query
        song_lists.last = last
    end
    if song_lists.restoring and song_lists.restoring.page and menu.onGotoPage then menu:onGotoPage(song_lists.restoring.page) end
    song_lists.restoring = nil
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

-- Favorites -------------------------------------------------------------------

function Songbook:isFavorite(uid)
    return self:getMap("favorites")[uid] == true
end

function Songbook:setFavorite(uid, on)
    self:setMapValue("favorites", uid, on and true or nil)
end

function Songbook:onSongbookToggleFavorite()
    local open = self:currentSongId()
    local uid = open and self:collectableUid(open)
    if not uid then return end
    local on = not self:isFavorite(uid)
    if on and not self:keepFollowedSong(open) then return end
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

-- Song lists on the device -----------------------------------------------------

--- List of songs on the device. filter(song) limits the list (nil = all).
-- empty = { text, help, action } for an empty list: `text` is shown in it,
-- `help` once as a message, `action` (see showList()) below the text.
-- on_close as in showList(); last: see song_lists.last; collection: name of the
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
            { self:playNowButton(song, close) },
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
    end, on_close, function(refresh, shown)
        local actions = { self:addListToPlaylistAction(shown) }
        if collection then
            table.insert(actions, 1, { text = _("Add songs…"),
                callback = function() self:showCollectionPicker(collection, refresh) end })
        end
        return actions
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
    local last = song_lists.last
    if not last then return self:onSongbookShowLocal() end
    song_lists.restoring = last
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
                song_lists.restoring = last
                self:showOnlineSongs(servers)
                song_lists.restoring = nil
            end)
        else
            song_lists.restoring = nil
            self:browseOnline()
        end
    elseif last.kind == "playlist" then
        song_lists.restoring = nil
        self:onSongbookShowPlaylist()
    else
        self:onSongbookShowLocal()
    end
    song_lists.restoring = nil
    return true
end
