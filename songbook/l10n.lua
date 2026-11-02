--[[--
Translations of the plugin's own strings. KOReader's gettext only reads
KOReader's catalog, so the plugin keeps its catalogs in songbook/l10n/<lang>.lua
(msgid → translation) and falls back to KOReader's gettext.
Pure Lua: no KOReader modules.
]]

local M = {}

--- Catalog names to try for a KOReader language: "pt_BR.UTF-8" → { "pt_BR", "pt" }.
function M.languages(lang)
    if not lang or lang == "" or lang == "C" then return {} end
    lang = lang:match("^[^.@]+") or lang
    local out = { lang }
    local base = lang:match("^(%a+)_")
    if base then table.insert(out, base) end
    return out
end

--- Catalog for `lang`: load(name) returns the catalog of one language or nil.
function M.catalog(lang, load)
    for _i, name in ipairs(M.languages(lang)) do
        local catalog = load(name)
        if catalog then return catalog end
    end
    return {}
end

--- gettext-like function: the catalog's translation, else gettext(msgid).
function M.wrap(gettext, catalog)
    return function(msgid)
        return catalog[msgid] or gettext(msgid)
    end
end

return M
