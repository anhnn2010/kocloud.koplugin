local BookActions = require("core/ui/library/book_actions")
local SelectionActions = require("core/ui/library/selection_actions")
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
--- The browser follows KOReader Cloud storage+ navigation and interaction
--- patterns: one Menu instance is kept alive while its item table is replaced
--- as folders change, and long-pressing a file exposes Delete / Select actions.
---@class KOCloudBooksBrowser: Menu
---@field library KOCloudLibraryService
---@field book_actions KOCloudBookActions
---@field selection_actions KOCloudSelectionActions
local BooksBrowser = Menu:extend{
    title = _("My Books"),
    subtitle = _("KOCloud/Books"),
    show_path = true,
    title_bar_fm_style = true,
    title_bar_left_icon = "appbar.menu",
    item_table = {},
    is_borderless = true,
    is_popout = false,
}

--- Initialize the browser and load the KOCloud Books root.
function BooksBrowser:init()
    if not self.library then
        error("KOCloud BooksBrowser requires LibraryService")
    end

    self.book_actions = BookActions:new{
        browser = self,
        library = self.library,
    }
    self.selection_actions = SelectionActions:new{
        browser = self,
        library = self.library,
        book_actions = self.book_actions,
    }

    self.onLeftButtonTap = function()
        if self.selection_actions:isActive() then
            self.selection_actions:showDialog()
        else
            self:showFolderActions()
        end
    end

    self.onLeftButtonHold = function()
        self.selection_actions:toggle()
    end

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
                        self.book_actions:chooseUpload()
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

                        local parent_folder_ref = self:getCurrentFolderRef()
                        local enter_after_creation =
                            enter_folder_checkbox.checked

                        UIManager:close(input_dialog)

                        NetworkMgr:runWhenOnline(function()
                            self:createFolder(
                                folder_name,
                                parent_folder_ref,
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
---@param parent_folder_ref? KOCloudRemoteRef
---@param enter_after_creation boolean
function BooksBrowser:createFolder(
    folder_name,
    parent_folder_ref,
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
            self.library:createFolder(
                folder_name,
                parent_folder_ref
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
                ref = folder.ref,
                key = folder.key,
                name = folder.name or folder_name,
            })
        end

        self:loadCurrentFolder()
    end)
end

--- Return the remote folder reference for the current browser location.
--- Nil means the managed KOCloud/Books root.
---@return KOCloudRemoteRef|nil folder_ref
function BooksBrowser:getCurrentFolderRef()
    local current = self.paths[#self.paths]

    if current then
        return current.ref
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

    return table.concat(parts, "/")
end

--- Return the book size using the same compact presentation as CloudStorage.
---@param book KOCloudLibraryEntry
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
---@param folders KOCloudLibraryEntry[]
---@param books KOCloudLibraryEntry[]
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
            dim = self.selection_actions:isSelected(book) or nil,
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
---@param on_loaded? fun()
function BooksBrowser:loadCurrentFolder(on_loaded)
    local loading_message = InfoMessage:new{
        text = _("Loading KOCloud library…"),
    }

    UIManager:show(loading_message)

    UIManager:scheduleIn(0.1, function()
        local folders, books, err =
            self.library:listFolder(
                self:getCurrentFolderRef()
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

        local item_table = self:buildItemTable(folders, books)

        self:switchItemTable(_("My Books"), item_table)

        if self.title_bar then
            self.title_bar:setSubTitle(self:getCurrentPath())
        end

        if on_loaded then
            on_loaded()
        end
    end)
end

--- Open a child folder, toggle a selected book, or show book actions.
---@param item table
function BooksBrowser:onMenuSelect(item)
    if item.folder then
        table.insert(self.paths, {
            ref = item.folder.ref,
            key = item.folder.key,
            name = item.folder.name or _("Folder"),
        })
        self:loadCurrentFolder()
    elseif item.book then
        if self.selection_actions:isActive() then
            self.selection_actions:toggleItem(item)
        else
            self.book_actions:show(item.book)
        end
    end

    return true
end

--- Match Cloud storage+ long-press behavior for remote files.
---@param item table
function BooksBrowser:onMenuHold(item)
    if item.book then
        if self.selection_actions:isActive() then
            self.selection_actions:showDialog()
        else
            self.selection_actions:showBookHoldDialog(item)
        end
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
