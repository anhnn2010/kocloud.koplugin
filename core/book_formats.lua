--- KOReader document formats supported by KOCloud.
---
--- Keep this list aligned with kocloud-companion/src/book-formats.js so the
--- companion and KOReader plugin accept the same book files.
local BookFormats = {}

local FORMATS = {
    epub = {
        label = "EPUB",
        mime_type = "application/epub+zip",
    },
    pdf = {
        label = "PDF",
        mime_type = "application/pdf",
    },
    djvu = {
        label = "DJVU",
        mime_type = "image/vnd.djvu",
    },
    djv = {
        label = "DJVU",
        mime_type = "image/vnd.djvu",
    },
    fb2 = {
        label = "FB2",
        mime_type = "application/fb2",
    },
    mobi = {
        label = "MOBI",
        mime_type = "application/x-mobipocket-ebook",
    },
    azw = {
        label = "AZW",
        mime_type = "application/vnd.amazon.ebook",
    },
    doc = {
        label = "DOC",
        mime_type = "application/msword",
    },
    docx = {
        label = "DOCX",
        mime_type =
            "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
    },
    rtf = {
        label = "RTF",
        mime_type = "application/rtf",
    },
    html = {
        label = "HTML",
        mime_type = "text/html",
    },
    htm = {
        label = "HTML",
        mime_type = "text/html",
    },
    xhtml = {
        label = "XHTML",
        mime_type = "application/xhtml+xml",
    },
    chm = {
        label = "CHM",
        mime_type = "application/vnd.ms-htmlhelp",
    },
    txt = {
        label = "TXT",
        mime_type = "text/plain",
    },
    md = {
        label = "MD",
        mime_type = "text/markdown",
    },
    cbz = {
        label = "CBZ",
        mime_type = "application/vnd.comicbook+zip",
    },
    cbr = {
        label = "CBR",
        mime_type = "application/vnd.comicbook-rar",
    },
    cbt = {
        label = "CBT",
        mime_type = "application/vnd.comicbook+tar",
    },
    pdb = {
        label = "PDB",
        mime_type = "application/vnd.palm",
    },
    prc = {
        label = "PRC",
        mime_type = "application/x-mobipocket-ebook",
    },
    xps = {
        label = "XPS",
        mime_type = "application/oxps",
    },
    zip = {
        label = "ZIP",
        mime_type = "application/zip",
    },
}

--- Return the lower-case extension without a leading dot.
---@param name? string
---@return string
function BookFormats.getExtension(name)
    local value = tostring(name or "")
    local extension = value:match("%.([^%.]+)$")

    if not extension then
        return ""
    end

    return extension:lower()
end

--- Return whether a file name uses a KOCloud-supported KOReader format.
---@param name? string
---@return boolean
function BookFormats.isSupported(name)
    return FORMATS[BookFormats.getExtension(name)] ~= nil
end

--- Return the MIME type to use when uploading a book.
---@param name? string
---@param fallback_mime_type? string
---@return string
function BookFormats.getMimeType(name, fallback_mime_type)
    local format = FORMATS[BookFormats.getExtension(name)]

    if format then
        return format.mime_type
    end

    if fallback_mime_type and fallback_mime_type ~= "" then
        return fallback_mime_type
    end

    return "application/octet-stream"
end

--- Return a short display label such as EPUB, DJVU, or MOBI.
---@param name? string
---@return string
function BookFormats.getLabel(name)
    local format = FORMATS[BookFormats.getExtension(name)]

    if format then
        return format.label
    end

    return "Book"
end

return BookFormats
