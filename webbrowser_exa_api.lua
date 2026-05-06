local https = require("ssl.https")
local socket_url = require("socket.url")
local ltn12 = require("ltn12")
local socketutil = require("socketutil")
local json = require("json")
local Utils = require("webbrowser_utils")
local logger = require("logger")

local ExaApi = {}

local DEFAULT_TIMEOUT = 15
local DEFAULT_MAXTIME = 30
local MAX_RESULTS_ALLOWED = 100

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

    if type(decoded.error) == "string" and decoded.error ~= "" then
        return decoded.error
    end

    if type(decoded.message) == "string" and decoded.message ~= "" then
        return decoded.message
    end

    if type(decoded.detail) == "string" and decoded.detail ~= "" then
        return decoded.detail
    end

    return fallback
end

local function parse_results(payload, limit)
    local ok, decoded = pcall(function()
        return json.decode(payload)
    end)
    if not ok or type(decoded) ~= "table" then
        return nil, "Failed to decode Exa Search response."
    end

    local exa_results = decoded.results
    if type(exa_results) ~= "table" then
        return {}
    end

    local results = {}

    for _, item in ipairs(exa_results) do
        if type(item) == "table" then
            local url = item.url
            local title = Utils.clean_text(item.title or "")
            local snippet = ""
            
            if type(item.text) == "string" and item.text ~= "" then
                snippet = Utils.clean_text(item.text)
            end
            
            if url and url ~= "" and title ~= "" then
                local parsed = socket_url.parse(url)
                local domain = parsed and parsed.host or nil
                
                local result_entry = {
                    url = url,
                    title = title,
                    snippet = snippet,
                    domain = domain,
                }

                if type(item.publishedDate) == "string" then
                    result_entry.published_date = item.publishedDate
                end

                if type(item.author) == "string" then
                    result_entry.author = item.author
                end

                table.insert(results, result_entry)
            end
        end
        if #results >= limit then
            break
        end
    end

    return results
end

function ExaApi.search(query, opts)
    local settings = opts or {}
    local api_key = settings.api_key
    if not api_key or api_key == "" then
        return nil, "Missing Exa Search API key."
    end

    local endpoint = settings.base_url or "https://api.exa.ai/search"
    local max_results = settings.max_results or MAX_RESULTS_ALLOWED
    if max_results < 1 then
        max_results = 1
    elseif max_results > MAX_RESULTS_ALLOWED then
        max_results = MAX_RESULTS_ALLOWED
    end

    local request_payload = {
        query = query,
        numResults = max_results,
        type = settings.search_type or "auto",
    }

    if settings.user_location and settings.user_location ~= "" then
        request_payload.userLocation = settings.user_location
    end

    if settings.category and settings.category ~= "" then
        request_payload.category = settings.category
    end

    if settings.include_text then
        request_payload.contents = {
            text = true
        }
    end

    local ok, request_body = pcall(function()
        return json.encode(request_payload)
    end)
    if not ok then
        return nil, "Failed to encode Exa request payload."
    end

    local headers = {
        ["Content-Type"] = "application/json",
        ["x-api-key"] = api_key,
        ["Accept"] = "application/json",
        ["User-Agent"] = settings.user_agent or "Mozilla/5.0 (compatible; KOReader)",
        ["Content-Length"] = tostring(#request_body),
    }

    local body, err, err_body = fetch_post(endpoint, headers, request_body, settings.timeout, settings.maxtime)
    if not body then
        local message = extract_error_message(err_body, err)
        if logger then
            logger.warn("webbrowser", "Exa API request failed", {
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

return ExaApi
