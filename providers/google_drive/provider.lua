local BookFormats = require("core/book_formats")
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

--- Return the basename of a local path.
---@param path string
---@return string
local function basename(path)
    return path:match("([^/\\]+)$") or path
end

--- Return the Google Drive file ID stored in an opaque KOCloud reference.
---@param ref KOCloudRemoteRef|nil
---@return string|nil file_id
---@return string|nil error_message
local function getRefId(ref)
    if ref == nil then
        return nil, nil
    end

    if type(ref) ~= "table"
        or type(ref.id) ~= "string"
        or ref.id == ""
    then
        return nil, "Invalid Google Drive remote reference"
    end

    return ref.id, nil
end

--- Convert Google Drive metadata to the provider-neutral KOCloud entry model.
---@param file KOCloudGoogleDriveFile
---@return KOCloudRemoteEntry
local function toRemoteEntry(file)
    local parent_refs

    if type(file.parents) == "table" then
        parent_refs = {}

        for _index, parent_id in ipairs(file.parents) do
            table.insert(parent_refs, { id = parent_id })
        end
    end

    return {
        ref = {
            id = file.id,
        },
        name = file.name or "",
        kind = file.mimeType == DriveApi.FOLDER_MIME_TYPE
                and "folder"
            or "file",
        size = tonumber(file.size),
        modified_at = file.modifiedTime,
        mime_type = file.mimeType,
        metadata = file.appProperties or {},
        parent_refs = parent_refs,
    }
end

--- Convert a provider-neutral entry back to the legacy Drive-shaped object.
---
--- This compatibility bridge keeps the existing Library UI unchanged while
--- it is migrated to LibraryService in the next architecture steps.
---@param entry KOCloudRemoteEntry
---@return KOCloudGoogleDriveFile
local function toLegacyDriveFile(entry)
    local parents

    if type(entry.parent_refs) == "table" then
        parents = {}

        for _index, parent_ref in ipairs(entry.parent_refs) do
            if type(parent_ref) == "table"
                and type(parent_ref.id) == "string"
            then
                table.insert(parents, parent_ref.id)
            end
        end
    end

    return {
        id = entry.ref.id,
        name = entry.name,
        mimeType = entry.mime_type,
        parents = parents,
        appProperties = entry.metadata,
        size = entry.size and tostring(entry.size) or nil,
        modifiedTime = entry.modified_at,
    }
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

--- Return generic storage capabilities implemented by this adapter.
---@return KOCloudProviderCapabilities
function GoogleDriveProvider:getCapabilities()
    return {
        trash = true,
        custom_metadata = true,
        resumable_upload = true,
        server_side_copy = false,
        stable_refs = true,
    }
end

--- List direct children of a Google Drive folder.
---@param parent_ref? KOCloudRemoteRef Nil means the visible Drive root.
---@param options? table
---@return KOCloudRemoteEntry[]|nil entries
---@return string|nil error_message
function GoogleDriveProvider:listChildren(parent_ref, options)
    options = options or {}

    local parent_id, ref_error = getRefId(parent_ref)

    if ref_error then
        return nil, ref_error
    end

    local access_token, token_error = self:getAccessToken()

    if not access_token then
        return nil, token_error
    end

    local query_parent = parent_id or "root"
    local query = string.format(
        "trashed = false and '%s' in parents",
        query_parent
    )
    local entries = {}
    local page_token

    repeat
        local result, list_error = DriveApi:listFiles(
            access_token,
            query,
            {
                page_size = options.page_size or 100,
                page_token = page_token,
                order_by = options.order_by or "name",
            }
        )

        if not result then
            return nil, list_error
        end

        for _index, file in ipairs(result.files) do
            table.insert(entries, toRemoteEntry(file))
        end

        page_token = result.nextPageToken
    until not page_token or page_token == ""

    return entries, nil
end

--- Return metadata for one Google Drive entry.
---@param entry_ref KOCloudRemoteRef
---@param options? table
---@return KOCloudRemoteEntry|nil entry
---@return string|nil error_message
function GoogleDriveProvider:getEntry(entry_ref, options)
    local file_id, ref_error = getRefId(entry_ref)

    if ref_error or not file_id then
        return nil, ref_error or "Google Drive remote reference is required"
    end

    local access_token, token_error = self:getAccessToken()

    if not access_token then
        return nil, token_error
    end

    local file, get_error = DriveApi:getFile(access_token, file_id)

    if not file then
        return nil, get_error
    end

    return toRemoteEntry(file), nil
end

