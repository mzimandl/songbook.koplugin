--[[--
The open song: transposition and the key dialog, autoscroll, the song button,
the scroll progress in the footer and the song options (songActions()).
]]

local C = require("songbook/ui/common")
local ChordPro = require("songbook/chordpro")
local Transpose = require("songbook/transpose")

local ButtonDialog = require("ui/widget/buttondialog")
local ConfirmBox = require("ui/widget/confirmbox")
local DoubleSpinWidget = require("ui/widget/doublespinwidget")
local Device = require("device")
local Event = require("ui/event")
local Notification = require("ui/widget/notification")
local Screen = Device.screen
local UIManager = require("ui/uimanager")

local Songbook = C.Songbook
local jam = C.jam
local _, T = C._, C.T
local read_file = C.read_file
local song_meta = C.song_meta
local notify = C.notify
local split_uid = C.split_uid
local now = C.now
local show_actions = C.show_actions

-- Transposition ---------------------------------------------------------------

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
    local meta = ChordPro.parse_meta(text)
    local choices = Transpose.key_choices(meta.key or ChordPro.first_chord(text),
        self:get("notation"), Transpose.song_notation(meta))
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

-- Autoscroll ------------------------------------------------------------------
--
-- The song's length is spread evenly over the document height, which gives
-- the line being played. Once it gets `trigger` screens below the top of the
-- view, the view moves by `step` screens (1/`autoscroll_step` of the screen
-- in scroll mode, keeping AUTOSCROLL_PLAYED screens of played lines visible,
-- repainted without the e-ink flash; a whole page in page mode). A manual move re-anchors the timing at the new
-- position. While a menu is open over the song the view waits and then
-- catches up in one move.

local AUTOSCROLL_PAGE = { step = 1, trigger = 0.9, page = true }
local AUTOSCROLL_PLAYED = 0.25
local AUTOSCROLL_MIN_WAIT = 0.5   -- seconds
local AUTOSCROLL_COVERED_WAIT = 1   -- seconds between checks while a menu is open

--- Length of song `uid` in seconds: set on the device, else {duration} in the file.
function Songbook:songDuration(uid)
    local own = self:getMap("duration")[uid]
    if own then return own end
    local meta = song_meta(self:songPath(uid))
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
        -- the last lines are on the screen: run out the song's length, so the
        -- jam guests' pages (which may be longer) scroll to the end too
        local left = a.duration - (now() - a.start)
        if left <= 0 then
            self:stopAutoscroll()
        else
            UIManager:unschedule(a.task)
            UIManager:scheduleIn(math.max(left, AUTOSCROLL_MIN_WAIT), a.task)
        end
        return
    end
    local played = (now() - a.start) / a.duration * height
    if played >= pos + mode.trigger * h then
        if self:songCovered() then
            -- a menu or dialog is open: moving would repaint the song under it
            UIManager:unschedule(a.task)
            UIManager:scheduleIn(AUTOSCROLL_COVERED_WAIT, a.task)
            return
        end
        -- after waiting under a menu, catch up in one move
        local steps = math.max(1, math.floor((played - pos - mode.trigger * h) / (mode.step * h)) + 1)
        a.moving = true
        if mode.page then
            self.ui:handleEvent(Event:new("GotoViewRel", steps * mode.step))
        else
            self:withoutFlashing(function()
                self.ui:handleEvent(Event:new("GotoViewRel", steps * mode.step))
            end)
        end
        a.moving = false
    end
    self:scheduleAutoscroll()
end

--- Run f() with the song's "partial" repaints made "ui" ones: they don't count
-- towards the e-ink full refresh (the flash every few page turns), so small
-- scroll steps don't make the screen blink.
function Songbook:withoutFlashing(f)
    local dialog = self.ui.view and self.ui.view.dialog
    local setDirty = UIManager.setDirty
    UIManager.setDirty = function(um, widget, mode, ...)
        if mode == "partial" and widget ~= nil and widget == dialog then mode = "ui" end
        return setDirty(um, widget, mode, ...)
    end
    local ok, err = pcall(f)
    UIManager.setDirty = setDirty
    if not ok then error(err, 0) end
end

--- Whether a widget (a menu, a dialog; not a toast) is shown over the song.
function Songbook:songCovered()
    if not UIManager.topdown_widgets_iter then return false end
    for w in UIManager:topdown_widgets_iter() do
        if w == self.ui then return false end
        if not w.toast and not w.invisible then return true end
    end
    return false
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
    jam.autoscroll = self.autoscroll   -- for the jam session's guests
    self:anchorAutoscroll()
    C.keep_awake(true)
    self:scheduleAutoscroll()
    Notification:notify(T(_("Autoscroll: %1"), ChordPro.format_duration(duration)))
end

function Songbook:stopAutoscroll()
    local a = self.autoscroll
    if not a then return end
    self.autoscroll = nil
    if jam.autoscroll == a then jam.autoscroll = nil end
    UIManager:unschedule(a.task)
    C.keep_awake(false)
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
    local meta = song_meta(self:songPath(uid))
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

