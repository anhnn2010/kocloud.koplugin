local JSON = require("json")
local http = require("socket.http")
local ltn12 = require("ltn12")
local socket = require("socket")
local socketutil = require("socketutil")
local url = require("socket.url")

local OAuthClient = require("providers/google_drive/oauth_client")

local DEVICE_CODE_ENDPOINT = "https://oauth2.googleapis.com/device/code"
local TOKEN_ENDPOINT = "https://oauth2.googleapis.com/token"

local DEVICE_GRANT_TYPE = "urn:ietf:params:oauth:grant-type:device_code"
local REFRESH_GRANT_TYPE = "refresh_token"
local EXPIRY_SAFETY_MARGIN_SECONDS = 60

--- Device authorization state returned by Google.
---@class KOCloudGoogleDriveDeviceSession
---@field device_code string
---@field user_code string
---@field verification_url string
---@field expires_at integer Unix timestamp.
---@field interval integer Polling interval in seconds.
---@field next_poll_at integer Earliest Unix timestamp for the next poll.

--- Result of one device authorization polling attempt.
---@class KOCloudGoogleDrivePollResult
---@field status "authorized"|"pending"|"slow_down"|"denied"|"expired"|"error"
---@field retry_after? integer Seconds before the next poll.
---@field error_message? string Human-readable failure detail.

--- OAuth token manager for the KOCloud Google Drive provider.
---@class KOCloudGoogleDriveAuth
---@field config table User-specific Google Drive token state.
local Auth = {}
Auth.__index = Auth

--- Encode fields for an application/x-www-form-urlencoded request.
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

