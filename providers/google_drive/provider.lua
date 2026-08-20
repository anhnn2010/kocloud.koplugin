local Auth = require("providers/google_drive/auth")
local BaseProvider = require("providers/base")

--- Google Drive storage provider for KOCloud.
---@class KOCloudGoogleDriveProvider: KOCloudBaseProvider
---@field name string Human-readable provider name.
---@field type string Stable provider identifier.
---@field auth KOCloudGoogleDriveAuth Google OAuth token manager.
local GoogleDriveProvider = setmetatable({
    name = "Google Drive",
    type = "google_drive",
}, {
    __index = BaseProvider,
})

GoogleDriveProvider.__index = GoogleDriveProvider

--- Create a new Google Drive provider instance.
---@param config? table Google Drive provider configuration.
---@return KOCloudGoogleDriveProvider
function GoogleDriveProvider:new(config)
    ---@type KOCloudGoogleDriveProvider
    local instance = BaseProvider.new(self, config)
    instance.auth = Auth:new(instance.config)
    return instance
end

--- Return whether Google Drive OAuth is configured.
---@return boolean
function GoogleDriveProvider:isConfigured()
    return self.auth:isConfigured()
end

--- Return a usable Google OAuth access token.
---
--- A cached token is returned when possible. Otherwise the auth manager
--- refreshes it using the configured refresh token.
---@return string|nil access_token
---@return string|nil error_message
function GoogleDriveProvider:getAccessToken()
    return self.auth:getAccessToken()
end

return GoogleDriveProvider
