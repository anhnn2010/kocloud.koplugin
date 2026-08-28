local ButtonDialog = require("ui/widget/buttondialog")
local ConfirmBox = require("ui/widget/confirmbox")
local InfoMessage = require("ui/widget/infomessage")
local MultiConfirmBox = require("ui/widget/multiconfirmbox")
local NetworkMgr = require("ui/network/manager")
local PathChooser = require("ui/widget/pathchooser")
local UIManager = require("ui/uimanager")
local filemanagerutil = require("apps/filemanager/filemanagerutil")
local ffiUtil = require("ffi/util")
local util = require("util")
local _ = require("gettext")
local N_ = _.ngettext
local T = ffiUtil.template

--- Multi-select UI actions for the KOCloud Library browser.
---@class KOCloudSelectionActions
---@field browser KOCloudBooksBrowser
---@field library KOCloudLibraryService
---@field book_actions KOCloudBookActions
---@field selected_books? table<string, KOCloudLibraryEntry>
---@field last_download_dir? string
local SelectionActions = {}
SelectionActions.__index = SelectionActions

---@param options table
---@return KOCloudSelectionActions
function SelectionActions:new(options)
    options = options or {}

    if not options.browser or not options.library or not options.book_actions then
        error(
            "KOCloud SelectionActions requires browser, LibraryService, "
                .. "and BookActions"
        )
    end

    return setmetatable({
        browser = options.browser,
        library = options.library,
        book_actions = options.book_actions,
    }, self)
end

--- Return whether multi-select mode is active.
---@return boolean
function SelectionActions:isActive()
    return self.selected_books ~= nil
end

--- Return whether a book is selected.
---@param book KOCloudLibraryEntry
---@return boolean
function SelectionActions:isSelected(book)
    return self.selected_books ~= nil
        and self.selected_books[book.key] ~= nil
end

--- Toggle Cloud storage+-style remote file selection mode.
function SelectionActions:toggle()
    local browser = self.browser

    if self.selected_books then
        for _index, item in ipairs(browser.item_table) do
            item.dim = nil
        end
        self.selected_books = nil
        browser:setTitleBarLeftIcon("appbar.menu")
        browser:updateItems(1, true)
        return
    end

    self.selected_books = {}
    browser:setTitleBarLeftIcon("check")
end

--- Toggle one book while selection mode is active.
---@param item table
function SelectionActions:toggleItem(item)
    local browser = self.browser
    local book = item.book

    if not self.selected_books or not book then
        return
    end

    if self.selected_books[book.key] then
        self.selected_books[book.key] = nil
        item.dim = nil
    else
        self.selected_books[book.key] = book
        item.dim = true
    end

    browser:updateItems(1, true)
end

--- Show Delete / Select actions when a remote book is long-pressed.
---@param item table
function SelectionActions:showBookHoldDialog(item)
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
                        self.book_actions:showDeleteDialog(book)
                    end,
                },
                {
                    text = _("Select"),
                    callback = function()
                        UIManager:close(dialog)
                        self:toggle()
                        self.selected_books[book.key] = book
                        item.dim = true
                        self.browser:updateItems(1, true)
                    end,
                },
            },
        },
    }

    UIManager:show(dialog)
end

--- Return selected remote books as an array.
---@return KOCloudLibraryEntry[] books
function SelectionActions:getSelectedBooks()
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
function SelectionActions:showDialog()
    local browser = self.browser
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
                        self:showDeleteDialog()
                    end,
                },
                {
                    text = _("Download"),
                    enabled = actions_enabled,
                    callback = function()
                        UIManager:close(dialog)
                        self:showDownloadDialog()
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
                        for _index, item in ipairs(browser.item_table) do
                            item.dim = nil
                        end
                        browser:updateItems(1, true)
                    end,
                },
                {
                    text = _("Select all books in folder"),
                    callback = function()
                        UIManager:close(dialog)
                        for _index, item in ipairs(browser.item_table) do
                            if item.book then
                                self.selected_books[item.book.key] = item.book
                                item.dim = true
                            end
                        end
                        browser:updateItems(1, true)
                    end,
                },
            },
            {
                {
                    text = _("Exit select mode"),
                    callback = function()
                        UIManager:close(dialog)
                        self:toggle()
                    end,
                },
            },
        },
    }

    UIManager:show(dialog)
end

--- Confirm and delete all selected books.
function SelectionActions:showDeleteDialog()
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
                self:deleteBooks(books)
            end)
        end,
    })
end

--- Delete selected books while keeping failed items selected.
---@param books KOCloudLibraryEntry[]
function SelectionActions:deleteBooks(books)
    local Trapper = require("ui/trapper")
    local browser = self.browser

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
            self:toggle()
        end

        browser:loadCurrentFolder()

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
function SelectionActions:showDownloadDialog(download_dir)
    local browser = self.browser
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
            local path_chooser
            path_chooser = PathChooser:new{
                select_directory = true,
                select_file = false,
                show_files = false,
                path = download_dir,
                onConfirm = function(path)
                    if path then
                        self.last_download_dir = path
                        self:showDownloadDialog(path)
                    end
                end,
            }

            UIManager:show(path_chooser)
        end,
        choice2_text = _("Download"),
        choice2_callback = function()
            self.last_download_dir = download_dir
            NetworkMgr:runWhenOnline(function()
                self:downloadBooks(books, download_dir)
            end)
        end,
    })
end

--- Download selected books to one local folder.
---@param books KOCloudLibraryEntry[]
---@param download_dir string
function SelectionActions:downloadBooks(books, download_dir)
    local Trapper = require("ui/trapper")
    local browser = self.browser

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

            local local_path = self.book_actions:buildLocalPath(
                download_dir,
                book
            )
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
            self:toggle()
        else
            browser:loadCurrentFolder()
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

return SelectionActions
