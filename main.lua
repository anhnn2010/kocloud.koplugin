local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local _ = require("gettext")

local KOCloud = WidgetContainer:extend{
    name = "kocloud",
    is_doc_only = false,
}

function KOCloud:init()
    self.ui.menu:registerToMainMenu(self)
end

function KOCloud:addToMainMenu(menu_items)
    menu_items.kocloud = {
        text = _("KOCloud"),
        sorting_hint = "more_tools",
        callback = function()
            UIManager:show(InfoMessage:new{
                text = _("KOCloud plugin loaded successfully."),
            })
        end,
    }
end

return KOCloud
