local ButtonDialog = require("ui/widget/buttondialog")
local ConfirmBox = require("ui/widget/confirmbox")
local Device = require("device")
local filemanagerutil = require("apps/filemanager/filemanagerutil")
local InfoMessage = require("ui/widget/infomessage")
local NetworkMgr = require("ui/network/manager")
local OAuthSetupDialog = require("core/oauth_setup_dialog")
local OAuthSetupServer = require("core/oauth_setup_server")
local QRMessage = require("ui/widget/qrmessage")
local UIManager = require("ui/uimanager")
local _ = require("gettext")

--- Google Drive account/setup UI controller.
---
--- This module owns provider-specific setup UI and temporary OAuth sessions.
--- It intentionally talks to the Google Drive provider interface, while the
--- rest of KOCloud UI can stay provider-agnostic.
---@class KOCloudGoogleDriveSetupUI
---@field provider KOCloudGoogleDriveProvider
---@field layout KOCloudStorageLayoutService
---@field provider_state KOCloudProviderState
---@field device_auth_session? KOCloudGoogleDriveDeviceSession
---@field device_auth_dialog? ButtonDialog
---@field device_auth_poll_task? function
---@field device_auth_menu? table
---@field oauth_setup_server? KOCloudOAuthSetupServer
---@field oauth_setup_qr? table
local GoogleDriveSetup = {}
GoogleDriveSetup.__index = GoogleDriveSetup

--- Return whether a local file can contain Google OAuth credentials.
---@param filename string
---@return boolean
local function isOAuthCredentialsJsonFile(filename)
    return filename:lower():match("%.json$") ~= nil
end

--- Create Google Drive setup UI orchestration.
---@param provider KOCloudGoogleDriveProvider
---@param layout KOCloudStorageLayoutService
---@param provider_state KOCloudProviderState
---@return KOCloudGoogleDriveSetupUI
function GoogleDriveSetup:new(provider, layout, provider_state)
    return setmetatable({
        provider = provider,
        layout = layout,
        provider_state = provider_state,
    }, self)
end

--- Return a human-readable connection state.
---@return string
function GoogleDriveSetup:getAuthStatusText()
    if self.provider:isConfigured() then
        return _("Connected")
    end

    return _("Not connected")
end

--- Return whether complete KOCloud storage is initialized.
---@return boolean
function GoogleDriveSetup:isStorageInitialized()
    return self.layout:isInitialized()
end

--- Return a human-readable KOCloud storage state.
---@return string
function GoogleDriveSetup:getStorageStatusText()
    if self:isStorageInitialized() then
        return _("Initialized")
    end

    return _("Not initialized")
end

--- Return provider-specific Google Drive submenu items.
---@return table
function GoogleDriveSetup:getMenuItems()
    return {
        {
            text_func = function()
                return string.format(
                    _("Connection: %s"),
                    self:getAuthStatusText()
                )
            end,
            enabled = false,
        },
        {
            text_func = function()
                local status = self.provider:isClientConfigured()
                        and _("Configured")
                    or _("Not configured")

                return string.format(
                    _("OAuth credentials: %s"),
                    status
                )
            end,
            enabled = false,
        },
        {
            text_func = function()
                return string.format(
                    _("Storage: %s"),
                    self:getStorageStatusText()
                )
            end,
            enabled = false,
        },
        {
            text = _("Configure OAuth credentials"),
            sub_item_table_func = function()
                return self:getOAuthCredentialsMenuItems()
            end,
        },
        {
            text_func = function()
                if self.provider:isConfigured() then
                    return _("Disconnect Google Drive")
                end

                return _("Connect Google Drive")
            end,
            enabled_func = function()
                return self.provider:isClientConfigured()
            end,
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                if self.provider:isConfigured() then
                    self:confirmDisconnect(touchmenu_instance)
                    return
                end

                NetworkMgr:runWhenOnline(function()
                    self:startAuthorization(touchmenu_instance)
                end)
            end,
        },
        {
            text_func = function()
                if self:isStorageInitialized() then
                    return _("Verify provider storage")
                end

                return _("Initialize provider storage")
            end,
            enabled_func = function()
                return self.provider:isConfigured()
            end,
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                NetworkMgr:runWhenOnline(function()
                    self:initializeStorage(touchmenu_instance)
                end)
            end,
        },
        {
            text = _("Remove OAuth credentials"),
            enabled_func = function()
                return self.provider:isClientConfigured()
            end,
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                self:confirmRemoveOAuthCredentials(
                    touchmenu_instance
                )
            end,
        },
        {
            text = _("Setup help"),
            keep_menu_open = true,
            callback = function()
                self:showSetupHelp()
            end,
        },
    }
