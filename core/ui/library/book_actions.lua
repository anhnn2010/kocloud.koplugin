local BD = require("ui/bidi")
local BookFormats = require("core/book_formats")
local ButtonDialog = require("ui/widget/buttondialog")
local ConfirmBox = require("ui/widget/confirmbox")
local InfoMessage = require("ui/widget/infomessage")
local lfs = require("libs/libkoreader-lfs")
local NetworkMgr = require("ui/network/manager")
local PathChooser = require("ui/widget/pathchooser")
local UIManager = require("ui/uimanager")
local filemanagerutil = require("apps/filemanager/filemanagerutil")
local ffiUtil = require("ffi/util")
local util = require("util")
local _ = require("gettext")

--- Single-book UI actions for the KOCloud Library browser.
---@class KOCloudBookActions
---@field browser KOCloudBooksBrowser
---@field library KOCloudLibraryService
---@field last_upload_dir? string
local BookActions = {}
BookActions.__index = BookActions

---@param options table
---@return KOCloudBookActions
function BookActions:new(options)
    options = options or {}

    if not options.browser or not options.library then
        error("KOCloud BookActions requires browser and LibraryService")
    end

    return setmetatable({
        browser = options.browser,
        library = options.library,
    }, self)
end

--- Convert a remote file name into a safe local file name.
---@param name string
---@return string
function BookActions:sanitizeLocalFilename(name)
    local safe_name = name:gsub("[/\\]", "_")
    safe_name = safe_name:gsub("^%s+", "")
    safe_name = safe_name:gsub("%s+$", "")

    if safe_name == "" or safe_name == "." or safe_name == ".." then
        return "book"
    end

    return safe_name
end

--- Build a local path for a remote book.
---@param directory string
---@param book KOCloudLibraryEntry
---@return string
function BookActions:buildLocalPath(directory, book)
    local filename = self:sanitizeLocalFilename(book.name or "book")

    if directory:sub(-1) == "/" then
        return directory .. filename
    end

    return directory .. "/" .. filename
end

--- Show actions for one KOCloud-managed book.
---@param book KOCloudLibraryEntry
function BookActions:show(book)
    local dialog

    dialog = ButtonDialog:new{
        title = book.name or _("Book"),
        title_align = "center",
        buttons = {
            {
                {
                    text = _("Download"),
                    callback = function()
                        UIManager:close(dialog)
                        self:chooseDownloadFolder(book)
                    end,
                },
            },
            {
                {
                    text = _("Details"),
                    callback = function()
                        self:showDetails(book)
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
function BookActions:showDetails(book)
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
function BookActions:chooseDownloadFolder(book)
    local path_chooser
    path_chooser = PathChooser:new{
        select_directory = true,
        select_file = false,
        show_files = false,
        path = filemanagerutil.getHomeFolder(),
        onConfirm = function(directory)
            if not directory then
                return
            end

            self:confirmDownload(
                book,
                self:buildLocalPath(directory, book)
            )
        end,
    }

    UIManager:show(path_chooser)
end

--- Confirm overwrite when needed before downloading one book.
---@param book KOCloudLibraryEntry
---@param local_path string
function BookActions:confirmDownload(book, local_path)
    if lfs.attributes(local_path, "mode") ~= "file" then
        self:download(book, local_path)
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
            self:download(book, local_path)
        end,
    })
end

--- Download one Library book to local storage.
---@param book KOCloudLibraryEntry
---@param local_path string
function BookActions:download(book, local_path)
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

        self:showDownloadedDialog(local_path)
    end)
end

--- Ask whether a successfully downloaded book should be opened now.
--- This mirrors KOReader Cloud storage's post-download behavior.
---@param local_path string
function BookActions:showDownloadedDialog(local_path)
    local confirm_box = ConfirmBox:new{
        text = ffiUtil.template(
            _(
                "File saved to:\n%1\n"
                    .. "Would you like to read the downloaded book now?"
            ),
            BD.filepath(local_path)
        ),
        ok_text = _("Read now"),
        ok_callback = function()
            local Event = require("ui/event")
            local ReaderUI = require("apps/reader/readerui")

            UIManager:broadcastEvent(Event:new("SetupShowReader"))
            self.browser:onClose()
            ReaderUI:showReader(local_path)
        end,
    }

    -- The download message was just closed; defer the confirmation by one UI
    -- tick to avoid unnecessary e-Ink redraw congestion.
    UIManager:nextTick(function()
        UIManager:show(confirm_box)
    end)
end

--- Open KOReader's PathChooser directly for one supported local book.
function BookActions:chooseUpload()
    local path_chooser
    path_chooser = PathChooser:new{
        select_directory = false,
        select_file = true,
        show_files = true,
        file_filter = BookFormats.isSupported,
        path = self.last_upload_dir or filemanagerutil.getHomeFolder(),
        onConfirm = function(local_path)
            local directory = ffiUtil.dirname(local_path)
            if directory and directory ~= "" then
                self.last_upload_dir = directory
            end

            NetworkMgr:runWhenOnline(function()
                self:upload(local_path)
            end)
        end,
    }

    UIManager:show(path_chooser)
end

--- Upload one local book into the currently open Library folder.
---@param local_path string
function BookActions:upload(local_path)
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
            self.browser:getCurrentFolderRef()
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

        local uploaded_name = book.name or _("Book")

        self.browser:loadCurrentFolder(function()
            UIManager:show(InfoMessage:new{
                text = string.format(
                    _("Book uploaded successfully.\n\n%s"),
                    uploaded_name
                ),
                timeout = 4,
            })
        end)
    end)
end

--- Confirm moving one remote book to Trash or deleting it.
---@param book KOCloudLibraryEntry
function BookActions:showDeleteDialog(book)
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
                self:delete(book)
            end)
        end,
    })
end

--- Delete one remote book and refresh the browser.
---@param book KOCloudLibraryEntry
function BookActions:delete(book)
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

        self.browser:loadCurrentFolder()
    end)
end

return BookActions
