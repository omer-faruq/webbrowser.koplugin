local https = require("ssl.https")
local socket_url = require("socket.url")
local ltn12 = require("ltn12")
local socketutil = require("socketutil")
local json = require("json")
local Utils = require("webbrowser_utils")
local logger = require("logger")

local TavilyApi = {}

local DEFAULT_TIMEOUT = 15
local DEFAULT_MAXTIME = 30
local MAX_RESULTS_ALLOWED = 20

local function fetch_post(url, headers, body, timeout, maxtime)
    local response_chunks = {}
    socketutil:set_timeout(timeout or DEFAULT_TIMEOUT, maxtime or DEFAULT_MAXTIME)
    
    local request_body = body or ""
    local ok, status_code, _, status_line = https.request {
        url = url,
        method = "POST",
        headers = headers,
        source = ltn12.source.string(request_body),
        sink = ltn12.sink.table(response_chunks),
    }
    socketutil:reset_timeout()

    local response_body = table.concat(response_chunks)

    if not ok then
        return nil, status_line or status_code or "Request failed", response_body
    end

    local numeric_code = tonumber(status_code) or 0
    if numeric_code < 200 or numeric_code >= 300 then
        local message = status_line or ("HTTP " .. tostring(status_code))
        return nil, message, response_body, numeric_code
    end

    return response_body
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

    if type(decoded.detail) == "table" and type(decoded.detail.error) == "string" then
        return decoded.detail.error
    end

    if type(decoded.detail) == "string" and decoded.detail ~= "" then
        return decoded.detail
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
        return nil, "Failed to decode Tavily Search response."
    end

    local tavily_results = decoded.results
    if type(tavily_results) ~= "table" then
        return {}
    end

    local results = {}
    local metadata = {}

    if type(decoded.answer) == "string" and decoded.answer ~= "" then
        metadata.answer = decoded.answer
    end

    if type(decoded.response_time) == "number" then
        metadata.response_time = decoded.response_time
    end

    for _, item in ipairs(tavily_results) do
        if type(item) == "table" then
            local url = item.url
            local title = Utils.clean_text(item.title or "")
            local snippet = Utils.clean_text(item.content or "")
            
            if url and url ~= "" and title ~= "" then
                local parsed = socket_url.parse(url)
                local domain = parsed and parsed.host or nil
                
                local result_entry = {
                    url = url,
                    title = title,
                    snippet = snippet,
                    domain = domain,
                }

                if type(item.score) == "number" then
                    result_entry.score = item.score
                end

                table.insert(results, result_entry)
            end
        end
        if #results >= limit then
            break
        end
    end

    if metadata.answer or metadata.response_time then
        results._metadata = metadata
    end

    return results
end

function TavilyApi.search(query, opts)
    local settings = opts or {}
    local api_key = settings.api_key
    if not api_key or api_key == "" then
        return nil, "Missing Tavily Search API key."
    end

    local endpoint = settings.base_url or "https://api.tavily.com/search"
    local max_results = settings.max_results or MAX_RESULTS_ALLOWED
    if max_results < 1 then
        max_results = 1
    elseif max_results > MAX_RESULTS_ALLOWED then
        max_results = MAX_RESULTS_ALLOWED
    end

    local request_payload = {
        query = query,
        max_results = max_results,
        search_depth = settings.search_depth or "basic",
        topic = settings.topic or "general",
    }

    if settings.include_answer then
        request_payload.include_answer = settings.include_answer
    end

    if settings.include_raw_content then
        request_payload.include_raw_content = settings.include_raw_content
    end

    if settings.include_images then
        request_payload.include_images = settings.include_images
    end

    if settings.include_image_descriptions then
        request_payload.include_image_descriptions = settings.include_image_descriptions
    end

    if settings.include_favicon then
        request_payload.include_favicon = settings.include_favicon
    end

    if settings.time_range and settings.time_range ~= "" then
        request_payload.time_range = settings.time_range
    end

    if settings.start_date and settings.start_date ~= "" then
        request_payload.start_date = settings.start_date
    end

    if settings.end_date and settings.end_date ~= "" then
        request_payload.end_date = settings.end_date
    end

    if settings.country and settings.country ~= "" then
        request_payload.country = settings.country
    end

    if type(settings.include_domains) == "table" and #settings.include_domains > 0 then
        request_payload.include_domains = settings.include_domains
    end

    if type(settings.exclude_domains) == "table" and #settings.exclude_domains > 0 then
        request_payload.exclude_domains = settings.exclude_domains
    end

    local ok, request_body = pcall(function()
        return json.encode(request_payload)
    end)
    if not ok then
        return nil, "Failed to encode Tavily request payload."
    end

    local headers = {
        ["Content-Type"] = "application/json",
        ["Authorization"] = "Bearer " .. api_key,
        ["Accept"] = "application/json",
        ["User-Agent"] = settings.user_agent or "Mozilla/5.0 (compatible; KOReader)",
        ["Content-Length"] = tostring(#request_body),
    }

    local body, err, err_body = fetch_post(endpoint, headers, request_body, settings.timeout, settings.maxtime)
    if not body then
        local message = extract_error_message(err_body, err)
        if logger then
            logger.warn("webbrowser", "Tavily API request failed", {
                url = endpoint,
                query = query,
                max_results = max_results,
                message = message,
                err_body = err_body,
            })
        end
        return nil, message
    end

    local results, parse_err = parse_results(body, max_results)
    if not results then
        return nil, parse_err
    end

    return results
end

return TavilyApi