end

--- Return OAuth credential import/setup submenu items.
---@return table
function GoogleDriveSetup:getOAuthCredentialsMenuItems()
    return {
        {
            text_func = function()
                if self.oauth_setup_server
                    and self.oauth_setup_server:isRunning()
                then
                    return _("From browser: Show QR code")
                end

                return _("From browser (phone or computer)")
            end,
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                if self.oauth_setup_server
                    and self.oauth_setup_server:isRunning()
                then
                    self:showPhoneOAuthSetupQR()
                    return
                end

                NetworkMgr:runWhenOnline(function()
                    self:startPhoneOAuthSetup(touchmenu_instance)
                end)
            end,
        },
        {
            text = _("From KOReader storage (JSON file)"),
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                self:chooseOAuthCredentialsFile(
                    touchmenu_instance
                )
            end,
        },
    }
end

--- Start a temporary LAN web page for entering OAuth credentials by phone.
---@param touchmenu_instance? table
function GoogleDriveSetup:startPhoneOAuthSetup(touchmenu_instance)
    self:stopTemporaryServices()

    local server

    server = OAuthSetupServer:new{
        on_save = function(client_id, client_secret)
            local credentials, changed, save_error =
                self.provider:setOAuthCredentials(
                    client_id,
                    client_secret
                )

            if not credentials then
                return false, save_error
            end

            if changed then
                self.layout:clearCache()
                self.provider_state:save()
            end

            return true, nil
        end,
        on_saved = function()
            self.oauth_setup_server = nil
            self:closeOAuthSetupQR()
            self:updateMenu(touchmenu_instance)

            UIManager:show(InfoMessage:new{
                text = _(
                    "Google OAuth credentials saved.\n\n"
                        .. "You can now choose Connect Google Drive."
                ),
                timeout = 5,
            })
        end,
        on_timeout = function()
            self.oauth_setup_server = nil
            self:closeOAuthSetupQR()
            self:updateMenu(touchmenu_instance)

            UIManager:show(InfoMessage:new{
                text = _("Phone OAuth setup expired."),
                timeout = 3,
            })
        end,
    }

    local success, start_error = server:start()

    if not success then
        UIManager:show(InfoMessage:new{
            text = string.format(
                _("Cannot start phone OAuth setup:\n\n%s"),
                start_error or _("Unknown error")
            ),
        })
        return
    end

    local setup_url = server:getSetupURL()

    if not setup_url then
        server:stop()

        UIManager:show(InfoMessage:new{
            text = _(
                "Cannot determine this KOReader device's "
                    .. "Wi-Fi IP address."
            ),
        })
        return
    end

    self.oauth_setup_server = server
    self:updateMenu(touchmenu_instance)

    UIManager:nextTick(function()
        if self.oauth_setup_server == server
            and server:isRunning()
        then
            self:showPhoneOAuthSetupQR()
        end
    end)
end

--- Close the phone OAuth setup QR dialog if it is visible.
function GoogleDriveSetup:closeOAuthSetupQR()
    if not self.oauth_setup_qr then
        return
    end

    local qr = self.oauth_setup_qr
    self.oauth_setup_qr = nil
    UIManager:close(qr)
end

--- Show a compact QR + URL dialog for the current phone setup session.
function GoogleDriveSetup:showPhoneOAuthSetupQR()
    local server = self.oauth_setup_server

    if not server or not server:isRunning() then
        UIManager:show(InfoMessage:new{
            text = _("Phone OAuth setup is not running."),
            timeout = 3,
        })
        return
    end

    local setup_url = server:getSetupURL()

    if not setup_url then
        UIManager:show(InfoMessage:new{
            text = _(
                "Cannot determine this KOReader device's "
                    .. "Wi-Fi IP address."
            ),
        })
        return
    end

    self:closeOAuthSetupQR()

    local dialog

    dialog = OAuthSetupDialog:new{
        setup_url = setup_url,
        close_callback = function()
            if self.oauth_setup_qr == dialog then
                self.oauth_setup_qr = nil
            end
        end,
    }

    self.oauth_setup_qr = dialog
    UIManager:show(dialog)
end

