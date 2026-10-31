--[[--
Jam session web server: request parsing, routing and the guest web page
(pure Lua 5.1 / LuaJIT). main.lua owns the socket and passes a context:

ctx = {
  state     = function() -> { uid=, rev=, title=, artist=, notation= } (uid nil = no song)
  song_html = function(opts) -> html or nil      -- opts = { shift=, notation=, show_chords=, max_cols= }
  song_cho  = function() -> ChordPro text or nil
  songs     = function() -> list of { uid=, title=, artist=, key=, updated= } (all songs on the device)
  song_file = function(uid) -> ChordPro text or nil
  name      = repository name for /index.json,
  playlist  = function() -> { history = {entry...}, queue = {entry...} }
  request   = function(uid, by) -> true or nil, error ("queued", "full", "missing")
  labels    = see DEFAULT_LABELS,
  css       = stylesheet for the song inside the page,
}
`shift` is the guest's own transposition on top of the host's.

Endpoints (GET only; KOReader's SimpleTCPServer reads just the headers):
  /             guest page, polls /state.json and loads /song.html on change
  /state.json   what is being played; "rev" changes with the song or the host's options
  /song.html    current song; ?t= semitones on top of the host's key, ?n=cz|en, ?c=0 (no chords), ?w= columns
  /song.cho     current song source
  /index.json   all songs in the song repository format, so the host can be added as a repository
  /songs/<file> one song of the index ("~" stands for "/" in the uid)
  /playlist.json  played songs and guests' requests; entry = { uid, title, artist, by, at }
  /queue/add?uid=&by=  request a song -> { ok = true } or { ok = false, error = }
                       (?id= instead of uid: the song's id in /index.json, used by following songbooks)

Following another songbook (normalize_url, parse_state, song_id) is also
here; main.lua does the polling.
]]

local Render = require("songbook/render")

local M = {}

M.MAX_QUEUE = 30
M.MAX_HISTORY = 200
M.MAX_NAME = 30

local STATUS = {
    [200] = "OK", [400] = "Bad Request", [404] = "Not Found",
    [405] = "Method Not Allowed", [500] = "Internal Server Error",
}

local function url_decode(s)
    s = s:gsub("+", " ")
    return (s:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end))
end

--- Parse raw request headers. Returns { method, path, query } or nil.
function M.parse_request(data)
    local method, target = (data or ""):match("^(%u+) (%S+) HTTP/%d%.%d")
    if not method then return nil end
    local path, qs = target:match("^([^?#]*)%??([^#]*)")
    local query = {}
    for pair in qs:gmatch("[^&]+") do
        local k, v = pair:match("^([^=]*)=?(.*)$")
        query[url_decode(k)] = url_decode(v)
    end
    return { method = method, path = url_decode(path), query = query }
end

function M.response(code, ctype, body)
    body = body or ""
    return table.concat({
        "HTTP/1.1 " .. code .. " " .. (STATUS[code] or ""),
        "Content-Type: " .. ctype,
        "Content-Length: " .. #body,
        "Cache-Control: no-store",
        "Connection: close",
        "", body,
    }, "\r\n")
end

local function json_string(s)
    return '"' .. s:gsub('[%c"\\]', function(c)
        if c == '"' or c == "\\" then return "\\" .. c end
        return string.format("\\u%04x", c:byte())
    end) .. '"'
end

--- JSON for strings, numbers, booleans and tables (an empty table or one with
-- t[1] is an array; object keys are sorted).
function M.json(v)
    if type(v) == "string" then return json_string(v) end
    if type(v) ~= "table" then return tostring(v) end
    local out = {}
    if v[1] ~= nil or next(v) == nil then
        for _, item in ipairs(v) do out[#out + 1] = M.json(item) end
        return "[" .. table.concat(out, ",") .. "]"
    end
    local keys = {}
    for k in pairs(v) do keys[#keys + 1] = k end
    table.sort(keys)
    for _, k in ipairs(keys) do
        out[#out + 1] = json_string(k) .. ":" .. M.json(v[k])
    end
    return "{" .. table.concat(out, ",") .. "}"
end

--- File name stem of a song in /songs/ and its id in /index.json.
local function file_stem(uid) return (uid:gsub("/", "~")) end

--- Song id (file-name safe) for a uid of another songbook.
function M.song_id(uid)
    return (file_stem(uid):gsub("[^%w%-_%.]", "_"):gsub("^%.+", ""))
end

--- uid of the song with index id `id`, or nil.
function M.find_id(songs, id)
    for _, song in ipairs(songs) do
        if M.song_id(song.uid) == id then return song.uid end
    end
end

--- uid for a /songs/<stem>.cho request, or nil if it could leave the songs folder.
function M.uid_from_stem(stem)
    if not stem:match("^[%w%-_][%w%-_%.~]*$") or stem:find("..", 1, true) then return nil end
    return (stem:gsub("~", "/"))
end

--- index.json for songs as listed by ctx.songs().
function M.index(songs, name)
    local list = {}
    for _, song in ipairs(songs) do
        list[#list + 1] = {
            id = M.song_id(song.uid),
            uid = song.uid,
            file = "songs/" .. file_stem(song.uid) .. ".cho",
            title = song.title, artist = song.artist, key = song.key, updated = song.updated,
        }
    end
    return M.json({ version = 1, name = name, songs = list })
end

--- Address typed by a guest -> base URL ending with "/" (port added if missing).
function M.normalize_url(text, default_port)
    text = (text or ""):match("^%s*(.-)%s*$")
    if text == "" then return nil end
    if not text:match("^%a[%w+.-]*://") then text = "http://" .. text end
    local scheme, authority, path = text:match("^(%a[%w+.-]*://)([^/]*)(.*)$")
    if authority == "" then return nil end
    if not authority:match(":%d+$") and default_port then authority = authority .. ":" .. default_port end
    if path:sub(-1) ~= "/" then path = path .. "/" end
    return scheme .. authority .. path
end

--- Decode /state.json of another songbook. Returns { uid, rev, transpose } or nil.
function M.parse_state(body, decode)
    local ok, data = pcall(decode, body)
    if not ok or type(data) ~= "table" then return nil end
    local state = { transpose = 0 }
    if type(data.uid) == "string" and data.uid ~= "" and type(data.rev) == "string" then
        state.uid, state.rev = data.uid, data.rev
        if type(data.transpose) == "number" then state.transpose = M.add_semitones(data.transpose, 0) end
    end
    return state
end

--- Host transposition plus a guest's own shift, kept within -11..11.
function M.add_semitones(a, b)
    local t = ((a or 0) + (b or 0)) % 12
    if t > 6 then t = t - 12 end
    return t
end

local function int_param(v, min, max)
    local n = tonumber(v)
    if not n then return nil end
    n = math.floor(n)
    if n < min then return min elseif n > max then return max end
    return n
end

local function escape(s)
    return (s:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"):gsub('"', "&quot;"))
end

local PAGE = [[<!DOCTYPE html>
<html><head><meta charset="utf-8"/>
<meta name="viewport" content="width=device-width, initial-scale=1"/>
<title>%s</title>
<style>%s
body { margin: 0; }
#bar { position: sticky; top: 0; display: flex; flex-wrap: wrap; gap: 0.3em; align-items: center;
       padding: 0.4em 0.8em; background: inherit; border-bottom: 1px solid #8884; }
button { font-size: 1em; min-width: 2.4em; padding: 0.3em 0.5em; border-radius: 0.3em;
         border: 1px solid #8888; background: transparent; color: inherit; }
button.on { background: #8883; }
#t { min-width: 2em; text-align: center; }
#status { margin-left: auto; font-size: 0.85em; opacity: 0.7; }
#song, #list { margin: 0.8em; }
#song pre { font-size: var(--fs, 16px); }
#probe { position: absolute; visibility: hidden; }
#list h2 { font-size: 1.1em; margin: 1em 0 0.3em 0; }
#list ul { list-style: none; padding: 0; margin: 0; }
#list li { padding: 0.35em 0; border-bottom: 1px solid #8882; display: flex; gap: 0.5em; align-items: baseline; }
#list li .d { opacity: 0.7; font-size: 0.9em; }
#list li button { min-width: 2em; padding: 0.1em 0.4em; }
#list input { font-size: 1em; padding: 0.3em; width: 100%%; box-sizing: border-box; margin: 0.2em 0;
              background: transparent; color: inherit; border: 1px solid #8888; border-radius: 0.3em; }
#msg { min-height: 1.2em; font-weight: bold; }
</style></head><body>
<div id="bar">
<button id="tab"></button>
<span id="songbar"><button id="down">♭</button> <span id="t">0</span> <button id="up">♯</button>
<button id="nota">H</button> <button id="chords" class="on">%s</button>
<button id="smaller">A−</button> <button id="bigger">A+</button></span>
<span id="status"></span>
</div>
<div id="song"><p>%s</p></div>
<div id="list" hidden>
<h2 id="h_queue"></h2><ul id="queue"></ul>
<h2 id="h_request"></h2>
<input id="name" maxlength="30"/><input id="search" type="search"/>
<p id="msg"></p><ul id="songs"></ul>
<h2 id="h_history"></h2><ul id="history"></ul>
</div>
<pre id="probe">0000000000</pre>
<script>
var L = %s;
var P = { t: 0, n: "", c: 1, fs: 16, by: "" };
try { var saved = JSON.parse(localStorage.getItem("songbook-jam")); for (var k in saved) P[k] = saved[k]; } catch (e) {}
var rev = null, uid = null, host_notation = "cz", view = "song", songs = null;
function $(id) { return document.getElementById(id); }
function save() { try { localStorage.setItem("songbook-jam", JSON.stringify(P)); } catch (e) {} }
function json(r) { return r.json(); }
function el(tag, text, cls) {
  var e = document.createElement(tag);
  if (text != null) e.textContent = text;
  if (cls) e.className = cls;
  return e;
}
function cols() {
  var probe = $("probe");
  probe.style.fontSize = P.fs + "px";
  var w = probe.getBoundingClientRect().width / 10;
  return Math.max(16, Math.floor(($("song").clientWidth - 4) / w));
}
function bar() {
  $("t").textContent = P.t > 0 ? "+" + P.t : String(P.t);
  $("nota").textContent = (P.n || host_notation) == "cz" ? "H" : "B";
  $("chords").className = P.c ? "on" : "";
  document.documentElement.style.setProperty("--fs", P.fs + "px");
  $("tab").textContent = view == "song" ? L.playlist : L.song;
  $("songbar").hidden = view != "song";
  $("song").hidden = view != "song";
  $("list").hidden = view == "song";
}
function load(scroll) {
  if (!uid) return;
  var url = "/song.html?t=" + P.t + "&n=" + (P.n || host_notation) + "&c=" + P.c + "&w=" + cols()
    + "&rev=" + encodeURIComponent(rev);
  fetch(url, { cache: "no-store" }).then(function (r) { return r.text(); }).then(function (html) {
    var doc = new DOMParser().parseFromString(html, "text/html");
    $("song").innerHTML = doc.body.innerHTML;
    document.title = doc.title;
    if (scroll && view == "song") window.scrollTo(0, 0);
  });
}
function pad(n) { return n < 10 ? "0" + n : String(n); }
function entry(e, extra) {
  var li = el("li");
  li.appendChild(el("span", e.title));
  var d = [e.artist, extra].filter(Boolean).join(" · ");
  if (d) li.appendChild(el("span", d, "d"));
  return li;
}
function fill(ul, list, extra) {
  ul.innerHTML = "";
  list.forEach(function (e) { ul.appendChild(entry(e, extra(e))); });
  if (!list.length) ul.appendChild(el("li", L.nothing, "d"));
}
function loadPlaylist() {
  fetch("/playlist.json", { cache: "no-store" }).then(json).then(function (p) {
    fill($("queue"), p.queue, function (e) { return e.by; });
    fill($("history"), p.history.slice().reverse(), function (e) {
      var t = new Date(e.at * 1000);
      return pad(t.getHours()) + ":" + pad(t.getMinutes());
    });
  });
}
function norm(s) { return s.toLowerCase().normalize("NFD").replace(/[̀-ͯ]/g, ""); }
function showSongs() {
  var q = norm($("search").value.trim()), ul = $("songs"), n = 0;
  ul.innerHTML = "";
  (songs || []).forEach(function (s) {
    if (n >= 100 || (q && norm(s.title + " " + (s.artist || "")).indexOf(q) < 0)) return;
    n++;
    var li = entry(s), b = el("button", "+");
    b.onclick = function () { request(s); };
    li.insertBefore(b, li.firstChild);
    ul.appendChild(li);
  });
}
function loadSongs() {
  if (songs) return showSongs();
  fetch("/index.json", { cache: "no-store" }).then(json).then(function (i) { songs = i.songs; showSongs(); });
}
function request(s) {
  P.by = $("name").value.trim(); save();
  fetch("/queue/add?uid=" + encodeURIComponent(s.uid) + "&by=" + encodeURIComponent(P.by), { cache: "no-store" })
    .then(json).then(function (r) {
      $("msg").textContent = r.ok ? L.requested.replace("%%1", s.title) : (L[r.error] || r.error);
      loadPlaylist();
    });
}
function poll() {
  fetch("/state.json", { cache: "no-store" }).then(json).then(function (s) {
    $("status").textContent = "";
    host_notation = s.notation || "cz";
    if (!s.uid) {
      if (uid !== null || rev === null) $("song").innerHTML = "<p>" + L.waiting + "</p>";
      uid = null; rev = "";
    } else if (s.rev !== rev) {
      var changed = s.uid !== uid;
      uid = s.uid; rev = s.rev;
      bar(); load(changed);
    }
    if (view == "list") loadPlaylist();
  }).catch(function () { $("status").textContent = L.offline; })
    .then(function () { setTimeout(poll, 3000); });
}
function change(f) { return function () { f(); save(); bar(); load(false); }; }
$("up").onclick = change(function () { P.t = P.t >= 11 ? -11 : P.t + 1; });
$("down").onclick = change(function () { P.t = P.t <= -11 ? 11 : P.t - 1; });
$("nota").onclick = change(function () { P.n = (P.n || host_notation) == "cz" ? "en" : "cz"; });
$("chords").onclick = change(function () { P.c = P.c ? 0 : 1; });
$("smaller").onclick = change(function () { P.fs = Math.max(8, P.fs - 2); });
$("bigger").onclick = change(function () { P.fs = Math.min(40, P.fs + 2); });
$("tab").onclick = function () {
  view = view == "song" ? "list" : "song";
  bar(); window.scrollTo(0, 0);
  if (view == "list") { loadPlaylist(); loadSongs(); } else load(false);
};
$("search").oninput = showSongs;
$("name").value = P.by;
$("name").placeholder = L.your_name;
$("search").placeholder = L.search;
$("h_queue").textContent = L.up_next;
$("h_request").textContent = L.request;
$("h_history").textContent = L.played;
var resize_timer;
window.onresize = function () { clearTimeout(resize_timer); resize_timer = setTimeout(function () { load(false); }, 300); };
bar(); poll();
</script></body></html>
]]

local DEFAULT_LABELS = {
    title = "Songbook", waiting = "Waiting for a song…", offline = "Connection lost", chords = "Chords",
    song = "Song", playlist = "Playlist", up_next = "Up next", played = "Played",
    request = "Request a song", your_name = "Your name", search = "Search", nothing = "Nothing yet",
    requested = "Requested: %1", queued = "This song is already requested.",
    full = "Too many requests, try again later.", missing = "This song is not available.",
}

--- Guest web page; labels are inserted as text.
function M.page(labels, css)
    local l = {}
    for k, v in pairs(DEFAULT_LABELS) do l[k] = (labels and labels[k]) or v end
    local js = {}
    for k, v in pairs(l) do js[k] = v end
    js.waiting = escape(l.waiting)   -- inserted as HTML
    -- Plain gsub replacements: labels may contain "%".
    local values = { escape(l.title), css or "", escape(l.chords), escape(l.waiting), M.json(js) }
    local i = 0
    return (PAGE:gsub("%%(.)", function(c)
        if c ~= "s" then return c end   -- "%%" in PAGE is a literal "%"
        i = i + 1
        return values[i]
    end))
end

-- Playlist ------------------------------------------------------------------

--- Guest name: one line, at most MAX_NAME characters, nil if empty.
function M.clean_name(by)
    by = (by or ""):gsub("%c", " "):match("^%s*(.-)%s*$")
    if by == "" then return nil end
    return Render.truncate(by, M.MAX_NAME)
end

--- Add a request to the queue. Returns true or nil, "queued" / "full".
function M.add_request(queue, entry)
    for _, e in ipairs(queue) do
        if e.uid == entry.uid then return nil, "queued" end
    end
    if #queue >= M.MAX_QUEUE then return nil, "full" end
    queue[#queue + 1] = entry
    return true
end

--- Record a played song: append it to history (unless it is the last one
-- already, e.g. after transposing) and drop it from the queue.
-- Returns true when the playlist changed.
function M.played(history, queue, entry)
    local changed = false
    for i = #queue, 1, -1 do
        if queue[i].uid == entry.uid then
            table.remove(queue, i)
            changed = true
        end
    end
    local last = history[#history]
    if not (last and last.uid == entry.uid) then
        history[#history + 1] = entry
        while #history > M.MAX_HISTORY do table.remove(history, 1) end
        changed = true
    end
    return changed
end

--- Route a parsed request. Returns the full HTTP response string.
function M.handle(req, ctx)
    if not req then return M.response(400, "text/plain", "Bad request") end
    if req.method ~= "GET" then return M.response(405, "text/plain", "Only GET is supported") end
    local path = req.path
    if path == "/" or path == "/index.html" then
        return M.response(200, "text/html; charset=utf-8", M.page(ctx.labels, ctx.css))
    elseif path == "/state.json" then
        return M.response(200, "application/json; charset=utf-8", M.json(ctx.state()))
    elseif path == "/song.html" then
        local q = req.query
        local html = ctx.song_html({
            shift = int_param(q.t, -11, 11) or 0,
            notation = (q.n == "cz" or q.n == "en") and q.n or nil,
            show_chords = q.c ~= "0",
            max_cols = int_param(q.w, 16, 160),
        })
        if not html then return M.response(404, "text/plain", "No song is being played") end
        return M.response(200, "text/html; charset=utf-8", html)
    elseif path == "/song.cho" then
        local cho = ctx.song_cho()
        if not cho then return M.response(404, "text/plain", "No song is being played") end
        return M.response(200, "text/plain; charset=utf-8", cho)
    elseif path == "/index.json" then
        return M.response(200, "application/json; charset=utf-8", M.index(ctx.songs(), ctx.name))
    elseif path == "/playlist.json" then
        local p = ctx.playlist()
        return M.response(200, "application/json; charset=utf-8",
            M.json({ history = p.history or {}, queue = p.queue or {} }))
    elseif path == "/queue/add" then
        local ok, err = nil, "missing"
        local uid = req.query.uid
        if (not uid or uid == "") and req.query.id then uid = M.find_id(ctx.songs(), req.query.id) end
        if uid and uid ~= "" then
            ok, err = ctx.request(uid, M.clean_name(req.query.by))
        end
        return M.response(200, "application/json; charset=utf-8",
            M.json(ok and { ok = true } or { ok = false, error = err or "missing" }))
    end
    local stem = path:match("^/songs/(.+)%.cho$")
    local uid = stem and M.uid_from_stem(stem)
    local cho = uid and ctx.song_file(uid)
    if cho then
        return M.response(200, "text/plain; charset=utf-8", cho)
    end
    return M.response(404, "text/plain", "Not found")
end

return M
