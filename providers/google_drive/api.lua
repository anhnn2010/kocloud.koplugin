local JSON = require("json")
local http = require("socket.http")
local ltn12 = require("ltn12")
local socket = require("socket")
local socketutil = require("socketutil")
local url = require("socket.url")

local DRIVE_FILES_ENDPOINT = "https://www.googleapis.com/drive/v3/files"
local DRIVE_UPLOAD_ENDPOINT =
    "https://www.googleapis.com/upload/drive/v3/files"

local UPLOAD_CHUNK_SIZE = 1024 * 1024 -- 1 MiB, multiple of 256 KiB.

--- Google Drive file metadata used by KOCloud.
---@class KOCloudGoogleDriveFile
---@field id string
---@field name string
---@field mimeType string
---@field parents? string[]
---@field appProperties? table<string, string>
---@field size? string
---@field modifiedTime? string

--- Google Drive files.list response.
---@class KOCloudGoogleDriveFileList
---@field files KOCloudGoogleDriveFile[]
---@field nextPageToken? string

--- Options for files.list.
---@class KOCloudGoogleDriveListOptions
---@field spaces? string Drive space to search. Defaults to "drive".
---@field fields? string Partial-response fields selector.
---@field page_size? integer Number of files requested per page.
---@field page_token? string Token for the next result page.
---@field order_by? string Google Drive orderBy expression.

--- Low-level Google Drive REST API client for KOCloud.
---@class KOCloudGoogleDriveApi
local DriveApi = {}

DriveApi.FOLDER_MIME_TYPE = "application/vnd.google-apps.folder"

local DEFAULT_LIST_FIELDS =
    "nextPageToken,"
    .. "files(id,name,mimeType,parents,appProperties,size,modifiedTime)"

--- Encode a URL query parameter.
---@param value string
---@return string
local function encodeQueryValue(value)
    return url.escape(value)
end

--- Decode a JSON response body.
---@param response_body string
---@return table|nil response
---@return string|nil error_message
local function decodeJson(response_body)
    if response_body == "" then
        return {}, nil
    end

    local ok, response = pcall(JSON.decode, response_body)

    if not ok or type(response) ~= "table" then
        return nil, "Invalid JSON response from Google Drive"
    end

    return response, nil
end

--- Return a useful Google Drive API error message.
---@param response table|nil
---@param status string|number|nil
---@param code integer|nil
---@return string
local function getApiError(response, status, code)
    if response
        and type(response.error) == "table"
        and type(response.error.message) == "string"
    then
        return response.error.message
    end

    if status then
        return tostring(status)
    end

    return "HTTP " .. tostring(code)
end

--- Perform a raw HTTP request.
---@param request table LuaSocket request table.
---@return integer|nil status_code
---@return table|nil response_headers
---@return string response_body
---@return string|nil error_message
local function requestRaw(request)
    local sink = {}

    request.sink = request.sink or ltn12.sink.table(sink)

    socketutil:set_timeout()

    local ok, code, response_headers, status = pcall(function()
        return socket.skip(1, http.request(request))
    end)

    socketutil:reset_timeout()

    if not ok then
        return nil, nil, "", tostring(code)
    end

    code = tonumber(code)

    if response_headers == nil then
        return nil, nil, "", status or "network unreachable"
    end

    return code, response_headers, table.concat(sink), nil
end

--- Perform an authenticated Google Drive request and decode JSON.
---@param method "GET"|"POST"|"PATCH"
---@param request_url string
---@param access_token string
---@param body? table
---@return integer|nil status_code
---@return table|nil response
---@return string|nil error_message
local function requestJson(method, request_url, access_token, body)
    local encoded_body

    local headers = {
        ["Authorization"] = "Bearer " .. access_token,
        ["Accept"] = "application/json",
    }

    if body then
        local ok, result = pcall(JSON.encode, body)

        if not ok or type(result) ~= "string" then
            return nil, nil, "Unable to encode Google Drive request"
        end

        encoded_body = result
        headers["Content-Type"] = "application/json"
        headers["Content-Length"] = #encoded_body
    end

    local request = {
        url = request_url,
        method = method,
        headers = headers,
    }

    if encoded_body then
        request.source = ltn12.source.string(encoded_body)
    end

    local code, _, response_body, request_error = requestRaw(request)

    if request_error then
        return nil, nil, request_error
    end

    local response, decode_error = decodeJson(response_body)

    if not response then
        return code, nil, decode_error
    end

    if not code or code < 200 or code >= 300 then
        return code, response, getApiError(response, nil, code)
    end

    return code, response, nil
end

--- Return a local file's size in bytes.
---@param local_path string
---@return integer|nil size
---@return string|nil error_message
local function getFileSize(local_path)
    local file, open_error = io.open(local_path, "rb")

    if not file then
        return nil, open_error or "Unable to open local file"
    end

    local size, seek_error = file:seek("end")
    file:close()

    if not size then
        return nil, seek_error or "Unable to determine local file size"
    end

    return size, nil
