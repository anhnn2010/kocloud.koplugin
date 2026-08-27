--- Base interface for KOCloud storage providers.
---
--- Providers are storage adapters only. They expose generic remote-storage
--- primitives and must not contain KOCloud domain concepts such as books,
--- backups, reading data, or devices.
---@class KOCloudBaseProvider
---@field name string|nil Human-readable provider name.
---@field type string|nil Stable provider identifier.
---@field config table Provider configuration.
local BaseProvider = {}
BaseProvider.__index = BaseProvider

--- Opaque provider-specific reference to one remote entry.
---
--- Callers may retain and pass this value back to the same provider, but must
--- not inspect provider-specific fields such as Google Drive IDs or WebDAV
--- paths.
---@class KOCloudRemoteRef

--- Provider-neutral remote file or folder metadata.
---@class KOCloudRemoteEntry
---@field ref KOCloudRemoteRef Opaque provider-specific reference.
---@field name string Visible remote entry name.
---@field kind "file"|"folder"
---@field size? integer File size in bytes when available.
---@field modified_at? string Provider timestamp when available.
---@field mime_type? string MIME type when available.
---@field metadata? table<string, string> Provider-backed custom metadata.
---@field parent_refs? KOCloudRemoteRef[] Parent references when available.

--- Generic provider capabilities implemented by this adapter.
---@class KOCloudProviderCapabilities
---@field search boolean Provider implements provider-side entry search.
---@field trash boolean Delete can move entries to a recoverable trash.
---@field custom_metadata boolean Provider supports private custom metadata.
---@field resumable_upload boolean Provider implements resumable uploads.
---@field server_side_copy boolean Provider implements remote server-side copy.
---@field stable_refs boolean Remote references survive rename/move operations.

--- Create a new provider instance.
---@param config? table Provider configuration.
---@return KOCloudBaseProvider
function BaseProvider:new(config)
    local provider = setmetatable({}, self)
    provider.config = config or {}
    return provider
end

--- Return the human-readable provider name.
---@return string|nil
function BaseProvider:getName()
    return self.name
end

--- Return the provider type identifier.
---@return string|nil
function BaseProvider:getType()
    return self.type
end

--- Return generic capabilities implemented by this provider adapter.
---
--- Capabilities describe the KOCloud adapter implementation, not merely what
--- the remote service could theoretically support.
---@return KOCloudProviderCapabilities
function BaseProvider:getCapabilities()
    return {
        search = false,
        trash = false,
        custom_metadata = false,
        resumable_upload = false,
        server_side_copy = false,
        stable_refs = false,
    }
end

--- Raise a standard error for an unimplemented provider method.
---@param method_name string
---@return never
function BaseProvider:_notImplemented(method_name)
    error(string.format(
        "Cloud provider '%s' does not implement '%s'",
        self.type or "unknown",
        method_name
    ))
end


--- Serialize an opaque remote reference for persistent configuration.
---
--- The returned value must be representable by KOReader LuaSettings.
---@param ref KOCloudRemoteRef
---@return any serialized_ref
---@return string|nil error_message
function BaseProvider:serializeRef(ref)
    if type(ref) ~= "table" then
        return nil, "Invalid remote reference"
    end

    return ref, nil
end

--- Restore an opaque remote reference from persistent configuration.
---@param serialized_ref any
---@return KOCloudRemoteRef|nil ref
---@return string|nil error_message
function BaseProvider:deserializeRef(serialized_ref)
    if type(serialized_ref) ~= "table" then
        return nil, "Invalid serialized remote reference"
    end

    return serialized_ref, nil
end

--- Search remote entries using simple provider-neutral criteria.
---
--- Providers should advertise this through capabilities.search. Callers must
--- fall back to listChildren() when search is unavailable.
---@param criteria? table
---@return KOCloudRemoteEntry[]|nil entries
---@return string|nil error_message
function BaseProvider:findEntries(criteria)
    self:_notImplemented("findEntries")
end

--- List direct children of one remote folder.
---
--- A nil parent reference means the provider's user-visible root when that
--- concept exists.
---@param parent_ref? KOCloudRemoteRef
---@param options? table
---@return KOCloudRemoteEntry[]|nil entries
---@return string|nil error_message
function BaseProvider:listChildren(parent_ref, options)
    self:_notImplemented("listChildren")
end

--- Return metadata for one remote entry.
---@param entry_ref KOCloudRemoteRef
---@param options? table
---@return KOCloudRemoteEntry|nil entry
---@return string|nil error_message
function BaseProvider:getEntry(entry_ref, options)
    self:_notImplemented("getEntry")
end

--- Create a child folder under a remote parent.
---@param parent_ref KOCloudRemoteRef|nil
---@param name string
---@param options? table
---@return KOCloudRemoteEntry|nil entry
---@return string|nil error_message
function BaseProvider:createFolder(parent_ref, name, options)
    self:_notImplemented("createFolder")
end

--- Upload one local file under a remote parent.
---@param parent_ref KOCloudRemoteRef|nil
---@param local_path string
---@param remote_name string
---@param options? table
---@return KOCloudRemoteEntry|nil entry
---@return string|nil error_message
function BaseProvider:uploadFile(
    parent_ref,
    local_path,
    remote_name,
    options
)
    self:_notImplemented("uploadFile")
end

--- Download one remote file to a local path.
---@param file_ref KOCloudRemoteRef
---@param local_path string
---@param options? table
---@return boolean success
---@return string|nil error_message
function BaseProvider:downloadFile(file_ref, local_path, options)
    self:_notImplemented("downloadFile")
end

--- Delete one remote entry using the provider's safe default semantics.
---
--- For providers with trash support, the default should be recoverable.
---@param entry_ref KOCloudRemoteRef
---@param options? table
---@return boolean success
---@return string|nil error_message
function BaseProvider:deleteEntry(entry_ref, options)
    self:_notImplemented("deleteEntry")
end

return BaseProvider
