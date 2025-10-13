local https = require("ssl.https")
local socket_url = require("socket.url")
local ltn12 = require("ltn12")
local socketutil = require("socketutil")
local json = require("json")
local Utils = require("webbrowser_utils")

local GoogleApi = {}

local DEFAULT_TIMEOUT = 15
local DEFAULT_MAXTIME = 30
local DEFAULT_PAGE_SIZE = 10
local MAX_RESULTS_ALLOWED = 10

local function build_query_url(base_url, params)
    local query_parts = {}
    for key, value in pairs(params) do
        if value ~= nil and value ~= "" then
            query_parts[#query_parts + 1] = string.format("%s=%s", socket_url.escape(tostring(key)), socket_url.escape(tostring(value)))
        end
    end
    if #query_parts == 0 then
        return base_url
    end
    local separator = base_url:find("?", 1, true) and "&" or "?"
    return base_url .. separator .. table.concat(query_parts, "&")
end

local function fetch(url, headers, timeout, maxtime)
    local response_chunks = {}
    socketutil:set_timeout(timeout or DEFAULT_TIMEOUT, maxtime or DEFAULT_MAXTIME)
    local ok, status_code, _, status_line = https.request {
        url = url,
        method = "GET",
        headers = headers,
        sink = ltn12.sink.table(response_chunks),
    }
    socketutil:reset_timeout()

    local body = table.concat(response_chunks)

    if not ok then
        return nil, status_line or status_code or "Request failed", body
    end

    local numeric_code = tonumber(status_code) or 0
    if numeric_code < 200 or numeric_code >= 300 then
        local message = status_line or ("HTTP " .. tostring(status_code))
        return nil, message, body, numeric_code
    end

    return body
end

local function extract_error_message(body, fallback)
    if not body or body == "" then
        return fallback
    end

    local ok, decoded = pcall(function()
        return json.decode(body)
    end)
    if not ok or type(decoded) ~= "table" then
        return fallback
    end

    if type(decoded.error) == "table" then
        if type(decoded.error.message) == "string" and decoded.error.message ~= "" then
            return decoded.error.message
        end
        if type(decoded.error.errors) == "table" and decoded.error.errors[1] then
            local first = decoded.error.errors[1]
            if type(first) == "table" then
                return first.message or first.reason or fallback
            end
        end
    end

    if type(decoded.error) == "string" and decoded.error ~= "" then
        return decoded.error
    end

    if type(decoded.message) == "string" and decoded.message ~= "" then
        return decoded.message
    end

    return fallback
end

local function parse_results(payload, limit)
    local ok, decoded = pcall(function()
        return json.decode(payload)
    end)
    if not ok or type(decoded) ~= "table" then
        return nil, "Failed to decode Google Search response."
    end

    if type(decoded.items) ~= "table" then
        return {}
    end

    local results = {}
    for _, item in ipairs(decoded.items) do
        if type(item) == "table" then
            local url = item.link or item.formattedUrl or item.cacheId
            local title = Utils.clean_text(item.title or "")
            local snippet = Utils.clean_text(item.snippet or item.htmlSnippet or "")
            if url and url ~= "" and title ~= "" then
                local parsed = socket_url.parse(url)
                local domain = parsed and parsed.host or nil
                results[#results + 1] = {
                    url = url,
                    title = title,
                    snippet = snippet,
                    domain = domain,
                }
            end
        end
        if #results >= limit then
            break
        end
    end

    return results
end

function GoogleApi.search(query, opts)
    local settings = opts or {}
    local api_key = settings.api_key
    local cx = settings.cx

    if not api_key or api_key == "" then
        return nil, "Missing Google Custom Search API key."
    end

    if not cx or cx == "" then
        return nil, "Missing Google Custom Search engine ID (cx)."
    end

    local endpoint = settings.base_url or "https://customsearch.googleapis.com/customsearch/v1"

    local max_results = settings.max_results or MAX_RESULTS_ALLOWED
    if max_results < 1 then
        max_results = 1
    elseif max_results > MAX_RESULTS_ALLOWED then
        max_results = MAX_RESULTS_ALLOWED
    end

    local page_size = settings.page_size or DEFAULT_PAGE_SIZE
    if page_size < 1 then
        page_size = 1
    elseif page_size > MAX_RESULTS_ALLOWED then
        page_size = MAX_RESULTS_ALLOWED
    end
    if page_size > max_results then
        page_size = max_results
    end

    local params = {
        key = api_key,
        cx = cx,
        q = query,
        num = page_size,
    }

    local language = settings.language or settings.hl
    if language and language ~= "" then
        params.hl = language
    end

    local safe = settings.safe or settings.safesearch
    if safe and safe ~= "" then
        params.safe = safe
    end

    local start_index = settings.offset
    if type(start_index) == "number" and start_index > 0 then
        params.start = start_index + 1
    elseif type(settings.start) == "number" and settings.start > 0 then
        params.start = settings.start
    end

    local url = build_query_url(endpoint, params)

    local headers = {
        ["Accept"] = "application/json",
        ["User-Agent"] = settings.user_agent or "Mozilla/5.0 (compatible; KOReader)",
    }

    local body, err, err_body = fetch(url, headers, settings.timeout, settings.maxtime)
    if not body then
        local message = extract_error_message(err_body, err)
        return nil, message
    end

    local results, parse_err = parse_results(body, max_results)
    if not results then
        return nil, parse_err
    end

    return results
end

return GoogleApi
