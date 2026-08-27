local Protocol = require("core/protocol")

--- Provider-neutral KOCloud storage-layout manager.
---
--- This service owns the logical KOCloud folder structure. Providers only
--- expose generic storage primitives and optional provider-specific metadata.
---@class KOCloudStorageLayoutService
---@field provider KOCloudBaseProvider
---@field persistent_config_dirty boolean
local StorageLayoutService = {}
StorageLayoutService.__index = StorageLayoutService

local ROLE_KEY = Protocol.METADATA_KEYS.role
local SCHEMA_KEY = Protocol.METADATA_KEYS.schema
local INTERNAL_KEY = Protocol.METADATA_KEYS.internal

--- Create a storage-layout service for one provider instance.
---@param provider KOCloudBaseProvider
---@return KOCloudStorageLayoutService
function StorageLayoutService:new(provider)
    local instance = setmetatable({}, self)
    instance.provider = provider
    instance.persistent_config_dirty = false
    instance:_migrateLegacyCache()
    return instance
end

--- Return whether layout migration changed persistent provider configuration.
---@return boolean
function StorageLayoutService:isPersistentConfigDirty()
    return self.persistent_config_dirty == true
end

--- Mark migrated layout configuration as persisted.
function StorageLayoutService:markPersistentConfigSaved()
    self.persistent_config_dirty = false
end

--- Return provider capabilities with a safe empty fallback.
---@return KOCloudProviderCapabilities
function StorageLayoutService:_getCapabilities()
    return self.provider:getCapabilities() or {}
end

--- Deserialize one cached provider reference.
---@param value any
---@return KOCloudRemoteRef|nil ref
function StorageLayoutService:_deserializeCachedRef(value)
    if value == nil then
        return nil
    end

    local ref = self.provider:deserializeRef(value)
    return ref
end

--- Serialize and cache the current logical layout.
---@param root_entry KOCloudRemoteEntry
---@param folders table<string, KOCloudRemoteEntry>
---@return boolean success
---@return string|nil error_message
function StorageLayoutService:_cacheLayout(root_entry, folders)
    local root_ref, root_error = self.provider:serializeRef(root_entry.ref)

    if not root_ref then
        return false, root_error or "Cannot cache KOCloud root reference"
    end

    local cached_folders = {}

    for _, definition in ipairs(Protocol.MANAGED_FOLDERS) do
        local entry = folders[definition.key]

        if not entry then
            return false, "Missing KOCloud managed folder: " .. definition.key
        end

        local serialized_ref, serialize_error =
            self.provider:serializeRef(entry.ref)

        if not serialized_ref then
            return false, serialize_error
                or "Cannot cache KOCloud managed folder reference"
        end

        cached_folders[definition.key] = serialized_ref
    end

    self.provider.config.layout = {
        schema_version = Protocol.SCHEMA_VERSION,
        root = root_ref,
        folders = cached_folders,
    }

    -- Old KOCloud builds cached raw Google Drive IDs in these fields. Once a
    -- provider-neutral layout cache exists, remove the legacy representation.
    self.provider.config.root_folder_id = nil
    self.provider.config.folders = nil
    self.persistent_config_dirty = true

    return true, nil
end

--- Migrate the pre-A2 raw-ID cache to provider-neutral serialized refs.
---
--- Google Drive accepts the legacy string IDs through deserializeRef(). Future
--- providers never need to know these old fields.
function StorageLayoutService:_migrateLegacyCache()
    if type(self.provider.config.layout) == "table" then
        return
    end

    local legacy_root = self.provider.config.root_folder_id
    local legacy_folders = self.provider.config.folders

    if type(legacy_root) ~= "string" or legacy_root == "" then
        return
    end

    if type(legacy_folders) ~= "table" then
        return
    end

    local root_ref = self.provider:deserializeRef(legacy_root)

    if not root_ref then
        return
    end

    local serialized_root = self.provider:serializeRef(root_ref)

    if not serialized_root then
        return
    end

    local folders = {}

    for _, definition in ipairs(Protocol.MANAGED_FOLDERS) do
        local legacy_value = legacy_folders[definition.key]
        local ref = self.provider:deserializeRef(legacy_value)

        if not ref then
            return
        end

        local serialized_ref = self.provider:serializeRef(ref)

        if not serialized_ref then
            return
        end

        folders[definition.key] = serialized_ref
    end

    self.provider.config.layout = {
        schema_version = Protocol.SCHEMA_VERSION,
        root = serialized_root,
        folders = folders,
    }
    self.provider.config.root_folder_id = nil
    self.provider.config.folders = nil
    self.persistent_config_dirty = true
end

--- Remove cached remote layout references without touching remote storage.
function StorageLayoutService:clearCache()
    self.provider.config.layout = nil
    self.provider.config.root_folder_id = nil
    self.provider.config.folders = nil
    self.persistent_config_dirty = true
end

--- Return the cached KOCloud root reference.
---@return KOCloudRemoteRef|nil ref
function StorageLayoutService:getRootRef()
    local layout = self.provider.config.layout

    if type(layout) ~= "table" then
        return nil
    end

    return self:_deserializeCachedRef(layout.root)
end

