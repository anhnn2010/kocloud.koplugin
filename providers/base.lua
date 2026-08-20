--- Base interface for KOCloud storage providers.
---@class KOCloudBaseProvider
---@field name string|nil Human-readable provider name.
---@field type string|nil Stable provider identifier.
---@field config table Provider configuration.
local BaseProvider = {}
BaseProvider.__index = BaseProvider

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

--- List files and folders at a remote path.
---@param remote_path string
---@return table
function BaseProvider:list(remote_path)
    self:_notImplemented("list")
end

--- Download a remote file to a local path.
---@param remote_path string
---@param local_path string
---@return boolean
function BaseProvider:download(remote_path, local_path)
    self:_notImplemented("download")
end

--- Upload a local file to a remote path.
---@param local_path string
---@param remote_path string
---@return boolean
function BaseProvider:upload(local_path, remote_path)
    self:_notImplemented("upload")
end

--- Delete a remote file or folder.
---@param remote_path string
---@return boolean
function BaseProvider:delete(remote_path)
    self:_notImplemented("delete")
end

--- Create a remote folder.
---@param remote_path string
---@return boolean
function BaseProvider:createFolder(remote_path)
    self:_notImplemented("createFolder")
end

return BaseProvider
