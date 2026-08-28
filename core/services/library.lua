local BookFormats = require("core/book_formats")
local Protocol = require("core/protocol")

--- Provider-neutral KOCloud book-library service.
---
--- This service owns every KOCloud Library concept. UI code talks to this
--- service, while storage providers only receive generic file/folder requests.
---@class KOCloudLibraryService
---@field provider KOCloudBaseProvider
---@field layout KOCloudStorageLayoutService
---@class KOCloudLibraryEntry
---@field key string Opaque stable key used for UI/session identity.
---@field ref KOCloudRemoteRef Provider-specific opaque storage reference.
---@field name string
---@field kind "file"|"folder"
---@field size? integer
---@field modified_at? string
---@field mime_type? string
---@field metadata table<string, string>

local LibraryService = {}
LibraryService.__index = LibraryService

local ROLE_KEY = Protocol.METADATA_KEYS.role
local SCHEMA_KEY = Protocol.METADATA_KEYS.schema
local SOURCE_KEY = Protocol.METADATA_KEYS.source

--- Return the basename of a local path.
---@param path string
---@return string
local function basename(path)
    return path:match("([^/\\]+)$") or path
end

--- Create a Library service for one provider and storage layout.
---@param provider KOCloudBaseProvider
---@param layout KOCloudStorageLayoutService
---@return KOCloudLibraryService
function LibraryService:new(provider, layout)
    local instance = setmetatable({}, self)
    instance.provider = provider
    instance.layout = layout
    return instance
end

--- Return the active provider's human-readable name.
---@return string
function LibraryService:getProviderName()
    return self.provider:getName() or "Cloud storage"
end

--- Return whether delete uses recoverable trash semantics.
---@return boolean
function LibraryService:usesTrash()
    local capabilities = self.provider:getCapabilities() or {}
    return capabilities.trash == true
end

--- Return a stable opaque key for one library entry.
---@param entry table
---@return string|nil key
---@return string|nil error_message
function LibraryService:getEntryKey(entry)
    if type(entry) ~= "table" or entry.ref == nil then
        return nil, "Library entry reference is required"
    end

    return self.provider:getRefKey(entry.ref)
end

--- Return the Books root or a supplied child-folder reference.
---@param folder_ref? KOCloudRemoteRef
---@return KOCloudRemoteRef|nil ref
---@return string|nil error_message
function LibraryService:_resolveFolderRef(folder_ref)
    if folder_ref ~= nil then
        return folder_ref, nil
    end

    local books_ref = self.layout:getBooksRootRef()

    if not books_ref then
        return nil, "KOCloud Books storage is not initialized"
    end

    return books_ref, nil
end

--- Return custom metadata for a managed book when the provider supports it.
---@return table|nil metadata
function LibraryService:_buildBookMetadata()
    local capabilities = self.provider:getCapabilities() or {}

    if not capabilities.custom_metadata then
        return nil
    end

    return {
        [ROLE_KEY] = Protocol.ROLES.book,
        [SCHEMA_KEY] = Protocol.SCHEMA_VERSION,
        [SOURCE_KEY] = Protocol.SOURCES.koreader,
    }
end

--- Return custom metadata for a managed Library folder when supported.
---@return table|nil metadata
function LibraryService:_buildFolderMetadata()
    local capabilities = self.provider:getCapabilities() or {}

    if not capabilities.custom_metadata then
        return nil
    end

    return {
        [ROLE_KEY] = Protocol.ROLES.book_folder,
        [SCHEMA_KEY] = Protocol.SCHEMA_VERSION,
        [SOURCE_KEY] = Protocol.SOURCES.koreader,
    }
end

--- Convert one provider entry to the Library model used by the UI.
---@param entry KOCloudRemoteEntry
---@return KOCloudLibraryEntry|nil library_entry
---@return string|nil error_message
function LibraryService:_toLibraryEntry(entry)
    local key, key_error = self.provider:getRefKey(entry.ref)

    if not key then
        return nil, key_error or "Cannot identify remote library entry"
    end

    return {
        key = key,
        ref = entry.ref,
        name = entry.name,
        kind = entry.kind,
        size = entry.size,
        modified_at = entry.modified_at,
        mime_type = entry.mime_type,
        metadata = entry.metadata or {},
    }, nil
