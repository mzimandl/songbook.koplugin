--[[--
Jam session web server: request parsing, routing and the guest web page
(pure Lua 5.1 / LuaJIT). main.lua owns the socket and passes a context:

ctx = {
  state     = function() -> { uid=, rev=, title=, artist=, notation= } (uid nil = no song)
  song_html = function(opts) -> html or nil      -- opts = { shift=, notation=, show_chords=, max_cols= }
  song_cho  = function() -> ChordPro text or nil
  labels    = { title=, waiting=, offline=, chords= },
  css       = stylesheet for the song inside the page,
}
`shift` is the guest's own transposition on top of the host's.

Endpoints (GET only; KOReader's SimpleTCPServer reads just the headers):
  /             guest page, polls /state.json and loads /song.html on change
  /state.json   what is being played; "rev" changes with the song or the host's options
  /song.html    current song; ?t= semitones on top of the host's key, ?n=cz|en, ?c=0 (no chords), ?w= columns
  /song.cho     current song source
]]

local M = {}

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

--- JSON for a flat table of strings, numbers and booleans (keys sorted).
function M.json(t)
    local keys = {}
    for k in pairs(t) do keys[#keys + 1] = k end
    table.sort(keys)
    local out = {}
    for _, k in ipairs(keys) do
        local v = t[k]
        local enc = type(v) == "string" and json_string(v) or tostring(v)
        out[#out + 1] = json_string(k) .. ":" .. enc
    end
    return "{" .. table.concat(out, ",") .. "}"
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
#bar button { font-size: 1em; min-width: 2.4em; padding: 0.3em 0.5em; border-radius: 0.3em;
              border: 1px solid #8888; background: transparent; color: inherit; }
#bar button.on { background: #8883; }
#t { min-width: 2em; text-align: center; }
#status { margin-left: auto; font-size: 0.85em; opacity: 0.7; }
#song { margin: 0.8em; }
#song pre { font-size: var(--fs, 16px); }
#probe { position: absolute; visibility: hidden; }
</style></head><body>
<div id="bar">
<button id="down">♭</button><span id="t">0</span><button id="up">♯</button>
<button id="nota">H</button><button id="chords" class="on">%s</button>
<button id="smaller">A−</button><button id="bigger">A+</button>
<span id="status"></span>
</div>
<div id="song"><p>%s</p></div>
<pre id="probe">0000000000</pre>
<script>
var L = %s;
var P = { t: 0, n: "", c: 1, fs: 16 };
try { var saved = JSON.parse(localStorage.getItem("songbook-jam")); for (var k in saved) P[k] = saved[k]; } catch (e) {}
var rev = null, uid = null, host_notation = "cz";
function $(id) { return document.getElementById(id); }
function save() { try { localStorage.setItem("songbook-jam", JSON.stringify(P)); } catch (e) {} }
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
}
function load(scroll) {
  if (!uid) return;
  var url = "/song.html?t=" + P.t + "&n=" + (P.n || host_notation) + "&c=" + P.c + "&w=" + cols()
    + "&rev=" + encodeURIComponent(rev);
  fetch(url, { cache: "no-store" }).then(function (r) { return r.text(); }).then(function (html) {
    var doc = new DOMParser().parseFromString(html, "text/html");
    $("song").innerHTML = doc.body.innerHTML;
    document.title = doc.title;
    if (scroll) window.scrollTo(0, 0);
  });
}
function poll() {
  fetch("/state.json", { cache: "no-store" }).then(function (r) { return r.json(); }).then(function (s) {
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
var resize_timer;
window.onresize = function () { clearTimeout(resize_timer); resize_timer = setTimeout(function () { load(false); }, 300); };
bar(); poll();
</script></body></html>
]]

--- Guest web page; labels are inserted as text.
function M.page(labels, css)
    local l = labels or {}
    local js = M.json({
        waiting = escape(l.waiting or "Waiting for a song…"),
        offline = l.offline or "Connection lost",
    })
    -- Plain gsub replacements: labels may contain "%".
    local values = {
        escape(l.title or "Songbook"), css or "", escape(l.chords or "Chords"),
        escape(l.waiting or "Waiting for a song…"), js,
    }
    local i = 0
    return (PAGE:gsub("%%s", function() i = i + 1; return values[i] end))
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
    end
    return M.response(404, "text/plain", "Not found")
end

return M