end

--- List files visible to the KOCloud OAuth client.
---@param access_token string
---@param query? string Google Drive `q` expression.
---@param options? KOCloudGoogleDriveListOptions
---@return KOCloudGoogleDriveFileList|nil result
---@return string|nil error_message
function DriveApi:listFiles(access_token, query, options)
    options = options or {}

    local params = {
        "spaces=" .. encodeQueryValue(options.spaces or "drive"),
        "fields=" .. encodeQueryValue(
            options.fields or DEFAULT_LIST_FIELDS
        ),
        "pageSize=" .. tostring(options.page_size or 100),
    }

    if query and query ~= "" then
        table.insert(params, "q=" .. encodeQueryValue(query))
    end

    if options.page_token and options.page_token ~= "" then
        table.insert(
            params,
            "pageToken=" .. encodeQueryValue(options.page_token)
        )
    end

    if options.order_by and options.order_by ~= "" then
        table.insert(
            params,
            "orderBy=" .. encodeQueryValue(options.order_by)
        )
    end

    local request_url =
        DRIVE_FILES_ENDPOINT .. "?" .. table.concat(params, "&")

    local _, response, err = requestJson(
        "GET",
        request_url,
        access_token
    )

    if not response then
        return nil, err
    end

    response.files = response.files or {}
    return response, nil
end

--- Create a folder in Google Drive.
---@param access_token string
---@param name string Folder name.
---@param parent_id? string Parent folder ID. Omit to create in My Drive root.
---@param app_properties? table<string, string> Private app metadata.
---@return KOCloudGoogleDriveFile|nil folder
---@return string|nil error_message
function DriveApi:createFolder(
    access_token,
    name,
    parent_id,
    app_properties
)
    local metadata = {
        name = name,
        mimeType = self.FOLDER_MIME_TYPE,
    }

    if parent_id and parent_id ~= "" then
        metadata.parents = { parent_id }
    end

    if app_properties then
        metadata.appProperties = app_properties
    end

    local fields =
        "id,name,mimeType,parents,appProperties,modifiedTime"
    local request_url =
        DRIVE_FILES_ENDPOINT
        .. "?fields="
        .. encodeQueryValue(fields)

    local _, response, err = requestJson(
        "POST",
        request_url,
        access_token,
        metadata
    )

    if not response then
        return nil, err
    end

    return response, nil
end

--- Start a resumable Google Drive file upload.
---@param access_token string
---@param name string Remote file name.
---@param parent_id string Parent folder ID.
---@param mime_type string File MIME type.
---@param file_size integer File size in bytes.
---@param app_properties? table<string, string> Private app metadata.
---@return string|nil session_url
---@return string|nil error_message
function DriveApi:startResumableUpload(
    access_token,
    name,
    parent_id,
    mime_type,
    file_size,
    app_properties
)
    local metadata = {
        name = name,
        parents = { parent_id },
    }

    if app_properties then
        metadata.appProperties = app_properties
    end

    local ok, encoded_metadata = pcall(JSON.encode, metadata)

    if not ok or type(encoded_metadata) ~= "string" then
        return nil, "Unable to encode upload metadata"
    end

    local request_url =
        DRIVE_UPLOAD_ENDPOINT
        .. "?uploadType=resumable"
        .. "&fields="
        .. encodeQueryValue(
            "id,name,mimeType,parents,appProperties,size,modifiedTime"
        )

    local code, headers, response_body, request_error = requestRaw{
        url = request_url,
        method = "POST",
        headers = {
            ["Authorization"] = "Bearer " .. access_token,
            ["Accept"] = "application/json",
            ["Content-Type"] = "application/json; charset=UTF-8",
            ["Content-Length"] = #encoded_metadata,
            ["X-Upload-Content-Type"] = mime_type,
            ["X-Upload-Content-Length"] = file_size,
        },
        source = ltn12.source.string(encoded_metadata),
    }

    if request_error then
        return nil, request_error
    end

    if not code or code < 200 or code >= 300 then
        local response = decodeJson(response_body)
        return nil, getApiError(response, nil, code)
    end

    local session_url = headers.location or headers.Location

    if type(session_url) ~= "string" or session_url == "" then
        return nil, "Google Drive did not return an upload session URL"
    end

    return session_url, nil
end

