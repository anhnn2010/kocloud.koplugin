local DriveApi = require("providers/google_drive/api")
local Auth = require("providers/google_drive/auth")
local BaseProvider = require("providers/base")

local ROOT_FOLDER_NAME = "KOCloud"
local ROLE_KEY = "kocloud_role"
local SCHEMA_KEY = "kocloud_schema"
local SCHEMA_VERSION = "1"

---@class KOCloudManagedFolderDefinition
---@field key string Stable local config key.
---@field name string Default visible Google Drive folder name.
---@field role string Stable appProperties role identifier.
---@field internal? boolean Whether the folder stores KOCloud-internal data.

---@type KOCloudManagedFolderDefinition[]
local STORAGE_FOLDERS = {
    {
        key = "books",
        name = "Books",
        role = "books",
    },
    {
        key = "backups",
        name = "Backups",
        role = "backups",
    },
    {
        key = "reading_data",
        name = "ReadingData",
        role = "reading_data",
    },
    {
        key = "metadata",
        name = ".kocloud",
        role = "metadata",
        internal = true,
    },
}

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
--- The root is identified entirely by private appProperties. This allows the
--- user to rename the visible folder without causing KOCloud to create a
--- duplicate root folder.
---@return KOCloudGoogleDriveFile|nil folder
---@return string|nil error_message
function GoogleDriveProvider:findRootFolder()
    local access_token, token_error = self:getAccessToken()

    if not access_token then
        return nil, token_error
    end

    local query = string.format(
        "trashed = false and mimeType = '%s' "
            .. "and appProperties has { key='%s' and value='root' }",
        DriveApi.FOLDER_MIME_TYPE,
        ROLE_KEY
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
            [ROLE_KEY] = "root",
            [SCHEMA_KEY] = SCHEMA_VERSION,
        }
    )

    if not created_folder then
        return nil, false, create_error
    end

    self.config.root_folder_id = created_folder.id

    return created_folder, true, nil
end

--- Find a KOCloud-managed child folder by role under a parent folder.
---@param parent_id string Google Drive parent folder ID.
---@param role string Stable KOCloud folder role.
---@return KOCloudGoogleDriveFile|nil folder
---@return string|nil error_message
function GoogleDriveProvider:findManagedFolder(parent_id, role)
    local access_token, token_error = self:getAccessToken()

    if not access_token then
        return nil, token_error
    end

    local query = string.format(
        "trashed = false and '%s' in parents "
            .. "and mimeType = '%s' "
            .. "and appProperties has { key='%s' and value='%s' }",
        parent_id,
        DriveApi.FOLDER_MIME_TYPE,
        ROLE_KEY,
        role
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

--- Find or create one managed folder under the KOCloud root.
---@param parent_id string Google Drive parent folder ID.
---@param definition KOCloudManagedFolderDefinition
---@return KOCloudGoogleDriveFile|nil folder
---@return boolean created True when a new folder was created.
---@return string|nil error_message
function GoogleDriveProvider:ensureManagedFolder(parent_id, definition)
    local folder, find_error = self:findManagedFolder(
        parent_id,
        definition.role
    )

    if find_error then
        return nil, false, find_error
    end

    if folder then
        return folder, false, nil
    end

    local access_token, token_error = self:getAccessToken()

    if not access_token then
        return nil, false, token_error
    end

    local app_properties = {
        [ROLE_KEY] = definition.role,
        [SCHEMA_KEY] = SCHEMA_VERSION,
    }

    if definition.internal then
        app_properties.kocloud_internal = "true"
    end

    local created_folder, create_error = DriveApi:createFolder(
        access_token,
        definition.name,
        parent_id,
        app_properties
    )

    if not created_folder then
        return nil, false, create_error
    end

    return created_folder, true, nil
end

--- Ensure the complete KOCloud Google Drive storage layout exists.
---
--- Existing folders are reused based on private appProperties, even when the
--- user has renamed them. Missing folders are created individually.
---
--- The returned table is keyed by stable local names such as `books` and
--- `backups`. Folder IDs are also cached in `config.folders`.
---@return table<string, KOCloudGoogleDriveFile>|nil folders
---@return integer created_count Number of folders created during this call.
---@return string|nil error_message
function GoogleDriveProvider:ensureStorageLayout()
    local root_folder, root_created, root_error =
        self:ensureRootFolder()

    if not root_folder then
        return nil, 0, root_error
    end

    local folders = {
        root = root_folder,
    }
    local created_count = root_created and 1 or 0

    self.config.folders = self.config.folders or {}
    self.config.root_folder_id = root_folder.id

    for _, definition in ipairs(STORAGE_FOLDERS) do
        local folder, created, folder_error =
            self:ensureManagedFolder(
                root_folder.id,
                definition
            )

        if not folder then
            return nil, created_count, folder_error
        end

        folders[definition.key] = folder
        self.config.folders[definition.key] = folder.id

        if created then
            created_count = created_count + 1
        end
    end

    return folders, created_count, nil
end

--- Forget all local user-specific Google OAuth token state.
---
--- This does not revoke the token at Google. Remote revocation will be added
--- separately when the Disconnect flow is implemented.
function GoogleDriveProvider:clearAuthorization()
    self.auth:clearAuthorization()
end

return GoogleDriveProvider
