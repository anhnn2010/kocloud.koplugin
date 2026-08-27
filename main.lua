local BookFormats = require("core/book_formats")
local BooksBrowser = require("core/books_browser")
local ButtonDialog = require("ui/widget/buttondialog")
local Config = require("core/config")
local ConfirmBox = require("ui/widget/confirmbox")
local Device = require("device")
local filemanagerutil = require("apps/filemanager/filemanagerutil")
local GoogleDriveProvider = require("providers/google_drive/provider")
local InfoMessage = require("ui/widget/infomessage")
local lfs = require("libs/libkoreader-lfs")
local NetworkMgr = require("ui/network/manager")
local OAuthSetupDialog = require("core/oauth_setup_dialog")
local OAuthSetupServer = require("core/oauth_setup_server")
local QRMessage = require("ui/widget/qrmessage")
local StorageLayoutService = require("core/services/storage_layout")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local util = require("util")
local _ = require("gettext")


--- Main KOCloud plugin container.
---@class KOCloudPlugin: WidgetContainer
---@field config KOCloudConfig
---@field provider KOCloudGoogleDriveProvider
---@field layout KOCloudStorageLayoutService
---@field device_auth_session? KOCloudGoogleDriveDeviceSession
---@field device_auth_dialog? ButtonDialog
---@field device_auth_poll_task? function
---@field device_auth_menu? table
---@field oauth_setup_server? KOCloudOAuthSetupServer
---@field oauth_setup_qr? QRMessage
local KOCloud = WidgetContainer:extend{
    name = "kocloud",
    is_doc_only = false,
}

--- Return whether a local file can contain Google OAuth credentials.
---@param filename string
---@return boolean
local function isOAuthCredentialsJsonFile(filename)
    return filename:lower():match("%.json$") ~= nil
end

--- Convert a Google Drive file name into a safe local file name.
---@param name string
---@return string
local function sanitizeLocalFilename(name)
    local safe_name = name:gsub("[/\\]", "_")
    safe_name = safe_name:gsub("^%s+", "")
    safe_name = safe_name:gsub("%s+$", "")

    if safe_name == "" or safe_name == "." or safe_name == ".." then
        return "book"
    end

    return safe_name
end

--- Join a directory and file name using KOReader's local path convention.
---@param directory string
---@param filename string
---@return string
local function joinLocalPath(directory, filename)
    if directory:sub(-1) == "/" then
        return directory .. filename
    end

    return directory .. "/" .. filename
end

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

    self.layout = StorageLayoutService:new(self.provider)

    -- Older KOCloud versions persisted short-lived access-token state.
    -- Auth removes those legacy keys during construction; save the cleaned
    -- provider config once so kocloud.lua keeps only long-lived state.
    if self.provider:isPersistentConfigDirty()
        or self.layout:isPersistentConfigDirty()
    then
        self.config:setProviderConfig(
            provider_type,
            self.provider.config
        )
        self.config:flush()
        self.provider:markPersistentConfigSaved()
        self.layout:markPersistentConfigSaved()
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
    return self.layout:getManagedFolderCount()
end

--- Return whether the complete KOCloud storage layout is initialized.
---@return boolean
function KOCloud:isStorageInitialized()
    return self.layout:isInitialized()
end

--- Return a human-readable KOCloud storage status.
---@return string
function KOCloud:getStorageStatusText()
    if self:isStorageInitialized() then
        return _("Initialized")
    end

    return _("Not initialized")
end

--- Return the Google Drive provider submenu items.
---@return table
function KOCloud:getGoogleDriveMenuItems()
    local items = {
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
                                self:startPhoneOAuthSetup(
                                    touchmenu_instance
                                )
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
            end,
        },
    }

    table.insert(items, {
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
                self:confirmDisconnectGoogleDrive(
                    touchmenu_instance
                )
                return
            end

            NetworkMgr:runWhenOnline(function()
                self:startGoogleDriveAuthorization(
                    touchmenu_instance
                )
            end)
        end,
    })

    table.insert(items, {
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
                self:initializeProviderStorage(
                    touchmenu_instance
                )
            end)
        end,
    })

    table.insert(items, {
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
    })

    table.insert(items, {
        text = _("Setup help"),
        keep_menu_open = true,
        callback = function()
            self:showGoogleDriveSetupHelp()
        end,
    })

    return items
end