--- Upload a local file using a resumable Google Drive session.
---
--- Data is read in 1 MiB chunks, so the full book is never loaded into RAM.
---@param access_token string
---@param local_path string
---@param name string Remote file name.
---@param parent_id string Parent folder ID.
---@param mime_type? string File MIME type.
---@param app_properties? table<string, string> Private app metadata.
---@return KOCloudGoogleDriveFile|nil file
---@return string|nil error_message
function DriveApi:uploadFile(
    access_token,
    local_path,
    name,
    parent_id,
    mime_type,
    app_properties
)
    mime_type = mime_type or "application/octet-stream"

    local file_size, size_error = getFileSize(local_path)

    if not file_size then
        return nil, size_error
    end

    local session_url, session_error = self:startResumableUpload(
        access_token,
        name,
        parent_id,
        mime_type,
        file_size,
        app_properties
    )

    if not session_url then
        return nil, session_error
    end

    local file, open_error = io.open(local_path, "rb")

    if not file then
        return nil, open_error or "Unable to open local file"
    end

    local offset = 0

    while offset < file_size do
        local chunk = file:read(
            math.min(UPLOAD_CHUNK_SIZE, file_size - offset)
        )

        if not chunk or #chunk == 0 then
            file:close()
            return nil, "Unexpected end of local file during upload"
        end

        local chunk_start = offset
        local chunk_end = offset + #chunk - 1

        local code, headers, response_body, request_error = requestRaw{
            url = session_url,
            method = "PUT",
            headers = {
                ["Authorization"] = "Bearer " .. access_token,
                ["Content-Type"] = mime_type,
                ["Content-Length"] = #chunk,
                ["Content-Range"] = string.format(
                    "bytes %d-%d/%d",
                    chunk_start,
                    chunk_end,
                    file_size
                ),
            },
            source = ltn12.source.string(chunk),
        }

        if request_error then
            file:close()
            return nil, request_error
        end

        if code == 200 or code == 201 then
            file:close()

            local response, decode_error = decodeJson(response_body)

            if not response then
                return nil, decode_error
            end

            return response, nil
        end

        if code ~= 308 then
            file:close()

            local response = decodeJson(response_body)
            return nil, getApiError(response, nil, code)
        end

        local range = headers.range or headers.Range
        local received_end

        if type(range) == "string" then
            received_end = tonumber(
                range:match("bytes=%d+%-(%d+)")
                    or range:match("%d+%-(%d+)")
            )
        end

        if received_end then
            offset = received_end + 1
        else
            offset = chunk_end + 1
        end

        local seek_ok, seek_error = file:seek("set", offset)

        if not seek_ok then
            file:close()
            return nil, seek_error or "Unable to seek local upload file"
        end
    end

    file:close()
    return nil, "Google Drive upload ended without a final response"
end

--- Move a Google Drive file to Trash.
---@param access_token string
---@param file_id string Google Drive file ID.
---@return boolean success
---@return string|nil error_message
function DriveApi:trashFile(access_token, file_id)
    if type(file_id) ~= "string" or file_id == "" then
        return false, "Google Drive file ID is required"
    end

    local request_url =
        DRIVE_FILES_ENDPOINT
        .. "/"
        .. encodeQueryValue(file_id)
        .. "?fields="
        .. encodeQueryValue("id,name,trashed")

    local _, response, err = requestJson(
        "PATCH",
        request_url,
        access_token,
        {
            trashed = true,
        }
    )

    if not response then
        return false, err
    end

    return true, nil
end

--- Download a Google Drive blob file to a local path.
---
--- Content is first written to `<local_path>.part` and renamed only after a
--- successful HTTP response, avoiding partially downloaded books appearing
--- as complete local files.
---@param access_token string
---@param file_id string Google Drive file ID.
---@param local_path string Destination path.
---@return boolean success
---@return string|nil error_message
function DriveApi:downloadFile(access_token, file_id, local_path)
    local temp_path = local_path .. ".part"
    local output, open_error = io.open(temp_path, "wb")

    if not output then
        return false, open_error or "Unable to create local download file"
    end

    local request_url =
        DRIVE_FILES_ENDPOINT
        .. "/"
        .. encodeQueryValue(file_id)
        .. "?alt=media"

    socketutil:set_timeout()

    local ok, code, response_headers, status = pcall(function()
        return socket.skip(1, http.request{
            url = request_url,
            method = "GET",
            headers = {
                ["Authorization"] = "Bearer " .. access_token,
            },
            sink = ltn12.sink.file(output),
        })
    end)

    socketutil:reset_timeout()

    if not ok then
        pcall(output.close, output)
        os.remove(temp_path)
        return false, tostring(code)
    end

    code = tonumber(code)

    if response_headers == nil or not code or code < 200 or code >= 300 then
        pcall(output.close, output)
        os.remove(temp_path)
        return false, status or ("HTTP " .. tostring(code))
    end

    local renamed, rename_error = os.rename(temp_path, local_path)

    if not renamed then
        os.remove(temp_path)
        return false, rename_error or "Unable to finalize downloaded file"
    end

    return true, nil
end

return DriveApi
