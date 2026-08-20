local DriveApi = require("providers/google_drive/api")
local Auth = require("providers/google_drive/auth")
local BaseProvider = require("providers/base")

local ROOT_FOLDER_NAME = "KOCloud"
local ROOT_ROLE_KEY = "kocloud_role"
local ROOT_ROLE_VALUE = "root"
local ROOT_SCHEMA_KEY = "kocloud_schema"
local ROOT_SCHEMA_VERSION = "1"

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

--- Find the KOCloud-managed root folder in Google Drive.
---
--- The folder is identified by private appProperties rather than by name
--- alone, so a user's unrelated folder named "KOCloud" is ignored.
---@return KOCloudGoogleDriveFile|nil folder
---@return string|nil error_message
function GoogleDriveProvider:findRootFolder()
    local access_token, token_error = self:getAccessToken()

    if not access_token then
        return nil, token_error
    end

    local query = string.format(
        "trashed = false and name = '%s' "
            .. "and mimeType = '%s' "
            .. "and appProperties has { key='%s' and value='%s' }",
        ROOT_FOLDER_NAME,
        DriveApi.FOLDER_MIME_TYPE,
        ROOT_ROLE_KEY,
        ROOT_ROLE_VALUE
    )

    local result, list_error = DriveApi:listFiles(
        access_token,
        query,
        {
            page_size = 10,
        }
    )

    if not result then
        return nil, list_error
    end

    if #result.files == 0 then
        return nil, nil
    end

    return result.files[1], nil
end

--- Find or create the KOCloud-managed root folder.
---
--- On success, the discovered folder ID is cached in the provider config.
--- The caller is responsible for persisting the updated provider config.
---@return KOCloudGoogleDriveFile|nil folder
---@return boolean created True when a new folder was created.
---@return string|nil error_message
function GoogleDriveProvider:ensureRootFolder()
    local folder, find_error = self:findRootFolder()

    if find_error then
        return nil, false, find_error
    end

    if folder then
        self.config.root_folder_id = folder.id
        return folder, false, nil
    end

    local access_token, token_error = self:getAccessToken()

    if not access_token then
        return nil, false, token_error
    end

    local created_folder, create_error = DriveApi:createFolder(
        access_token,
        ROOT_FOLDER_NAME,
        nil,
        {
            [ROOT_ROLE_KEY] = ROOT_ROLE_VALUE,
            [ROOT_SCHEMA_KEY] = ROOT_SCHEMA_VERSION,
        }
    )

    if not created_folder then
        return nil, false, create_error
    end

    self.config.root_folder_id = created_folder.id

    return created_folder, true, nil
end

--- Forget all local user-specific Google OAuth token state.
---
--- This does not revoke the token at Google. Remote revocation will be added
--- separately when the Disconnect flow is implemented.
function GoogleDriveProvider:clearAuthorization()
    self.auth:clearAuthorization()
end

return GoogleDriveProvider
