local JSON = require("json")
local http = require("socket.http")
local ltn12 = require("ltn12")
local socket = require("socket")
local socketutil = require("socketutil")
local url = require("socket.url")

local DRIVE_FILES_ENDPOINT = "https://www.googleapis.com/drive/v3/files"

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

    return status or ("HTTP " .. tostring(code))
end

--- Perform an authenticated Google Drive request and decode JSON.
---@param method "GET"|"POST"
---@param request_url string
---@param access_token string
---@param body? table
---@return integer|nil status_code
---@return table|nil response
---@return string|nil error_message
local function requestJson(method, request_url, access_token, body)
    local sink = {}
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
        sink = ltn12.sink.table(sink),
    }

    if encoded_body then
        request.source = ltn12.source.string(encoded_body)
    end

    socketutil:set_timeout()

    local ok, code, response_headers, status = pcall(function()
        return socket.skip(1, http.request(request))
    end)

    socketutil:reset_timeout()

    if not ok then
        return nil, nil, tostring(code)
    end

    code = tonumber(code)

    if response_headers == nil then
        return nil, nil, status or "network unreachable"
    end

    local response_body = table.concat(sink)
    local response, decode_error = decodeJson(response_body)

    if not response then
        return code, nil, decode_error
    end

    if not code or code < 200 or code >= 300 then
        return code, response, getApiError(response, status, code)
    end

    return code, response, nil
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

return DriveApi
