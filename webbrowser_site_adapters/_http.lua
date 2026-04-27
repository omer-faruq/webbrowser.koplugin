-- Shared HTTP helper for site adapters.
--
-- Wraps KOReader's socket.http with sensible defaults, automatic redirect
-- following and a friendlier API for GET/POST. Adapters may use this helper
-- for any extra HTTP requests they need to perform (e.g. AJAX endpoints that
-- the page would normally hit from JavaScript).
--
-- Returns:
--   ok, body, headers   - on success (2xx)
--   false, err          - on failure or non-2xx final response

local socket_http = require("socket.http")
local socketutil = require("socketutil")
local ltn12 = require("ltn12")
local urlmod = require("socket.url")
local util = require("util")

local DEFAULT_TIMEOUT = 60
local DEFAULT_MAXTIME = 300
local DEFAULT_USER_AGENT = "Mozilla/5.0 (compatible; KOReader)"
local MAX_REDIRECTS = 5

local M = {}

local function encode_form(data)
    if type(data) ~= "table" then
        return tostring(data or "")
    end
    local parts = {}
    for k, v in pairs(data) do
        local key = urlmod.escape(tostring(k))
        local value
        if type(v) == "boolean" then
            value = v and "true" or "false"
        else
            value = urlmod.escape(tostring(v))
        end
        parts[#parts + 1] = key .. "=" .. value
    end
    return table.concat(parts, "&")
end

local function merge_headers(base, extra)
    local out = base and util.tableDeepCopy(base) or {}
    if extra then
        for k, v in pairs(extra) do
            out[k] = v
        end
    end
    return out
end

local function do_request(opts, redirect_count)
    redirect_count = redirect_count or 0
    if redirect_count > MAX_REDIRECTS then
        return false, "too many redirects"
    end

    local url = opts.url
    if type(url) ~= "string" or url == "" then
        return false, "invalid url"
    end

    local method = (opts.method or "GET"):upper()
    local headers = merge_headers({
        ["user-agent"] = DEFAULT_USER_AGENT,
        ["accept"] = "*/*",
    }, opts.headers)

    local source
    local data = opts.data
    if data ~= nil and (method == "POST" or method == "PUT" or method == "PATCH") then
        if type(data) == "table" then
            data = encode_form(data)
            headers["content-type"] = headers["content-type"] or "application/x-www-form-urlencoded"
        end
        headers["content-length"] = tostring(#data)
        source = ltn12.source.string(data)
    end

    local chunks = {}
    socketutil:set_timeout(opts.timeout or DEFAULT_TIMEOUT, opts.maxtime or DEFAULT_MAXTIME)
    local ok, code, resp_headers, status = socket_http.request{
        url = url,
        method = method,
        sink = ltn12.sink.table(chunks),
        source = source,
        headers = headers,
    }
    socketutil:reset_timeout()

    if not ok then
        return false, code or status or "request failed"
    end

    if resp_headers and resp_headers.location and code and code >= 300 and code <= 399 then
        local location = resp_headers.location
        if not location:match("^[%w][%w%+%-.]*:") then
            location = urlmod.absolute(url, location)
        end
        local preserve_body = (code == 307 or code == 308)
        local follow = {
            url = location,
            method = preserve_body and method or (method == "POST" and "GET" or method),
            headers = opts.headers,
            data = preserve_body and opts.data or nil,
            timeout = opts.timeout,
            maxtime = opts.maxtime,
        }
        return do_request(follow, redirect_count + 1)
    end

    if not code or code < 200 or code > 299 then
        return false, status or ("HTTP " .. tostring(code or "?")), resp_headers
    end

    return true, table.concat(chunks), resp_headers or {}
end

function M.request(opts)
    return do_request(opts or {})
end

function M.get(url, headers, opts)
    local o = opts and util.tableDeepCopy(opts) or {}
    o.url = url
    o.method = "GET"
    o.headers = merge_headers(o.headers, headers)
    return do_request(o)
end

function M.post(url, data, headers, opts)
    local o = opts and util.tableDeepCopy(opts) or {}
    o.url = url
    o.method = "POST"
    o.data = data
    o.headers = merge_headers(o.headers, headers)
    return do_request(o)
end

return M
