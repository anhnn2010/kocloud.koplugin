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

local BOOK_MIME_TYPES = {
    epub = "application/epub+zip",
    pdf = "application/pdf",
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

--- Return the basename of a local path.
---@param path string
---@return string
local function basename(path)
    return path:match("([^/\\]+)$") or path
end

--- Return the lower-case extension of a file name.
---@param name string
---@return string|nil
local function getExtension(name)
    local extension = name:match("%.([^%.]+)$")

    if not extension then
        return nil
    end

    return extension:lower()
end

--- Return the MIME type used when uploading a book.
---@param name string
---@return string
local function getBookMimeType(name)
    local extension = getExtension(name)

    if extension and BOOK_MIME_TYPES[extension] then
        return BOOK_MIME_TYPES[extension]
    end

    return "application/octet-stream"
end

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
---@return string|nil access_token
---@return string|nil error_message
function GoogleDriveProvider:getAccessToken()
    return self.auth:getAccessToken()
end

--- Find the KOCloud-managed root folder in Google Drive.
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

--- Return the cached Books folder ID, initializing storage when necessary.
---@return string|nil folder_id
---@return string|nil error_message
function GoogleDriveProvider:getBooksFolderId()
    local folders = self.config.folders

    if type(folders) == "table"
        and type(folders.books) == "string"
        and folders.books ~= ""
    then
        return folders.books, nil
    end

    local storage_folders, _, storage_error =
        self:ensureStorageLayout()

    if not storage_folders then
        return nil, storage_error
    end

    return storage_folders.books.id, nil
end

--- List all books managed by KOCloud.
---
--- Results are paginated internally until every matching Drive file has been
--- collected.
---@return KOCloudGoogleDriveFile[]|nil books
---@return string|nil error_message
function GoogleDriveProvider:listBooks()
    local books_folder_id, folder_error = self:getBooksFolderId()

    if not books_folder_id then
        return nil, folder_error
    end

    local access_token, token_error = self:getAccessToken()

    if not access_token then
        return nil, token_error
    end

    local query = string.format(
        "trashed = false and '%s' in parents "
            .. "and mimeType != '%s' "
            .. "and appProperties has { key='%s' and value='book' }",
        books_folder_id,
        DriveApi.FOLDER_MIME_TYPE,
        ROLE_KEY
    )

    local books = {}
    local page_token

    repeat
        local result, list_error = DriveApi:listFiles(
            access_token,
            query,
            {
                page_size = 100,
                page_token = page_token,
                order_by = "name",
            }
        )

        if not result then
            return nil, list_error
        end

        for _, file in ipairs(result.files) do
            table.insert(books, file)
        end

        page_token = result.nextPageToken
    until not page_token or page_token == ""

    return books, nil
end

--- Upload a local book into the KOCloud Books folder.
---@param local_path string Local EPUB/PDF/other book file path.
---@param remote_name? string Optional Google Drive file name.
---@return KOCloudGoogleDriveFile|nil book
---@return string|nil error_message
function GoogleDriveProvider:uploadBook(local_path, remote_name)
    if type(local_path) ~= "string" or local_path == "" then
        return nil, "Local book path is required"
    end

    local books_folder_id, folder_error = self:getBooksFolderId()

    if not books_folder_id then
        return nil, folder_error
    end

    local access_token, token_error = self:getAccessToken()

    if not access_token then
        return nil, token_error
    end

    local book_name = remote_name
    if type(book_name) ~= "string" or book_name == "" then
        book_name = basename(local_path)
    end

    return DriveApi:uploadFile(
        access_token,
        local_path,
        book_name,
        books_folder_id,
        getBookMimeType(book_name),
        {
            [ROLE_KEY] = "book",
            [SCHEMA_KEY] = SCHEMA_VERSION,
        }
    )
end

--- Download a KOCloud-managed book to a local path.
---@param file_id string Google Drive book file ID.
---@param local_path string Local destination path.
---@return boolean success
---@return string|nil error_message
function GoogleDriveProvider:downloadBook(file_id, local_path)
    if type(file_id) ~= "string" or file_id == "" then
        return false, "Google Drive book file ID is required"
    end

    if type(local_path) ~= "string" or local_path == "" then
        return false, "Local destination path is required"
    end

    local access_token, token_error = self:getAccessToken()

    if not access_token then
        return false, token_error
    end

    return DriveApi:downloadFile(
        access_token,
        file_id,
        local_path
    )
end

--- Forget all local user-specific Google OAuth token state.
function GoogleDriveProvider:clearAuthorization()
    self.auth:clearAuthorization()
end

return GoogleDriveProvider
