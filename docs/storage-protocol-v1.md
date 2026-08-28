# KOCloud Storage Protocol v1

KOCloud separates the portable storage contract from provider-specific
optimizations.

## Portable layout

```text
KOCloud/
├── Books/
├── Backups/
├── ReadingData/
└── .kocloud/
    └── manifest.json
```

`KOCloud/.kocloud/manifest.json` is the portable marker for a KOCloud storage
root. Provider IDs, paths, account IDs, OAuth data, and device secrets must
never be stored in this manifest.

Protocol v1 manifest:

```json
{
  "format": "kocloud-storage",
  "schema_version": 1,
  "layout": {
    "root": "KOCloud",
    "books": "Books",
    "backups": "Backups",
    "reading_data": "ReadingData",
    "metadata": ".kocloud"
  }
}
```

## Provider metadata

Providers may store metadata for faster discovery. Google Drive uses private
`appProperties`:

- `kocloud_role`
- `kocloud_schema`
- `kocloud_internal`
- `kocloud_source`

These properties are an optimization, not the portable protocol. A provider
such as WebDAV can implement KOCloud using only the portable layout and
manifest.

## Roles

Protocol v1 defines these roles:

- `root`
- `books`
- `backups`
- `reading_data`
- `metadata`
- `manifest`
- `book`
- `book_folder`

## Compatibility rule

A client must not silently rewrite a manifest with an unknown schema version.
Future protocol versions must use an explicit migration path.
