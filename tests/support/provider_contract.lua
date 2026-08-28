local Test = require("tests/test_helper")

local ProviderContract = {}

local function createLocalFile(content)
    local path = os.tmpname()
    local file = assert(io.open(path, "wb"))
    file:write(content)
    file:close()
    return path
end

function ProviderContract.register(name, createProvider)
    Test.test(name .. " refs serialize and round-trip", function()
        local provider = createProvider()
        local folder = provider:createFolder(nil, "Folder", {})
        local serialized = provider:serializeRef(folder.ref)
        local restored = provider:deserializeRef(serialized)
        local original_key = provider:getRefKey(folder.ref)
        local restored_key = provider:getRefKey(restored)

        Test.assertEqual(restored_key, original_key)
    end)

    Test.test(name .. " implements storage primitives", function()
        local provider = createProvider()
        local folder = provider:createFolder(nil, "Books", {})
        local local_path = createLocalFile("book-data")
        local uploaded = provider:uploadFile(
            folder.ref,
            local_path,
            "Book.epub",
            { mime_type = "application/epub+zip" }
        )
        os.remove(local_path)

        local children = provider:listChildren(folder.ref)
        Test.assertEqual(#children, 1)
        Test.assertEqual(children[1].name, "Book.epub")

        local fetched = provider:getEntry(uploaded.ref)
        Test.assertEqual(fetched.name, "Book.epub")

        local download_path = os.tmpname()
        Test.assertTrue(
            provider:downloadFile(uploaded.ref, download_path)
        )
        local downloaded = assert(io.open(download_path, "rb"))
        Test.assertEqual(downloaded:read("*a"), "book-data")
        downloaded:close()
        os.remove(download_path)

        Test.assertTrue(provider:deleteEntry(uploaded.ref))
    end)
end

return ProviderContract
