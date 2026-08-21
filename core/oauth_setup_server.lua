local Device = require("device")
local Event = require("ui/event")
local JSON = require("json")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local socket = require("socket")
local url = require("socket.url")

--- Temporary LAN-only setup server used to enter Google OAuth credentials
--- from a phone browser.
---
--- This implementation uses KOReader's SimpleTCPServer, the same server
--- integration pattern used by other KOReader local-web plugins.
---
--- Security model:
--- - starts only after an explicit user action,
--- - uses a random one-time URL token,
--- - accepts at most 64 KiB per request,
--- - automatically stops after five minutes or after a successful save,
--- - should only be used on a trusted local network.
---@class KOCloudOAuthSetupServer
---@field host string
---@field port integer
---@field token string
---@field http_socket? table
---@field http_messagequeue? any
---@field timeout_task? function
---@field on_save fun(client_id:string, client_secret:string):(boolean, string|nil)
---@field on_saved? fun()
---@field on_timeout? fun()
local OAuthSetupServer = {}
OAuthSetupServer.__index = OAuthSetupServer

OAuthSetupServer.DEFAULT_PORT = 8765
OAuthSetupServer.MAX_PORT_TRIES = 10
OAuthSetupServer.MAX_BODY_SIZE = 64 * 1024
OAuthSetupServer.TIMEOUT_SECONDS = 5 * 60

local HTTP_REASON = {
    [200] = "OK",
    [400] = "Bad Request",
    [403] = "Forbidden",
    [404] = "Not Found",
    [405] = "Method Not Allowed",
    [413] = "Payload Too Large",
    [500] = "Internal Server Error",
}

--- Escape text for HTML output.
---@param value string
---@return string
local function htmlEscape(value)
    return tostring(value)
        :gsub("&", "&amp;")
        :gsub("<", "&lt;")
        :gsub(">", "&gt;")
        :gsub('"', "&quot;")
        :gsub("'", "&#39;")
end