-- Song button and footer ------------------------------------------------------

function Songbook:onReaderReady()
    local uid = self:currentSongId()
    if not uid then return end
    if self:get("song_button") then self:addSongButton() end
    self:showScrollProgress()
    if self:get("autoscroll") and self:nowPlayingUid() == uid then self:startAutoscroll(true) end
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
    local function make_frame(playing)
        return FrameContainer:new{
            bordersize = Size.border.button,
            radius = Size.radius.button,
            padding = Size.padding.small,
            background = playing and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_WHITE,
            IconWidget:new{ icon = "appbar.menu", width = size, height = size, invert = playing },
        }
    end
    -- inverted while the open song is the one now playing
    local frames = { [false] = make_frame(false), [true] = make_frame(true) }
    local view = self.ui.view
    local plugin = self
    local button = {}
    function button:paintTo(bb, x, y)
        local uid = plugin:currentSongId()
        local frame = frames[uid ~= nil and uid == plugin:nowPlayingUid()]
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
    self.song_button = button
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

--- Redraw the song button after the song now playing changed.
function Songbook:repaintSongButton()
    local rect = self.song_button and self.song_button.rect
    if rect then UIManager:setDirty(self.ui, function() return "ui", rect end) end
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

-- Song options ----------------------------------------------------------------

--- Actions for the song that is open (for show_actions(), each with an `id`):
-- transposition, autoscroll | song length, favorite | collections | playlist,
-- Open now playing, the playlist, Play now / Finished | next song (`row`s for
-- the dialog, see show_actions()). Songs received while following are not kept in favorites,
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
            row = "scroll",
            text = self:isAutoscrolling() and _("Stop autoscroll") or _("Start autoscroll"),
            callback = function() self:onSongbookAutoscroll() end,
        },
        {
            id = "duration",
            row = "scroll",
            text = secs and T(_("Song length: %1"), ChordPro.format_duration(secs)) or _("Song length"),
            enabled = own ~= nil,
            callback = function() self:showDurationDialog() end,
        },
    }
    -- a followed song is kept among our songs when favorited or collected
    local collectable = self:collectableUid(uid)
    if collectable then
        local _key, id = split_uid(uid)
        local meta = song_meta(self:songPath(uid))
        local song = { uid = collectable, title = meta.title or id }
        local favorite = self:isFavorite(collectable)
        table.insert(actions, {
            id = "favorite",
            row = "add",
            text = favorite and _("Remove from favorites") or _("Add to favorites"),
            short = favorite and _("− Favorites") or _("+ Favorites"),
            callback = function() self:onSongbookToggleFavorite() end,
        })
        table.insert(actions, {
            id = "collections",
            row = "add",
            text = _("Add to collection"),
            short = _("+ Collection"),
            callback = function()
                self:showSongCollections(song, function() end, function() return self:keepFollowedSong(uid) ~= nil end)
            end,
        })
        -- while following: Request to play; the followed song is playing already
        local playlist = self:playlistButton(song, function() end)
        table.insert(actions, {
            id = "playlist",
            row = "add",
            text = playlist.text,
            short = (not self:isFollowing() and self:isQueued(collectable)) and _("− Playlist") or _("+ Playlist"),
            enabled = own ~= nil and playlist.enabled ~= false,
            callback = playlist.callback,
        })
    end
    table.insert(actions, {
        id = "show_playlist",
        text = self:isFollowing() and _("Playlist (jam session)") or _("Playlist"),
        callback = function() self:onSongbookShowPlaylist() end,
    })
    local now_uid = self:nowPlayingUid()
    if now_uid and now_uid ~= uid then
        table.insert(actions, {
            id = "now_playing",
            text = T(_("Open now playing: %1"), self:nowPlayingTitle() or ""),
            callback = function() self:onSongbookOpenNowPlaying() end,
        })
    end
    if own and not self:isFollowing() then
        if now_uid == uid then
            table.insert(actions, { id = "play", row = "play", text = _("Finished"),
                callback = function() self:finishPlaying() end })
        else
            table.insert(actions, { id = "play", row = "play", text = _("Play now"),
                callback = function() self:playSong(uid) end })
        end
    end
    -- always there, so the dialog keeps its layout; disabled with an empty Up next
    local next_song = self:nextInPlaylist()
    table.insert(actions, {
        id = "next",
        row = "play",
        text = next_song and T(_("Next song: %1"), next_song.title) or _("Next song"),
        short = next_song and T(_("Next: %1"), next_song.title) or nil,
        enabled = next_song ~= nil,
        callback = function() self:onSongbookNextSong() end,
    })
    return actions
end

--- Dialog of the open song (song button, gesture "song options").
function Songbook:showSongDialog()
    local uid = self:currentSongId()
    if not uid then return end
    local _key, id = split_uid(uid)
    local meta = song_meta(self:songPath(uid))
    local title = meta.title or id
    if meta.artist then title = title .. " – " .. meta.artist end
    show_actions(title, self:songActions())
    return true
end

Songbook.onSongbookSongDialog = Songbook.showSongDialog
