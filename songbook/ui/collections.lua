--[[--
Collections: named song lists.
]]

local C = require("songbook/ui/common")
local Search = require("songbook/search")

local ButtonDialog = require("ui/widget/buttondialog")
local ConfirmBox = require("ui/widget/confirmbox")
local InputDialog = require("ui/widget/inputdialog")
local UIManager = require("ui/uimanager")
local lfs = require("libs/libkoreader-lfs")
local util = require("util")

local Songbook = C.Songbook
local _, T = C._, C.T
local lower = C.lower
local notify = C.notify
local details = C.details
local show_actions = C.show_actions
local list_menu = C.list_menu
local collection_set = C.collection_set

-- Collections -------------------------------------------------------------------
--
-- Named song lists made on the device:
--   { { name = "...", songs = { [uid] = true }, order = { uid, ... }, sort = "added" }, ... }
-- Names are unique, so they identify a collection. `songs` says what is in it
-- (as in 1.2 and older, which keep reading it); `order` lists the songs in the
-- order they were added and may miss songs added by older versions or keep
-- removed ones, so it is only used for sorting. `sort` = "added" lists the songs
-- in that order, otherwise (nil) by title.


--- Sort `songs` (song tables with `uid`, sorted by title) for collection `c`:
-- in place, by c.sort. Songs missing from c.order come first, by title.
function Songbook:sortCollectionSongs(c, songs)
    if c.sort ~= "added" then return songs end
    local rank = {}
    for i, uid in ipairs(c.order or {}) do rank[uid] = i end
    local by_title = {}
    for i, song in ipairs(songs) do by_title[song] = i end
    table.sort(songs, function(a, b)
        local ra, rb = rank[a.uid] or 0, rank[b.uid] or 0
        if ra ~= rb then return ra < rb end
        return by_title[a] < by_title[b]
    end)
    return songs
end

--- ☰ action of a collection's list: switch its sort between title and order added.
function Songbook:collectionSortAction(name, refresh)
    local c = self:findCollection(name)
    local added = c and c.sort == "added"
    return {
        text = added and _("Sort by title") or _("Sort by order added"),
        enabled = c ~= nil,
        callback = function()
            local collections = self:getCollections()
            local found = self:findCollection(name, collections)
            if not found then return end
            found.sort = not added and "added" or nil
            self:saveCollections(collections)
            refresh()
        end,
    }
end

--- How many of the songs in set `songs` ({ [uid] = true }) are on the device
-- (a collection may still name songs deleted outside the plugin).
function Songbook:countOnDevice(songs)
    local n = 0
    for uid in pairs(songs) do
        if lfs.attributes(self:songPath(uid), "mode") == "file" then n = n + 1 end
    end
    return n
end

function Songbook:getCollections()
    local collections = self.settings:readSetting("collections") or {}
    table.sort(collections, function(a, b) return Search.fold(a.name, lower) < Search.fold(b.name, lower) end)
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
    collection_set(c, uid, on)
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
                mandatory = tostring(self:countOnDevice(c.songs)),
                collection = c.name,
                callback = function()
                    -- songs may be removed from the collection meanwhile: update the counts
                    self:showCollection(c.name, function() menu:switchItemTable(nil, build(), -1) end)
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
                        menu:switchItemTable(nil, build(), -1)
                    end)
                end },
                { text = _("Delete"), callback = function()
                    UIManager:show(ConfirmBox:new{
                        text = T(_("Delete collection \"%1\"?\nThe songs stay on the device."), name),
                        ok_text = _("Delete"),
                        ok_callback = function()
                            self:deleteCollection(name)
                            menu:switchItemTable(nil, build(), -1)
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
    }, on_close, { kind = "collection", arg = name }, name, function(songs)
        local c = self:findCollection(name)
        return c and self:sortCollectionSongs(c, songs) or songs
    end)
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