end

--- Return whether one remote file belongs in the Books browser.
---
--- Provider metadata is preferred when available. Extension fallback keeps
--- providers without custom metadata, such as a future WebDAV adapter, useful.
---@param entry KOCloudRemoteEntry
---@return boolean
function LibraryService:_isBookEntry(entry)
    if entry.kind ~= "file" then
        return false
    end

    local metadata = entry.metadata or {}

    if metadata[ROLE_KEY] == Protocol.ROLES.book then
        return true
    end

    return BookFormats.isSupported(entry.name or "")
end

--- List direct child folders and supported books in one Library folder.
---@param parent_ref? KOCloudRemoteRef Nil means KOCloud/Books.
---@return KOCloudLibraryEntry[]|nil folders
---@return KOCloudLibraryEntry[]|nil books
---@return string|nil error_message
function LibraryService:listFolder(parent_ref)
    local resolved_ref, ref_error = self:_resolveFolderRef(parent_ref)

    if not resolved_ref then
        return nil, nil, ref_error
    end

    local entries, list_error = self.provider:listChildren(
        resolved_ref,
        { order_by = "name" }
    )

    if not entries then
        return nil, nil, list_error
    end

    local folders = {}
    local books = {}

    for _index, entry in ipairs(entries) do
        if entry.kind == "folder" or self:_isBookEntry(entry) then
            local library_entry, entry_error = self:_toLibraryEntry(entry)

            if not library_entry then
                return nil, nil, entry_error
            end

            if library_entry.kind == "folder" then
                table.insert(folders, library_entry)
            else
                table.insert(books, library_entry)
            end
        end
    end

    return folders, books, nil
end

--- Create a child folder inside the Books library.
---@param folder_name string
---@param parent_ref? KOCloudRemoteRef Nil means KOCloud/Books.
---@return KOCloudLibraryEntry|nil folder
---@return string|nil error_message
function LibraryService:createFolder(folder_name, parent_ref)
    local resolved_ref, ref_error = self:_resolveFolderRef(parent_ref)

    if not resolved_ref then
        return nil, ref_error
    end

    local entry, create_error = self.provider:createFolder(
        resolved_ref,
        folder_name,
        {
            metadata = self:_buildFolderMetadata(),
        }
    )

    if not entry then
        return nil, create_error
    end

    return self:_toLibraryEntry(entry)
end

--- Upload one supported local book into the Books library.
---@param local_path string
---@param parent_ref? KOCloudRemoteRef Nil means KOCloud/Books.
---@param remote_name? string
---@return KOCloudLibraryEntry|nil book
---@return string|nil error_message
function LibraryService:uploadBook(local_path, parent_ref, remote_name)
    if type(local_path) ~= "string" or local_path == "" then
        return nil, "Local book path is required"
    end

    local book_name = remote_name

    if type(book_name) ~= "string" or book_name == "" then
        book_name = basename(local_path)
    end

    if not BookFormats.isSupported(book_name) then
        return nil, "Unsupported KOReader book format"
    end

    local resolved_ref, ref_error = self:_resolveFolderRef(parent_ref)

    if not resolved_ref then
        return nil, ref_error
    end

    local entry, upload_error = self.provider:uploadFile(
        resolved_ref,
        local_path,
        book_name,
        {
            mime_type = BookFormats.getMimeType(book_name),
            metadata = self:_buildBookMetadata(),
        }
    )

    if not entry then
        return nil, upload_error
    end

    return self:_toLibraryEntry(entry)
end

--- Download one Library book to local storage.
---@param book KOCloudLibraryEntry
---@param local_path string
---@return boolean success
---@return string|nil error_message
function LibraryService:downloadBook(book, local_path)
    if type(book) ~= "table" or book.ref == nil then
        return false, "Library book reference is required"
    end

    return self.provider:downloadFile(book.ref, local_path)
end

--- Delete one Library book using the provider's safe default semantics.
---@param book KOCloudLibraryEntry
---@return boolean success
---@return string|nil error_message
function LibraryService:deleteBook(book)
    if type(book) ~= "table" or book.ref == nil then
        return false, "Library book reference is required"
    end

    return self.provider:deleteEntry(book.ref)
end

return LibraryService
