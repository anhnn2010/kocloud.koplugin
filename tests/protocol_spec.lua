local Test = require("tests/test_helper")
local Protocol = require("core/protocol")

Test.test("protocol exposes stable v1 paths", function()
    Test.assertEqual(Protocol.FORMAT, "kocloud-storage")
    Test.assertEqual(Protocol.VERSION, 1)
    Test.assertEqual(Protocol.getManagedPath("books"), "KOCloud/Books")
    Test.assertEqual(
        Protocol.getManifestPath(),
        "KOCloud/.kocloud/manifest.json"
    )
end)

Test.test("protocol builds and validates manifest v1", function()
    local manifest = Protocol.buildManifest()

    Test.assertTrue(Protocol.isManifestV1(manifest))
    Test.assertEqual(manifest.layout.root, "KOCloud")
    Test.assertEqual(manifest.layout.reading_data, "ReadingData")

    manifest.schema_version = 2
    Test.assertFalse(Protocol.isManifestV1(manifest))
end)

Test.test("protocol manifest JSON is deterministic", function()
    local json = Protocol.buildManifestJson()

    Test.assertTrue(json:find('"format": "kocloud%-storage"') ~= nil)
    Test.assertTrue(json:find('"schema_version": 1') ~= nil)
    Test.assertTrue(json:find('"metadata": "%.kocloud"') ~= nil)
end)
