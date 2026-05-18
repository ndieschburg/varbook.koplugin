--[[
    HTTP client wrapper for the Varbook server API.
    Handles GET/POST requests with Bearer token authentication.
]]--

local http = require("socket.http")
local ltn12 = require("ltn12")
local socket = require("socket")
local socketutil = require("socketutil")
local JSON = require("json")
local logger = require("logger")

local VarbookAPI = {}

--- Initialize with server URL and token.
-- @param server_url string Base server URL (e.g. "https://your-domain.com")
-- @param token string 16-char API token
function VarbookAPI:new(server_url, token)
    local o = {
        server_url = server_url,
        token = token,
    }
    setmetatable(o, { __index = self })
    return o
end

--- Build authorization headers.
-- @return table HTTP headers
function VarbookAPI:headers(content_length)
    local h = {
        ["Accept"] = "application/json",
        ["Authorization"] = "Bearer " .. self.token,
    }
    if content_length then
        h["Content-Type"] = "application/json"
        h["Content-Length"] = tostring(content_length)
    end
    return h
end

--- Fetch server progress for a document.
-- @param doc_hash string KOReader partial MD5 hash
-- @return table|nil {progress, timestamp} or nil on error
-- @return string|nil Error message
--- Fetch server progress for a document.
-- @param doc_hash string KOReader partial MD5 hash
-- @param filename string|nil Original filename for fallback matching
-- @return table|nil {progress, timestamp} or nil on error
-- @return string|nil Error message
function VarbookAPI:getProgress(doc_hash, filename)
    local url = self.server_url .. "/api/varbook/progress/" .. doc_hash
    if filename then
        url = url .. "?filename=" .. filename
    end
    local sink = {}
    local request = {
        url = url,
        method = "GET",
        headers = self:headers(),
        sink = ltn12.sink.table(sink),
    }

    logger.dbg("Varbook: GET", request.url)
    socketutil:set_timeout(10, 30)
    local code, resp_headers, status = socket.skip(1, http.request(request))
    socketutil:reset_timeout()
    logger.dbg("Varbook: getProgress response code:", code)

    if resp_headers == nil then
        logger.warn("Varbook: network error on getProgress:", status or code)
        return nil, "network_error"
    end

    local body = table.concat(sink)
    logger.dbg("Varbook: getProgress body:", body)

    if code == 401 then
        return nil, "unauthorized"
    end

    if code == 404 then
        return nil, nil
    end

    if code ~= 200 then
        logger.warn("Varbook: getProgress HTTP", code, body)
        return nil, "http_" .. tostring(code)
    end

    local ok, result = pcall(JSON.decode, body)
    if not ok or not result then
        logger.warn("Varbook: failed to decode getProgress response:", body)
        return nil, "json_error"
    end

    -- Parse pivot if present (JSON null decodes as json.null which is a function, not a table)
    local pivot = nil
    if type(result.pivot) == "table" and result.pivot.spine_index then
        pivot = {
            spine_index = tonumber(result.pivot.spine_index) or 0,
            spine_href = result.pivot.spine_href or "",
            spine_percent = tonumber(result.pivot.spine_percent) or 0,
            source = result.pivot.source or "unknown",
        }
    end

    logger.dbg("Varbook: getProgress result: progress=", result.progress,
        "timestamp=", result.timestamp, "last_sync_client=", result.last_sync_client,
        "position=", result.position, "has_pivot=", pivot ~= nil)
    return {
        progress = tonumber(result.progress) or 0,
        timestamp = tonumber(result.timestamp) or 0,
        last_sync_client = result.last_sync_client,
        position = result.position,
        pivot = pivot,
    }, nil
end