--- Return configured/available cloud provider menu items.
---@return table
function KOCloud:getCloudProvidersMenuItems()
    return {
        {
            text_func = function()
                return string.format(
                    _("Google Drive: %s"),
                    self:getAuthStatusText()
                )
            end,
            sub_item_table_func = function()
                return self:getGoogleDriveMenuItems()
            end,
        },
    }
end

--- Return Library service menu items.
---@return table
function KOCloud:getLibraryMenuItems()
    local ready = self.provider:isConfigured()
        and self:isStorageInitialized()

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

--- Return KOCloud settings and status menu items.
---@return table
function KOCloud:getSettingsAndStatusMenuItems()
    return {
        {
            text = _("Status"),
            keep_menu_open = true,
            callback = function()
                self:showStatus()
            end,
        },
    }
end

--- Return the KOCloud root submenu.
---
--- Keep this level provider-agnostic. Root entries represent stable KOCloud
--- feature areas; provider-specific configuration belongs under
--- "Cloud providers".
---@return table
function KOCloud:getSubMenuItems()
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

--- Start a temporary LAN web page for entering OAuth credentials by phone.
---@param touchmenu_instance? table
function KOCloud:startPhoneOAuthSetup(touchmenu_instance)
    self:stopPhoneOAuthSetup()

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
                self.config:setProviderConfig(
                    self.provider:getType(),
                    self.provider.config
                )
                self.config:flush()
                self.provider:markPersistentConfigSaved()
                self.layout:markPersistentConfigSaved()
            end

            return true, nil
        end,
        on_saved = function()
            self.oauth_setup_server = nil

            if self.oauth_setup_qr then
                local qr = self.oauth_setup_qr
                self.oauth_setup_qr = nil
                UIManager:close(qr)
            end

            if touchmenu_instance
                and touchmenu_instance.updateItems
            then
                touchmenu_instance:updateItems()
            end

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

            if self.oauth_setup_qr then
                local qr = self.oauth_setup_qr
                self.oauth_setup_qr = nil
                UIManager:close(qr)
            end

            if touchmenu_instance
                and touchmenu_instance.updateItems
            then
                touchmenu_instance:updateItems()
            end

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

    if touchmenu_instance and touchmenu_instance.updateItems then
        touchmenu_instance:updateItems()
    end

    -- Show the QR directly. Do not stack a timed InfoMessage underneath it:
    -- QRMessage closes on any tap, and an underlying timed message would
    -- briefly flash on screen after the QR is dismissed.
    UIManager:nextTick(function()
        if self.oauth_setup_server == server
            and server:isRunning()
        then
            self:showPhoneOAuthSetupQR()
        end
    end)
end

--- Show a compact QR + URL dialog for the current phone setup session.
function KOCloud:showPhoneOAuthSetupQR()
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

    if self.oauth_setup_qr then
        UIManager:close(self.oauth_setup_qr)
    end

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

--- Stop any temporary phone OAuth setup server and QR dialog.
function KOCloud:stopPhoneOAuthSetup()
    if self.oauth_setup_qr then
        local qr = self.oauth_setup_qr
        self.oauth_setup_qr = nil
        UIManager:close(qr)
    end

    if self.oauth_setup_server then
        self.oauth_setup_server:stop()
        self.oauth_setup_server = nil
    end
end

--- Open KOReader's file chooser for Google's downloaded OAuth JSON file.
---@param touchmenu_instance? table
function KOCloud:chooseOAuthCredentialsFile(touchmenu_instance)
    local title_header = _("Choose OAuth JSON from KOReader storage")

    local caller_callback = function(json_path)
        self:importOAuthCredentials(
            json_path,
            touchmenu_instance
        )
    end

    filemanagerutil.showChooseDialog(
        title_header,
        caller_callback,
        nil,
        filemanagerutil.getHomeFolder(),
        isOAuthCredentialsJsonFile
    )
end