--- Stop temporary provider setup services and dialogs.
function GoogleDriveSetup:stopTemporaryServices()
    self:closeOAuthSetupQR()

    if self.oauth_setup_server then
        self.oauth_setup_server:stop()
        self.oauth_setup_server = nil
    end
end

--- Open KOReader's file chooser for Google's downloaded OAuth JSON file.
---@param touchmenu_instance? table
function GoogleDriveSetup:chooseOAuthCredentialsFile(touchmenu_instance)
    filemanagerutil.showChooseDialog(
        _("Choose OAuth JSON from KOReader storage"),
        function(json_path)
            self:importOAuthCredentials(
                json_path,
                touchmenu_instance
            )
        end,
        nil,
        filemanagerutil.getHomeFolder(),
        isOAuthCredentialsJsonFile
    )
end

--- Import and persist Google OAuth application credentials.
---@param json_path string
---@param touchmenu_instance? table
function GoogleDriveSetup:importOAuthCredentials(
    json_path,
    touchmenu_instance
)
    local credentials, changed, import_error =
        self.provider:importOAuthCredentials(json_path)

    if not credentials then
        UIManager:show(InfoMessage:new{
            text = string.format(
                _("Cannot import OAuth credentials:\n\n%s"),
                import_error or _("Unknown error")
            ),
        })
        return
    end

    if changed then
        self.layout:clearCache()
        self.provider_state:save()
    end

    local message = _(
        "Google OAuth credentials imported successfully."
    )

    if changed and not self.provider:isConfigured() then
        message = message
            .. "\n\n"
            .. _("You can now connect Google Drive.")
    end

    UIManager:show(InfoMessage:new{
        text = message,
        timeout = 4,
    })

    self:updateMenu(touchmenu_instance)
end

--- Confirm disconnecting the currently authorized Google Drive account.
---@param touchmenu_instance? table
function GoogleDriveSetup:confirmDisconnect(touchmenu_instance)
    UIManager:show(ConfirmBox:new{
        text = _(
            "Disconnect Google Drive on this device?\n\n"
                .. "Your files in Google Drive will not be deleted."
        ),
        ok_text = _("Disconnect"),
        ok_callback = function()
            self.provider:disconnect()
            self.layout:clearCache()
            self.provider_state:save()
            self:updateMenu(touchmenu_instance)

            UIManager:show(InfoMessage:new{
                text = _("Google Drive disconnected."),
                timeout = 3,
            })
        end,
    })
end

--- Confirm removal of the user's Google OAuth application credentials.
---@param touchmenu_instance? table
function GoogleDriveSetup:confirmRemoveOAuthCredentials(
    touchmenu_instance
)
    UIManager:show(ConfirmBox:new{
        text = _(
            "Remove Google OAuth credentials from this device?\n\n"
                .. "This also disconnects Google Drive locally. "
                .. "Files in Google Drive will not be deleted."
        ),
        ok_text = _("Remove"),
        ok_callback = function()
            local success, clear_error =
                self.provider:clearOAuthCredentials()

            if not success then
                UIManager:show(InfoMessage:new{
                    text = string.format(
                        _("Cannot remove OAuth credentials:\n\n%s"),
                        clear_error or _("Unknown error")
                    ),
                })
                return
            end

            self.layout:clearCache()
            self.provider_state:save()
            self:updateMenu(touchmenu_instance)

            UIManager:show(InfoMessage:new{
                text = _("Google OAuth credentials removed."),
                timeout = 3,
            })
        end,
    })
end

--- Show the one-time Google Cloud setup instructions for KOCloud.
function GoogleDriveSetup:showSetupHelp()
    UIManager:show(InfoMessage:new{
        text = _(
            "Google Drive setup\n\n"
                .. "1. Create a Google Cloud project.\n"
                .. "2. Enable Google Drive API.\n"
                .. "3. Create an OAuth client of type "
                .. "\"TVs and Limited Input devices\".\n"
                .. "4. Download the OAuth client JSON file.\n"
                .. "5. Open Configure OAuth credentials.\n\n"
                .. "Recommended: From browser (phone or computer)\n"
                .. "Scan the QR code with your phone, or open the setup address "
                .. "on a computer or another device on the same Wi-Fi network. "
                .. "Then choose the JSON file in that browser.\n\n"
                .. "Fallback: From KOReader storage (JSON file)\n"
                .. "First copy the downloaded JSON file into the "
                .. "KOReader device storage, then select it using "
                .. "KOReader's file picker.\n\n"
                .. "6. Connect Google Drive and authorize on your phone.\n\n"
                .. "For long-term use, publish the OAuth app to "
                .. "In production. OAuth apps left in Testing can issue "
                .. "refresh tokens that expire after 7 days."
        ),
    })
