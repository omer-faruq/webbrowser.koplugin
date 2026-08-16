local socket_url = require("socket.url")
local frontend_util = require("util")

local Utils = {}

local function trim(text)
    if not text then
        return ""
    end
    text = text:gsub("^%s+", "")
    text = text:gsub("%s+$", "")
    return text
end

local function html_entities_to_utf8(text)
    if not text or text == "" then
        return ""
    end
    return frontend_util.htmlEntitiesToUtf8(text)
end

local function parse_query_string(query)
    local params = {}
    if not query or query == "" then
        return params
    end
    for pair in query:gmatch("[^&]+") do
        local key, value = pair:match("([^=]+)=(.*)")
        if key then
            key = socket_url.unescape(key)
            value = socket_url.unescape(value or "")
            params[key] = value
        else
            pair = socket_url.unescape(pair)
            params[pair] = ""
        end
    end
    return params
end

function Utils.decode_result_url(raw_url)
    if not raw_url or raw_url == "" then
        return raw_url
    end

    local parsed = socket_url.parse(raw_url)
    if not parsed then
        return raw_url
    end

    if parsed.query then
        local params = parse_query_string(parsed.query)
        if params.uddg and params.uddg ~= "" then
            return params.uddg
        end
    end

    if parsed.scheme and parsed.host then
        return socket_url.build(parsed)
    end

    return raw_url
end

function Utils.absolute_url(base_url, link)
    if not link or link == "" then
        return nil
    end
    if link:match("^[a-zA-Z][a-zA-Z0-9+.-]*://") then
        return link
    end
    if not base_url or base_url == "" then
        return link
    end
    local absolute = socket_url.absolute(base_url, link)
    return absolute or link
end

function Utils.strip_fragment(url)
    if type(url) ~= "string" or url == "" then
        return url
    end
    local fragment_start = url:find("#", 1, true)
    if fragment_start then
        return url:sub(1, fragment_start - 1)
    end
    return url
end

function Utils.ensure_markdown_gateway(url)
    if not url or url == "" then
        return url
    end
    if url:match("^https://r%.jina%.ai/") then
        return url
    end
    -- A cloud gateway cannot reach a server running on this device, and asking
    -- it to try would defeat the point of an offline source such as kiwix-serve.
    if Utils.is_loopback_url(url) then
        return url
    end
    local stripped = Utils.strip_fragment(url)
    return "https://r.jina.ai/" .. (stripped or url)
end

function Utils.clean_text(text)
    return trim(html_entities_to_utf8(text))
end

-- True when the URL points at this device, i.e. no network link is needed to
-- reach it. Used to skip NetworkMgr:runWhenOnline() so that a locally served
-- source (kiwix-serve) stays usable with Wi-Fi off.
function Utils.is_loopback_url(url)
    if type(url) ~= "string" or url == "" then
        return false
    end

    -- The host is pulled out by hand rather than via socket_url.parse(),
    -- which mangles bracketed IPv6 authorities like "[::1]:8888".
    local authority = url:match("^%a[%w+.-]*://([^/?#]*)") or url:match("^([^/?#]*)")
    if not authority or authority == "" then
        return false
    end
    authority = authority:gsub("^[^@]*@", "") -- drop any userinfo

    local host
    if authority:sub(1, 1) == "[" then
        host = authority:match("^%[([^%]]*)%]")
    else
        host = authority:match("^([^:]*)")
    end
    if not host or host == "" then
        return false
    end

    host = host:lower()

    if host == "localhost" or host == "::1" or host == "0:0:0:0:0:0:0:1" then
        return true
    end

    -- IPv4-mapped IPv6, e.g. "::ffff:127.0.0.1"
    local mapped = host:match("^::ffff:(%d+%.%d+%.%d+%.%d+)$")
    if mapped then
        host = mapped
    end

    -- the whole 127.0.0.0/8 block, not just 127.0.0.1
    local a, b, c, d = host:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
    if a then
        a, b, c, d = tonumber(a), tonumber(b), tonumber(c), tonumber(d)
        if a == 127 and b < 256 and c < 256 and d < 256 then
            return true
        end
    end

    return false
end

function Utils.parse_query_string(query)
    return parse_query_string(query)
end

return Utils
