local ok, gettext = pcall(require, "gettext")
local _ = ok and gettext or function(s) return s end
return {
    name = "varbook",
    fullname = _("Varbook Sync"),
    description = _([[Synchronize reading progress between KOReader and a Bookshelf (Varbook) server. Read on your e-reader, then pick up where you left off on the web reader — and vice versa.]]),
    version = "1.0.0",
}
