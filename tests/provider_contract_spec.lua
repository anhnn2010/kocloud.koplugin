local FakeProvider = require("tests/support/fake_provider")
local ProviderContract = require("tests/support/provider_contract")

ProviderContract.register("fake provider", function()
    return FakeProvider:new()
end)