--- Create one Google Drive folder under a remote parent.
---@param parent_ref KOCloudRemoteRef|nil Nil means the visible Drive root.
---@param name string
---@param options? table
---@return KOCloudRemoteEntry|nil entry
---@return string|nil error_message
function GoogleDriveProvider:createFolder(parent_ref, name, options)
    if type(name) ~= "string" or name == "" then
        return nil, "Folder name is required"
    end

    options = options or {}

    local parent_id, ref_error = getRefId(parent_ref)

    if ref_error then
        return nil, ref_error
    end

    local access_token, token_error = self:getAccessToken()

    if not access_token then
        return nil, token_error
    end

    local folder, create_error = DriveApi:createFolder(
        access_token,
        name,
        parent_id,
        options.metadata
    )

    if not folder then
        return nil, create_error
    end

    return toRemoteEntry(folder), nil
end

--- Upload one local file under a Google Drive parent folder.
---@param parent_ref KOCloudRemoteRef|nil
---@param local_path string
---@param remote_name string
---@param options? table
---@return KOCloudRemoteEntry|nil entry
---@return string|nil error_message
function GoogleDriveProvider:uploadFile(
    parent_ref,
    local_path,
    remote_name,
    options
)
    if type(local_path) ~= "string" or local_path == "" then
        return nil, "Local file path is required"
    end

    if type(remote_name) ~= "string" or remote_name == "" then
        return nil, "Remote file name is required"
    end

    options = options or {}

    local parent_id, ref_error = getRefId(parent_ref)

    if ref_error then
        return nil, ref_error
    end

    if not parent_id then
        return nil, "Google Drive upload parent is required"
    end

    local access_token, token_error = self:getAccessToken()

    if not access_token then
        return nil, token_error
    end

    local file, upload_error = DriveApi:uploadFile(
        access_token,
        local_path,
        remote_name,
        parent_id,
        options.mime_type,
        options.metadata
    )

    if not file then
        return nil, upload_error
    end

    return toRemoteEntry(file), nil
end

--- Download one Google Drive entry to a local path.
---@param file_ref KOCloudRemoteRef
---@param local_path string
---@param options? table
---@return boolean success
---@return string|nil error_message
function GoogleDriveProvider:downloadFile(file_ref, local_path, options)
    local file_id, ref_error = getRefId(file_ref)

    if ref_error or not file_id then
        return false, ref_error or "Google Drive remote reference is required"
    end

    if type(local_path) ~= "string" or local_path == "" then
        return false, "Local destination path is required"
    end

    local access_token, token_error = self:getAccessToken()

    if not access_token then
        return false, token_error
    end

    return DriveApi:downloadFile(access_token, file_id, local_path)
end

--- Delete one Google Drive entry using recoverable Trash semantics.
---@param entry_ref KOCloudRemoteRef
---@param options? table
---@return boolean success
---@return string|nil error_message
function GoogleDriveProvider:deleteEntry(entry_ref, options)
    options = options or {}

    if options.permanent then
        return false, "Permanent Google Drive deletion is not implemented"
    end

    local file_id, ref_error = getRefId(entry_ref)

    if ref_error or not file_id then
        return false, ref_error or "Google Drive remote reference is required"
    end

    local access_token, token_error = self:getAccessToken()

    if not access_token then
        return false, token_error
    end

    return DriveApi:trashFile(access_token, file_id)
end

--- Return whether the KOCloud application OAuth client is configured.
---@return boolean
function GoogleDriveProvider:isClientConfigured()
    return self.auth:isClientConfigured()
end

--- Return the KOReader settings file used for OAuth application credentials.
---@return string
function GoogleDriveProvider:getOAuthCredentialSettingsFile()
    return self.auth:getClientSettingsFile()
end

--- Save Google OAuth application credentials from the phone setup flow.
---
--- If the OAuth client changes, cached Google Drive folder IDs are also
--- cleared because the next authorization may point to a different account.
---@param client_id string
---@param client_secret string
---@return table|nil credentials
---@return boolean changed
---@return string|nil error_message
function GoogleDriveProvider:setOAuthCredentials(
    client_id,
    client_secret
)
    local credentials, changed, save_error =
        self.auth:setClientCredentials(
            client_id,
            client_secret
        )

    if not credentials then
        return nil, false, save_error
    end

    if changed then
        self.config.root_folder_id = nil
        self.config.folders = nil
    end

    return credentials, changed, nil
end

--- Import Google OAuth application credentials from a downloaded JSON file.
---
--- If the OAuth client changes, cached Google Drive folder IDs are also
--- cleared because the next authorization may point to a different account.
---@param json_path string
---@return table|nil credentials
---@return boolean changed
---@return string|nil error_message
function GoogleDriveProvider:importOAuthCredentials(json_path)
    local credentials, changed, import_error =
        self.auth:importClientCredentials(json_path)

    if not credentials then
        return nil, false, import_error
    end

    if changed then
        self.config.root_folder_id = nil
        self.config.folders = nil
    end

    return credentials, changed, nil
end

--- Disconnect Google Drive and clear account-specific cached folder IDs.
function GoogleDriveProvider:disconnect()
    self.auth:clearAuthorization()
    self.config.root_folder_id = nil
    self.config.folders = nil
end

