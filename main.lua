local GoogleDriveProvider = require("providers/google_drive/provider")
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local _ = require("gettext")

--- Main KOCloud plugin container.
---@class KOCloudPlugin: WidgetContainer
---@field provider KOCloudGoogleDriveProvider
local KOCloud = WidgetContainer:extend{
    name = "kocloud",
    is_doc_only = false,
}

--- Initialize KOCloud and register it in the KOReader main menu.
function KOCloud:init()
    self.provider = GoogleDriveProvider:new()
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
                    _("Provider: %s\nType: %s"),
                    self.provider:getName(),
                    self.provider:getType()
                ),
            })
        end,
    }
end

return KOCloud
