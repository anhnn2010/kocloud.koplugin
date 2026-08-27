local Config = require("core/config")
local GoogleDriveSetup = require("core/ui/google_drive_setup")
local LibraryService = require("core/services/library")
local MainMenu = require("core/ui/main_menu")
local ProviderFactory = require("providers/factory")
local ProviderState = require("core/provider_state")
local StorageLayoutService = require("core/services/storage_layout")
local WidgetContainer = require("ui/widget/container/widgetcontainer")

--- Main KOCloud composition root.
---
--- Runtime behavior lives in services, storage providers, and UI controllers.
--- This container wires those components together and delegates KOReader
--- lifecycle/menu integration.
---@class KOCloudPlugin: WidgetContainer
---@field config KOCloudConfig
---@field provider KOCloudBaseProvider
---@field provider_state KOCloudProviderState
---@field layout KOCloudStorageLayoutService
---@field library KOCloudLibraryService
---@field provider_setup table Provider-specific setup UI controller.
---@field main_menu KOCloudMainMenu
local KOCloud = WidgetContainer:extend{
    name = "kocloud",
    is_doc_only = false,
}

--- Create the setup UI controller for the active provider.
---@param provider_type string
---@return table
function KOCloud:createProviderSetup(provider_type)
    if provider_type == "google_drive" then
        return GoogleDriveSetup:new(
            self.provider,
            self.layout,
            self.provider_state
        )
    end

    error(string.format(
        "Unsupported KOCloud provider setup UI: %s",
        tostring(provider_type)
    ))
end

--- Initialize KOCloud and compose its runtime dependencies.
function KOCloud:init()
    self.config = Config:new()
    self.config:ensureDefaults()

    local provider_type = self.config:getActiveProvider()
    local provider_config = self.config:getProviderConfig(provider_type)

    self.provider = ProviderFactory.create(
        provider_type,
        provider_config
    )
    self.layout = StorageLayoutService:new(self.provider)
    self.library = LibraryService:new(self.provider, self.layout)
    self.provider_state = ProviderState:new(
        self.config,
        self.provider,
        self.layout
    )

    -- Persist one-time migration/cleanup of long-lived provider state.
    self.provider_state:saveIfDirty()

    self.provider_setup = self:createProviderSetup(provider_type)
    self.main_menu = MainMenu:new{
        config = self.config,
        provider = self.provider,
        layout = self.layout,
        library = self.library,
        provider_setup = self.provider_setup,
    }

    self.ui.menu:registerToMainMenu(self)
end

--- Stop temporary local setup services before KOReader exits.
function KOCloud:onExit()
    self.provider_setup:stopTemporaryServices()
end

--- Stop temporary local setup services when this plugin instance closes.
function KOCloud:onCloseWidget()
    self.provider_setup:stopTemporaryServices()
end

--- Do not leave a temporary credential server listening during suspend.
function KOCloud:onSuspend()
    self.provider_setup:stopTemporaryServices()
end

--- Add KOCloud to the KOReader main menu.
---@param menu_items table
function KOCloud:addToMainMenu(menu_items)
    self.main_menu:addToMainMenu(menu_items)
end

return KOCloud
