local Device = require("device")
local Event = require("ui/event")
local JSON = require("json")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local socket = require("socket")

--- Temporary browser server used to select existing Google Drive books with
--- Google Picker and import them into KOCloud.
---@class KOCloudDriveImportServer
---@field host string
---@field port integer
---@field token string
---@field access_token string
---@field picker_api_key string
---@field app_id string
---@field http_socket? table
---@field http_messagequeue? any
---@field timeout_task? function
---@field on_import fun(files:table[]):(table[]|nil, table[]|nil, string|nil)
---@field on_finished? fun(imported_count:integer, failed_count:integer)
---@field on_timeout? fun()
local DriveImportServer = {}
DriveImportServer.__index = DriveImportServer

DriveImportServer.DEFAULT_PORT = 8780
DriveImportServer.MAX_PORT_TRIES = 10
DriveImportServer.MAX_BODY_SIZE = 64 * 1024
DriveImportServer.TIMEOUT_SECONDS = 5 * 60

local HTTP_REASON = {
    [200] = "OK",
    [400] = "Bad Request",
    [403] = "Forbidden",
    [404] = "Not Found",
    [405] = "Method Not Allowed",
    [413] = "Payload Too Large",
    [500] = "Internal Server Error",
}

--- Escape text before embedding it into HTML/JavaScript.
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

---@param value string
---@return string
local function jsString(value)
    local encoded = JSON.encode(tostring(value))
    return encoded
end

--- Generate a short, human-friendly pairing token.
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

--- Create an import server.
---@param options table
---@return KOCloudDriveImportServer
function DriveImportServer:new(options)
    options = options or {}

    local instance = setmetatable({}, self)

    instance.host = options.host or "*"
    instance.port = tonumber(options.port) or self.DEFAULT_PORT
    instance.token = generateToken()
    instance.access_token = assert(options.access_token)
    instance.picker_api_key = assert(options.picker_api_key)
    instance.app_id = assert(options.app_id)
    instance.on_import = assert(options.on_import)
    instance.on_finished = options.on_finished
    instance.on_timeout = options.on_timeout

    return instance
end

---@return boolean
function DriveImportServer:isRunning()
    return self.http_socket ~= nil
end

---@return string|nil
function DriveImportServer:getLocalIPAddress()
    local udp = socket.udp()

    if not udp then
        return nil
    end

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

---@return string|nil
function DriveImportServer:getURL()
    local ip = self:getLocalIPAddress()

    if not ip then
        return nil
    end

    return string.format(
        "http://%s:%d/i/%s",
        ip,
        self.port,
        self.token
    )
end

function DriveImportServer:openFirewall()
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

function DriveImportServer:closeFirewall()
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

---@return boolean success
---@return string|nil error_message
function DriveImportServer:start()
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
            "Cannot start Google Drive import server: "
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
        "KOCloud Drive import server listening on port",
        self.port
    )

    return true, nil
end

function DriveImportServer:stop()
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

