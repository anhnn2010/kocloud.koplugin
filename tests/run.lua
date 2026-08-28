package.path = table.concat({
    "./?.lua",
    "./?/init.lua",
    package.path,
}, ";")

local Test = require("tests/test_helper")

require("tests/protocol_spec")
require("tests/book_formats_spec")
require("tests/provider_contract_spec")
require("tests/library_service_spec")
require("tests/storage_layout_spec")

Test.run()