--- Import and persist Google OAuth application credentials.
---@param json_path string
---@param touchmenu_instance? table
function KOCloud:importOAuthCredentials(
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

    -- Replacing the OAuth client may authorize a different Drive account.
    -- Clear cached remote layout references before persisting the new state.
    if changed then
        self.layout:clearCache()
        self.config:setProviderConfig(
            self.provider:getType(),
            self.provider.config
        )
        self.config:flush()
        self.provider:markPersistentConfigSaved()
        self.layout:markPersistentConfigSaved()
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

    if touchmenu_instance and touchmenu_instance.updateItems then
        touchmenu_instance:updateItems()
    end
end

--- Confirm disconnecting the currently authorized Google Drive account.
---@param touchmenu_instance? table
function KOCloud:confirmDisconnectGoogleDrive(
    touchmenu_instance
)
    UIManager:show(ConfirmBox:new{
        text = _(
            "Disconnect Google Drive on this device?\n\n"
                .. "Your files in Google Drive will not be deleted."
        ),
        ok_text = _("Disconnect"),
        ok_callback = function()
            self.provider:disconnect()
            self.layout:clearCache()

            self.config:setProviderConfig(
                self.provider:getType(),
                self.provider.config
            )
            self.config:flush()
            self.provider:markPersistentConfigSaved()
            self.layout:markPersistentConfigSaved()

            if touchmenu_instance
                and touchmenu_instance.updateItems
            then
                touchmenu_instance:updateItems()
            end

            UIManager:show(InfoMessage:new{
                text = _("Google Drive disconnected."),
                timeout = 3,
            })
        end,
    })
end

--- Confirm removal of the user's Google OAuth application credentials.
---@param touchmenu_instance? table
function KOCloud:confirmRemoveOAuthCredentials(
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
                        _(
                            "Cannot remove OAuth credentials:\n\n%s"
                        ),
                        clear_error or _("Unknown error")
                    ),
                })
                return
            end

            self.layout:clearCache()

            self.config:setProviderConfig(
                self.provider:getType(),
                self.provider.config
            )
            self.config:flush()
            self.provider:markPersistentConfigSaved()
            self.layout:markPersistentConfigSaved()

            if touchmenu_instance
                and touchmenu_instance.updateItems
            then
                touchmenu_instance:updateItems()
            end

            UIManager:show(InfoMessage:new{
                text = _("Google OAuth credentials removed."),
                timeout = 3,
            })
        end,
    })
end

--- Show the one-time Google Cloud setup instructions for KOCloud.
function KOCloud:showGoogleDriveSetupHelp()
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
function KOCloud:showStatus()
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
            self:getManagedFolderCount(),
            self.layout:getExpectedManagedFolderCount(),
            root_status,
            self.config:getSettingsFile(),
            self.provider:getOAuthCredentialSettingsFile()
        ),
    })
end

--- Browse KOCloud Books using a single remote-folder Menu.
---
--- Folder navigation follows KOReader's built-in CloudStorage pattern: the
--- browser keeps one Menu open and replaces its item table when the current
--- remote folder changes.
function KOCloud:showBooks()
    UIManager:show(BooksBrowser:new{
        kocloud_plugin = self,
    })
end

--- Show actions for a KOCloud-managed book.
---@param book KOCloudGoogleDriveFile
function KOCloud:showBookActions(book)
    local dialog

    dialog = ButtonDialog:new{
        title = book.name or _("Book"),
        buttons = {
            {
                {
                    text = _("Download"),
                    callback = function()
                        UIManager:close(dialog)
                        self:chooseBookDownloadFolder(book)
                    end,
                },
            },
            {
                {
                    text = _("Details"),
                    callback = function()
                        self:showBookDetails(book)
                    end,
                },
            },
            {
                {
                    text = _("Close"),
                    callback = function()
                        UIManager:close(dialog)
                    end,
                },
            },
        },
    }

    UIManager:show(dialog)
end

--- Show metadata for a KOCloud-managed book.
---@param book KOCloudGoogleDriveFile
function KOCloud:showBookDetails(book)
    local size_text = _("Unknown")

    if book.size then
        local size = tonumber(book.size)

        if size then
            size_text = util.getFriendlySize(size)
        end
    end

    UIManager:show(InfoMessage:new{
        text = string.format(
            _(
                "Name: %s\n"
                    .. "Size: %s\n"
                    .. "Modified: %s\n"
                    .. "Drive file ID: %s"
            ),
            book.name or _("Unknown"),
            size_text,
            book.modifiedTime or _("Unknown"),
            book.id or _("Unknown")
        ),
    })
end

--- Ask the user where a KOCloud book should be downloaded.
---@param book KOCloudGoogleDriveFile
function KOCloud:chooseBookDownloadFolder(book)
    local title_header = _("Choose download folder")

    local caller_callback = function(directory)
        if not directory then
            return
        end

        local filename = sanitizeLocalFilename(
            book.name or "book"
        )
        local local_path = joinLocalPath(directory, filename)

        self:confirmBookDownload(book, local_path)
    end

    filemanagerutil.showChooseDialog(
        title_header,
        caller_callback,
        nil,
        filemanagerutil.getHomeFolder()
    )
