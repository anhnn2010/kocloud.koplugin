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

--- Return whether the KOCloud application OAuth client is configured.
---@return boolean
function GoogleDriveProvider:isClientConfigured()
    return self.auth:isClientConfigured()
end

--- Return whether this user has authorized Google Drive.
---@return boolean
function GoogleDriveProvider:isConfigured()
    return self.auth:isAuthorized()
end

--- Start a Google Device Authorization Flow session.
---@return KOCloudGoogleDriveDeviceSession|nil session
---@return string|nil error_message
function GoogleDriveProvider:requestDeviceAuthorization()
    return self.auth:requestDeviceAuthorization()
end

--- Poll Google once for the result of a device authorization session.
---@param session KOCloudGoogleDriveDeviceSession
---@return KOCloudGoogleDrivePollResult
function GoogleDriveProvider:pollDeviceAuthorization(session)
    return self.auth:pollDeviceAuthorization(session)
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

--- Forget all local user-specific Google OAuth token state.
---
--- This does not revoke the token at Google. Remote revocation will be added
--- separately when the Disconnect flow is implemented.
function GoogleDriveProvider:clearAuthorization()
    self.auth:clearAuthorization()
end

return GoogleDriveProvider
