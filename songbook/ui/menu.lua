--[[--
The Songbook menu: the song lists, Playlist submenu and settings.
]]

local C = require("songbook/ui/common")
local Render = require("songbook/render")

local InfoMessage = require("ui/widget/infomessage")
local SpinWidget = require("ui/widget/spinwidget")
local UIManager = require("ui/uimanager")

local Songbook = C.Songbook
local _, T = C._, C.T
local DEFAULTS = C.DEFAULTS

--- The Playlist submenu: the list, the song now playing and the next song
-- (always there, disabled while there is none; the song options have them too).
function Songbook:playlistMenu()
    return {
        {
            songbook_item = "show_playlist",
            text = _("Show playlist"),
            keep_menu_open = true,
            callback = function() self:onSongbookShowPlaylist() end,
        },
        {
            songbook_item = "now_playing",
            text_func = function()
                local title = self:nowPlayingUid() and self:nowPlayingTitle()
                return title and T(_("Now playing: %1"), Render.truncate(title, 24)) or _("Nothing is playing")
            end,
            enabled_func = function() return self:nowPlayingUid() ~= nil end,
            callback = function() self:onSongbookOpenNowPlaying() end,
        },
        {
            songbook_item = "next",
            text_func = function()
                local e = self:nextInPlaylist()
                return e and T(_("Next song: %1"), Render.truncate(e.title, 24)) or _("Next song")
            end,
            enabled_func = function() return self:nextInPlaylist() ~= nil end,
            callback = function() self:onSongbookNextSong() end,
        },
    }
end

--- Items of the song library: the song lists and the Playlist submenu.
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
            sub_item_table_func = function() return self:playlistMenu() end,
        },
    }
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
            -- the count in this item changes with the list
            callback = function(touchmenu_instance)
                self:showRepositories(function()
                    if touchmenu_instance then touchmenu_instance:updateItems() end
                end)
            end,
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
            separator = true,
        },
        {
            text = _("Formatting"),
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
                    text = _("Show chords"),
                    checked_func = function() return self:get("show_chords") end,
                    callback = function() self:setAndRefresh("show_chords", not self:get("show_chords")) end,
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
                    text = _("Autoscroll when a song starts playing"),
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
            text = _("Quick menu"),
            help_text = _("A button in the bottom right corner of an open song opens a quick menu with the song's options: transposition, autoscroll, favorites, collections and playlist. They are also available as Song options in the Songbook menu and as the gesture action \"Songbook: song options\"."),
            checked_func = function() return self:get("song_button") end,
            callback = function() self:setAndRefresh("song_button", not self:get("song_button")) end,
        },
        {
            text = _("Opening a song plays it"),
            help_text = _("A song you open becomes the song now playing: the jam session shares it and it goes to Played afterwards. Otherwise opening only shows the song, and Play now in the song's options plays it."),
            checked_func = function() return self:get("play_on_open") end,
            callback = function() self:set("play_on_open", not self:get("play_on_open")) end,
        },
    }
end

-- songActions() that don't concern the open song, left out of the menu's Song options
local MENU_SKIPS_ACTION = { now_playing = true, next = true, show_playlist = true }

--- The Songbook menu: the open song's actions (disabled without one, for when
-- the song button is off), the library, jam session and settings. Built when
-- it opens, so the labels show the open song and the playlist.
function Songbook:mainMenu()
    local items = self:libraryMenu()
    table.insert(items, 1, {
        songbook_item = "song",
        text = _("Song options"),
        enabled_func = function() return self:currentSongId() ~= nil end,
        sub_item_table_func = function()
            local sub = {}
            for _i, a in ipairs(self:songActions()) do
                -- the playlist items are in the menu below
                if not MENU_SKIPS_ACTION[a.id] then
                    table.insert(sub, { text = a.text, enabled = a.enabled ~= false, callback = a.callback })
                end
            end
            return sub
        end,
        separator = true,
    })
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