--- Generate a short, human-friendly random pairing token.
---
--- Eight characters from a 32-symbol alphabet provide 40 bits of entropy.
--- That is ample for a temporary LAN-only setup link that expires after
--- five minutes, while remaining practical to type manually.
---@return string
local function generateToken()
    local alphabet = "23456789abcdefghjkmnpqrstuvwxyz"
    local token_length = 8

    local file = io.open("/dev/urandom", "rb")

    if file then
        local bytes = file:read(token_length)
        file:close()

        if bytes and #bytes == token_length then
            local chars = {}

            for index = 1, token_length do
                local byte = string.byte(bytes, index)
                local position = (byte % #alphabet) + 1
                chars[index] = alphabet:sub(position, position)
            end

            return table.concat(chars)
        end
    end

    -- Fallback for unusual platforms without /dev/urandom.
    math.randomseed(
        math.floor(socket.gettime() * 1000000) + os.time()
    )

    local chars = {}

    for index = 1, token_length do
        local position = math.random(1, #alphabet)
        chars[index] = alphabet:sub(position, position)
    end

    return table.concat(chars)
end

--- Decode application/x-www-form-urlencoded text.
---@param value string
---@return string
local function formDecode(value)
    value = value:gsub("+", " ")
    return url.unescape(value)
end

--- Parse application/x-www-form-urlencoded data.
---@param body string
---@return table<string, string>
local function parseForm(body)
    local result = {}

    for item in body:gmatch("[^&]+") do
        local key, value = item:match("^([^=]*)=(.*)$")

        if key then
            result[formDecode(key)] = formDecode(value)
        end
    end

    return result
end

--- Extract a client ID and secret from Google's OAuth credentials JSON.
---@param raw string
---@return string|nil client_id
---@return string|nil client_secret
local function extractJsonCredentials(raw)
    if raw == "" then
        return nil, nil
    end

    local ok, data = pcall(JSON.decode, raw)

    if not ok or type(data) ~= "table" then
        return nil, nil
    end

    local credentials = data.installed or data.web or data

    if type(credentials) ~= "table" then
        return nil, nil
    end

    local client_id = credentials.client_id
    local client_secret = credentials.client_secret

    if type(client_id) ~= "string" or client_id == "" then
        client_id = nil
    end

    if type(client_secret) ~= "string" or client_secret == "" then
        client_secret = nil
    end

    return client_id, client_secret
end

--- Create a setup server.
---@param options table
---@return KOCloudOAuthSetupServer
function OAuthSetupServer:new(options)
    options = options or {}

    local instance = setmetatable({}, self)

    instance.host = options.host or "*"
    instance.port = tonumber(options.port) or self.DEFAULT_PORT
    instance.token = generateToken()
    instance.on_save = assert(
        options.on_save,
        "OAuthSetupServer requires on_save"
    )
    instance.on_saved = options.on_saved
    instance.on_timeout = options.on_timeout

    return instance
end

--- Return whether the server is currently listening.
---@return boolean
function OAuthSetupServer:isRunning()
    return self.http_socket ~= nil
end

--- Determine the device's LAN IPv4 address.
---@return string|nil
function OAuthSetupServer:getLocalIPAddress()
    local udp = socket.udp()

    if not udp then
        return nil
    end

    -- This does not need to send a packet. It only asks the OS which local
    -- interface would be used for a route.
    local ok = udp:setpeername("10.255.255.255", 1)

    if not ok then
        udp:close()
        return nil
    end

    local ip = udp:getsockname()
    udp:close()

    if type(ip) ~= "string"
        or ip == ""
        or ip == "0.0.0.0"
        or ip == "127.0.0.1"
    then
        return nil
    end

    return ip
end

--- Return the browser setup URL.
---
--- The one-time token intentionally lives in the URL path instead of a query
--- string. This avoids QR/browser/proxy query-string normalization issues.
---@return string|nil
function OAuthSetupServer:getSetupURL()
    local ip = self:getLocalIPAddress()

    if not ip then
        return nil
    end

    return string.format(
        "http://%s:%d/s/%s",
        ip,
        self.port,
        self.token
    )
end

--- Open a Kindle firewall rule for the temporary port.
function OAuthSetupServer:openFirewall()
    if not Device:isKindle() then
        return
    end

    os.execute(string.format(
        "iptables -A INPUT -p tcp --dport %d "
            .. "-m conntrack --ctstate NEW,ESTABLISHED -j ACCEPT",
        self.port
    ))
    os.execute(string.format(
        "iptables -A OUTPUT -p tcp --sport %d "
            .. "-m conntrack --ctstate ESTABLISHED -j ACCEPT",
        self.port
    ))
end

--- Remove the temporary Kindle firewall rule.
function OAuthSetupServer:closeFirewall()
    if not Device:isKindle() then
        return
    end

    os.execute(string.format(
        "iptables -D INPUT -p tcp --dport %d "
            .. "-m conntrack --ctstate NEW,ESTABLISHED -j ACCEPT",
        self.port
    ))
    os.execute(string.format(
        "iptables -D OUTPUT -p tcp --sport %d "
            .. "-m conntrack --ctstate ESTABLISHED -j ACCEPT",
        self.port
    ))
end

--- Start the local HTTP setup server.
---@return boolean success
---@return string|nil error_message
function OAuthSetupServer:start()
    if self:isRunning() then
        return true, nil
    end

    local ServerClass = require("ui/message/simpletcpserver")
    local last_error

    for offset = 0, self.MAX_PORT_TRIES - 1 do
        local candidate_port = self.port + offset

        local server = ServerClass:new{
            host = self.host,
            port = tostring(candidate_port),
            receiveCallback = function(data, request_id)
                return self:onRequest(data, request_id)
            end,
        }

        local ok, start_error = server:start()

        if ok then
            self.port = candidate_port
            self.http_socket = server
            break
        end

        last_error = start_error
        server:stop()
    end

    if not self.http_socket then
        return false,
            "Cannot start KOCloud setup server: "
                .. tostring(last_error or "no free port")
    end

    self:openFirewall()

    self.http_messagequeue =
        UIManager:insertZMQ(self.http_socket)

    self.timeout_task = function()
        self.timeout_task = nil
        self:stop()

        if self.on_timeout then
            self.on_timeout()
        end
    end

    UIManager:scheduleIn(
        self.TIMEOUT_SECONDS,
        self.timeout_task
    )

    logger.info(
        "KOCloud OAuth setup server listening on port",
        self.port
    )

    return true, nil
end

--- Stop the temporary setup server.
function OAuthSetupServer:stop()
    if self.timeout_task then
        UIManager:unschedule(self.timeout_task)
        self.timeout_task = nil
    end

    if self.http_socket then
        self.http_socket:stop()
        self.http_socket = nil
    end

    if self.http_messagequeue then
        UIManager:removeZMQ(self.http_messagequeue)
        self.http_messagequeue = nil
    end

    self:closeFirewall()
end

--- Send one HTTP response.
---@param request_id any
---@param status integer
---@param content_type string
---@param body string
---@return any
function OAuthSetupServer:sendResponse(
    request_id,
    status,
    content_type,
    body
)
    if not self.http_socket then
        return Event:new("InputEvent")
    end

    local reason = HTTP_REASON[status] or "Unknown"
    local response = table.concat({
        string.format("HTTP/1.0 %d %s", status, reason),
        "Content-Type: " .. content_type,
        "Content-Length: " .. tostring(#body),
        "Connection: close",
        "Cache-Control: no-store, no-cache, must-revalidate, max-age=0",
        "Pragma: no-cache",
        "X-Content-Type-Options: nosniff",
        "",
        body,
    }, "\r\n")

    self.http_socket:send(response, request_id)

    return Event:new("InputEvent")
end

--- Return the setup page HTML.
---@return string
function OAuthSetupServer:getSetupPage()
    local token = htmlEscape(self.token)

    return string.format([[
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>KOCloud Google Drive Setup</title>
<style>
body{font-family:system-ui,sans-serif;max-width:680px;margin:2rem auto;padding:0 1rem;line-height:1.45}
label{display:block;font-weight:600;margin-top:1rem}
input,textarea,button{box-sizing:border-box;width:100%%;font:inherit;padding:.75rem;margin-top:.35rem}
textarea{min-height:8rem}
button{margin-top:1.2rem;font-weight:700}
.note{background:#f2f2f2;padding:.8rem;border-radius:.5rem}
</style>
</head>
<body>
<h1>KOCloud Google Drive Setup</h1>
<p class="note">
This page is served temporarily by your KOReader.
Use only on a trusted Wi-Fi network. The server shuts down after saving
or after five minutes.
</p>

<form method="post" action="/v/%s">
<label for="file">Google OAuth credentials JSON</label>
<input id="file" type="file" accept=".json,application/json">
<p>Choose the JSON downloaded from Google Cloud. Your browser reads it locally.</p>

<label for="client_id">Client ID</label>
<input id="client_id" name="client_id" autocomplete="off">

<label for="client_secret">Client Secret</label>
<input id="client_secret" name="client_secret" type="password" autocomplete="off">

<details>
<summary>Or paste the credentials JSON</summary>
<label for="credentials_json">Credentials JSON</label>
<textarea id="credentials_json" name="credentials_json"></textarea>
</details>

<button type="submit">Save to KOReader</button>
</form>

<script>
(function(){
  var file = document.getElementById("file");
  var id = document.getElementById("client_id");
  var secret = document.getElementById("client_secret");

  file.addEventListener("change", function(){
    if (!file.files || !file.files[0]) return;

    var reader = new FileReader();
    reader.onload = function(){
      try {
        var data = JSON.parse(reader.result);
        var c = data.installed || data.web || data;
        id.value = c.client_id || "";
        secret.value = c.client_secret || "";
      } catch (e) {
        alert("The selected file is not valid Google OAuth JSON.");
      }
    };
    reader.readAsText(file.files[0]);
  });
})();
</script>
</body>
</html>
]], token)
end

--- Read the remaining POST body from SimpleTCPServer's request socket.
---@param initial_body string
---@param content_length integer
---@param request_id any
---@return string
local function completeRequestBody(
    initial_body,
    content_length,
    request_id
)
    if #initial_body >= content_length
        or not request_id
        or not request_id.receive
    then
        return initial_body
    end

    local remaining = content_length - #initial_body
    local chunks = { initial_body }

    while remaining > 0 do
        local part, receive_error, partial =
            request_id:receive(remaining)

        local chunk = part or partial

        if chunk and #chunk > 0 then
            table.insert(chunks, chunk)
            remaining = remaining - #chunk
        else
            logger.warn(
                "KOCloud OAuth setup: failed reading POST body:",
                receive_error or "unknown"
            )
            break
        end
    end

    return table.concat(chunks)
end

--- Handle one HTTP request received by KOReader's SimpleTCPServer.
---@param data string
---@param request_id any
---@return any
function OAuthSetupServer:onRequest(data, request_id)
    local head, body =
        data:match("^(.-)\r?\n\r?\n(.*)$")

    head = head or data
    body = body or ""

    local method, uri =
        head:match("^(%u+)%s+([^%s]+)%s+HTTP/%d%.%d")

    if not method or not uri then
        return self:sendResponse(
            request_id,
            400,
            "text/plain; charset=utf-8",
            "Malformed HTTP request."
        )
    end

    if method ~= "GET" and method ~= "POST" then
        return self:sendResponse(
            request_id,
            405,
            "text/plain; charset=utf-8",
            "Only GET and POST are supported."
        )
    end

    local headers = {}

    for line in head:gmatch("\r?\n([^\r\n]+)") do
        local key, value =
            line:match("^%s*([^:]+):%s*(.*)$")

        if key and value then
            headers[key:lower()] = value
        end
    end

    local content_length =
        tonumber(headers["content-length"] or "0") or 0

    if content_length < 0
        or content_length > self.MAX_BODY_SIZE
    then
        return self:sendResponse(
            request_id,
            413,
            "text/plain; charset=utf-8",
            "Request is too large."
        )
    end

    if method == "POST" then
        body = completeRequestBody(
            body,
            content_length,
            request_id
        )
    end

    -- Route by path token instead of a query parameter.
    local setup_token = uri:match("^/s/([23456789abcdefghjkmnpqrstuvwxyz]+)")
    local save_token = uri:match("^/v/([23456789abcdefghjkmnpqrstuvwxyz]+)")

    if method == "GET" and setup_token then
        if setup_token ~= self.token then
            return self:sendResponse(
                request_id,
                403,
                "text/plain; charset=utf-8",
                "Invalid or expired KOCloud setup link."
            )
        end

        return self:sendResponse(
            request_id,
            200,
            "text/html; charset=utf-8",
            self:getSetupPage()
        )
    end

    if method == "POST" and save_token then
        if save_token ~= self.token then
            return self:sendResponse(
                request_id,
                403,
                "text/plain; charset=utf-8",
                "Invalid or expired KOCloud setup link."
            )
        end

        local content_type = headers["content-type"] or ""

        if not content_type:find(
            "application/x%-www%-form%-urlencoded"
        ) then
            return self:sendResponse(
                request_id,
                400,
                "text/plain; charset=utf-8",
                "Unsupported form encoding."
            )
        end

        local form = parseForm(body)
        local client_id = form.client_id
        local client_secret = form.client_secret

        if form.credentials_json
            and form.credentials_json ~= ""
        then
            local json_id, json_secret =
                extractJsonCredentials(
                    form.credentials_json
                )

            client_id = json_id or client_id
            client_secret = json_secret or client_secret
        end

        if type(client_id) ~= "string"
            or client_id == ""
            or type(client_secret) ~= "string"
            or client_secret == ""
        then
            return self:sendResponse(
                request_id,
                400,
                "text/html; charset=utf-8",
                "<h1>Missing credentials</h1>"
                    .. "<p>Client ID and Client Secret are required.</p>"
            )
        end

        local success, save_error =
            self.on_save(client_id, client_secret)

        if not success then
            return self:sendResponse(
                request_id,
                500,
                "text/html; charset=utf-8",
                "<h1>Could not save credentials</h1><p>"
                    .. htmlEscape(
                        save_error or "Unknown error"
                    )
                    .. "</p>"
            )
        end

        local response_event = self:sendResponse(
            request_id,
            200,
            "text/html; charset=utf-8",
            "<h1>KOCloud configured</h1>"
                .. "<p>Google OAuth credentials were saved successfully.</p>"
                .. "<p>You can return to KOReader and connect Google Drive.</p>"
        )

        UIManager:nextTick(function()
            self:stop()

            if self.on_saved then
                self.on_saved()
            end
        end)

        return response_event
    end

    return self:sendResponse(
        request_id,
        404,
        "text/plain; charset=utf-8",
        "Not found."
    )
end

return OAuthSetupServer
