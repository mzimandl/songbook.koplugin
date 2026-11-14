--[[--
HTTP GET that never waits (pure Lua 5.1 / LuaJIT).
No KOReader modules: `socket` (LuaSocket) is passed in, so tests can fake it.

For plain "http://" addresses on the local network (the followed songbook):
socket.http blocks the UI until the answer or its timeout, which freezes the
reader when the other songbook is gone. Here the connection is opened with a
zero timeout and poll() moves it on a little each time it is called
(songbook/ui/jam.lua polls from a UIManager ZMQ):

    local req = HttpGet.start(socket, url, 4, now)   -- nil, err for another scheme
    ... if req:poll(now) then use req.body (or req.err, req.code) end
    req:close()

The answer is read until the server closes the connection or Content-Length
bytes came (the songbook's server does both); chunked answers are not read.
]]

local M = {}

M.MAX_BODY = 4 * 1024 * 1024   -- bytes: more is refused (a song, an index)

--- host, port, path of an "http://" URL ("[::1]" hosts without the brackets), or nil.
function M.parse_url(url)
    local authority, path = (url or ""):match("^http://([^/?#]+)([^#]*)")
    if not authority then return nil end
    local host, port = authority:match("^%[(.+)%]:(%d+)$")
    if not host then host = authority:match("^%[(.+)%]$") end
    if not host then host, port = authority:match("^([^:]+):(%d+)$") end
    if not host then host = authority:match("^[^:]+$") end
    if not host then return nil end
    port = tonumber(port or 80)
    if port < 1 or port > 65535 then return nil end
    if path == "" or path:sub(1, 1) == "?" then path = "/" .. path end
    return host, port, path
end

--- Status code and body of a raw HTTP response; complete = true once all of a
-- Content-Length body is there. nil while the headers are incomplete.
function M.parse_response(data)
    local head_end, body_start = data:find("\r\n\r\n", 1, true)
    if not head_end then return nil end
    local head = data:sub(1, head_end)
    local code = tonumber(head:match("^HTTP/%d%.%d (%d%d%d)"))
    if not code then return nil end
    local body = data:sub(body_start + 1)
    local length = tonumber(head:lower():match("\r\ncontent%-length:%s*(%d+)"))
    if length and #body >= length then return code, body:sub(1, length), true end
    return code, body, false
end

local Request = {}
Request.__index = Request

--- Start GET `url`, to be finished within `timeout` seconds from `now`.
-- Returns the request (poll() it), or nil, error.
function M.start(socket, url, timeout, now)
    local host, port, path = M.parse_url(url)
    if not host then return nil, "not an http:// address" end
    local tcp, err = socket.tcp()
    if not tcp then return nil, err end
    tcp:settimeout(0)
    local req = setmetatable({
        socket = socket, tcp = tcp, deadline = now + timeout,
        state = "connecting", sent = 0, chunks = {}, size = 0,
        out = "GET " .. path .. " HTTP/1.1\r\nHost: " .. host .. ":" .. port
            .. "\r\nUser-Agent: KOReader-Songbook\r\nCache-Control: no-cache\r\nConnection: close\r\n\r\n",
    }, Request)
    -- with a zero timeout this returns at once: 1, or nil, "timeout" while connecting
    local ok, cerr = tcp:connect(host, port)
    if ok then
        req.state = "sending"
    elseif cerr ~= "timeout" and cerr ~= "Operation already in progress" then
        req:finish(nil, cerr)
    end
    return req
end

function Request:finish(body, err, code)
    self.done, self.body, self.err, self.code = true, body, err, code
    self:close()
end

function Request:close()
    if self.tcp then
        self.tcp:close()
        self.tcp = nil
    end
end

-- All that came: the body when the status is 200.
function Request:answer(closed)
    local data = table.concat(self.chunks)
    local code, body, complete = M.parse_response(data)
    if not code then
        if closed then self:finish(nil, "no answer") end
        return
    end
    if not (complete or closed) then return end
    if code ~= 200 then return self:finish(nil, "HTTP " .. code, code) end
    self:finish(body, nil, code)
end

--- Move the request on without waiting. Returns true once it is finished:
-- then `body` is the answer, or nil with `err` (and `code` for an HTTP status).
function Request:poll(now)
    if self.done then return true end
    if now > self.deadline then
        self:finish(nil, "timeout")
        return true
    end
    if self.state == "connecting" then
        -- writable = connected, or the connection failed (then there is no peer)
        local _r, writable = self.socket.select(nil, { self.tcp }, 0)
        if not (writable and writable[1]) then return false end
        if not self.tcp:getpeername() then
            self:finish(nil, "connection failed")
            return true
        end
        self.state = "sending"
    end
    if self.state == "sending" then
        local last, err, partial = self.tcp:send(self.out, self.sent + 1)
        if last then
            self.sent = last
        elseif err == "timeout" then
            self.sent = partial or self.sent
        else
            self:finish(nil, err)
            return true
        end
        if self.sent < #self.out then return false end
        self.state = "receiving"
    end
    while not self.done do
        local data, err, partial = self.tcp:receive(8192)
        local chunk = data or partial
        if chunk and chunk ~= "" then
            self.chunks[#self.chunks + 1] = chunk
            self.size = self.size + #chunk
            if self.size > M.MAX_BODY then
                self:finish(nil, "answer too long")
                return true
            end
        end
        if data then
            self:answer(false)
        elseif err == "closed" then
            self:answer(true)
            if not self.done then self:finish(nil, "no answer") end
        elseif err == "timeout" then
            self:answer(false)   -- nothing more for now
            break
        else
            self:finish(nil, err)
        end
    end
    return self.done == true
end

return M
