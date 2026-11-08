--[[--
Song repositories: browsing and downloading their songs, managing the list.
]]

local C = require("songbook/ui/common")
local Repo = require("songbook/repo")

local ButtonDialog = require("ui/widget/buttondialog")
local ConfirmBox = require("ui/widget/confirmbox")
local InputDialog = require("ui/widget/inputdialog")
local NetworkMgr = require("ui/network/manager")
local UIManager = require("ui/uimanager")
local lfs = require("libs/libkoreader-lfs")
local util = require("util")

local Songbook = C.Songbook
local _, T = C._, C.T
local JAM_KEY = C.JAM_KEY
local read_file = C.read_file
local write_file = C.write_file
local sort_songs = C.sort_songs
local busy = C.busy
local notify = C.notify
local make_uid = C.make_uid
local song_file_id = C.song_file_id
local details = C.details
local list_menu = C.list_menu

-- Download all stops after this many failed songs in a row.
local DOWNLOAD_MAX_FAILURES = 3

-- Browsing and downloading ----------------------------------------------------

--- Why a GitHub repository refused a request with HTTP status `code`, or nil.
local function access_hint(server, code)
    if not Repo.github(server.url) then return nil end
    local token = server.token
    if code == 401 and token then
        return _("The access token was refused: it may have expired. Set it again under Access token.")
    elseif (code == 403 or code == 404) and token then
        return _("Check the address, and that the token can read this repository's contents.")
    elseif code == 404 then
        return _("If the repository is private, set its access token under Access token.")
    end
end

--- Fetch `path` of `server` (with its access token, see Repo.request()).
-- Returns body or nil, error message, HTTP status code.
local function fetch_from(server, path)
    local url, headers = Repo.request(server.url, path, server.token)
    return Repo.fetch(url, nil, nil, headers)
end

--- Load a server's index. Songs get `uid` and `server` fields.
-- Returns songs or nil, error message, HTTP status code.
function Songbook:fetchIndex(server)
    local msg = busy(T(_("Loading song list: %1…"), self:serverName(server)))
    local body, err, code = fetch_from(server, "index.json")
    UIManager:close(msg)
    if not body then
        local text = T(_("Cannot load song list: %1"), err)
        local hint = access_hint(server, code)
        return nil, hint and text .. "\n\n" .. hint or text, code
    end
    local songs, perr, name = Repo.parse_index(body, require("json").decode)
    if perr == Repo.ERR_NEWER then
        return nil, _("This repository needs a newer version of the Songbook plugin.")
    end
    if not songs then return nil, T(_("Cannot load song list: %1"), perr) end
    if name ~= server.index_name then
        local servers = self:getServers()
        for _, s in ipairs(servers) do
            if s.key == server.key then s.index_name = name end
        end
        self:saveServers(servers)
        server.index_name = name
    end
    for _, song in ipairs(songs) do
        song.uid = make_uid(server.key, song.id)
        song.server = server
    end
    sort_songs(songs)
    return songs
end

function Songbook:isDownloaded(song)
    return lfs.attributes(self:songPath(song.uid), "mode") == "file"
end

function Songbook:isUpToDate(song)
    if not self:isDownloaded(song) then return false end
    local have = self:getMap("downloaded")[song.uid]
    return song.updated == nil or have == song.updated
end

function Songbook:download(song)
    local body, err = fetch_from(song.server, song.file)
    if not body then return nil, err end
    util.makePath(self.songs_dir .. "/" .. song.server.key)
    local ok, werr = write_file(self:songPath(song.uid), body)
    if not ok then return nil, werr end
    self:setMapValue("downloaded", song.uid, song.updated or true)
    return true
end

--- Run cb() online, asking for a first server when none is set up.
function Songbook:withServers(cb)
    if #self:onlineServers() == 0 then
        self:askServerUrl(_("Add song repository"), "", function(url)
            self:addServer(url)
            self:withServers(cb)
        end)
        return
    end
    NetworkMgr:runWhenOnline(cb)
end