end

--- Confirm overwrite when needed before downloading a book.
---@param book KOCloudGoogleDriveFile
---@param local_path string
function KOCloud:confirmBookDownload(book, local_path)
    if lfs.attributes(local_path, "mode") ~= "file" then
        self:downloadBook(book, local_path)
        return
    end

    UIManager:show(ConfirmBox:new{
        text = string.format(
            _(
                "A file already exists at:\n\n%s\n\n"
                    .. "Overwrite it?"
            ),
            local_path
        ),
        ok_text = _("Overwrite"),
        ok_callback = function()
            self:downloadBook(book, local_path)
        end,
    })
end

--- Download one KOCloud-managed book to local storage.
---@param book KOCloudGoogleDriveFile
---@param local_path string
function KOCloud:downloadBook(book, local_path)
    local downloading_message = InfoMessage:new{
        text = string.format(
            _("Downloading book…\n\n%s"),
            book.name or _("Book")
        ),
    }

    UIManager:show(downloading_message)

    UIManager:scheduleIn(0.1, function()
        local success, err = self.provider:downloadBook(
            book.id,
            local_path
        )

        UIManager:close(downloading_message)

        if not success then
            UIManager:show(InfoMessage:new{
                text = string.format(
                    _("Cannot download book:\n\n%s"),
                    err or _("Unknown error")
                ),
            })
            return
        end

        UIManager:show(InfoMessage:new{
            text = string.format(
                _(
                    "Book downloaded successfully.\n\n"
                        .. "%s"
                ),
                local_path
            ),
            timeout = 5,
        })
    end)
end

--- Open KOReader's file chooser for a supported local book file.
function KOCloud:chooseBookForUpload(parent_folder_id, uploaded_callback)
    local title_header = _("Choose a book to upload")

    local caller_callback = function(local_path)
        NetworkMgr:runWhenOnline(function()
            self:uploadBook(
                local_path,
                parent_folder_id,
                uploaded_callback
            )
        end)
    end

    filemanagerutil.showChooseDialog(
        title_header,
        caller_callback,
        nil,
        filemanagerutil.getHomeFolder(),
        BookFormats.isSupported
    )
end

--- Upload one local book into a KOCloud Books folder.
---@param local_path string
---@param parent_folder_id? string
---@param uploaded_callback? fun(book: KOCloudGoogleDriveFile)
function KOCloud:uploadBook(
    local_path,
    parent_folder_id,
    uploaded_callback
)
    local uploading_message = InfoMessage:new{
        text = string.format(
            _("Uploading book…\n\n%s"),
            local_path
        ),
    }

    UIManager:show(uploading_message)

    UIManager:scheduleIn(0.1, function()
        local book, err = self.provider:uploadBook(
            local_path,
            nil,
            parent_folder_id
        )

        UIManager:close(uploading_message)

        if not book then
            UIManager:show(InfoMessage:new{
                text = string.format(
                    _("Cannot upload book:\n\n%s"),
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

        UIManager:show(InfoMessage:new{
            text = string.format(
                _("Book uploaded successfully.\n\n%s"),
                book.name
            ),
            timeout = 4,
        })

        if uploaded_callback then
            uploaded_callback(book)
        end
    end)
end

--- Find or create the complete KOCloud storage layout.
---@param touchmenu_instance? table
function KOCloud:initializeProviderStorage(touchmenu_instance)
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

    self.config:setProviderConfig(
        self.provider:getType(),
        self.provider.config
    )
    self.config:flush()
    self.layout:markPersistentConfigSaved()

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
        self.provider:markPersistentConfigSaved()

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

--- Stop temporary local setup services before KOReader exits.
function KOCloud:onExit()
    self:stopPhoneOAuthSetup()
end

--- Stop temporary local setup services when this plugin instance closes.
function KOCloud:onCloseWidget()
    self:stopPhoneOAuthSetup()
end

--- Do not leave a temporary credential server listening during suspend.
function KOCloud:onSuspend()
    self:stopPhoneOAuthSetup()
end

--- Add KOCloud to the KOReader main menu.
---@param menu_items table
function KOCloud:addToMainMenu(menu_items)
    menu_items.kocloud = {
        text = _("KOCloud"),
        sorting_hint = "tools",
        sub_item_table_func = function()
            return self:getSubMenuItems()
        end,
    }
end

return KOCloud
