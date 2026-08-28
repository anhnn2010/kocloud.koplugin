--- KOCloud Storage Protocol v1.
---
--- This module contains provider-neutral constants shared conceptually by the
--- KOReader plugin and KOCloud Companion. Provider-specific metadata may use
--- these values as an optimization, but the portable storage contract is the
--- KOCloud directory layout plus `.kocloud/manifest.json`.
local Protocol = {}

Protocol.FORMAT = "kocloud-storage"
Protocol.VERSION = 1
Protocol.SCHEMA_VERSION = tostring(Protocol.VERSION)

Protocol.MANIFEST = {
    filename = "manifest.json",
    mime_type = "application/json",
}

Protocol.METADATA_KEYS = {
    role = "kocloud_role",
    schema = "kocloud_schema",
    internal = "kocloud_internal",
    source = "kocloud_source",
}

Protocol.ROLES = {
    root = "root",
    books = "books",
    backups = "backups",
    reading_data = "reading_data",
    metadata = "metadata",
    manifest = "manifest",
    book = "book",
    book_folder = "book_folder",
}

Protocol.SOURCES = {
    koreader = "koreader",
    web_companion = "web_companion",
    drive_import = "drive_import",
    manual_drive = "manual_drive",
}

Protocol.ROOT_FOLDER = {
    key = "root",
    name = "KOCloud",
    role = Protocol.ROLES.root,
}

Protocol.MANAGED_FOLDERS = {
    {
        key = "books",
        name = "Books",
        role = Protocol.ROLES.books,
    },
    {
        key = "backups",
        name = "Backups",
        role = Protocol.ROLES.backups,
    },
    {
        key = "reading_data",
        name = "ReadingData",
        role = Protocol.ROLES.reading_data,
    },
    {
        key = "metadata",
        name = ".kocloud",
        role = Protocol.ROLES.metadata,
        internal = true,
    },
}

--- Return one managed-folder definition by logical key.
---@param key string
---@return table|nil definition
function Protocol.getManagedFolder(key)
    for _, definition in ipairs(Protocol.MANAGED_FOLDERS) do
        if definition.key == key then
            return definition
        end
    end

    return nil
end

--- Return the portable path to one managed folder below KOCloud root.
---@param key string
---@return string|nil path
function Protocol.getManagedPath(key)
    local definition = Protocol.getManagedFolder(key)

    if not definition then
        return nil
    end

    return Protocol.ROOT_FOLDER.name .. "/" .. definition.name
end

--- Return the portable path to the protocol manifest.
---@return string
function Protocol.getManifestPath()
    local metadata_path = Protocol.getManagedPath("metadata")
    return metadata_path .. "/" .. Protocol.MANIFEST.filename
end

--- Escape one controlled string for JSON output.
---@param value string
---@return string
local function jsonString(value)
    local escaped = value
        :gsub("\\", "\\\\")
        :gsub('"', '\\"')
        :gsub("\n", "\\n")
        :gsub("\r", "\\r")
        :gsub("\t", "\\t")

    return '"' .. escaped .. '"'
end

--- Build the portable KOCloud Storage Protocol v1 manifest.
---
--- The manifest intentionally contains logical names only. Provider refs/IDs
--- are local adapter details and must never leak into the portable protocol.
---@return table manifest
function Protocol.buildManifest()
    local layout = {
        root = Protocol.ROOT_FOLDER.name,
    }

    for _, definition in ipairs(Protocol.MANAGED_FOLDERS) do
        layout[definition.key] = definition.name
    end

    return {
        format = Protocol.FORMAT,
        schema_version = Protocol.VERSION,
        layout = layout,
    }
end

--- Return whether a decoded manifest matches KOCloud Storage Protocol v1.
---@param manifest table
---@return boolean
function Protocol.isManifestV1(manifest)
    if type(manifest) ~= "table"
        or manifest.format ~= Protocol.FORMAT
        or manifest.schema_version ~= Protocol.VERSION
        or type(manifest.layout) ~= "table"
    then
        return false
    end

    local expected = Protocol.buildManifest().layout

    for key, value in pairs(expected) do
        if manifest.layout[key] ~= value then
            return false
        end
    end

    return true
end

--- Serialize the current protocol manifest as deterministic JSON.
---
--- Keeping this tiny encoder local avoids introducing a JSON runtime
--- dependency solely for a manifest whose values are controlled constants.
---@return string json
function Protocol.buildManifestJson()
    local manifest = Protocol.buildManifest()
    local layout = manifest.layout

    return table.concat({
        "{\n",
        "  \"format\": ", jsonString(manifest.format), ",\n",
        "  \"schema_version\": ", tostring(manifest.schema_version), ",\n",
        "  \"layout\": {\n",
        "    \"root\": ", jsonString(layout.root), ",\n",
        "    \"books\": ", jsonString(layout.books), ",\n",
        "    \"backups\": ", jsonString(layout.backups), ",\n",
        "    \"reading_data\": ", jsonString(layout.reading_data), ",\n",
        "    \"metadata\": ", jsonString(layout.metadata), "\n",
        "  }\n",
        "}\n",
    })
end

return Protocol