---@param request_id any
---@param status integer
---@param content_type string
---@param body string
---@return any
function DriveImportServer:sendResponse(
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

---@return string
function DriveImportServer:getPage()
    local token = htmlEscape(self.token)

    return string.format([[
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Import books to KOCloud</title>
<style>
body{font-family:system-ui,sans-serif;max-width:720px;margin:2rem auto;padding:0 1rem;line-height:1.45}
button{font:inherit;padding:.75rem 1rem;margin:.4rem 0;width:100%%}
.note{background:#f2f2f2;padding:.8rem;border-radius:.5rem}
#selected{white-space:pre-wrap;background:#fafafa;padding:.7rem;border:1px solid #ddd;min-height:3rem}
#status{margin-top:1rem;font-weight:600}
</style>
<script src="https://apis.google.com/js/api.js"></script>
</head>
<body>
<h1>Import books to KOCloud</h1>
<p class="note">
Choose EPUB or PDF files already stored in Google Drive.
Google copies them directly into KOCloud/Books; ebook data does not pass
through your KOReader device.
</p>

<button id="pick" disabled>Select books from Google Drive</button>
<div id="selected">Loading Google Picker…</div>
<button id="import" disabled>Import selected books</button>
<div id="status"></div>

<script>
const ACCESS_TOKEN = %s;
const API_KEY = %s;
const APP_ID = %s;
const IMPORT_URL = %s;
let selectedFiles = [];

function setStatus(text) {
  document.getElementById("status").textContent = text || "";
}

function renderSelection() {
  const box = document.getElementById("selected");
  const button = document.getElementById("import");

  if (!selectedFiles.length) {
    box.textContent = "No books selected.";
    button.disabled = true;
    return;
  }

  box.textContent = selectedFiles
    .map((f, i) => `${i + 1}. ${f.name}`)
    .join("\n");
  button.disabled = false;
}

function pickerCallback(data) {
  if (data.action === google.picker.Action.PICKED) {
    selectedFiles = (data.docs || []).map(doc => ({
      id: doc.id,
      name: doc.name,
      mimeType: doc.mimeType
    }));
    renderSelection();
  }
}

function openPicker() {
  const view = new google.picker.DocsView()
    .setIncludeFolders(false)
    .setSelectFolderEnabled(false)
    .setMode(google.picker.DocsViewMode.LIST)
    .setMimeTypes("application/epub+zip,application/pdf");

  const picker = new google.picker.PickerBuilder()
    .setDeveloperKey(API_KEY)
    .setAppId(APP_ID)
    .setOAuthToken(ACCESS_TOKEN)
    .setOrigin(window.location.origin)
    .enableFeature(google.picker.Feature.MULTISELECT_ENABLED)
    .setMaxItems(50)
    .addView(view)
    .setCallback(pickerCallback)
    .setTitle("Choose books to import")
    .build();

  picker.setVisible(true);
}

function pickerLoaded() {
  document.getElementById("pick").disabled = false;
  document.getElementById("selected").textContent = "No books selected.";
}

document.getElementById("pick").addEventListener("click", openPicker);

document.getElementById("import").addEventListener("click", async function() {
  if (!selectedFiles.length) return;

  this.disabled = true;
  setStatus("Importing…");

  try {
    const response = await fetch(IMPORT_URL, {
      method: "POST",
      headers: {"Content-Type": "application/json"},
      body: JSON.stringify({files: selectedFiles})
    });

    const result = await response.json();

    if (!response.ok || !result.ok) {
      throw new Error(result.error || `HTTP ${response.status}`);
    }

    const imported = result.imported || [];
    const failed = result.failed || [];

    let message = `Imported ${imported.length} book(s).`;
    if (failed.length) {
      message += ` Failed: ${failed.length}.`;
    }

    setStatus(message);

    if (!failed.length) {
      selectedFiles = [];
      renderSelection();
    } else {
      document.getElementById("import").disabled = false;
    }
  } catch (error) {
    setStatus("Import failed: " + error.message);
    document.getElementById("import").disabled = false;
  }
});

gapi.load("picker", {callback: pickerLoaded});
</script>
</body>
</html>
]],
        jsString(self.access_token),
        jsString(self.picker_api_key),
        jsString(self.app_id),
        jsString("/x/" .. token)
    )
end

--- Read remaining POST data if the initial SimpleTCPServer read was partial.
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
                "KOCloud Drive import: failed reading POST body:",
                receive_error or "unknown"
            )
            break
        end
    end

    return table.concat(chunks)
end

---@param data string
---@param request_id any
---@return any
function DriveImportServer:onRequest(data, request_id)
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
            "application/json",
            '{"ok":false,"error":"Malformed HTTP request"}'
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
            "application/json",
            '{"ok":false,"error":"Request is too large"}'
        )
    end

    if method == "POST" then
        body = completeRequestBody(
            body,
            content_length,
            request_id
        )
    end

    local page_token = uri:match("^/i/([23456789abcdefghjkmnpqrstuvwxyz]+)")
    local import_token = uri:match("^/x/([23456789abcdefghjkmnpqrstuvwxyz]+)")

    if method == "GET" and page_token then
        if page_token ~= self.token then
            return self:sendResponse(
                request_id,
                403,
                "text/plain; charset=utf-8",
                "Invalid or expired KOCloud import link."
            )
        end

        return self:sendResponse(
            request_id,
            200,
            "text/html; charset=utf-8",
            self:getPage()
        )
    end

    if method == "POST" and import_token then
        if import_token ~= self.token then
            return self:sendResponse(
                request_id,
                403,
                "application/json",
                '{"ok":false,"error":"Invalid or expired import session"}'
            )
        end

        local ok, payload = pcall(JSON.decode, body)

        if not ok
            or type(payload) ~= "table"
            or type(payload.files) ~= "table"
        then
            return self:sendResponse(
                request_id,
                400,
                "application/json",
                '{"ok":false,"error":"Invalid import request"}'
            )
        end

        local imported, failed, import_error =
            self.on_import(payload.files)

        if not imported then
            local response = JSON.encode({
                ok = false,
                error = import_error or "Google Drive import failed",
            })

            return self:sendResponse(
                request_id,
                500,
                "application/json",
                response
            )
        end

        failed = failed or {}

        local response = JSON.encode({
            ok = true,
            imported = imported,
            failed = failed,
        })

        local event = self:sendResponse(
            request_id,
            200,
            "application/json",
            response
        )

        if self.on_finished then
            UIManager:nextTick(function()
                self.on_finished(#imported, #failed)
            end)
        end

        return event
    end

    return self:sendResponse(
        request_id,
        404,
        "text/plain; charset=utf-8",
        "Not found."
    )
end

return DriveImportServer
