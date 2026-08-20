local JSON = require("json")
local http = require("socket.http")
local ltn12 = require("ltn12")
local socket = require("socket")
local socketutil = require("socketutil")
local url = require("socket.url")

local TOKEN_ENDPOINT = "https://oauth2.googleapis.com/token"
local EXPIRY_SAFETY_MARGIN_SECONDS = 60

--- OAuth token manager for the KOCloud Google Drive provider.
---
--- Initial user authorization is intentionally performed outside KOReader
--- with a Google Desktop OAuth client. KOReader keeps the resulting refresh
--- token and uses it to obtain short-lived access tokens.
---@class KOCloudGoogleDriveAuth
---@field config table Google Drive OAuth configuration and token state.
local Auth = {}
Auth.__index = Auth

--- Encode form fields for an application/x-www-form-urlencoded request.
---@param fields table<string, string>
---@return string
local function encodeForm(fields)
    local parts = {}

    for key, value in pairs(fields) do
        table.insert(
            parts,
            url.escape(key) .. "=" .. url.escape(value)
        )
    end

    return table.concat(parts, "&")
end

--- Create a Google Drive OAuth token manager.
---@param config? table Google Drive provider configuration.
---@return KOCloudGoogleDriveAuth
function Auth:new(config)
    local instance = setmetatable({}, self)
    instance.config = config or {}
    return instance
end

--- Return whether the minimum refresh-token configuration is available.
---@return boolean
function Auth:isConfigured()
    return type(self.config.client_id) == "string"
        and self.config.client_id ~= ""
        and type(self.config.refresh_token) == "string"
        and self.config.refresh_token ~= ""
end

--- Return the current mutable OAuth configuration.
---
--- The caller owns persistence of this table through KOCloudConfig.
---@return table
function Auth:getConfig()
    return self.config
end

--- Return a cached access token when it is still safely usable.
---@return string|nil
function Auth:getCachedAccessToken()
    local access_token = self.config.access_token
    local expires_at = tonumber(self.config.expires_at)

    if type(access_token) ~= "string" or access_token == "" then
        return nil
    end

    if not expires_at then
        return nil
    end

    if os.time() + EXPIRY_SAFETY_MARGIN_SECONDS >= expires_at then
        return nil
    end

    return access_token
end

--- Exchange the configured refresh token for a new Google access token.
---
--- This method updates `config.access_token` and `config.expires_at` in memory.
--- The caller must persist the updated config after a successful refresh.
---@return string|nil access_token
---@return string|nil error_message
function Auth:refreshAccessToken()
    if not self:isConfigured() then
        return nil, "Google Drive OAuth is not configured"
    end

    local fields = {
        client_id = self.config.client_id,
        refresh_token = self.config.refresh_token,
        grant_type = "refresh_token",
    }

    if type(self.config.client_secret) == "string"
        and self.config.client_secret ~= ""
    then
        fields.client_secret = self.config.client_secret
    end

    local body = encodeForm(fields)
    local sink = {}

    socketutil:set_timeout()

    local code, headers, status = socket.skip(1, http.request{
        url = TOKEN_ENDPOINT,
        method = "POST",
        headers = {
            ["Content-Type"] = "application/x-www-form-urlencoded",
            ["Content-Length"] = #body,
        },
        source = ltn12.source.string(body),
        sink = ltn12.sink.table(sink),
    })

    socketutil:reset_timeout()

    if headers == nil then
        return nil, status or code or "network unreachable"
    end

    local response_body = table.concat(sink)
    local ok, response = pcall(JSON.decode, response_body)

    if not ok or type(response) ~= "table" then
        return nil, "Invalid response from Google OAuth token endpoint"
    end

    if code ~= 200 then
        return nil,
            response.error_description
                or response.error
                or status
                or ("HTTP " .. tostring(code))
    end

    if type(response.access_token) ~= "string"
        or response.access_token == ""
    then
        return nil, "Google OAuth response did not contain an access token"
    end

    self.config.access_token = response.access_token

    local expires_in = tonumber(response.expires_in)
    if expires_in then
        self.config.expires_at = os.time() + expires_in
    else
        self.config.expires_at = nil
    end

    if type(response.refresh_token) == "string"
        and response.refresh_token ~= ""
    then
        self.config.refresh_token = response.refresh_token
    end

    return self.config.access_token, nil
end

--- Return a usable access token, refreshing it when necessary.
---
--- A successful refresh changes the in-memory config, so the caller should
--- persist `getConfig()` through KOCloudConfig.
---@return string|nil access_token
---@return string|nil error_message
function Auth:getAccessToken()
    local cached_token = self:getCachedAccessToken()

    if cached_token then
        return cached_token, nil
    end

    return self:refreshAccessToken()
end

--- Forget only the short-lived access token state.
---
--- The refresh token remains configured, allowing a new access token to be
--- obtained later without asking the user to authorize again.
function Auth:clearCachedAccessToken()
    self.config.access_token = nil
    self.config.expires_at = nil
end

return Auth
