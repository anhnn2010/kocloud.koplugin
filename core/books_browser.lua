local ButtonDialog = require("ui/widget/buttondialog")
local CheckButton = require("ui/widget/checkbutton")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local Menu = require("ui/widget/menu")
local NetworkMgr = require("ui/network/manager")
local UIManager = require("ui/uimanager")
local util = require("util")
local _ = require("gettext")

--- Remote KOCloud Books browser backed by the active cloud provider.
---
--- The browser follows KOReader's CloudStorage navigation pattern: one Menu
--- instance is kept alive while its item table is replaced as folders change.
--- `self.paths` is inherited from Menu and stores the current remote path.
---@class KOCloudBooksBrowser: Menu
---@field kocloud_plugin KOCloudPlugin
local BooksBrowser = Menu:extend{
    title = _("My Books"),
    subtitle = _("KOCloud / Books"),
    show_path = true,
    title_bar_fm_style = true,
    title_bar_left_icon = "appbar.menu",
    item_table = {},
    is_borderless = true,
    is_popout = false,
}

--- Initialize the browser and load the KOCloud Books root.
function BooksBrowser:init()
    self.onLeftButtonTap = function()
        self:showFolderActions()
    end
    self.onLeftButtonHold = self.onLeftButtonTap

    Menu.init(self)
    self:loadCurrentFolder()
end

