local https = require("ssl.https")
local socket_url = require("socket.url")
local ltn12 = require("ltn12")
local socketutil = require("socketutil")
local json = require("json")
local Utils = require("webbrowser_utils")

local BraveApi = {}

local DEFAULT_TIMEOUT = 15
local DEFAULT_MAXTIME = 30
local DEFAULT_PAGE_SIZE = 10
local MAX_RESULTS_ALLOWED = 20

local function build_query_url(base_url, params)
    local query_parts = {}
    for key, value in pairs(params) do
        if value ~= nil and value ~= "" then
            table.insert(query_parts, string.format("%s=%s", socket_url.escape(tostring(key)), socket_url.escape(tostring(value))))
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
        return decoded.error.message or decoded.error.code or fallback
    end

    if type(decoded.message) == "string" and decoded.message ~= "" then
        return decoded.message
    end

    if type(decoded.error) == "string" and decoded.error ~= "" then
        return decoded.error
    end

    return fallback
end

local function parse_results(payload, limit)
    local ok, decoded = pcall(function()
        return json.decode(payload)
    end)
    if not ok or type(decoded) ~= "table" then
        return nil, "Failed to decode Brave Search response."
    end

    local web_results = decoded.web and decoded.web.results
    if type(web_results) ~= "table" then
        return {}
    end

    local results = {}
    for _, item in ipairs(web_results) do
        if type(item) == "table" then
            local url = item.url or item.link
            local title = Utils.clean_text(item.title or "")
            local snippet = Utils.clean_text(item.description or item.snippet or "")
            if url and url ~= "" and title ~= "" then
                local parsed = socket_url.parse(url)
                local domain = parsed and parsed.host or nil
                table.insert(results, {
                    url = url,
                    title = title,
                    snippet = snippet,
                    domain = domain,
                })
            end
        end
        if #results >= limit then
            break
        end
    end

    return results
end

function BraveApi.search(query, opts)
    local settings = opts or {}
    local api_key = settings.api_key
    if not api_key or api_key == "" then
        return nil, "Missing Brave Search API key."
    end

    local endpoint = settings.base_url or "https://api.search.brave.com/res/v1/web/search"
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
        q = query,
        count = page_size,
        offset = settings.offset or 0,
    }

    local language = settings.language or settings.lang
    if language and language ~= "" then
        params.lang = language
    end

    local country = settings.country
    if country and country ~= "" then
        params.country = country
    end

    local search_lang = settings.search_lang
    if search_lang and search_lang ~= "" then
        params.search_lang = search_lang
    end

    local ui_lang = settings.ui_lang
    if ui_lang and ui_lang ~= "" then
        params.ui_lang = ui_lang
    end

    local fresh = settings.freshness
    if fresh and fresh ~= "" then
        params.freshness = fresh
    end

    local safesearch = settings.safesearch or settings.safe_search
    if safesearch and safesearch ~= "" then
        params.safesearch = safesearch
    end

    local url = build_query_url(endpoint, params)

    local headers = {
        ["Accept"] = "application/json",
        ["User-Agent"] = settings.user_agent or "Mozilla/5.0 (compatible; KOReader)",
        ["X-Subscription-Token"] = api_key,
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

return BraveApi