--- Return a cached managed-folder reference by logical key.
---@param key string
---@return KOCloudRemoteRef|nil ref
function StorageLayoutService:getFolderRef(key)
    local layout = self.provider.config.layout

    if type(layout) ~= "table" or type(layout.folders) ~= "table" then
        return nil
    end

    return self:_deserializeCachedRef(layout.folders[key])
end

--- Return the cached Books root reference.
---@return KOCloudRemoteRef|nil ref
function StorageLayoutService:getBooksRootRef()
    return self:getFolderRef("books")
end

--- Return the number of cached managed folders.
---@return integer
function StorageLayoutService:getManagedFolderCount()
    local count = 0

    for _, definition in ipairs(Protocol.MANAGED_FOLDERS) do
        if self:getFolderRef(definition.key) then
            count = count + 1
        end
    end

    return count
end

--- Return the number of logical managed folders in this protocol version.
---@return integer
function StorageLayoutService:getExpectedManagedFolderCount()
    return #Protocol.MANAGED_FOLDERS
end

--- Return whether the complete KOCloud layout is cached locally.
---@return boolean
function StorageLayoutService:isInitialized()
    return self:getRootRef() ~= nil
        and self:getManagedFolderCount()
            == self:getExpectedManagedFolderCount()
end

--- Return provider metadata for one managed folder when supported.
---@param definition table
---@return table|nil metadata
function StorageLayoutService:_buildManagedMetadata(definition)
    local capabilities = self:_getCapabilities()

    if not capabilities.custom_metadata then
        return nil
    end

    local metadata = {
        [ROLE_KEY] = definition.role,
        [SCHEMA_KEY] = Protocol.SCHEMA_VERSION,
    }

    if definition.internal then
        metadata[INTERNAL_KEY] = "true"
    end

    return metadata
end

--- Return whether one remote folder matches a logical layout definition.
---@param entry KOCloudRemoteEntry
---@param definition table
---@return boolean
function StorageLayoutService:_matchesDefinition(entry, definition)
    if entry.kind ~= "folder" then
        return false
    end

    local capabilities = self:_getCapabilities()

    if capabilities.custom_metadata then
        return type(entry.metadata) == "table"
            and entry.metadata[ROLE_KEY] == definition.role
    end

    return entry.name == definition.name
end

--- Find one managed folder under a parent reference.
---@param parent_ref? KOCloudRemoteRef
---@param definition table
---@param global_search? boolean
---@return KOCloudRemoteEntry|nil entry
---@return string|nil error_message
function StorageLayoutService:_findManagedFolder(
    parent_ref,
    definition,
    global_search
)
    local capabilities = self:_getCapabilities()

    if global_search
        and capabilities.search
        and capabilities.custom_metadata
    then
        local entries, search_error = self.provider:findEntries({
            kind = "folder",
            metadata = {
                [ROLE_KEY] = definition.role,
            },
            limit = 10,
        })

        if not entries then
            return nil, search_error
        end

        if #entries > 0 then
            return entries[1], nil
        end

        return nil, nil
    end

    local entries, list_error = self.provider:listChildren(parent_ref, {
        order_by = "name",
    })

    if not entries then
        return nil, list_error
    end

    for _, entry in ipairs(entries) do
        if self:_matchesDefinition(entry, definition) then
            return entry, nil
        end
    end

    return nil, nil
end

--- Find or create one managed folder.
---@param parent_ref? KOCloudRemoteRef
---@param definition table
---@param global_search? boolean
---@return KOCloudRemoteEntry|nil entry
---@return boolean created
---@return string|nil error_message
function StorageLayoutService:_ensureManagedFolder(
    parent_ref,
    definition,
    global_search
)
    local entry, find_error = self:_findManagedFolder(
        parent_ref,
        definition,
        global_search
    )

    if find_error then
        return nil, false, find_error
    end

    if entry then
        return entry, false, nil
    end

    local created_entry, create_error = self.provider:createFolder(
        parent_ref,
        definition.name,
        {
            metadata = self:_buildManagedMetadata(definition),
        }
    )

    if not created_entry then
        return nil, false, create_error
    end

    return created_entry, true, nil
end

--- Ensure the complete provider-neutral KOCloud storage layout exists.
---@return table<string, KOCloudRemoteEntry>|nil folders
---@return integer created_count
---@return string|nil error_message
function StorageLayoutService:ensureStorageLayout()
    local root, root_created, root_error = self:_ensureManagedFolder(
        nil,
        Protocol.ROOT_FOLDER,
        true
    )

    if not root then
        return nil, 0, root_error
    end

    local folders = {
        root = root,
    }
    local created_count = root_created and 1 or 0

    for _, definition in ipairs(Protocol.MANAGED_FOLDERS) do
        local folder, created, folder_error = self:_ensureManagedFolder(
            root.ref,
            definition,
            false
        )

        if not folder then
            return nil, created_count, folder_error
        end

        folders[definition.key] = folder

        if created then
            created_count = created_count + 1
        end
    end

    local cached, cache_error = self:_cacheLayout(root, folders)

    if not cached then
        return nil, created_count, cache_error
    end

    return folders, created_count, nil
end

return StorageLayoutService
