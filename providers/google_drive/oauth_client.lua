local DataStorage = require("datastorage")
local JSON = require("json")
local LuaSettings = require("luasettings")

--- Google OAuth / Picker application configuration for KOCloud.
---
--- Each KOCloud user owns their own Google Cloud project. Configuration is
--- stored outside the plugin in KOReader's settings directory:
---   <KOReader settings>/kocloud_oauth_client.lua
---
--- User OAuth tokens are NOT stored here.
---@class KOCloudGoogleOAuthClient
local OAuthClient = {}

OAuthClient.SETTINGS_FILE =
    DataStorage:getSettingsDir() .. "/kocloud_oauth_client.lua"

OAuthClient.SCOPES = {
    "https://www.googleapis.com/auth/drive.file",
}

OAuthClient.CLIENT_ID = nil
OAuthClient.CLIENT_SECRET = nil
OAuthClient.PICKER_API_KEY = nil
OAuthClient.APP_ID = nil

--- Return a non-empty string, otherwise nil.
---@param value any
---@return string|nil
local function nonEmptyString(value)
    if type(value) == "string" and value ~= "" then
        return value
    end

    return nil
end

--- Derive the Google Cloud project number used by PickerBuilder.setAppId().
---
--- Google OAuth client IDs normally begin with the Cloud project number,
--- for example:
---   1234567890-abc.apps.googleusercontent.com
---   1234567890.apps.googleusercontent.com
---@param client_id string|nil
---@return string|nil
local function deriveAppId(client_id)
    if type(client_id) ~= "string" then
        return nil
    end

    return client_id:match("^(%d+)[%-.]")
end

--- Read the currently saved Google application configuration.
---@return string|nil client_id
---@return string|nil client_secret
---@return string|nil picker_api_key
local function readSavedCredentials()
    local settings = LuaSettings:open(OAuthClient.SETTINGS_FILE)

    return nonEmptyString(settings:readSetting("client_id")),
        nonEmptyString(settings:readSetting("client_secret")),
        nonEmptyString(settings:readSetting("picker_api_key"))
end

--- Load saved Google application configuration into this module.
function OAuthClient:reload()
    self.CLIENT_ID,
        self.CLIENT_SECRET,
        self.PICKER_API_KEY = readSavedCredentials()

    self.APP_ID = deriveAppId(self.CLIENT_ID)
end

--- Return whether OAuth application credentials are available.
---@return boolean
function OAuthClient:isConfigured()
    return self.CLIENT_ID ~= nil
        and self.CLIENT_SECRET ~= nil
end

--- Return whether Google Picker configuration is complete.
---@return boolean
function OAuthClient:isPickerConfigured()
    return self:isConfigured()
        and self.PICKER_API_KEY ~= nil
        and self.APP_ID ~= nil
end

--- Return the credential settings file used by KOCloud.
---@return string
function OAuthClient:getSettingsFile()
    return self.SETTINGS_FILE
end

--- Return the OAuth scopes as a space-delimited string.
---@return string
function OAuthClient:getScopeString()
    return table.concat(self.SCOPES, " ")
end

--- Return Google Picker configuration.
---@return table|nil config
function OAuthClient:getPickerConfig()
    if not self:isPickerConfigured() then
        return nil
    end

    return {
        api_key = self.PICKER_API_KEY,
        app_id = self.APP_ID,
    }
end

--- Save Google OAuth credentials and optional Picker API key.
---
--- When the OAuth client changes and no new Picker key is supplied, the old
--- Picker key is cleared because it may belong to a different Cloud project.
---@param client_id string
---@param client_secret string
---@param picker_api_key? string
---@return boolean success
---@return string|nil error_message
function OAuthClient:saveCredentials(
    client_id,
    client_secret,
    picker_api_key
)
    client_id = nonEmptyString(client_id)
    client_secret = nonEmptyString(client_secret)
    picker_api_key = nonEmptyString(picker_api_key)

    if not client_id then
        return false, "OAuth credentials do not contain a client ID"
    end

    if not client_secret then
        return false, "OAuth credentials do not contain a client secret"
    end

    local previous_client_id = self.CLIENT_ID
    local settings = LuaSettings:open(self.SETTINGS_FILE)

    settings:saveSetting("client_id", client_id)
    settings:saveSetting("client_secret", client_secret)

    if picker_api_key then
        settings:saveSetting("picker_api_key", picker_api_key)
    elseif previous_client_id ~= nil
        and previous_client_id ~= client_id
    then
        settings:delSetting("picker_api_key")
    end

    settings:flush()

    self:reload()

    return true, nil
end

--- Save or replace only the Google Picker API key.
---@param picker_api_key string
---@return boolean success
---@return string|nil error_message
function OAuthClient:savePickerApiKey(picker_api_key)
    picker_api_key = nonEmptyString(picker_api_key)

    if not picker_api_key then
        return false, "Google Picker API key is required"
    end

    if not self:isConfigured() then
        return false, "Configure Google OAuth credentials first"
    end

    local settings = LuaSettings:open(self.SETTINGS_FILE)
    settings:saveSetting("picker_api_key", picker_api_key)
    settings:flush()

    self:reload()

    return true, nil
end

--- Extract client ID and secret from a Google OAuth credentials JSON object.
---@param data table
---@return string|nil client_id
---@return string|nil client_secret
local function extractCredentials(data)
    if type(data) ~= "table" then
        return nil, nil
    end

    local credential_data

    if type(data.installed) == "table" then
        credential_data = data.installed
    elseif type(data.web) == "table" then
        credential_data = data.web
    else
        credential_data = data
    end

    return nonEmptyString(credential_data.client_id),
        nonEmptyString(credential_data.client_secret)
end

--- Import Google's downloaded OAuth credentials JSON file.
---@param json_path string
---@return table|nil credentials
---@return string|nil error_message
function OAuthClient:importFromJsonFile(json_path)
    local file, open_error = io.open(json_path, "rb")

    if not file then
        return nil,
            "Cannot open OAuth credentials file: "
                .. tostring(open_error)
    end

    local raw = file:read("*a")
    file:close()

    if type(raw) ~= "string" or raw == "" then
        return nil, "OAuth credentials file is empty"
    end

    local ok, data = pcall(JSON.decode, raw)

    if not ok or type(data) ~= "table" then
        return nil, "OAuth credentials file is not valid JSON"
    end

    local client_id, client_secret = extractCredentials(data)

    if not client_id then
        return nil,
            "OAuth credentials JSON does not contain client_id"
    end

    if not client_secret then
        return nil,
            "OAuth credentials JSON does not contain client_secret"
    end

    local old_client_id = self.CLIENT_ID
    local old_client_secret = self.CLIENT_SECRET

    local saved, save_error =
        self:saveCredentials(client_id, client_secret)

    if not saved then
        return nil, save_error
    end

    return {
        client_id = client_id,
        client_secret = client_secret,
        changed = old_client_id ~= client_id
            or old_client_secret ~= client_secret,
    }, nil
end

--- Remove locally saved Google application configuration.
---@return boolean success
---@return string|nil error_message
function OAuthClient:clearCredentials()
    self.CLIENT_ID = nil
    self.CLIENT_SECRET = nil
    self.PICKER_API_KEY = nil
    self.APP_ID = nil

    local file = io.open(self.SETTINGS_FILE, "rb")

    if not file then
        return true, nil
    end

    file:close()

    local ok, remove_error = os.remove(self.SETTINGS_FILE)

    if not ok then
        return false,
            "Cannot remove OAuth credentials: "
                .. tostring(remove_error)
    end

    return true, nil
end

OAuthClient:reload()

return OAuthClient
