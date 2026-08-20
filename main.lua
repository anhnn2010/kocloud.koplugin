local ButtonDialog = require("ui/widget/buttondialog")
local Config = require("core/config")
local Device = require("device")
local GoogleDriveProvider = require("providers/google_drive/provider")
local InfoMessage = require("ui/widget/infomessage")
local NetworkMgr = require("ui/network/manager")
local QRMessage = require("ui/widget/qrmessage")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local _ = require("gettext")

local EXPECTED_MANAGED_FOLDER_COUNT = 4

--- Main KOCloud plugin container.
---@class KOCloudPlugin: WidgetContainer
---@field config KOCloudConfig
---@field provider KOCloudGoogleDriveProvider
---@field device_auth_session? KOCloudGoogleDriveDeviceSession
---@field device_auth_dialog? ButtonDialog
---@field device_auth_poll_task? function
---@field device_auth_menu? table
local KOCloud = WidgetContainer:extend{
    name = "kocloud",
    is_doc_only = false,
}

--- Initialize KOCloud, load configuration, create the active provider,
--- and register the plugin in the KOReader main menu.
function KOCloud:init()
    self.config = Config:new()
    self.config:ensureDefaults()

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

--- Return a human-readable connection status for the active provider.
---@return string
function KOCloud:getAuthStatusText()
    if self.provider:isConfigured() then
        return _("Connected")
    end

    return _("Not connected")
end

--- Return the number of cached managed KOCloud folders.
---@return integer
function KOCloud:getManagedFolderCount()
    local folders = self.provider.config.folders

    if type(folders) ~= "table" then
        return 0
    end

    local count = 0
    for _, folder_id in pairs(folders) do
        if type(folder_id) == "string" and folder_id ~= "" then
            count = count + 1
        end
    end

    return count
end

--- Return whether the complete KOCloud storage layout is initialized.
---@return boolean
function KOCloud:isStorageInitialized()
    return type(self.provider.config.root_folder_id) == "string"
        and self.provider.config.root_folder_id ~= ""
        and self:getManagedFolderCount() == EXPECTED_MANAGED_FOLDER_COUNT
end

--- Return a human-readable KOCloud storage status.
---@return string
function KOCloud:getStorageStatusText()
    if self:isStorageInitialized() then
        return _("Initialized")
    end

    return _("Not initialized")
end

--- Return the KOCloud submenu items.
---@return table
function KOCloud:getSubMenuItems()
    local items = {
        {
            text_func = function()
                return string.format(
                    _("Google Drive: %s"),
                    self:getAuthStatusText()
                )
            end,
            enabled = false,
        },
    }

    if not self.provider:isConfigured() then
        table.insert(items, {
            text = _("Connect Google Drive"),
            callback = function(touchmenu_instance)
                NetworkMgr:runWhenOnline(function()
                    self:startGoogleDriveAuthorization(
                        touchmenu_instance
                    )
                end)
            end,
        })
    else
        table.insert(items, {
            text_func = function()
                if self:isStorageInitialized() then
                    return _("Verify storage")
                end

                return _("Initialize storage")
            end,
            callback = function(touchmenu_instance)
                NetworkMgr:runWhenOnline(function()
                    self:initializeGoogleDriveStorage(
                        touchmenu_instance
                    )
                end)
            end,
        })
    end

    table.insert(items, {
        text = _("Status"),
        callback = function()
            self:showStatus()
        end,
    })

    return items
end

--- Show KOCloud provider, OAuth, and storage status information.
function KOCloud:showStatus()
    local client_status = self.provider:isClientConfigured()
            and _("Configured")
        or _("Not configured")

    local root_folder_id = self.provider.config.root_folder_id
        or _("Not available")

    UIManager:show(InfoMessage:new{
        text = string.format(
            _(
                "Provider: %s\n"
                    .. "Type: %s\n"
                    .. "Connection: %s\n"
                    .. "OAuth app: %s\n"
                    .. "Storage: %s\n"
                    .. "Managed folders: %d/%d\n"
                    .. "Root folder ID: %s\n"
                    .. "Settings: %s"
            ),
            self.provider:getName(),
            self.provider:getType(),
            self:getAuthStatusText(),
            client_status,
            self:getStorageStatusText(),
            self:getManagedFolderCount(),
            EXPECTED_MANAGED_FOLDER_COUNT,
            root_folder_id,
            self.config:getSettingsFile()
        ),
    })
end

--- Find or create the complete KOCloud Google Drive storage layout.
---@param touchmenu_instance? table
function KOCloud:initializeGoogleDriveStorage(touchmenu_instance)
    if not self.provider:isConfigured() then
        UIManager:show(InfoMessage:new{
            text = _("Connect Google Drive first."),
            timeout = 3,
        })
        return
    end

    local folders, created_count, err =
        self.provider:ensureStorageLayout()

    if not folders then
        UIManager:show(InfoMessage:new{
            text = string.format(
                _("Cannot initialize KOCloud storage:\n\n%s"),
                err or _("Unknown error")
            ),
        })
        return
    end

    self.config:setProviderConfig(
        self.provider:getType(),
        self.provider.config
    )
    self.config:flush()

    local message

    if created_count > 0 then
        message = string.format(
            _(
                "KOCloud storage initialized successfully.\n\n"
                    .. "Created %d folder(s).\n"
                    .. "Root: %s"
            ),
            created_count,
            folders.root.name
        )
    else
        message = string.format(
            _(
                "KOCloud storage verified successfully.\n\n"
                    .. "All managed folders are available.\n"
                    .. "Root: %s"
            ),
            folders.root.name
        )
    end

    UIManager:show(InfoMessage:new{
        text = message,
        timeout = 4,
    })

    if touchmenu_instance and touchmenu_instance.updateItems then
        touchmenu_instance:updateItems()
    end
