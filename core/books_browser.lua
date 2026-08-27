local BookFormats = require("core/book_formats")
local ButtonDialog = require("ui/widget/buttondialog")
local CheckButton = require("ui/widget/checkbutton")
local ConfirmBox = require("ui/widget/confirmbox")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local MultiConfirmBox = require("ui/widget/multiconfirmbox")
local Menu = require("ui/widget/menu")
local lfs = require("libs/libkoreader-lfs")
local NetworkMgr = require("ui/network/manager")
local UIManager = require("ui/uimanager")
local filemanagerutil = require("apps/filemanager/filemanagerutil")
local ffiUtil = require("ffi/util")
local util = require("util")
local _ = require("gettext")
local N_ = _.ngettext
local T = ffiUtil.template

--- Remote KOCloud Books browser backed by the active cloud provider.
---
--- The browser follows KOReader Cloud storage+ navigation and interaction
--- patterns: one Menu instance is kept alive while its item table is replaced
--- as folders change, and long-pressing a file exposes Delete / Select actions.
---@class KOCloudBooksBrowser: Menu
---@field library KOCloudLibraryService
---@field selected_books? table<string, KOCloudLibraryEntry>
---@field last_download_dir? string
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

--- Convert a remote file name into a safe local file name.
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

--- Join a local directory and file name.
---@param directory string
---@param filename string
---@return string
local function joinLocalPath(directory, filename)
    if directory:sub(-1) == "/" then
        return directory .. filename
    end

    return directory .. "/" .. filename
end

--- Initialize the browser and load the KOCloud Books root.
function BooksBrowser:init()
    if not self.library then
        error("KOCloud BooksBrowser requires LibraryService")
    end

    self.onLeftButtonTap = function()
        if self.selected_books then
            self:showSelectModeDialog()
        else
            self:showFolderActions()
        end
    end

    self.onLeftButtonHold = function()
        self:toggleSelectMode()
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
                        self:chooseBookForUpload()
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

--- Show actions for one KOCloud-managed book.
---@param book KOCloudLibraryEntry
function BooksBrowser:showBookActions(book)
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

--- Show provider-neutral metadata for one managed book.
---@param book KOCloudLibraryEntry
function BooksBrowser:showBookDetails(book)
    local size_text = _("Unknown")

    if book.size then
        local size = tonumber(book.size)

        if size then
            size_text = util.getFriendlySize(size)
        end
    end

    local reference = book.key or _("Unknown")
    local provider_name = self.library:getProviderName()

    UIManager:show(InfoMessage:new{
        text = string.format(
            _(
                "Name: %s\n"
                    .. "Size: %s\n"
                    .. "Modified: %s\n"
                    .. "%s reference: %s"
            ),
            book.name or _("Unknown"),
            size_text,
            book.modified_at or _("Unknown"),
            provider_name,
            reference
        ),
    })
end

--- Ask where one remote book should be downloaded.
---@param book KOCloudLibraryEntry
function BooksBrowser:chooseBookDownloadFolder(book)
    local caller_callback = function(directory)
        if not directory then
            return
        end

        local filename = sanitizeLocalFilename(book.name or "book")
        local local_path = joinLocalPath(directory, filename)
        self:confirmBookDownload(book, local_path)
    end

    filemanagerutil.showChooseDialog(
        _("Choose download folder"),
        caller_callback,
        nil,
        filemanagerutil.getHomeFolder()
    )
end

--- Confirm overwrite when needed before downloading one book.
---@param book KOCloudLibraryEntry
---@param local_path string
function BooksBrowser:confirmBookDownload(book, local_path)
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

