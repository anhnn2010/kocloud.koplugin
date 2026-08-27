--- Shared KOCloud storage protocol constants.
---
--- Keep provider-neutral KOCloud concepts here. Storage providers may use
--- these values to persist optional provider-specific metadata, but providers
--- must not own the storage layout itself.
local Protocol = {}

Protocol.SCHEMA_VERSION = "1"

Protocol.METADATA_KEYS = {
    role = "kocloud_role",
    schema = "kocloud_schema",
    internal = "kocloud_internal",
}

Protocol.ROLES = {
    root = "root",
    books = "books",
    backups = "backups",
    reading_data = "reading_data",
    metadata = "metadata",
    book = "book",
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

return Protocol
