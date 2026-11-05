local _ = require("gettext")
-- KOReader's catalog lacks these; Czech is kept here, as _meta.lua can't require the plugin's modules.
local cs = (_.current_lang or ""):match("^cs") ~= nil
return {
    name = "songbook",
    version = "0.6.3",
    fullname = cs and "Zpěvník" or _("Songbook"),
    description = cs and "Stahování písní s akordy pro kytaru (ChordPro) ze serveru písní a jejich čtení s transpozicí."
        or _([[Download songs with guitar chords (ChordPro) from a song server and read them with transposition.]]),
}
