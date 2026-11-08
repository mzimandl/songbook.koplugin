--[[--
Finding shared songbooks on the local network (pure Lua 5.1 / LuaJIT).
No KOReader modules: `socket` (LuaSocket) is passed in, so tests can fake it.
Everything is non-blocking and polled (songbook/ui/jam.lua polls from UIManager ZMQs).

A follower broadcasts "SONGBOOK-DISCOVER <version>" from SEARCH_PORT (or any
port) to DISCOVERY_PORT; a sharing songbook answers to the sender with
"SONGBOOK <version> <http port> <name>". Other versions are ignored.
]]

local M = {}

M.VERSION = 1
M.DISCOVERY_PORT = 8766 -- UDP, sharing songbook listens
M.SEARCH_PORT = 8767    -- UDP, follower listens for answers
M.MAX_NAME = 32         -- characters

--- Name cleaned for the wire: no control characters, at most MAX_NAME characters.
function M.clean_name(name)
    name = tostring(name or ""):gsub("%c", " "):gsub("^%s+", ""):gsub("%s+$", "")
    local out, count = {}, 0
    for ch in name:gmatch("[\1-\127\194-\244][\128-\191]*") do
        count = count + 1
        if count > M.MAX_NAME then break end
        out[#out + 1] = ch
    end
    return table.concat(out)
end

--- Broadcast addresses to search: everywhere, and the /24 network of `ip`
-- (some routers drop 255.255.255.255).
function M.broadcasts(ip)
    local out = { "255.255.255.255" }
    local a, b, c = (ip or ""):match("^(%d+)%.(%d+)%.(%d+)%.%d+$")
    if a then out[#out + 1] = a .. "." .. b .. "." .. c .. ".255" end
    return out
end

--- IPv4 address of this device on the local network from a list of network
-- interfaces as KOReader's ffi/netinfo retrieves them ({ name, ipv4, wireless };
-- ipv4 may be "a / b"): a wireless one first. nil when there is none.
function M.pick_ip(ifaces)
    local found
    for _i, iface in ipairs(ifaces or {}) do
        local ip = type(iface.ipv4) == "string" and iface.ipv4:match("^%s*(%d+%.%d+%.%d+%.%d+)")
        if ip and not ip:match("^127%.") and not ip:match("^169%.254%.") then
            if iface.wireless then return ip end
            found = found or ip
        end
    end
    return found
end

function M.discover()
    return "SONGBOOK-DISCOVER " .. M.VERSION
end

function M.is_discover(msg)
    local version = (msg or ""):match("^SONGBOOK%-DISCOVER (%d+)")
    return version ~= nil and tonumber(version) == M.VERSION
end

function M.announce(port, name)
    return string.format("SONGBOOK %d %d %s", M.VERSION, port, M.clean_name(name))
end

--- An answer to a search: { port, name }, or nil for anything else.
function M.parse_announce(msg)
    local version, port, name = (msg or ""):match("^SONGBOOK (%d+) (%d+) ?(.-)%s*$")
    port = tonumber(port)
    if not version or tonumber(version) ~= M.VERSION or port < 1 or port > 65535 then return nil end
    return { port = port, name = M.clean_name(name) }
end

--- Base URL of a found songbook (as Jam.normalize_url() makes it).
function M.url(found)
    return string.format("http://%s:%d/", found.ip, found.port)
end

-- Sharing: answers searches ------------------------------------------------------

local Responder = {}
Responder.__index = Responder

--- Listens on DISCOVERY_PORT and answers with `port` and name_fn(). Returns the
-- responder, or nil, error (then the songbook can still be followed by address).
function M.responder(socket, port, name_fn)
    local udp = socket.udp()
    if not udp then return nil, "udp" end
    local ok, err = udp:setsockname("*", M.DISCOVERY_PORT)
    if not ok then
        udp:close()
        return nil, err
    end
    udp:settimeout(0)
    return setmetatable({ udp = udp, port = port, name_fn = name_fn }, Responder)
end

function Responder:poll()
    while true do
        local msg, ip, port = self.udp:receivefrom()
        if not msg then break end
        if M.is_discover(msg) then
            self.udp:sendto(M.announce(self.port, self.name_fn()), ip, port)
        end
    end
end

function Responder:close()
    self.udp:close()
end

-- Following: searches ------------------------------------------------------------

local Search = {}
Search.__index = Search

--- Broadcasts searches (send() every second or so) and collects answers in
-- `found` (list of { ip, port, name, seen }).
function M.search(socket, local_ip)
    local udp = socket.udp()
    if not udp then return nil, "udp" end
    if not udp:setsockname("*", M.SEARCH_PORT) then
        udp:close()
        udp = socket.udp()
        if not udp or not udp:setsockname("*", 0) then return nil, "udp" end
    end
    udp:settimeout(0)
    udp:setoption("broadcast", true)
    return setmetatable({ udp = udp, found = {}, targets = M.broadcasts(local_ip) }, Search)
end

function Search:send()
    for _i, addr in ipairs(self.targets) do
        self.udp:sendto(M.discover(), addr, M.DISCOVERY_PORT)
    end
end

--- Reads answers. Returns true when the list changed.
function Search:poll(now)
    local changed = false
    while true do
        local msg, ip = self.udp:receivefrom()
        if not msg then break end
        local book = M.parse_announce(msg)
        if book then
            local known
            for _i, f in ipairs(self.found) do
                if f.ip == ip and f.port == book.port then known = f end
            end
            if known then
                if known.name ~= book.name then changed = true end
                known.name, known.seen = book.name, now
            else
                self.found[#self.found + 1] = { ip = ip, port = book.port, name = book.name, seen = now }
                changed = true
            end
        end
    end
    return changed
end

--- Drops songbooks not heard of for `age` seconds. Returns true when any was dropped.
function Search:expire(now, age)
    local changed = false
    for i = #self.found, 1, -1 do
        if now - self.found[i].seen > age then
            table.remove(self.found, i)
            changed = true
        end
    end
    return changed
end

function Search:close()
    self.udp:close()
end

return M
