local FakeProvider = {}
FakeProvider.__index = FakeProvider

local function cloneRef(ref)
    if type(ref) ~= "table" then
        return ref
    end

    return { id = ref.id }
end

local function readFile(path)
    local file = io.open(path, "rb")

    if not file then
        return nil
    end

    local content = file:read("*a")
    file:close()
    return content
end

local function writeFile(path, content)
    local file = assert(io.open(path, "wb"))
    file:write(content or "")
    file:close()
end

function FakeProvider:new(options)
    options = options or {}

    local instance = setmetatable({}, self)
    instance.name = options.name or "Fake storage"
    instance.type = "fake"
    instance.config = options.config or {}
    instance.capabilities = options.capabilities or {
        search = true,
        trash = true,
        custom_metadata = true,
        resumable_upload = false,
        server_side_copy = false,
        stable_refs = true,
    }
    instance.entries = {}
    instance.children = {
        root = {},
    }
    instance.next_id = 1
    instance.calls = {}
    return instance
end

function FakeProvider:getName()
    return self.name
end

function FakeProvider:getCapabilities()
    return self.capabilities
end

function FakeProvider:serializeRef(ref)
    if type(ref) == "string" then
        return ref
    end

    if type(ref) ~= "table" or not ref.id then
        return nil, "Invalid reference"
    end

    return ref.id, nil
end

function FakeProvider:deserializeRef(value)
    if type(value) == "table" and value.id then
        return cloneRef(value), nil
    end

    if type(value) ~= "string" or value == "" then
        return nil, "Invalid serialized reference"
    end

    return { id = value }, nil
end

function FakeProvider:getRefKey(ref)
    if type(ref) ~= "table" or not ref.id then
        return nil, "Invalid reference"
    end

    return "fake:" .. ref.id, nil
end

function FakeProvider:_parentKey(parent_ref)
    if parent_ref == nil then
        return "root"
    end

    return parent_ref.id
end

function FakeProvider:_insertEntry(entry, parent_ref)
    self.entries[entry.ref.id] = entry

    local parent_key = self:_parentKey(parent_ref)
    self.children[parent_key] = self.children[parent_key] or {}
    table.insert(self.children[parent_key], entry.ref.id)

    if entry.kind == "folder" then
        self.children[entry.ref.id] = self.children[entry.ref.id] or {}
    end
end

function FakeProvider:_newEntry(kind, name, parent_ref, options)
    local id = tostring(self.next_id)
    self.next_id = self.next_id + 1

    local entry = {
        ref = { id = id },
        name = name,
        kind = kind,
        size = options and options.size or nil,
        mime_type = options and options.mime_type or nil,
        metadata = options and options.metadata or {},
        content = options and options.content or nil,
    }

    self:_insertEntry(entry, parent_ref)
    return entry
end

function FakeProvider:addFolder(parent_ref, name, metadata)
    return self:_newEntry("folder", name, parent_ref, {
        metadata = metadata,
    })
end

function FakeProvider:addFile(parent_ref, name, options)
    options = options or {}
    return self:_newEntry("file", name, parent_ref, options)
end

function FakeProvider:findEntries(criteria)
    local matches = {}

    for _, entry in pairs(self.entries) do
        local include = true

        if criteria.kind and entry.kind ~= criteria.kind then
            include = false
        end

        for key, value in pairs(criteria.metadata or {}) do
            if (entry.metadata or {})[key] ~= value then
                include = false
            end
        end

        if include then
            table.insert(matches, entry)
        end
    end

    return matches, nil
end

function FakeProvider:listChildren(parent_ref, _options)
    local parent_key = self:_parentKey(parent_ref)
    local result = {}

    for _, child_id in ipairs(self.children[parent_key] or {}) do
        table.insert(result, self.entries[child_id])
    end

    table.sort(result, function(left, right)
        return left.name < right.name
    end)

    return result, nil
end

function FakeProvider:getEntry(ref, _options)
    return self.entries[ref.id], nil
end

function FakeProvider:createFolder(parent_ref, name, options)
    table.insert(self.calls, {
        method = "createFolder",
        parent_ref = parent_ref,
        name = name,
        options = options,
    })

    return self:addFolder(
        parent_ref,
        name,
        options and options.metadata or nil
    ), nil
end

function FakeProvider:uploadFile(
    parent_ref,
    local_path,
    remote_name,
    options
)
    table.insert(self.calls, {
        method = "uploadFile",
        parent_ref = parent_ref,
        local_path = local_path,
        remote_name = remote_name,
        options = options,
    })

    local content = readFile(local_path)

    return self:addFile(parent_ref, remote_name, {
        content = content,
        size = content and #content or 0,
        mime_type = options and options.mime_type or nil,
        metadata = options and options.metadata or nil,
    }), nil
end

function FakeProvider:downloadFile(file_ref, local_path, _options)
    local entry = self.entries[file_ref.id]

    if not entry then
        return false, "Not found"
    end

    writeFile(local_path, entry.content or "")
    return true, nil
end

function FakeProvider:deleteEntry(entry_ref, _options)
    local entry = self.entries[entry_ref.id]

    if not entry then
        return false, "Not found"
    end

    entry.deleted = true
    return true, nil
end

return FakeProvider
