--- Static Google OAuth client configuration for KOCloud.
---
--- These credentials identify the KOCloud application itself. They are not
--- user credentials and must not be stored in settings/kocloud.lua.
---
--- Google currently documents both drive.file and drive.appdata as valid
--- Device Authorization Flow scopes. In practice, the device endpoint may
--- reject drive.appdata with "invalid device flow scope", so KOCloud v1 uses
--- drive.file only.
local OAuthClient = {}

OAuthClient.CLIENT_ID = nil
OAuthClient.CLIENT_SECRET = nil

OAuthClient.SCOPES = {
    "https://www.googleapis.com/auth/drive.file",
}

--- Return whether KOCloud application OAuth credentials are available.
---@return boolean
function OAuthClient:isConfigured()
    return type(self.CLIENT_ID) == "string"
        and self.CLIENT_ID ~= ""
        and self.CLIENT_ID ~= "YOUR_CLIENT_ID"
        and type(self.CLIENT_SECRET) == "string"
        and self.CLIENT_SECRET ~= ""
        and self.CLIENT_SECRET ~= "YOUR_CLIENT_SECRET"
end

--- Return the OAuth scopes as a space-delimited string.
---@return string
function OAuthClient:getScopeString()
    return table.concat(self.SCOPES, " ")
end

return OAuthClient
