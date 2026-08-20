local DataStorage = require("datastorage")
local LuaSettings = require("luasettings")

--- Static Google OAuth client configuration for KOCloud.
---
--- Development credentials are loaded from:
---   <KOReader settings>/kocloud_oauth_client.lua
---
--- Release builds may optionally provide:
---   providers/google_drive/oauth_client_release.lua
---
--- User OAuth tokens are NOT stored here. They remain in settings/kocloud.lua.
---@class KOCloudGoogleOAuthClient
local OAuthClient = {}

OAuthClient.SETTINGS_FILE =
    DataStorage:getSettingsDir() .. "/kocloud_oauth_client.lua"

OAuthClient.SCOPES = {
    "https://www.googleapis.com/auth/drive.file",
}

--- Return a non-empty string, otherwise nil.
---@param value any
---@return string|nil
local function nonEmptyString(value)
    if type(value) == "string" and value ~= "" then
        return value
    end

    return nil
end

--- Load optional release credentials packaged with a KOCloud release.
---@return table
local function loadReleaseCredentials()
    local ok, credentials = pcall(
        require,
        "providers/google_drive/oauth_client_release"
    )

    if ok and type(credentials) == "table" then
        return credentials
    end

    return {}
end

--- Load local development credentials from KOReader settings.
---@return table
local function loadLocalCredentials()
    local settings = LuaSettings:open(OAuthClient.SETTINGS_FILE)

    return {
        client_id = nonEmptyString(
            settings:readSetting("client_id")
        ),
        client_secret = nonEmptyString(
            settings:readSetting("client_secret")
        ),
    }
end

local local_credentials = loadLocalCredentials()
local release_credentials = loadReleaseCredentials()

-- Local settings intentionally override packaged release credentials.
-- This makes development/testing possible without modifying tracked source.
OAuthClient.CLIENT_ID =
    local_credentials.client_id
    or nonEmptyString(release_credentials.CLIENT_ID)

OAuthClient.CLIENT_SECRET =
    local_credentials.client_secret
    or nonEmptyString(release_credentials.CLIENT_SECRET)

--- Return whether OAuth application credentials are available.
---@return boolean
function OAuthClient:isConfigured()
    return self.CLIENT_ID ~= nil
        and self.CLIENT_SECRET ~= nil
end

--- Return where the active OAuth application credentials came from.
---@return "local"|"release"|"none"
function OAuthClient:getCredentialSource()
    if local_credentials.client_id
        and local_credentials.client_secret
    then
        return "local"
    end

    if self.CLIENT_ID and self.CLIENT_SECRET then
        return "release"
    end

    return "none"
end

--- Return the OAuth scopes as a space-delimited string.
---@return string
function OAuthClient:getScopeString()
    return table.concat(self.SCOPES, " ")
end

return OAuthClient