--- Push a batch of position updates to the server.
-- @param doc_hash string KOReader partial MD5 hash
-- @param updates table Array of {percentage, timestamp, xpointer} records
-- @param pivot table|nil Optional pivot data for cross-client sync
-- @return number|nil Number of synced positions, or nil on error
-- @return string|nil Error message
--- Push a batch of position updates to the server.
-- @param doc_hash string KOReader partial MD5 hash
-- @param updates table Array of {percentage, timestamp, xpointer} records
-- @param pivot table|nil Optional pivot data for cross-client sync
-- @param filename string|nil Original filename for fallback matching
-- @return number|nil Number of synced positions, or nil on error
-- @return string|nil Error message
function VarbookAPI:pushBatch(doc_hash, updates, pivot, filename)
    if #updates == 0 then
        return 0, nil
    end

    -- Convert timestamps to ISO8601 for the server
    local formatted = {}
    for _, u in ipairs(updates) do
        local entry = {
            progress = u.percentage,
            timestamp = os.date("!%Y-%m-%dT%H:%M:%SZ", tonumber(u.timestamp)),
        }
        if u.xpointer then
            entry.position = u.xpointer
        end
        table.insert(formatted, entry)
    end

    local payload = { updates = formatted }
    if pivot then
        payload.pivot = pivot
    end
    if filename then
        payload.filename = filename
    end

    local body = JSON.encode(payload)
    local sink = {}
    local request = {
        url = self.server_url .. "/api/varbook/progress/" .. doc_hash .. "/batch",
        method = "POST",
        headers = self:headers(#body),
        source = ltn12.source.string(body),
        sink = ltn12.sink.table(sink),
    }

    logger.dbg("Varbook: POST", request.url, "updates:", #formatted)
    logger.dbg("Varbook: pushBatch body:", body)
    socketutil:set_timeout(10, 60)
    local code, resp_headers, status = socket.skip(1, http.request(request))
    socketutil:reset_timeout()
    logger.dbg("Varbook: pushBatch response code:", code)

    if resp_headers == nil then
        logger.warn("Varbook: network error on pushBatch:", status or code)
        return nil, "network_error"
    end

    local resp_body = table.concat(sink)
    logger.dbg("Varbook: pushBatch response body:", resp_body)

    if code == 401 then
        return nil, "unauthorized"
    end

    if code == 404 then
        return nil, "book_not_found"
    end

    if code ~= 200 then
        logger.warn("Varbook: pushBatch HTTP", code, resp_body)
        return nil, "http_" .. tostring(code)
    end

    local ok, result = pcall(JSON.decode, resp_body)
    if not ok or not result or not result.data then
        logger.warn("Varbook: failed to decode pushBatch response:", resp_body)
        return nil, "json_error"
    end

    return result.data.synced_count or #updates, nil
end

--- Claim a pairing code to receive an API token.
-- Standalone function (no auth needed).
-- @param server_url string Base server URL (e.g. "https://your-domain.com")
-- @param code string 5-digit pairing code
-- @return string|nil Plain API token on success
-- @return string|nil Error type: "invalid_code", "rate_limited", "network_error"
function VarbookAPI.claimPairingCode(server_url, code)
    local payload = JSON.encode({ code = code })
    local sink = {}
    local request = {
        url = server_url .. "/api/pairing/claim",
        method = "POST",
        headers = {
            ["Accept"] = "application/json",
            ["Content-Type"] = "application/json",
            ["Content-Length"] = tostring(#payload),
        },
        source = ltn12.source.string(payload),
        sink = ltn12.sink.table(sink),
    }

    logger.dbg("Varbook: POST", request.url, "(pairing claim)")
    socketutil:set_timeout(10, 30)
    local resp_code, resp_headers, status = socket.skip(1, http.request(request))
    socketutil:reset_timeout()
    logger.dbg("Varbook: claimPairingCode response code:", resp_code)

    if resp_headers == nil then
        logger.warn("Varbook: network error on claimPairingCode:", status or resp_code)
        return nil, "network_error"
    end

    if resp_code == 404 or resp_code == 422 then
        return nil, "invalid_code"
    end

    if resp_code == 429 then
        return nil, "rate_limited"
    end

    if resp_code ~= 200 then
        logger.warn("Varbook: claimPairingCode HTTP", resp_code)
        return nil, "http_" .. tostring(resp_code)
    end

    local body = table.concat(sink)
    local ok, result = pcall(JSON.decode, body)
    if not ok or not result or not result.data or not result.data.token then
        logger.warn("Varbook: failed to decode claimPairingCode response:", body)
        return nil, "json_error"
    end

    return result.data.token, nil
end

return VarbookAPI
