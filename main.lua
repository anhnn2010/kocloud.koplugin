local Config = require("core/config")
local GoogleDriveProvider = require("providers/google_drive/provider")
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local _ = require("gettext")

--- Main KOCloud plugin container.
---@class KOCloudPlugin: WidgetContainer
---@field config KOCloudConfig
---@field provider KOCloudGoogleDriveProvider
local KOCloud = WidgetContainer:extend{
    name = "kocloud",
    is_doc_only = false,
}

--- Initialize KOCloud, load configuration, create the active provider,
--- and register the plugin in the KOReader main menu.
function KOCloud:init()
    self.config = Config:new()

    local provider_type = self.config:getActiveProvider()
    local provider_config = self.config:getProviderConfig(provider_type)

    if provider_type == "google_drive" then
        self.provider = GoogleDriveProvider:new(provider_config)
    else
        error(string.format(
            "Unsupported KOCloud provider: %s",
            provider_type
        ))
    end

    self.ui.menu:registerToMainMenu(self)
end

--- Add KOCloud to the KOReader main menu.
---@param menu_items table
function KOCloud:addToMainMenu(menu_items)
    menu_items.kocloud = {
        text = _("KOCloud"),
        sorting_hint = "more_tools",
        callback = function()
            UIManager:show(InfoMessage:new{
                text = string.format(
                    _(
                        "Provider: %s\n"
                            .. "Type: %s\n"
                            .. "Settings: %s"
                    ),
                    self.provider:getName(),
                    self.provider:getType(),
                    self.config:getSettingsFile()
                ),
            })
        end,
    }
end

return KOCloud
