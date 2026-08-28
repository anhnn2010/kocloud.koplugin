# Testing

KOCloud keeps UI/device testing on real KOReader hardware, while pure domain
and storage logic is covered by small Lua tests.

## Local unit tests

Run from the plugin repository root with LuaJIT:

```sh
luajit tests/run.lua
```

The suite covers:

- KOCloud Storage Protocol v1
- supported book formats
- reusable storage-provider contract behavior
- LibraryService behavior with an in-memory provider
- StorageLayoutService creation, manifest handling, and legacy-cache migration

The tests intentionally avoid KOReader UI mocks. Browser/menu interactions are
still validated on a real device.

## Provider contract

`tests/support/provider_contract.lua` is reusable. A future provider such as
WebDAV should create a provider instance and register the same contract suite.
Provider-specific tests can then cover extra capabilities separately.

## CI

`.github/workflows/test.yml` compiles every Lua file with LuaJIT and runs the
unit/contract suite on every push and pull request.
