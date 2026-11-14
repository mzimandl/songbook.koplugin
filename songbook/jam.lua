--[[--
Jam session web server: request parsing, routing and the guest web page
(pure Lua 5.1 / LuaJIT). songbook/ui/jam.lua owns the socket and passes a context:

ctx = {
  state     = function(peer_url) -> { uid=, rev=, title=, artist=, notation=, name=, peers= }
              (uid nil = no song; peers = { { url=, name= } } without the asking peer_url)
  song_html = function(opts) -> html or nil      -- opts = { shift=, notation=, show_chords= }
  song_cho  = function() -> ChordPro text or nil
  songs     = function() -> list of { uid=, title=, artist=, key=, updated= } (all songs on the device)
  song_file = function(uid) -> ChordPro text or nil
  name      = repository name for /index.json,
  playlist  = function() -> { now = entry or nil, history = {entry...}, queue = {entry...} }
  request   = function(uid, by) -> true or nil, error ("queued", "full", "missing")
  join      = function(peer) -- a following songbook shares its songs: peer = { url=, name= }
  request_from = function(url, uid, by) -> like request; `uid` is a song of the peer at `url`
  library   = true: serve only /index.json and /songs/ (a following songbook's own songs)
  labels    = see DEFAULT_LABELS,
  css       = stylesheet for the song inside the page,
}
`shift` is the guest's own transposition on top of the host's.

Endpoints (GET only; KOReader's SimpleTCPServer reads just the headers):
  /             guest page, polls /state.json and loads /song.html on change
  /state.json   the song now playing; "rev" changes with the song or the host's options;
                "api" = API_VERSION (missing before 1.0: version 1); "scroll" =
                { progress = 0..1, duration = seconds } while the host autoscrolls it
                (optional, since 1.3: the guest page scrolls along)
                ?name=&share=<port>: a following songbook that shares its own songs on
                that port (same endpoints, `library`); polling keeps it among the peers
  /song.html    song now playing; ?t= semitones on top of the host's key, ?n=cz|en, ?c=0 (no chords)
  /song.cho     source of the song now playing
  /index.json   all songs in the song repository format, so the host can be added as a repository
  /songs/<file> one song of the index ("~" stands for "/" in the uid)
  /playlist.json  now playing, played songs and guests' requests; entry = { uid, title, artist, by, at }
  /queue/add?uid=&by=  request a song -> { ok = true } or { ok = false, error = }
                       (?id= instead of uid: the song's id in /index.json, used by following songbooks;
                       ?from=<port>: uid is a song of the asking songbook, shared on that port)

Following another songbook (normalize_url, parse_state, song_id) is also
here; songbook/ui/jam.lua does the polling.
]]

local Render = require("songbook/render")

local M = {}

--- Version of the API other songbooks use (/state.json "api", /song paths,
-- /queue/add). Raise it only for changes older songbooks would misread;
-- a follower stops following a songbook with a newer one.
M.API_VERSION = 1
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

--- Is `uid` a song uid that stays inside the songs folder? ("<id>" or
-- "<key>/<id>"; ids of copied files may contain spaces or accents.)
function M.valid_uid(uid)
    if type(uid) ~= "string" or uid:find("[%c\\]") then return false end
    local parts = { uid:match("^([^/]+)/([^/]+)$") }
    if #parts == 0 then
        if uid == "" or uid:find("/", 1, true) then return false end
        parts = { uid }
    end
    for _, part in ipairs(parts) do
        if part:sub(1, 1) == "." then return false end   -- ".", ".." and hidden files
    end
    return true
end

--- uid for a /songs/<stem>.cho request, or nil if it could leave the songs folder.
function M.uid_from_stem(stem)
    local uid = stem:gsub("~", "/")
    return M.valid_uid(uid) and uid or nil
end

local function url_encode(s)
    return (s:gsub("[^%w%-_%.~]", function(c) return string.format("%%%02X", c:byte()) end))
end

--- Path of a song's file relative to the server root ("songs/<stem>.cho").
function M.song_path(uid)
    return "songs/" .. url_encode(file_stem(uid)) .. ".cho"
end

--- index.json for songs as listed by ctx.songs().
function M.index(songs, name)
    local list = {}
    for _, song in ipairs(songs) do
        list[#list + 1] = {
            id = M.song_id(song.uid),
            uid = song.uid,
            file = M.song_path(song.uid),
            title = song.title, artist = song.artist, key = song.key, updated = song.updated,
        }
    end
    return M.json({ version = 1, name = name, songs = list })
end

--- Query string ("?a=1&b=x%20y", keys sorted) for the non-nil values of `params`.
function M.query(params)
    local keys = {}
    for k, v in pairs(params) do
        if v ~= nil and v ~= "" then keys[#keys + 1] = k end
    end
    if #keys == 0 then return "" end
    table.sort(keys)
    for i, k in ipairs(keys) do keys[i] = k .. "=" .. url_encode(tostring(params[k])) end
    return "?" .. table.concat(keys, "&")
end

local function port_param(v)
    local n = tonumber(v)
    if n and n == math.floor(n) and n >= 1 and n <= 65535 then return n end
end

--- Base URL of a songbook at `ip` sharing its songs on `port` (nil if invalid).
function M.peer_url(ip, port)
    port = port_param(port)
    if type(ip) ~= "string" or not port or not ip:match("^[%x%.:]+$") then return nil end
    if ip:find(":", 1, true) then ip = "[" .. ip .. "]" end
    return string.format("http://%s:%d/", ip, port)
end

--- A following songbook that shares its songs ({ url, name }), from a
-- /state.json request (req.ip set by the server), or nil.
function M.peer(req)
    local url = M.peer_url(req.ip, req.query.share)
    if not url then return nil end
    return { url = url, name = M.clean_name(req.query.name) }
end

local function parse_peers(list)
    local peers = {}
    for _, p in ipairs(type(list) == "table" and list or {}) do
        if type(p) == "table" and type(p.url) == "string" and p.url:match("^http://[%w%.%-:%[%]]+/$") then
            peers[#peers + 1] = { url = p.url, name = M.clean_name(type(p.name) == "string" and p.name or nil) }
        end
    end
    return peers
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

--- Decode /state.json of another songbook. Returns { api, uid, rev, transpose,
-- name, peers, scroll } or nil (name nil and peers empty from older songbooks).
function M.parse_state(body, decode)
    local ok, data = pcall(decode, body)
    if not ok or type(data) ~= "table" then return nil end
    local state = {
        api = type(data.api) == "number" and data.api or 1,
        transpose = 0,
        name = M.clean_name(type(data.name) == "string" and data.name or nil),
        peers = parse_peers(data.peers),
    }
    if type(data.uid) == "string" and data.uid ~= "" and type(data.rev) == "string" then
        state.uid, state.rev = data.uid, data.rev
        if type(data.transpose) == "number" then state.transpose = M.add_semitones(data.transpose, 0) end
        -- the host's autoscroll of this song (since 1.3)
        local s = data.scroll
        if type(s) == "table" and type(s.progress) == "number" and type(s.duration) == "number"
                and s.duration > 0 and s.progress >= 0 and s.progress <= 1 then
            state.scroll = { progress = s.progress, duration = s.duration }
        end
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
#song .l, #song .ly, #song pre { font-size: var(--fs, 16px); }
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
<button id="smaller">A−</button> <button id="bigger">A+</button>
<button id="follow" hidden>⇣</button></span>
<span id="status"></span>
</div>
<div id="song"><p>%s</p></div>
<div id="list" hidden>
<h2 id="h_now"></h2><ul id="now"></ul>
<h2 id="h_queue"></h2><ul id="queue"></ul>
<h2 id="h_request"></h2>
<input id="name" maxlength="30"/><input id="search" type="search"/>
<p id="msg"></p><ul id="songs"></ul>
<h2 id="h_history"></h2><ul id="history"></ul>
</div>
<script>
var L = %s;
var P = { t: 0, n: "", c: 1, fs: 16, by: "", follow: 1 };
try { var saved = JSON.parse(localStorage.getItem("songbook-jam")); for (var k in saved) P[k] = saved[k]; } catch (e) {}
var rev = null, uid = null, host_notation = "cz", view = "song", songs = null;
// numbers of the latest song and playlist requests: older answers that arrive late are dropped
var song_seq = 0, playlist_seq = 0, scroll_up = false;
// the host's autoscroll ({ progress, duration, at }) and whether the guest paused following it
var scroll = null, paused = false;
function $(id) { return document.getElementById(id); }
function save() { try { localStorage.setItem("songbook-jam", JSON.stringify(P)); } catch (e) {} }
function json(r) { return r.json(); }
function el(tag, text, cls) {
  var e = document.createElement(tag);
  if (text != null) e.textContent = text;
  if (cls) e.className = cls;
  return e;
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
  $("follow").hidden = !scroll;
  $("follow").className = P.follow && !paused ? "on" : "";
}
// The host's progress now: from the last /state.json, moved on by the time
// since then, plus the part of the correction made so far.
function progress(t) {
  var d = t - scroll.at;
  return scroll.progress + d / 1000 / scroll.duration + scroll.corr * Math.min(1, d / SMOOTH);
}
// Each /state.json arrives a little late (the network, a busy reader), so a
// small difference from our own estimate is spread over the next seconds
// instead of jumping; a large one (the host moved) is taken at once.
var SMOOTH = 3000, JUMP = 2;   // ms, seconds of the song
function setScroll(s) {
  var t = performance.now();
  if (!s) { scroll = null; return; }
  if (scroll && scroll.duration == s.duration) {
    var p = progress(t);
    var corr = s.progress - p;
    if (Math.abs(corr) * s.duration < JUMP) {
      scroll = { progress: p, duration: s.duration, at: t, corr: corr };
      return;
    }
  }
  scroll = { progress: s.progress, duration: s.duration, at: t, corr: 0 };
}
// Keep the line the host is playing a quarter down the screen.
function follow() {
  requestAnimationFrame(follow);
  if (!scroll || !P.follow || paused || view != "song" || !uid) return;
  var p = Math.min(1, progress(performance.now()));
  var song = $("song");
  var y = Math.max(0, Math.round(song.offsetTop + p * song.offsetHeight - window.innerHeight / 4));
  if (Math.abs(y - window.scrollY) >= 1) window.scrollTo(0, y);
}
// Scrolling by hand pauses following until the button is tapped.
function pause() { if (scroll && P.follow && !paused) { paused = true; bar(); } }
function load(scroll) {
  if (!uid) return;
  var seq = ++song_seq;
  scroll_up = scroll_up || scroll;   // a newer request still scrolls a new song to the top
  var url = "/song.html?t=" + P.t + "&n=" + (P.n || host_notation) + "&c=" + P.c
    + "&rev=" + encodeURIComponent(rev);
  fetch(url, { cache: "no-store" }).then(function (r) { return r.text(); }).then(function (html) {
    if (seq !== song_seq) return;
    var doc = new DOMParser().parseFromString(html, "text/html");
    $("song").innerHTML = doc.body.innerHTML;
    document.title = doc.title;
    if (scroll_up && view == "song") window.scrollTo(0, 0);
    scroll_up = false;
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
  var seq = ++playlist_seq;
  fetch("/playlist.json", { cache: "no-store" }).then(json).then(function (p) {
    if (seq !== playlist_seq) return;
    fill($("now"), p.now ? [p.now] : [], function () { return ""; });
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
      if (changed) { paused = false; scroll = null; }
      uid = s.uid; rev = s.rev;
      load(changed);
    }
    setScroll(s.uid && s.scroll && s.scroll.duration > 0 ? s.scroll : null);
    bar();
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
$("follow").onclick = function () {
  if (!P.follow || paused) { P.follow = 1; paused = false; } else P.follow = 0;
  save(); bar();
};
["wheel", "touchmove"].forEach(function (e) { window.addEventListener(e, pause, { passive: true }); });
window.addEventListener("keydown", function (e) {
  if (["ArrowUp", "ArrowDown", "PageUp", "PageDown", "Home", "End", " "].indexOf(e.key) >= 0) pause();
});
$("tab").onclick = function () {
  view = view == "song" ? "list" : "song";
  bar(); window.scrollTo(0, 0);
  if (view == "list") { loadPlaylist(); loadSongs(); } else load(false);
};
$("search").oninput = showSongs;
$("name").value = P.by;
$("name").placeholder = L.your_name;
$("search").placeholder = L.search;
$("h_now").textContent = L.now_playing;
$("h_queue").textContent = L.up_next;
$("h_request").textContent = L.request;
$("h_history").textContent = L.played;
$("follow").title = L.follow;
bar(); poll(); follow();
</script></body></html>
]]

local DEFAULT_LABELS = {
    title = "Songbook", waiting = "Waiting for a song…", offline = "Connection lost", chords = "Chords",
    song = "Song", playlist = "Playlist", now_playing = "Now playing", up_next = "Up next", played = "Played",
    request = "Request a song", your_name = "Your name", search = "Search", nothing = "Nothing yet",
    requested = "Requested: %1", queued = "This song is already requested.",
    full = "Too many requests, try again later.", missing = "This song is not available.",
    follow = "Scroll with the host",
}

--- Guest web page; labels are inserted as text.
function M.page(labels, css)
    local l = {}
    for k, v in pairs(DEFAULT_LABELS) do l[k] = (labels and labels[k]) or v end
    local js = {}
    for k, v in pairs(l) do js[k] = v end
    js.waiting = escape(l.waiting)   -- inserted as HTML
    -- Plain gsub replacements: labels may contain "%".
    -- "</" must not end the script (a device name is free text)
    local values = { escape(l.title), css or "", escape(l.chords), escape(l.waiting), (M.json(js):gsub("</", "<\\/")) }
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

--- Add a song to the queue, which holds at most `max` songs (default
-- MAX_QUEUE, the limit for guests). Returns true or nil, "queued" / "full".
function M.add_request(queue, entry, max)
    for _, e in ipairs(queue) do
        if e.uid == entry.uid then return nil, "queued" end
    end
    if #queue >= (max or M.MAX_QUEUE) then return nil, "full" end
    queue[#queue + 1] = entry
    return true
end

local function add_history(history, entry)
    history[#history + 1] = entry
    while #history > M.MAX_HISTORY do table.remove(history, 1) end
end

--- Make `entry` the song now playing of playlist `p` ({ now, history, queue }):
-- the previous one goes to history, the new one leaves the queue.
-- Returns true when the playlist changed.
function M.play(p, entry)
    local changed = false
    for i = #p.queue, 1, -1 do
        if p.queue[i].uid == entry.uid then
            table.remove(p.queue, i)
            changed = true
        end
    end
    if p.now and p.now.uid == entry.uid then return changed end
    if p.now then add_history(p.history, p.now) end
    p.now = entry
    return true
end

--- The song now playing has finished: it goes to history. Returns true when
-- something was playing.
function M.finish(p)
    if not p.now then return false end
    add_history(p.history, p.now)
    p.now = nil
    return true
end

local function parse_entry(e)
    if type(e) ~= "table" or type(e.title) ~= "string" then return nil end
    return {
        uid = type(e.uid) == "string" and e.uid or nil,
        title = e.title,
        artist = type(e.artist) == "string" and e.artist or nil,
        by = type(e.by) == "string" and e.by or nil,
        at = tonumber(e.at),
    }
end

--- Decode /playlist.json of another songbook into { now, history, queue }, or
-- nil. Songbooks before Now playing send no `now`.
function M.parse_playlist(body, decode)
    local ok, data = pcall(decode, body)
    if not ok or type(data) ~= "table" then return nil end
    local p = { now = parse_entry(data.now) }
    for _, name in ipairs({ "history", "queue" }) do
        p[name] = {}
        for _, e in ipairs(type(data[name]) == "table" and data[name] or {}) do
            local entry = parse_entry(e)
            if entry then table.insert(p[name], entry) end
        end
    end
    return p
end

--- Route a parsed request. Returns the full HTTP response string.
function M.handle(req, ctx)
    if not req then return M.response(400, "text/plain", "Bad request") end
    if req.method ~= "GET" then return M.response(405, "text/plain", "Only GET is supported") end
    local path = req.path
    if ctx.library and path ~= "/index.json" and not path:match("^/songs/") then
        return M.response(404, "text/plain", "Not found")
    end
    if path == "/" or path == "/index.html" then
        return M.response(200, "text/html; charset=utf-8", M.page(ctx.labels, ctx.css))
    elseif path == "/state.json" then
        local peer = ctx.join and M.peer(req)
        if peer then ctx.join(peer) end
        local state = ctx.state(peer and peer.url)
        state.api = M.API_VERSION
        return M.response(200, "application/json; charset=utf-8", M.json(state))
    elseif path == "/song.html" then
        local q = req.query
        local html = ctx.song_html({
            shift = int_param(q.t, -11, 11) or 0,
            notation = (q.n == "cz" or q.n == "en") and q.n or nil,
            show_chords = q.c ~= "0",
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
            M.json({ now = p.now, history = p.history or {}, queue = p.queue or {} }))
    elseif path == "/queue/add" then
        local ok, err = nil, "missing"
        local uid, by = req.query.uid, M.clean_name(req.query.by)
        if req.query.from then
            local url = M.peer_url(req.ip, req.query.from)
            if url and ctx.request_from and M.valid_uid(uid) then
                ok, err = ctx.request_from(url, uid, by)
            end
        else
            if (not uid or uid == "") and req.query.id then uid = M.find_id(ctx.songs(), req.query.id) end
            if M.valid_uid(uid) then
                ok, err = ctx.request(uid, by)
            end
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
