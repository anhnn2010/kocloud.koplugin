--- Persist provider-owned KOCloud configuration through the shared config
--- manager.
---@class KOCloudProviderState
---@field config KOCloudConfig
---@field provider KOCloudBaseProvider
---@field layout KOCloudStorageLayoutService
local ProviderState = {}
ProviderState.__index = ProviderState

--- Create a provider-state persistence helper.
---@param config KOCloudConfig
---@param provider KOCloudBaseProvider
---@param layout KOCloudStorageLayoutService
---@return KOCloudProviderState
function ProviderState:new(config, provider, layout)
    return setmetatable({
        config = config,
        provider = provider,
        layout = layout,
    }, self)
end

--- Persist the current provider configuration and clear dirty flags.
function ProviderState:save()
    self.config:setProviderConfig(
        self.provider:getType(),
        self.provider.config
    )
    self.config:flush()
    self.provider:markPersistentConfigSaved()
    self.layout:markPersistentConfigSaved()
end

--- Persist provider configuration only when provider/layout migration changed
--- long-lived state.
---@return boolean saved
function ProviderState:saveIfDirty()
    if not self.provider:isPersistentConfigDirty()
        and not self.layout:isPersistentConfigDirty()
    then
        return false
    end

    self:save()
    return true
end

return ProviderState
