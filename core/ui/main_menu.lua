local BooksBrowser = require("core/books_browser")
local NetworkMgr = require("ui/network/manager")
local UIManager = require("ui/uimanager")
local _ = require("gettext")

--- Provider-agnostic KOCloud main-menu composition.
---@class KOCloudMainMenu
---@field config KOCloudConfig
---@field provider KOCloudBaseProvider
---@field layout KOCloudStorageLayoutService
---@field library KOCloudLibraryService
---@field provider_setup table Provider-specific setup UI controller.
local MainMenu = {}
MainMenu.__index = MainMenu

--- Create KOCloud menu orchestration.
---@param args table
---@return KOCloudMainMenu
function MainMenu:new(args)
    return setmetatable({
        config = assert(args.config),
        provider = assert(args.provider),
        layout = assert(args.layout),
        library = assert(args.library),
        provider_setup = assert(args.provider_setup),
    }, self)
end

--- Return Library feature menu items.
---@return table
function MainMenu:getLibraryMenuItems()
    local ready = self.provider:isConfigured()
        and self.layout:isInitialized()

    local items = {
        {
            text = _("My Books"),
            enabled = ready,
            keep_menu_open = true,
            callback = function()
                NetworkMgr:runWhenOnline(function()
                    self:showBooks()
                end)
            end,
        },
    }

    if not ready then
        table.insert(items, {
            text = _(
                "Configure a cloud provider and initialize its storage "
                    .. "to use the library."
            ),
            enabled = false,
            separator = true,
        })
    end

    return items
end

--- Return configured/available cloud provider menu items.
---@return table
function MainMenu:getCloudProvidersMenuItems()
    return {
        {
            text_func = function()
                return string.format(
                    _("%s: %s"),
                    self.provider:getName(),
                    self.provider_setup:getAuthStatusText()
                )
            end,
            sub_item_table_func = function()
                return self.provider_setup:getMenuItems()
            end,
        },
    }
end

--- Return KOCloud settings and status menu items.
---@return table
function MainMenu:getSettingsAndStatusMenuItems()
    return {
        {
            text = _("Status"),
            keep_menu_open = true,
            callback = function()
                self.provider_setup:showStatus(self.config)
            end,
        },
    }
end

--- Return the provider-agnostic KOCloud root submenu.
---@return table
function MainMenu:getSubMenuItems()
    return {
        {
            text = _("Library"),
            sub_item_table_func = function()
                return self:getLibraryMenuItems()
            end,
        },
        {
            text = _("Cloud providers"),
            sub_item_table_func = function()
                return self:getCloudProvidersMenuItems()
            end,
        },
        {
            text = _("Settings & status"),
            sub_item_table_func = function()
                return self:getSettingsAndStatusMenuItems()
            end,
        },
    }
end

--- Show the remote KOCloud library browser.
function MainMenu:showBooks()
    UIManager:show(BooksBrowser:new{
        library = self.library,
    })
end

--- Register KOCloud in KOReader's main menu.
---@param menu_items table
function MainMenu:addToMainMenu(menu_items)
    menu_items.kocloud = {
        text = _("KOCloud"),
        sorting_hint = "tools",
        sub_item_table_func = function()
            return self:getSubMenuItems()
        end,
    }
end

return MainMenu