end

--- Show KOCloud provider, OAuth, and storage status information.
---@param config KOCloudConfig
function GoogleDriveSetup:showStatus(config)
    local client_status = self.provider:isClientConfigured()
            and _("Configured")
        or _("Not configured")

    local root_ref = self.layout:getRootRef()
    local root_status = root_ref and _("Available")
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
                    .. "Storage root: %s\n"
                    .. "Settings: %s\n"
                    .. "OAuth credentials: %s"
            ),
            self.provider:getName(),
            self.provider:getType(),
            self:getAuthStatusText(),
            client_status,
            self:getStorageStatusText(),
            self.layout:getManagedFolderCount(),
            self.layout:getExpectedManagedFolderCount(),
            root_status,
            config:getSettingsFile(),
            self.provider:getOAuthCredentialSettingsFile()
        ),
    })
end

--- Find or create the complete KOCloud storage layout.
---@param touchmenu_instance? table
function GoogleDriveSetup:initializeStorage(touchmenu_instance)
    if not self.provider:isConfigured() then
        UIManager:show(InfoMessage:new{
            text = _("Connect Google Drive first."),
            timeout = 3,
        })
        return
    end

    local folders, created_count, err =
        self.layout:ensureStorageLayout()

    if not folders then
        UIManager:show(InfoMessage:new{
            text = string.format(
                _("Cannot initialize KOCloud storage:\n\n%s"),
                err or _("Unknown error")
            ),
        })
        return
    end

    self.provider_state:save()

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

    self:updateMenu(touchmenu_instance)
end

--- Start Google Drive Device Authorization Flow.
---@param touchmenu_instance? table
function GoogleDriveSetup:startAuthorization(touchmenu_instance)
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

    self:cancelAuthorization()
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
                        self:cancelAuthorization()
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
            self:clearAuthorizationSession()
        end
    end

    self.device_auth_dialog = dialog
    UIManager:show(dialog)

    self.device_auth_poll_task = function()
        self:pollAuthorization()
    end

    UIManager:scheduleIn(
        session.interval,
        self.device_auth_poll_task
    )
end

--- Poll Google once for the current device authorization session.
function GoogleDriveSetup:pollAuthorization()
    local session = self.device_auth_session

    if not session then
        return
    end

    local result = self.provider:pollDeviceAuthorization(session)

    if result.status == "authorized" then
        self.provider_state:save()

        local menu = self.device_auth_menu
        self:finishAuthorizationDialog()

        UIManager:show(InfoMessage:new{
            text = _("Google Drive connected successfully."),
            timeout = 3,
        })

        self:updateMenu(menu)
        return
    end

    if result.status == "pending"
        or result.status == "slow_down"
        or (result.status == "error" and result.retry_after)
    then
        UIManager:scheduleIn(
            result.retry_after or session.interval,
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

    self:finishAuthorizationDialog()
    UIManager:show(InfoMessage:new{ text = message })
end

--- Close the authorization dialog and stop its polling task.
function GoogleDriveSetup:finishAuthorizationDialog()
    local dialog = self.device_auth_dialog

    self.device_auth_dialog = nil
    self:clearAuthorizationSession()

    if dialog then
        UIManager:close(dialog)
    end
end

--- Clear the current authorization session and scheduled polling.
function GoogleDriveSetup:clearAuthorizationSession()
    if self.device_auth_poll_task then
        UIManager:unschedule(self.device_auth_poll_task)
    end

    self.device_auth_session = nil
    self.device_auth_poll_task = nil
    self.device_auth_menu = nil
end

--- Cancel the current Google Drive authorization attempt.
function GoogleDriveSetup:cancelAuthorization()
    local dialog = self.device_auth_dialog

    self.device_auth_dialog = nil
    self:clearAuthorizationSession()

    if dialog then
        UIManager:close(dialog)
    end
end

--- Refresh a KOReader TouchMenu if the caller supplied one.
---@param touchmenu_instance? table
function GoogleDriveSetup:updateMenu(touchmenu_instance)
    if touchmenu_instance and touchmenu_instance.updateItems then
        touchmenu_instance:updateItems()
    end
end

return GoogleDriveSetup