--- Download one Library book to local storage.
---@param book KOCloudLibraryEntry
---@param local_path string
function BooksBrowser:downloadBook(book, local_path)
    local downloading_message = InfoMessage:new{
        text = string.format(
            _("Downloading book…\n\n%s"),
            book.name or _("Book")
        ),
    }

    UIManager:show(downloading_message)

    UIManager:scheduleIn(0.1, function()
        local success, err = self.library:downloadBook(book, local_path)

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
                _("Book downloaded successfully.\n\n%s"),
                local_path
            ),
            timeout = 5,
        })
    end)
end

--- Open KOReader's file chooser for one supported local book.
function BooksBrowser:chooseBookForUpload()
    local caller_callback = function(local_path)
        NetworkMgr:runWhenOnline(function()
            self:uploadBook(local_path)
        end)
    end

    filemanagerutil.showChooseDialog(
        _("Choose a book to upload"),
        caller_callback,
        nil,
        filemanagerutil.getHomeFolder(),
        BookFormats.isSupported
    )
end

--- Upload one local book into the currently open Library folder.
---@param local_path string
function BooksBrowser:uploadBook(local_path)
    local uploading_message = InfoMessage:new{
        text = string.format(
            _("Uploading book…\n\n%s"),
            local_path
        ),
    }

    UIManager:show(uploading_message)

    UIManager:scheduleIn(0.1, function()
        local book, err = self.library:uploadBook(
            local_path,
            self:getCurrentFolderRef()
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

        UIManager:show(InfoMessage:new{
            text = string.format(
                _("Book uploaded successfully.\n\n%s"),
                book.name or _("Book")
            ),
            timeout = 4,
        })

        self:loadCurrentFolder()
    end)
end

--- Toggle Cloud storage+-style remote file selection mode.
function BooksBrowser:toggleSelectMode()
    if self.selected_books then
        for _index, item in ipairs(self.item_table) do
            item.dim = nil
        end
        self.selected_books = nil
        self:setTitleBarLeftIcon("appbar.menu")
        self:updateItems(1, true)
        return
    end

    self.selected_books = {}
    self:setTitleBarLeftIcon("check")
end

--- Show Delete / Select actions when a remote book is long-pressed.
---@param item table
function BooksBrowser:showBookHoldDialog(item)
    local dialog
    local book = item.book

    if not book then
        return
    end

    dialog = ButtonDialog:new{
        title = book.name or _("Book"),
        title_align = "center",
        buttons = {
            {
                {
                    text = _("Delete"),
                    callback = function()
                        UIManager:close(dialog)
                        self:showBookDeleteDialog(book)
                    end,
                },
                {
                    text = _("Select"),
                    callback = function()
                        UIManager:close(dialog)
                        self:toggleSelectMode()
                        self.selected_books[book.key] = book
                        item.dim = true
                        self:updateItems(1, true)
                    end,
                },
            },
        },
    }

    UIManager:show(dialog)
end

--- Confirm moving one remote book to Trash.
---@param book KOCloudLibraryEntry
function BooksBrowser:showBookDeleteDialog(book)
    local delete_note = self.library:usesTrash()
            and _("The file will be moved to Trash.")
        or _("This action cannot be undone.")

    UIManager:show(ConfirmBox:new{
        text = _("Delete this file?")
            .. "\n\n"
            .. (book.name or _("Book"))
            .. "\n\n"
            .. delete_note,
        ok_text = _("Delete"),
        ok_callback = function()
            NetworkMgr:runWhenOnline(function()
                self:deleteBook(book)
            end)
        end,
    })
end

--- Move one remote book to Trash and refresh the browser.
---@param book KOCloudLibraryEntry
function BooksBrowser:deleteBook(book)
    local deleting_message = InfoMessage:new{
        text = string.format(
            _("Deleting…\n\n%s"),
            book.name or _("Book")
        ),
    }

    UIManager:show(deleting_message)

    UIManager:scheduleIn(0.1, function()
        local success, err = self.library:deleteBook(book)

        UIManager:close(deleting_message)

        if not success then
            UIManager:show(InfoMessage:new{
                text = string.format(
                    _("Cannot delete book:\n\n%s"),
                    err or _("Unknown error")
                ),
            })
            return
        end

        if self.selected_books then
            self.selected_books[book.key] = nil
        end

        self:loadCurrentFolder()
    end)
end

--- Return selected remote books as an array.
---@return KOCloudLibraryEntry[] books
function BooksBrowser:getSelectedBooks()
    local books = {}

    if not self.selected_books then
        return books
    end

    for book_id, book in pairs(self.selected_books) do
        if book_id and book then
            table.insert(books, book)
        end
    end

    table.sort(books, function(left, right)
        return (left.name or "") < (right.name or "")
    end)

    return books
end

--- Show actions for Cloud storage+-style multi-select mode.
function BooksBrowser:showSelectModeDialog()
    local select_count = self.selected_books
        and util.tableSize(self.selected_books)
        or 0
    local actions_enabled = select_count > 0
    local dialog

    dialog = ButtonDialog:new{
        title = actions_enabled
                and T(
                    N_("1 book selected", "%1 books selected", select_count),
                    select_count
                )
            or _("No books selected"),
        title_align = "center",
        buttons = {
            {
                {
                    text = _("Delete"),
                    enabled = actions_enabled,
                    callback = function()
                        UIManager:close(dialog)
                        self:showSelectedBooksDeleteDialog()
                    end,
                },
                {
                    text = _("Download"),
                    enabled = actions_enabled,
                    callback = function()
                        UIManager:close(dialog)
                        self:showSelectedBooksDownloadDialog()
                    end,
                },
            },
            {},
            {
                {
                    text = _("Deselect all"),
                    enabled = actions_enabled,
                    callback = function()
                        UIManager:close(dialog)
                        self.selected_books = {}
                        for _index, item in ipairs(self.item_table) do
                            item.dim = nil
                        end
                        self:updateItems(1, true)
                    end,
                },
                {
                    text = _("Select all books in folder"),
                    callback = function()
                        UIManager:close(dialog)
                        for _index, item in ipairs(self.item_table) do
                            if item.book then
                                self.selected_books[item.book.key] = item.book
                                item.dim = true
                            end
                        end
                        self:updateItems(1, true)
                    end,
                },
            },
            {
                {
                    text = _("Exit select mode"),
                    callback = function()
                        UIManager:close(dialog)
                        self:toggleSelectMode()
                    end,
                },
            },
        },
    }

    UIManager:show(dialog)
end

--- Confirm and delete all selected books.
function BooksBrowser:showSelectedBooksDeleteDialog()
    local books = self:getSelectedBooks()
    local book_count = #books

    if book_count == 0 then
        return
    end

    local delete_note = self.library:usesTrash()
            and _("Files will be moved to Trash.")
        or _("This action cannot be undone.")

    UIManager:show(ConfirmBox:new{
        text = T(
            N_("Delete 1 book?", "Delete %1 books?", book_count),
            book_count
        ) .. "\n\n" .. delete_note,
        ok_text = _("Delete"),
        ok_callback = function()
            NetworkMgr:runWhenOnline(function()
                self:deleteSelectedBooks(books)
            end)
        end,
    })
end

--- Delete selected books while keeping failed items selected.
---@param books KOCloudLibraryEntry[]
function BooksBrowser:deleteSelectedBooks(books)
    local Trapper = require("ui/trapper")

    Trapper:wrap(function()
        local book_count = #books
        local success_count = 0
        local failure_count = 0

        for index, book in ipairs(books) do
            local text = string.format(
                _("Deleting book (%d/%d):\n%s"),
                index,
                book_count,
                book.name or _("Book")
            )

            if not Trapper:info(text) then
                break
            end

            local success = self.library:deleteBook(book)

            if success then
                self.selected_books[book.key] = nil
                success_count = success_count + 1
            else
                failure_count = failure_count + 1
            end
        end

        Trapper:clear()

        if not next(self.selected_books) then
            self:toggleSelectMode()
        end

        self:loadCurrentFolder()

        local text = T(
            N_("Deleted 1 book.", "Deleted %1 books.", success_count),
            success_count
        )

        if failure_count > 0 then
            text = text
                .. "\n"
                .. T(
                    N_(
                        "Could not delete 1 book.",
                        "Could not delete %1 books.",
                        failure_count
                    ),
                    failure_count
                )
        end

        UIManager:show(InfoMessage:new{ text = text })
    end)
end

--- Ask for one local folder and confirm downloading selected remote books.
---@param download_dir? string
function BooksBrowser:showSelectedBooksDownloadDialog(download_dir)
    local books = self:getSelectedBooks()
    local book_count = #books

    if book_count == 0 then
        return
    end

    download_dir = download_dir
        or self.last_download_dir
        or filemanagerutil.getHomeFolder()

    UIManager:show(MultiConfirmBox:new{
        text = T(
            N_("Download 1 book?", "Download %1 books?", book_count),
            book_count
        )
            .. "\n\n"
            .. _("Download folder:")
            .. "\n"
            .. download_dir
            .. "\n\n"
            .. _("Existing files will be overwritten."),
        choice1_text = _("Choose folder"),
        choice1_callback = function()
            filemanagerutil.showChooseDialog(
                _("Choose download folder"),
                function(path)
                    if path then
                        self.last_download_dir = path
                        self:showSelectedBooksDownloadDialog(path)
                    end
                end,
                nil,
                download_dir
            )
        end,
        choice2_text = _("Download"),
        choice2_callback = function()
            self.last_download_dir = download_dir
            NetworkMgr:runWhenOnline(function()
                self:downloadSelectedBooks(books, download_dir)
            end)
        end,
    })
end

--- Download selected books to one local folder.
---@param books KOCloudLibraryEntry[]
---@param download_dir string
function BooksBrowser:downloadSelectedBooks(books, download_dir)
    local Trapper = require("ui/trapper")

    Trapper:wrap(function()
        local book_count = #books
        local success_count = 0
        local failure_count = 0

        for index, book in ipairs(books) do
            local text = string.format(
                _("Downloading book (%d/%d):\n%s"),
                index,
                book_count,
                book.name or _("Book")
            )

            if not Trapper:info(text) then
                break
            end

            local filename = sanitizeLocalFilename(book.name or "book")
            local local_path = joinLocalPath(download_dir, filename)
            local success = self.library:downloadBook(book, local_path)

            if success then
                self.selected_books[book.key] = nil
                success_count = success_count + 1
            else
                failure_count = failure_count + 1
            end
        end

        Trapper:clear()

        if not next(self.selected_books) then
            self:toggleSelectMode()
        else
            self:loadCurrentFolder()
        end

        local text = T(
            N_("Downloaded 1 book.", "Downloaded %1 books.", success_count),
            success_count
        )

        if failure_count > 0 then
            text = text
                .. "\n"
                .. T(
                    N_(
                        "Could not download 1 book.",
                        "Could not download %1 books.",
                        failure_count
                    ),
                    failure_count
                )
        end

        UIManager:show(InfoMessage:new{ text = text })
    end)
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
            dim = self.selected_books
                and self.selected_books[book.key] ~= nil
                or nil,
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
        if self.selected_books then
            if self.selected_books[item.book.key] then
                self.selected_books[item.book.key] = nil
                item.dim = nil
            else
                self.selected_books[item.book.key] = item.book
                item.dim = true
            end
            self:updateItems(1, true)
        else
            self:showBookActions(item.book)
        end
    end

    return true
end

--- Match Cloud storage+ long-press behavior for remote files.
---@param item table
function BooksBrowser:onMenuHold(item)
    if item.book then
        if self.selected_books then
            self:showSelectModeDialog()
        else
            self:showBookHoldDialog(item)
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
