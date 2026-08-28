local Test = require("tests/test_helper")
local FakeProvider = require("tests/support/fake_provider")
local LibraryService = require("core/services/library")
local Protocol = require("core/protocol")

local function createLibrary()
    local provider = FakeProvider:new()
    local books = provider:addFolder(nil, "Books", {})
    local layout = {
        getBooksRootRef = function()
            return books.ref
        end,
    }

    return LibraryService:new(provider, layout), provider, books
end

Test.test("library lists folders and supported books only", function()
    local library, provider, books = createLibrary()

    provider:addFolder(books.ref, "Fiction", {})
    provider:addFile(books.ref, "Novel.epub", {})
    provider:addFile(books.ref, "notes.bin", {})
    provider:addFile(books.ref, "managed.bin", {
        metadata = {
            [Protocol.METADATA_KEYS.role] = Protocol.ROLES.book,
        },
    })

    local folders, files = library:listFolder()

    Test.assertEqual(#folders, 1)
    Test.assertEqual(folders[1].name, "Fiction")
    Test.assertEqual(#files, 2)
end)

Test.test("library upload writes book metadata and MIME", function()
    local library, provider = createLibrary()
    local temp_path = os.tmpname() .. ".epub"
    local file = assert(io.open(temp_path, "wb"))
    file:write("epub")
    file:close()

    local uploaded, upload_error = library:uploadBook(temp_path)
    os.remove(temp_path)

    Test.assertNil(upload_error)
    Test.assertNotNil(uploaded)

    local call = provider.calls[#provider.calls]
    Test.assertEqual(call.method, "uploadFile")
    Test.assertEqual(
        call.options.mime_type,
        "application/epub+zip"
    )
    Test.assertEqual(
        call.options.metadata[Protocol.METADATA_KEYS.role],
        Protocol.ROLES.book
    )
end)

Test.test("library rejects unsupported upload formats", function()
    local library = createLibrary()
    local uploaded, upload_error = library:uploadBook("Book.azw3")

    Test.assertNil(uploaded)
    Test.assertEqual(upload_error, "Unsupported KOReader book format")
end)

Test.test("library creates folders with library metadata", function()
    local library, provider = createLibrary()
    local folder = library:createFolder("Programming")
    local call = provider.calls[#provider.calls]

    Test.assertEqual(folder.name, "Programming")
    Test.assertEqual(call.method, "createFolder")
    Test.assertEqual(
        call.options.metadata[Protocol.METADATA_KEYS.role],
        Protocol.ROLES.book_folder
    )
end)
