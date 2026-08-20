local ButtonDialog = require("ui/widget/buttondialog")
local Config = require("core/config")
local ConfirmBox = require("ui/widget/confirmbox")
local Device = require("device")
local filemanagerutil = require("apps/filemanager/filemanagerutil")
local GoogleDriveProvider = require("providers/google_drive/provider")
local InfoMessage = require("ui/widget/infomessage")
local lfs = require("libs/libkoreader-lfs")
local Menu = require("ui/widget/menu")
local NetworkMgr = require("ui/network/manager")
local QRMessage = require("ui/widget/qrmessage")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local util = require("util")
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

--- Return whether a local file is supported by the KOCloud upload picker.
---@param filename string
---@return boolean
local function isSupportedBookFile(filename)
    local lower_name = filename:lower()

    return lower_name:match("%.epub$") ~= nil
        or lower_name:match("%.pdf$") ~= nil
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

        if self:isStorageInitialized() then
            table.insert(items, {
                text = _("My Books"),
                callback = function()
                    NetworkMgr:runWhenOnline(function()
                        self:showBooks()
                    end)
                end,
            })

            table.insert(items, {
                text = _("Upload book"),
                callback = function()
                    self:chooseBookForUpload()
                end,
            })
        end
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

--- Show all KOCloud-managed books in a paginated KOReader menu.
function KOCloud:showBooks()
    local loading_message = InfoMessage:new{
        text = _("Loading KOCloud books…"),
    }

    UIManager:show(loading_message)

    UIManager:scheduleIn(0.1, function()
        local books, err = self.provider:listBooks()

        UIManager:close(loading_message)

        if not books then
            UIManager:show(InfoMessage:new{
                text = string.format(
                    _("Cannot load KOCloud books:\n\n%s"),
                    err or _("Unknown error")
                ),
            })
            return
        end

        if #books == 0 then
            UIManager:show(InfoMessage:new{
                text = _("No books have been uploaded to KOCloud yet."),
                timeout = 4,
            })
            return
        end

        local item_table = {}

        for _, book in ipairs(books) do
            table.insert(item_table, {
                text = book.name,
                book = book,
            })
        end

        local books_menu

        books_menu = Menu:new{
            title = string.format(
                _("My Books (%d)"),
                #books
            ),
            item_table = item_table,
            items_max_lines = 2,
        }

        --- Open actions for the selected KOCloud book.
        ---@param item table
        function books_menu:onMenuSelect(item)
            if item.book then
                self.kocloud_plugin:showBookActions(item.book)
            end
        end

        books_menu.kocloud_plugin = self

        UIManager:show(books_menu)
    end)
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

--- Open KOReader's file chooser for a local EPUB or PDF.
function KOCloud:chooseBookForUpload()
    local title_header = _("Choose a book to upload")

    local caller_callback = function(local_path)
        NetworkMgr:runWhenOnline(function()
            self:uploadBook(local_path)
        end)
    end

    filemanagerutil.showChooseDialog(
        title_header,
        caller_callback,
        nil,
        filemanagerutil.getHomeFolder(),
        isSupportedBookFile
    )
end

--- Upload one local book into the KOCloud Books folder.
---@param local_path string
function KOCloud:uploadBook(local_path)
    local uploading_message = InfoMessage:new{
        text = string.format(
            _("Uploading book…\n\n%s"),
            local_path
        ),
    }

    UIManager:show(uploading_message)

    UIManager:scheduleIn(0.1, function()
        local book, err = self.provider:uploadBook(local_path)

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
    end)
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