function Songbook:browseOnline()
    self:withServers(function()
        local servers = self:onlineServers()
        if #servers == 1 then
            self:showOnlineSongs({ servers[1] })
            return
        end
        local picker
        local items = {{
            text = _("All repositories"),
            bold = true,
            callback = function() self:showOnlineSongs(servers) end,
        }}
        -- the jam session's songbooks (last in onlineServers()) under their own heading
        local jam_heading = false
        for _i, server in ipairs(servers) do
            if server.jam and not jam_heading then
                jam_heading = true
                items[#items].separator = true
                table.insert(items, { text = _("Jam session"), bold = true, select_enabled = false })
            end
            table.insert(items, {
                text = self:serverName(server),
                callback = function() self:showOnlineSongs({ server }) end,
            })
        end
        picker = list_menu(_("Song repositories"), items, function()
            return {{ text = _("Manage repositories…"), callback = function()
                -- the picker would show the old list
                UIManager:close(picker)
                self:showRepositories()
            end }}
        end)
        self:trackList(picker)
        UIManager:show(picker)
    end)
end

--- Load the indexes of `servers` and show their songs in one list.
-- Servers that fail are reported; the others are still shown.
function Songbook:showOnlineSongs(servers)
    local songs, errors = {}, {}
    for _, server in ipairs(servers) do
        local list, err = self:fetchIndex(server)
        if list then
            for _, song in ipairs(list) do table.insert(songs, song) end
        else
            table.insert(errors, self:serverName(server) .. ": " .. err)
        end
    end
    if #errors > 0 then notify(table.concat(errors, "\n")) end
    if #songs == 0 and #errors > 0 then return end
    local multi = #servers > 1
    if multi then
        sort_songs(songs)
    end

    local function status(song)
        if not self:isDownloaded(song) then return nil end
        return self:isUpToDate(song) and _("saved") or _("update")
    end
    local title = multi and _("All repositories") or self:serverName(servers[1])
    local function actions(refresh)
        local n = 0
        for _i, song in ipairs(songs) do
            if not self:isUpToDate(song) then n = n + 1 end
        end
        return {
            {
                text = n > 0 and T(_("Download all (%1)"), n) or _("All songs downloaded"),
                enabled = n > 0,
                callback = function()
                    self:downloadSongs(songs)
                    refresh()
                end,
            },
            { text = _("Manage repositories…"), callback = function() self:showRepositories() end },
        }
    end
    local keys = {}
    for _i, server in ipairs(servers) do table.insert(keys, server.key) end
    self:showList(title, function() return songs end, function(song)
        return {
            text = song.title,
            mandatory = details(song.artist, multi and self:serverName(song.server) or nil, status(song)),
            callback = function()
                if not self:isUpToDate(song) then
                    local msg = busy(T(_("Downloading %1…"), song.title))
                    local ok, derr = self:download(song)
                    UIManager:close(msg)
                    if not ok then
                        notify(T(_("Download failed: %1"), derr))
                        return
                    end
                end
                self:closeList()
                self:openSong(song.uid)
            end,
        }
    end, function(song, refresh)
        local dialog
        local function close() UIManager:close(dialog) end
        local function download()
            local msg = busy(T(_("Downloading %1…"), song.title))
            local ok, derr = self:download(song)
            UIManager:close(msg)
            if not ok then notify(T(_("Download failed: %1"), derr)) end
            return ok
        end
        local function ensure_downloaded()
            return self:isDownloaded(song) or download()
        end
        local buttons = {
            -- favorites, collections and our playlist hold songs on the device, so download first
            { self:playNowButton(song, close, ensure_downloaded) },
            { self:playlistButton(song, close, ensure_downloaded) },
            { self:favoriteButton(song, close, refresh, ensure_downloaded) },
            { self:collectionsButton(song, close, refresh, ensure_downloaded) },
            {{ text = _("Download again"), callback = function()
                close()
                if download() then
                    notify(_("Downloaded."))
                    refresh()
                end
            end }},
        }
        dialog = ButtonDialog:new{ title = song.title, buttons = buttons }
        UIManager:show(dialog)
    end, nil, actions, { last = { kind = "online", arg = keys } })
end

--- Download the songs of `songs` that aren't up to date and report how it went.
function Songbook:downloadSongs(songs)
    local missing = {}
    for _i, song in ipairs(songs) do
        if not self:isUpToDate(song) then table.insert(missing, song) end
    end
    local done, failed, in_row = 0, 0, 0
    for i, song in ipairs(missing) do
        local msg = busy(T(_("Downloading %1 / %2…"), i, #missing))
        local ok, err = self:download(song)
        UIManager:close(msg)
        if ok then
            done, in_row = done + 1, 0
        else
            failed, in_row = failed + 1, in_row + 1
            -- the connection is gone: every further song would wait for its timeout
            if in_row >= DOWNLOAD_MAX_FAILURES and i < #missing then
                notify(T(_("Downloading stopped after %1 failures in a row (%2). Downloaded: %3, not downloaded: %4"),
                    in_row, err, done, #missing - done))
                return
            end
        end
    end
    notify(T(_("Downloaded: %1, up to date: %2, failed: %3"), done, #songs - #missing, failed))
end

-- Managing repositories -------------------------------------------------------

--- Ask for a server URL. on_saved(url) is called with a non-empty URL.
function Songbook:askServerUrl(title, current, on_saved)
    local dialog
    dialog = InputDialog:new{
        title = title,
        description = _("GitHub repository address, or any web folder containing index.json."),
        input = current or "",
        input_hint = "https://github.com/user/songs",
        buttons = {{
            { text = _("Cancel"), id = "close", callback = function() UIManager:close(dialog) end },
            { text = _("Save"), is_enter_default = true, callback = function()
                local url = util.trim(dialog:getInputText())
                UIManager:close(dialog)
                if url ~= "" then on_saved(url) end
            end },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

--- Folder names a new repository key must not use.
function Songbook:takenKeys()
    local taken = { [JAM_KEY] = true }
    for _, server in ipairs(self:getServers()) do taken[server.key] = true end
    for _url, key in pairs(self.settings:readSetting("jam_servers") or {}) do taken[key] = true end
    -- also avoid folders left behind by removed servers
    for name in lfs.dir(self.songs_dir) do taken[name] = true end
    return taken
end

function Songbook:addServer(url)
    local servers = self:getServers()
    local server = { key = Repo.server_key(url, self:takenKeys()), url = url }
    table.insert(servers, server)
    self:saveServers(servers)
    util.makePath(self.songs_dir .. "/" .. server.key)
    return server
end

--- Update fields of the server with `key` (nil values clear a field).
function Songbook:updateServer(key, fields)
    local servers = self:getServers()
    for _, server in ipairs(servers) do
        if server.key == key then
            for k, v in pairs(fields) do server[k] = v end
        end
    end
    self:saveServers(servers)
end

--- Remove a server; with delete_songs also its downloaded songs.
function Songbook:removeServer(key, delete_songs)
    local servers = self:getServers()
    for i = #servers, 1, -1 do
        if servers[i].key == key then table.remove(servers, i) end
    end
    self:saveServers(servers)
    if not delete_songs then return end
    local dir = self.songs_dir .. "/" .. key
    if lfs.attributes(dir, "mode") ~= "directory" then return end
    for name in lfs.dir(dir) do
        local id = song_file_id(name)
        if id then
            self:deleteSong(make_uid(key, id))
        elseif name ~= "." and name ~= ".." then
            os.remove(dir .. "/" .. name)
        end
    end
    os.remove(dir)
end

--- Load the name of a repository that was just added or got a new URL from its
-- index (fetchIndex() saves it), so lists show it right away and not only after
-- its songs are loaded. done() runs afterwards, also when the index failed.
function Songbook:loadServerName(key, done)
    NetworkMgr:runWhenOnline(function()
        local server = self:findServer(key)
        local songs, err, code
        if server then songs, err, code = self:fetchIndex(server) end
        if server and not songs then
            if code == 404 and Repo.github(server.url) and not server.token then
                -- most likely a private repository
                UIManager:show(ConfirmBox:new{
                    text = err,
                    ok_text = _("Access token…"),
                    ok_callback = function() self:askServerToken(server, done) end,
                })
            else
                notify(err)
            end
        end
        done()
    end)
end

--- List of the song repositories: tap one to edit or remove it.
-- on_close(): optional, called when the list is closed.
function Songbook:showRepositories(on_close)
    local menu
    local refresh
    local function build()
        local items = {}
        for _i, server in ipairs(self:getServers()) do
            table.insert(items, {
                text = self:serverName(server),
                callback = function() self:showServerActions(server, refresh) end,
            })
        end
        table.insert(items, {
            text = _("Add repository…"),
            bold = true,
            callback = function()
                self:askServerUrl(_("Add song repository"), "", function(url)
                    local server = self:addServer(url)
                    refresh()
                    self:loadServerName(server.key, refresh)
                end)
            end,
        })
        return items
    end
    refresh = function() menu:switchItemTable(nil, build()) end
    menu = list_menu(_("Song repositories"), build())
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
    return true
end

function Songbook:showServerActions(server, on_changed)
    local dialog
    local function close_then(fn)
        return function()
            UIManager:close(dialog)
            fn()
        end
    end
    dialog = ButtonDialog:new{
        title = self:serverName(server) .. "\n" .. server.url,
        buttons = {
            {
                { text = _("Edit URL"), callback = close_then(function()
                    self:askServerUrl(_("Song repository URL"), server.url, function(url)
                        self:updateServer(server.key, { url = url, index_name = false })
                        on_changed()
                        self:loadServerName(server.key, on_changed)
                    end)
                end) },
                { text = _("Rename"), callback = close_then(function()
                    self:askServerName(server, on_changed)
                end) },
            },
            {
                { text = server.token and _("Access token (set)…") or _("Access token…"),
                  enabled = Repo.github(server.url) ~= nil,
                  callback = close_then(function()
                    self:askServerToken(server, on_changed)
                end) },
                { text = _("Remove"), callback = close_then(function()
                    self:askRemoveServer(server, on_changed)
                end) },
            },
        },
    }
    UIManager:show(dialog)
end

--- Where a token can be copied over USB (koreader/songbook/token.txt), to load
-- it instead of typing it.
function Songbook:tokenFile()
    return self.data_dir .. "/token.txt"
end

--- A token as GitHub makes them (ghp_…, github_pat_…), or nil.
local function clean_token(text)
    local token = util.trim(text or ""):match("^%S+$")
    return token and token:match("^[%w_]+$") and token or nil
end

--- Access token of a private GitHub repository: typed (hidden), loaded from
-- tokenFile() (which is deleted then) or removed. The token is checked by
-- loading the repository's index.
function Songbook:askServerToken(server, on_changed)
    local dialog
    local function save(token)
        UIManager:close(dialog)
        self:updateServer(server.key, { token = token or false })
        server.token = token
        on_changed()
        if token then self:loadServerName(server.key, on_changed) end
    end
    local file = self:tokenFile()
    local has_file = lfs.attributes(file, "mode") == "file"
    dialog = InputDialog:new{
        title = _("Access token"),
        description = T(_("For a private GitHub repository: a fine-grained personal access token (GitHub → Settings → Developer settings) with access to this repository only and the permission Contents: read-only.\n\nInstead of typing it, you can copy it into %1 and load it from there."), file),
        input = "",
        input_hint = server.token and _("Token is set; type a new one") or "github_pat_…",
        text_type = "password",
        buttons = {
            {
                { text = _("Load from file"), enabled = has_file, callback = function()
                    local token = clean_token((read_file(file) or ""):match("[^\r\n]*"))
                    if not token then
                        UIManager:close(dialog)
                        return notify(T(_("No token found in %1."), file))
                    end
                    os.remove(file)
                    save(token)
                end },
                { text = _("Remove token"), enabled = server.token and true or false, callback = function() save(nil) end },
            },
            {
                { text = _("Cancel"), id = "close", callback = function() UIManager:close(dialog) end },
                { text = _("Save"), is_enter_default = true, callback = function()
                    local token = clean_token(dialog:getInputText())
                    if not token then
                        UIManager:close(dialog)
                        return notify(_("That doesn't look like a GitHub token."))
                    end
                    save(token)
                end },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function Songbook:askServerName(server, on_changed)
    local dialog
    dialog = InputDialog:new{
        title = _("Repository name"),
        description = _("Leave empty to use the name from the repository."),
        input = server.name or "",
        input_hint = server.index_name or Repo.default_name(server.url),
        buttons = {{
            { text = _("Cancel"), id = "close", callback = function() UIManager:close(dialog) end },
            { text = _("Save"), is_enter_default = true, callback = function()
                local name = util.trim(dialog:getInputText())
                UIManager:close(dialog)
                self:updateServer(server.key, { name = name ~= "" and name or false })
                on_changed()
            end },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function Songbook:askRemoveServer(server, on_changed)
    local dialog
    local function remove(delete_songs)
        return function()
            UIManager:close(dialog)
            self:removeServer(server.key, delete_songs)
            on_changed()
        end
    end
    dialog = ButtonDialog:new{
        title = T(_("Remove repository \"%1\"?"), self:serverName(server)),
        buttons = {
            {{ text = _("Remove and delete its songs"), callback = remove(true) }},
            {{ text = _("Remove, keep downloaded songs"), callback = remove(false) }},
            {{ text = _("Cancel"), callback = function() UIManager:close(dialog) end }},
        },
    }
    UIManager:show(dialog)
end