--- POST form data and decode the JSON response.
---@param endpoint string
---@param fields table<string, string>
---@return integer|nil status_code
---@return table|nil response
---@return string|nil error_message
local function postForm(endpoint, fields)
    local body = encodeForm(fields)
    local sink = {}

    socketutil:set_timeout()

    local code, headers, status = socket.skip(1, http.request{
        url = endpoint,
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
        return nil, nil, status or tostring(code) or "network unreachable"
    end

    local response_body = table.concat(sink)
    local ok, response = pcall(JSON.decode, response_body)

    if not ok or type(response) ~= "table" then
        return tonumber(code), nil, "Invalid JSON response from Google OAuth"
    end

    return tonumber(code), response, nil
end

--- Create a Google Drive OAuth token manager.
---@param config? table User-specific Google Drive token state.
---@return KOCloudGoogleDriveAuth
function Auth:new(config)
    local instance = setmetatable({}, self)
    instance.config = config or {}
    return instance
end

--- Return whether KOCloud application OAuth credentials are available.
---@return boolean
function Auth:isClientConfigured()
    return OAuthClient:isConfigured()
end

--- Return whether this user has already connected Google Drive.
---@return boolean
function Auth:isAuthorized()
    return type(self.config.refresh_token) == "string"
        and self.config.refresh_token ~= ""
end

--- Return whether this user has completed Google Drive authorization.
---
--- Kept as the public compatibility method used by GoogleDriveProvider.
---@return boolean
function Auth:isConfigured()
    return self:isAuthorized()
end

--- Return the current mutable user token configuration.
---
--- The caller owns persistence of this table through KOCloudConfig.
---@return table
function Auth:getConfig()
    return self.config
end

--- Request a new Google device authorization session.
---@return KOCloudGoogleDriveDeviceSession|nil session
---@return string|nil error_message
function Auth:requestDeviceAuthorization()
    if not self:isClientConfigured() then
        return nil, "KOCloud Google OAuth client is not configured"
    end

    local code, response, request_error = postForm(
        DEVICE_CODE_ENDPOINT,
        {
            client_id = OAuthClient.CLIENT_ID,
            scope = OAuthClient:getScopeString(),
        }
    )

    if request_error then
        return nil, request_error
    end

    if code ~= 200 then
        return nil,
            response.error_description
                or response.error
                or response.error_code
                or ("HTTP " .. tostring(code))
    end

    if type(response.device_code) ~= "string"
        or type(response.user_code) ~= "string"
        or type(response.verification_url) ~= "string"
    then
        return nil, "Google returned an incomplete device authorization response"
    end

    local expires_in = tonumber(response.expires_in)
    local interval = tonumber(response.interval)

    if not expires_in or expires_in <= 0 then
        return nil, "Google returned an invalid device-code expiry"
    end

    if not interval or interval <= 0 then
        interval = 5
    end

    local now = os.time()

    ---@type KOCloudGoogleDriveDeviceSession
    local session = {
        device_code = response.device_code,
        user_code = response.user_code,
        verification_url = response.verification_url,
        expires_at = now + expires_in,
        interval = interval,
        next_poll_at = now + interval,
    }

    return session, nil
end

--- Poll Google once for the result of a device authorization session.
---
--- This method intentionally performs only one request. The UI layer should
--- schedule subsequent calls according to `retry_after` so KOReader remains
--- responsive while the user authorizes from a phone or browser.
---@param session KOCloudGoogleDriveDeviceSession
---@return KOCloudGoogleDrivePollResult
function Auth:pollDeviceAuthorization(session)
    local now = os.time()

    if now >= session.expires_at then
        return {
            status = "expired",
            error_message = "Google device authorization code expired",
        }
    end

    if now < session.next_poll_at then
        return {
            status = "pending",
            retry_after = session.next_poll_at - now,
        }
    end

    local code, response, request_error = postForm(
        TOKEN_ENDPOINT,
        {
            client_id = OAuthClient.CLIENT_ID,
            client_secret = OAuthClient.CLIENT_SECRET,
            device_code = session.device_code,
            grant_type = DEVICE_GRANT_TYPE,
        }
    )

    if request_error then
        session.next_poll_at = now + session.interval
        return {
            status = "error",
            retry_after = session.interval,
            error_message = request_error,
        }
    end

    if code == 200 and type(response.access_token) == "string" then
        self.config.access_token = response.access_token
        self.config.refresh_token = response.refresh_token
            or self.config.refresh_token

        local expires_in = tonumber(response.expires_in)
        if expires_in then
            self.config.expires_at = now + expires_in
        else
            self.config.expires_at = nil
        end

        self.config.scope = response.scope
        self.config.token_type = response.token_type

        if type(self.config.refresh_token) ~= "string"
            or self.config.refresh_token == ""
        then
            return {
                status = "error",
                error_message = "Google did not return a refresh token",
            }
        end

        return {
            status = "authorized",
        }
    end

    local oauth_error = response and response.error or nil

    if oauth_error == "authorization_pending" then
        session.next_poll_at = now + session.interval
        return {
            status = "pending",
            retry_after = session.interval,
        }
    end

    if oauth_error == "slow_down" then
        session.interval = session.interval + 5
        session.next_poll_at = now + session.interval
        return {
            status = "slow_down",
            retry_after = session.interval,
        }
    end

    if oauth_error == "access_denied" then
        return {
            status = "denied",
            error_message = response.error_description
                or "Google Drive authorization was denied",
        }
    end

    return {
        status = "error",
        error_message = response.error_description
            or oauth_error
            or ("HTTP " .. tostring(code)),
    }
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

--- Exchange the stored refresh token for a new access token.
---@return string|nil access_token
---@return string|nil error_message
function Auth:refreshAccessToken()
    if not self:isClientConfigured() then
        return nil, "KOCloud Google OAuth client is not configured"
    end

    if not self:isAuthorized() then
        return nil, "Google Drive is not authorized"
    end

    local code, response, request_error = postForm(
        TOKEN_ENDPOINT,
        {
            client_id = OAuthClient.CLIENT_ID,
            client_secret = OAuthClient.CLIENT_SECRET,
            refresh_token = self.config.refresh_token,
            grant_type = REFRESH_GRANT_TYPE,
        }
    )

    if request_error then
        return nil, request_error
    end

    if code ~= 200 then
        return nil,
            response.error_description
                or response.error
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

    if type(response.scope) == "string" then
        self.config.scope = response.scope
    end

    if type(response.token_type) == "string" then
        self.config.token_type = response.token_type
    end

    return self.config.access_token, nil
end

--- Return a usable Google OAuth access token.
---@return string|nil access_token
---@return string|nil error_message
function Auth:getAccessToken()
    local cached_token = self:getCachedAccessToken()

    if cached_token then
        return cached_token, nil
    end

    return self:refreshAccessToken()
end

--- Forget short-lived access-token state but keep authorization.
function Auth:clearCachedAccessToken()
    self.config.access_token = nil
    self.config.expires_at = nil
end

--- Forget all user-specific Google OAuth token state.
---
--- This only removes local state. Token revocation will be added separately.
function Auth:clearAuthorization()
    self.config.access_token = nil
    self.config.refresh_token = nil
    self.config.expires_at = nil
    self.config.scope = nil
    self.config.token_type = nil
end

return Auth