--- Remove OAuth application credentials and all account-specific local state.
---@return boolean success
---@return string|nil error_message
function GoogleDriveProvider:clearOAuthCredentials()
    local success, clear_error =
        self.auth:clearClientCredentials()

    if not success then
        return false, clear_error
    end

    self.config.root_folder_id = nil
    self.config.folders = nil

    return true, nil
end

--- Return whether this user has authorized Google Drive.
---@return boolean
function GoogleDriveProvider:isConfigured()
    return self.auth:isAuthorized()
end

--- Return whether auth changed persistent provider configuration.
---@return boolean
function GoogleDriveProvider:isPersistentConfigDirty()
    return self.auth:isPersistentConfigDirty()
end

--- Mark persistent auth configuration as saved.
function GoogleDriveProvider:markPersistentConfigSaved()
    self.auth:markPersistentConfigSaved()
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

--- List folders and KOCloud-managed books directly under one library folder.
---
--- Compatibility API retained until LibraryService owns this domain logic.
---@param parent_folder_id? string Google Drive parent folder ID.
---@return KOCloudGoogleDriveFile[]|nil folders
---@return KOCloudGoogleDriveFile[]|nil books
---@return string|nil error_message
function GoogleDriveProvider:listLibraryFolder(parent_folder_id)
    local folder_id = parent_folder_id

    if type(folder_id) ~= "string" or folder_id == "" then
        local books_folder_id, folder_error = self:getBooksFolderId()

        if not books_folder_id then
            return nil, nil, folder_error
        end

        folder_id = books_folder_id
    end

    local entries, list_error = self:listChildren(
        { id = folder_id },
        { order_by = "name" }
    )

    if not entries then
        return nil, nil, list_error
    end

    local folders = {}
    local books = {}

    for _index, entry in ipairs(entries) do
        if entry.kind == "folder" then
            table.insert(folders, toLegacyDriveFile(entry))
        elseif entry.metadata[ROLE_KEY] == "book" then
            table.insert(books, toLegacyDriveFile(entry))
        end
    end

    return folders, books, nil
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


--- Create a child folder inside the KOCloud Books library.
---
--- Compatibility API retained until LibraryService owns this domain logic.
---@param folder_name string
---@param parent_folder_id? string Google Drive parent folder ID.
---@return KOCloudGoogleDriveFile|nil folder
---@return string|nil error_message
function GoogleDriveProvider:createLibraryFolder(
    folder_name,
    parent_folder_id
)
    local folder_id = parent_folder_id

    if type(folder_id) ~= "string" or folder_id == "" then
        local books_folder_id, folder_error = self:getBooksFolderId()

        if not books_folder_id then
            return nil, folder_error
        end

        folder_id = books_folder_id
    end

    local entry, create_error = self:createFolder(
        { id = folder_id },
        folder_name
    )

    if not entry then
        return nil, create_error
    end

    return toLegacyDriveFile(entry), nil
end

--- Upload a local book into a KOCloud Books folder.
---
--- Compatibility API retained until LibraryService owns this domain logic.
---@param local_path string Local supported book file path.
---@param remote_name? string Optional Google Drive file name.
---@param parent_folder_id? string Google Drive parent folder ID.
---@return KOCloudGoogleDriveFile|nil book
---@return string|nil error_message
function GoogleDriveProvider:uploadBook(
    local_path,
    remote_name,
    parent_folder_id
)
    if type(local_path) ~= "string" or local_path == "" then
        return nil, "Local book path is required"
    end

    local books_folder_id = parent_folder_id

    if type(books_folder_id) ~= "string" or books_folder_id == "" then
        local folder_error
        books_folder_id, folder_error = self:getBooksFolderId()

        if not books_folder_id then
            return nil, folder_error
        end
    end

    local book_name = remote_name

    if type(book_name) ~= "string" or book_name == "" then
        book_name = basename(local_path)
    end

    local entry, upload_error = self:uploadFile(
        { id = books_folder_id },
        local_path,
        book_name,
        {
            mime_type = BookFormats.getMimeType(book_name),
            metadata = {
                [ROLE_KEY] = "book",
                [SCHEMA_KEY] = SCHEMA_VERSION,
            },
        }
    )

    if not entry then
        return nil, upload_error
    end

    return toLegacyDriveFile(entry), nil
end

--- Move a KOCloud-managed book to Google Drive Trash.
---@param file_id string Google Drive book file ID.
---@return boolean success
---@return string|nil error_message
function GoogleDriveProvider:deleteBook(file_id)
    if type(file_id) ~= "string" or file_id == "" then
        return false, "Google Drive book file ID is required"
    end

    return self:deleteEntry({ id = file_id })
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

    return self:downloadFile({ id = file_id }, local_path)
end

--- Forget all local user-specific Google OAuth token state.
function GoogleDriveProvider:clearAuthorization()
    self.auth:clearAuthorization()
end

return GoogleDriveProvider
