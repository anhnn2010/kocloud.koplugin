local DataStorage = require("datastorage")
local LuaSettings = require("luasettings")

--- Persistent configuration manager for KOCloud.
---@class KOCloudConfig
---@field settings LuaSettings KOReader LuaSettings instance.
local Config = {}
Config.__index = Config

Config.SETTINGS_FILE = DataStorage:getSettingsDir() .. "/kocloud.lua"

local KEY_ACTIVE_PROVIDER = "active_provider"
local KEY_PROVIDERS = "providers"

--- Create a KOCloud configuration manager.
---@return KOCloudConfig
function Config:new()
    local instance = setmetatable({}, self)
    instance.settings = LuaSettings:open(self.SETTINGS_FILE)
    return instance
end

--- Return the path to the KOCloud settings file.
---@return string
function Config:getSettingsFile()
    return self.SETTINGS_FILE
end

--- Return the currently selected provider type.
---@return string
function Config:getActiveProvider()
    return self.settings:readSetting(KEY_ACTIVE_PROVIDER, "google_drive")
end

--- Set the currently selected provider type.
---@param provider_type string
function Config:setActiveProvider(provider_type)
    self.settings:saveSetting(KEY_ACTIVE_PROVIDER, provider_type)
end

--- Return configuration for a provider.
---@param provider_type string
---@return table
function Config:getProviderConfig(provider_type)
    local providers = self.settings:readSetting(KEY_PROVIDERS, {})
    return providers[provider_type] or {}
end

--- Save configuration for a provider.
---@param provider_type string
---@param provider_config table
function Config:setProviderConfig(provider_type, provider_config)
    local providers = self.settings:readSetting(KEY_PROVIDERS, {})
    providers[provider_type] = provider_config
    self.settings:saveSetting(KEY_PROVIDERS, providers)
end

--- Delete configuration for a provider.
---@param provider_type string
function Config:deleteProviderConfig(provider_type)
    local providers = self.settings:readSetting(KEY_PROVIDERS, {})
    providers[provider_type] = nil
    self.settings:saveSetting(KEY_PROVIDERS, providers)
end

--- Flush pending KOCloud settings changes to disk.
function Config:flush()
    self.settings:flush()
end

return Config
