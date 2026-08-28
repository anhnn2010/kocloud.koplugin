local Test = require("tests/test_helper")
local FakeProvider = require("tests/support/fake_provider")
local Protocol = require("core/protocol")

package.preload["rapidjson"] = function()
    return {
        decode = function(content)
            if not content:find('"format": "kocloud%-storage"') then
                return nil, "Invalid manifest"
            end

            return Protocol.buildManifest(), nil
        end,
    }
end

local StorageLayoutService = require("core/services/storage_layout")

Test.test("storage layout creates and caches protocol v1", function()
    local provider = FakeProvider:new()
    local layout = StorageLayoutService:new(provider)
    local folders, created_count, layout_error =
        layout:ensureStorageLayout()

    Test.assertNil(layout_error)
    Test.assertNotNil(folders)
    Test.assertEqual(created_count, 5)
    Test.assertTrue(layout:isInitialized())
    Test.assertNotNil(layout:getBooksRootRef())

    local metadata_ref = layout:getFolderRef("metadata")
    local metadata_children = provider:listChildren(metadata_ref)

    Test.assertEqual(#metadata_children, 1)
    Test.assertEqual(
        metadata_children[1].name,
        Protocol.MANIFEST.filename
    )

    local _folders_again, created_again, second_error =
        layout:ensureStorageLayout()

    Test.assertNil(second_error)
    Test.assertEqual(created_again, 0)
end)

Test.test("storage layout migrates legacy raw-id cache", function()
    local provider = FakeProvider:new({
        config = {
            root_folder_id = "root-id",
            folders = {
                books = "books-id",
                backups = "backups-id",
                reading_data = "reading-id",
                metadata = "metadata-id",
            },
        },
    })

    local layout = StorageLayoutService:new(provider)

    Test.assertTrue(layout:isPersistentConfigDirty())
    Test.assertNil(provider.config.root_folder_id)
    Test.assertNil(provider.config.folders)
    Test.assertEqual(provider.config.layout.root, "root-id")
    Test.assertEqual(
        provider.config.layout.folders.books,
        "books-id"
    )
end)
