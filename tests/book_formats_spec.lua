local Test = require("tests/test_helper")
local BookFormats = require("core/book_formats")

local supported = {
    "epub", "pdf", "djvu", "djv", "fb2", "mobi", "azw", "doc",
    "docx", "rtf", "html", "htm", "xhtml", "chm", "txt", "md",
    "cbz", "cbr", "cbt", "pdb", "prc", "xps", "zip",
}

Test.test("book formats accept the shared KOCloud set", function()
    Test.assertEqual(#supported, 23)

    for _, extension in ipairs(supported) do
        Test.assertTrue(
            BookFormats.isSupported("Book." .. extension),
            "Expected support for " .. extension
        )
    end
end)

Test.test("book formats reject unsupported Kindle formats", function()
    Test.assertFalse(BookFormats.isSupported("Book.azw3"))
    Test.assertFalse(BookFormats.isSupported("Book.kfx"))
end)

Test.test("book formats return stable MIME and labels", function()
    Test.assertEqual(
        BookFormats.getMimeType("Book.epub"),
        "application/epub+zip"
    )
    Test.assertEqual(BookFormats.getLabel("Book.djv"), "DJVU")
    Test.assertEqual(BookFormats.getLabel("Book.unknown"), "Book")
end)