end

--- Start Google Drive Device Authorization Flow.
---@param touchmenu_instance? table
function KOCloud:startGoogleDriveAuthorization(touchmenu_instance)
    if self.provider:isConfigured() then
        UIManager:show(InfoMessage:new{
            text = _("Google Drive is already connected."),
            timeout = 3,
        })
        return
    end

    local session, err = self.provider:requestDeviceAuthorization()

    if not session then
        UIManager:show(InfoMessage:new{
            text = string.format(
                _("Cannot start Google Drive authorization:\n\n%s"),
                err or _("Unknown error")
            ),
        })
        return
    end

    self:cancelGoogleDriveAuthorization()

    self.device_auth_session = session
    self.device_auth_menu = touchmenu_instance

    local dialog

    dialog = ButtonDialog:new{
        title = string.format(
            _(
                "Connect Google Drive\n\n"
                    .. "Open on your phone or computer:\n"
                    .. "%s\n\n"
                    .. "Enter this code:\n"
                    .. "%s\n\n"
                    .. "Waiting for authorization…"
            ),
            session.verification_url,
            session.user_code
        ),
        title_align = "center",
        buttons = {
            {
                {
                    text = _("Show QR code"),
                    callback = function()
                        UIManager:show(QRMessage:new{
                            text = session.verification_url,
                            width = Device.screen:getWidth(),
                            height = Device.screen:getHeight(),
                        })
                    end,
                },
            },
            {
                {
                    text = _("Cancel"),
                    callback = function()
                        self:cancelGoogleDriveAuthorization()
                    end,
                },
            },
        },
    }

    dialog.onCloseWidget = function(this)
        local super = getmetatable(this)
        if super.onCloseWidget then
            super.onCloseWidget(this)
        end

        if self.device_auth_dialog == this then
            self:clearGoogleDriveAuthorizationSession()
        end
    end

    self.device_auth_dialog = dialog
    UIManager:show(dialog)

    self.device_auth_poll_task = function()
        self:pollGoogleDriveAuthorization()
    end

    UIManager:scheduleIn(
        session.interval,
        self.device_auth_poll_task
    )
end

--- Poll Google once for the current device authorization session.
function KOCloud:pollGoogleDriveAuthorization()
    local session = self.device_auth_session

    if not session then
        return
    end

    local result = self.provider:pollDeviceAuthorization(session)

    if result.status == "authorized" then
        self.config:setProviderConfig(
            self.provider:getType(),
            self.provider.config
        )
        self.config:flush()

        local menu = self.device_auth_menu
        self:finishGoogleDriveAuthorizationDialog()

        UIManager:show(InfoMessage:new{
            text = _("Google Drive connected successfully."),
            timeout = 3,
        })

        if menu and menu.updateItems then
            menu:updateItems()
        end
        return
    end

    if result.status == "pending"
        or result.status == "slow_down"
        or (result.status == "error" and result.retry_after)
    then
        local retry_after = result.retry_after or session.interval
        UIManager:scheduleIn(
            retry_after,
            self.device_auth_poll_task
        )
        return
    end

    local message

    if result.status == "denied" then
        message = _("Google Drive authorization was denied.")
    elseif result.status == "expired" then
        message = _("Google Drive authorization code expired.")
    else
        message = result.error_message
            or _("Google Drive authorization failed.")
    end

    self:finishGoogleDriveAuthorizationDialog()

    UIManager:show(InfoMessage:new{
        text = message,
    })
end

--- Close the authorization dialog and stop its polling task.
function KOCloud:finishGoogleDriveAuthorizationDialog()
    local dialog = self.device_auth_dialog

    self.device_auth_dialog = nil
    self:clearGoogleDriveAuthorizationSession()

    if dialog then
        UIManager:close(dialog)
    end
end

--- Clear the current device authorization session and scheduled polling.
function KOCloud:clearGoogleDriveAuthorizationSession()
    if self.device_auth_poll_task then
        UIManager:unschedule(self.device_auth_poll_task)
    end

    self.device_auth_session = nil
    self.device_auth_poll_task = nil
    self.device_auth_menu = nil
end

--- Cancel the current Google Drive authorization attempt.
function KOCloud:cancelGoogleDriveAuthorization()
    local dialog = self.device_auth_dialog

    self.device_auth_dialog = nil
    self:clearGoogleDriveAuthorizationSession()

    if dialog then
        UIManager:close(dialog)
    end
end

--- Add KOCloud to the KOReader main menu.
---@param menu_items table
function KOCloud:addToMainMenu(menu_items)
    menu_items.kocloud = {
        text = _("KOCloud"),
        sorting_hint = "more_tools",
        sub_item_table_func = function()
            return self:getSubMenuItems()
        end,
    }
end

return KOCloud
