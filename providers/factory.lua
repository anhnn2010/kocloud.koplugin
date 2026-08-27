local GoogleDriveProvider = require("providers/google_drive/provider")

--- Provider factory for KOCloud storage adapters.
---
--- This is the only composition-layer module that maps a configured provider
--- type to a concrete provider implementation.
local ProviderFactory = {}

local FACTORIES = {
    google_drive = function(config)
        return GoogleDriveProvider:new(config)
    end,
}

--- Create one configured KOCloud storage provider.
---@param provider_type string
---@param provider_config? table
---@return KOCloudBaseProvider
function ProviderFactory.create(provider_type, provider_config)
    local factory = FACTORIES[provider_type]

    if not factory then
        error(string.format(
            "Unsupported KOCloud provider: %s",
            tostring(provider_type)
        ))
    end

    return factory(provider_config or {})
end

return ProviderFactory