--- Show actions that apply to the currently open remote folder.
function BooksBrowser:showFolderActions()
    local dialog

    dialog = ButtonDialog:new{
        buttons = {
            {
                {
                    text = _("Upload book"),
                    callback = function()
                        UIManager:close(dialog)
                        self.kocloud_plugin:chooseBookForUpload(
                            self:getCurrentFolderId(),
                            function()
                                self:loadCurrentFolder()
                            end
                        )
                    end,
                },
            },
            {
                {
                    text = _("New folder"),
                    callback = function()
                        UIManager:close(dialog)
                        self:showCreateFolderDialog()
                    end,
                },
            },
            {
                {
                    text = _("Refresh"),
                    callback = function()
                        UIManager:close(dialog)
                        self:loadCurrentFolder()
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

--- Prompt for a new folder name and create it under the current folder.
function BooksBrowser:showCreateFolderDialog()
    local input_dialog
    local enter_folder_checkbox

    input_dialog = InputDialog:new{
        title = _("New folder"),
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        UIManager:close(input_dialog)
                    end,
                },
                {
                    text = _("Create"),
                    is_enter_default = true,
                    callback = function()
                        local folder_name = input_dialog:getInputText()
                        folder_name = folder_name:gsub("^%s+", "")
                        folder_name = folder_name:gsub("%s+$", "")

                        if folder_name == "" then
                            return
                        end

                        local parent_folder_id = self:getCurrentFolderId()
                        local enter_after_creation =
                            enter_folder_checkbox.checked

                        UIManager:close(input_dialog)

                        NetworkMgr:runWhenOnline(function()
                            self:createFolder(
                                folder_name,
                                parent_folder_id,
                                enter_after_creation
                            )
                        end)
                    end,
                },
            },
        },
    }

    enter_folder_checkbox = CheckButton:new{
        text = _("Enter folder after creation"),
        checked = false,
        parent = input_dialog,
    }

    input_dialog:addWidget(enter_folder_checkbox)
    UIManager:show(input_dialog)
    input_dialog:onShowKeyboard()
end

--- Create one child folder and refresh or enter it after success.
---@param folder_name string
---@param parent_folder_id? string
---@param enter_after_creation boolean
function BooksBrowser:createFolder(
    folder_name,
    parent_folder_id,
    enter_after_creation
)
    local creating_message = InfoMessage:new{
        text = string.format(
            _("Creating folder…\n\n%s"),
            folder_name
        ),
    }

    UIManager:show(creating_message)

    UIManager:scheduleIn(0.1, function()
        local folder, err =
            self.kocloud_plugin.provider:createLibraryFolder(
                folder_name,
                parent_folder_id
            )

        UIManager:close(creating_message)

        if not folder then
            UIManager:show(InfoMessage:new{
                text = string.format(
                    _("Cannot create folder:\n\n%s"),
                    err or _("Unknown error")
                ),
            })
            return
        end

        if enter_after_creation then
            table.insert(self.paths, {
                id = folder.id,
                name = folder.name or folder_name,
            })
        end

        self:loadCurrentFolder()
    end)
end

--- Return the Google Drive folder ID for the current browser location.
--- Nil means the managed KOCloud/Books root.
---@return string|nil folder_id
function BooksBrowser:getCurrentFolderId()
    local current = self.paths[#self.paths]

    if current then
        return current.id
    end

    return nil
end

--- Return the visible remote path for the title-bar subtitle.
---@return string
function BooksBrowser:getCurrentPath()
    local parts = { _("KOCloud"), _("Books") }

    for _index, path_item in ipairs(self.paths) do
        table.insert(parts, path_item.name or _("Folder"))
    end

    return table.concat(parts, " / ")
end

--- Return the book size using the same compact presentation as CloudStorage.
---@param book KOCloudGoogleDriveFile
---@return string|nil
function BooksBrowser:getBookInfo(book)
    if not book.size then
        return nil
    end

    local size = tonumber(book.size)

    if not size then
        return nil
    end

    return util.getFriendlySize(size)
end

--- Build menu items for one remote folder.
---@param folders KOCloudGoogleDriveFile[]
---@param books KOCloudGoogleDriveFile[]
---@return table item_table
function BooksBrowser:buildItemTable(folders, books)
    local item_table = {}

    for _index, folder in ipairs(folders) do
        table.insert(item_table, {
            text = (folder.name or _("Folder")) .. "/",
            folder = folder,
        })
    end

    for _index, book in ipairs(books) do
        table.insert(item_table, {
            text = book.name or _("Book"),
            mandatory = self:getBookInfo(book),
            book = book,
        })
    end

    if #folders == 0 and #books == 0 then
        table.insert(item_table, {
            text = #self.paths == 0
                    and _("No books or folders have been added to KOCloud yet.")
                or _("This KOCloud folder is empty."),
            enabled = false,
        })
    end

    return item_table
end

--- Reload the current remote folder into this Menu instance.
function BooksBrowser:loadCurrentFolder()
    local loading_message = InfoMessage:new{
        text = _("Loading KOCloud library…"),
    }

    UIManager:show(loading_message)

    UIManager:scheduleIn(0.1, function()
        local folders, books, err =
            self.kocloud_plugin.provider:listLibraryFolder(
                self:getCurrentFolderId()
            )

        UIManager:close(loading_message)

        if not folders then
            UIManager:show(InfoMessage:new{
                text = string.format(
                    _("Cannot load KOCloud library:\n\n%s"),
                    err or _("Unknown error")
                ),
            })
            return
        end

        local item_count = #folders + #books
        local item_table = self:buildItemTable(folders, books)

        self:switchItemTable(
            string.format(_("My Books (%d)"), item_count),
            item_table
        )

        if self.title_bar then
            self.title_bar:setSubTitle(self:getCurrentPath())
        end
    end)
end

--- Open a child folder or show actions for a selected book.
---@param item table
function BooksBrowser:onMenuSelect(item)
    if item.folder then
        table.insert(self.paths, {
            id = item.folder.id,
            name = item.folder.name or _("Folder"),
        })
        self:loadCurrentFolder()
    elseif item.book then
        self.kocloud_plugin:showBookActions(item.book)
    end

    return true
end

--- Return to the parent remote folder, or close My Books at the root.
function BooksBrowser:onReturn()
    if #self.paths == 0 then
        UIManager:close(self)
        return true
    end

    table.remove(self.paths)
    self:loadCurrentFolder()

    return true
end

--- Long Back returns directly to the KOCloud Books root.
function BooksBrowser:onHoldReturn()
    if #self.paths == 0 then
        UIManager:close(self)
        return true
    end

    for index = #self.paths, 1, -1 do
        table.remove(self.paths, index)
    end

    self:loadCurrentFolder()

    return true
end

return BooksBrowser
