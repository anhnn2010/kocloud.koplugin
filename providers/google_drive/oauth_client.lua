--- Static Google OAuth client configuration for KOCloud.
---
--- These credentials identify the KOCloud application itself. They are not
--- user credentials and must not be stored in settings/kocloud.lua.
---
--- For development, replace CLIENT_ID and CLIENT_SECRET with credentials from
--- a Google OAuth client whose application type is "TVs and Limited Input
--- devices". For release builds, these values should be supplied by the
--- KOCloud release process.
local OAuthClient = {}

OAuthClient.CLIENT_ID = nil
OAuthClient.CLIENT_SECRET = nil

OAuthClient.SCOPES = {
    "https://www.googleapis.com/auth/drive.file",
    "https://www.googleapis.com/auth/drive.appdata",
}

--- Return whether KOCloud application OAuth credentials are available.
---@return boolean
function OAuthClient:isConfigured()
    return type(self.CLIENT_ID) == "string"
        and self.CLIENT_ID ~= ""
        and type(self.CLIENT_SECRET) == "string"
        and self.CLIENT_SECRET ~= ""
end

--- Return the OAuth scopes as a space-delimited string.
---@return string
function OAuthClient:getScopeString()
    return table.concat(self.SCOPES, " ")
end

return OAuthClient
