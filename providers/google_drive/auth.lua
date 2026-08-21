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
---
--- Only the long-lived refresh token belongs in persistent KOCloud settings.
--- Access tokens and their expiry timestamps are session state and are kept
--- only in memory.
---@class KOCloudGoogleDriveAuth
---@field config table Persistent user-specific Google Drive state.
---@field access_token? string Short-lived access token kept only in memory.
---@field expires_at? integer Access-token expiry kept only in memory.
---@field persistent_config_dirty boolean Whether auth changed persistent config.
local Auth = {}
Auth.__index = Auth

local LEGACY_TRANSIENT_KEYS = {
    "access_token",
    "expires_at",
    "scope",
    "token_type",
}

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

--- Remove transient token fields persisted by older KOCloud versions.
---@param config table
---@return boolean changed
local function removeLegacyTransientState(config)
    local changed = false

    for _, key in ipairs(LEGACY_TRANSIENT_KEYS) do
        if config[key] ~= nil then
            config[key] = nil
            changed = true
        end
    end

    return changed
end

--- Create a Google Drive OAuth token manager.
---@param config? table Persistent user-specific Google Drive state.
---@return KOCloudGoogleDriveAuth
function Auth:new(config)
    local instance = setmetatable({}, self)

    instance.config = config or {}
    instance.access_token = nil
    instance.expires_at = nil
    instance.persistent_config_dirty =
        removeLegacyTransientState(instance.config)

    return instance
end

--- Return whether KOCloud application OAuth credentials are available.
---@return boolean
function Auth:isClientConfigured()
    return OAuthClient:isConfigured()
end

--- Return whether Google Picker configuration is complete.
---@return boolean
function Auth:isPickerConfigured()
    return OAuthClient:isPickerConfigured()
end

--- Return Google Picker application configuration.
---@return table|nil config
function Auth:getPickerConfig()
    return OAuthClient:getPickerConfig()
end

--- Return the KOReader settings file that stores OAuth application credentials.
---@return string
function Auth:getClientSettingsFile()
    return OAuthClient:getSettingsFile()
end

--- Save Google OAuth application credentials entered through another setup UI.
---
--- When credentials change, the existing refresh token can no longer be
--- assumed to belong to the same OAuth client, so local authorization state
--- is cleared and the user must authorize again.
---@param client_id string
---@param client_secret string
---@return table|nil credentials
---@return boolean changed
---@return string|nil error_message
function Auth:setClientCredentials(
    client_id,
    client_secret,
    picker_api_key
)
    local old_client_id = OAuthClient.CLIENT_ID
    local old_client_secret = OAuthClient.CLIENT_SECRET

    local saved, save_error =
        OAuthClient:saveCredentials(
            client_id,
            client_secret,
            picker_api_key
        )

    if not saved then
        return nil, false, save_error
    end

    local changed = old_client_id ~= client_id
        or old_client_secret ~= client_secret

    if changed and self:isAuthorized() then
        self:clearAuthorization()
    end

    return {
        client_id = client_id,
        client_secret = client_secret,
        changed = changed,
    }, changed, nil
end

--- Import a Google OAuth credentials JSON file.
---
--- When credentials change, the existing refresh token can no longer be
--- assumed to belong to the same OAuth client, so local authorization state
--- is cleared and the user must authorize again.
---@param json_path string
---@return table|nil credentials
---@return boolean changed
---@return string|nil error_message
function Auth:importClientCredentials(json_path)
    local credentials, import_error =
        OAuthClient:importFromJsonFile(json_path)

    if not credentials then
        return nil, false, import_error
    end

    if credentials.changed and self:isAuthorized() then
        self:clearAuthorization()
    end

    return credentials, credentials.changed, nil
end

--- Remove saved OAuth application credentials and local authorization state.
---@return boolean success
---@return string|nil error_message
function Auth:clearClientCredentials()
    self:clearAuthorization()
    return OAuthClient:clearCredentials()
end

--- Return whether this user has already connected Google Drive.
---@return boolean
function Auth:isAuthorized()
    return type(self.config.refresh_token) == "string"
        and self.config.refresh_token ~= ""
end

--- Return whether persistent auth configuration needs to be saved.
---@return boolean
function Auth:isPersistentConfigDirty()
    return self.persistent_config_dirty
end

--- Mark persistent auth configuration as saved.
function Auth:markPersistentConfigSaved()
    self.persistent_config_dirty = false
end

--- Return the current mutable persistent user configuration.
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
        self.access_token = response.access_token

        local expires_in = tonumber(response.expires_in)
        if expires_in then
            self.expires_at = now + expires_in
        else
            self.expires_at = nil
        end

        local refresh_token = response.refresh_token

        if type(refresh_token) ~= "string" or refresh_token == "" then
            return {
                status = "error",
                error_message = "Google did not return a refresh token",
            }
        end

        if self.config.refresh_token ~= refresh_token then
            self.config.refresh_token = refresh_token
            self.persistent_config_dirty = true
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
    if type(self.access_token) ~= "string"
        or self.access_token == ""
    then
        return nil
    end

    if not self.expires_at then
        return nil
    end

    if os.time() + EXPIRY_SAFETY_MARGIN_SECONDS >= self.expires_at then
        return nil
    end

    return self.access_token
end

--- Exchange the stored refresh token for a new in-memory access token.
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

    self.access_token = response.access_token

    local expires_in = tonumber(response.expires_in)
    if expires_in then
        self.expires_at = os.time() + expires_in
    else
        self.expires_at = nil
    end

    return self.access_token, nil
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
    self.access_token = nil
    self.expires_at = nil
end

--- Forget all user-specific Google OAuth token state.
---
--- This only removes local state. Token revocation will be added separately.
function Auth:clearAuthorization()
    self:clearCachedAccessToken()

    if self.config.refresh_token ~= nil then
        self.config.refresh_token = nil
        self.persistent_config_dirty = true
    end
end

return Auth
