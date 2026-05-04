local HtmlParser = require("htmlparser")
local socket_http = require("socket.http")
local socket_url = require("socket.url")
local socket = require("socket")
local ltn12 = require("ltn12")
local socketutil = require("socketutil")
local Utils = require("webbrowser_utils")

local DuckDuckGo = {}

local DEFAULT_TIMEOUT = 15
local DEFAULT_MAXTIME = 30

local function fetch(url, timeout, maxtime)
    local response_chunks = {}
    socketutil:set_timeout(timeout or DEFAULT_TIMEOUT, maxtime or DEFAULT_MAXTIME)
    local request = {
        url = url,
        method = "GET",
        sink = ltn12.sink.table(response_chunks),
        headers = {
            ["user-agent"] = "Mozilla/5.0 (compatible; KOReader)"
        }
    }

    local code, headers, status = socket.skip(1, socket_http.request(request))
    socketutil:reset_timeout()

    if not code then
        return nil, status or "Request failed"
    end

    local numeric_code = tonumber(code) or 0
    if numeric_code < 200 or numeric_code >= 300 then
        return nil, status or tostring(code)
    end

    return table.concat(response_chunks), headers
end

local function extract_text(node)
    local raw = node:getcontent() or node:gettext()
    return Utils.clean_text(raw)
end

local function find_nodes_by_class(node, class_name, found)
    found = found or {}
    if node.attributes and node.attributes.class then
        for cls in node.attributes.class:gmatch("%S+") do
            if cls == class_name then
                table.insert(found, node)
                break
            end
        end
    end
    if node.nodes then
        for _, child in ipairs(node.nodes) do
            find_nodes_by_class(child, class_name, found)
        end
    end
    return found
end

local function find_first_child_with_class(node, tag_name, class_name)
    if not node.nodes then
        return nil
    end
    for _, child in ipairs(node.nodes) do
        local matches_tag = not tag_name or child.name == tag_name
        local matches_class = false
        if child.attributes and child.attributes.class then
            for cls in child.attributes.class:gmatch("%S+") do
                if cls == class_name then
                    matches_class = true
                    break
                end
            end
        end
        if matches_tag and matches_class then
            return child
        end
        local nested = find_first_child_with_class(child, tag_name, class_name)
        if nested then
            return nested
        end
    end
    return nil
end

local function normalize_language_code(code)
    if not code or code == "" then
        return "en-us"
    end
    
    local lower_code = code:lower()
    local parts = {}
    for part in lower_code:gmatch("[^-]+") do
        table.insert(parts, part)
    end
    
    if #parts ~= 2 then
        return lower_code
    end
    
    local first, second = parts[1], parts[2]
    
    local known_countries = {
        br = true, tr = true, us = true, uk = true, au = true, ca = true,
        de = true, fr = true, es = true, it = true, nl = true, pl = true,
        ru = true, jp = true, cn = true, kr = true, ["in"] = true, za = true,
        mx = true, ar = true, cl = true, co = true, pe = true, ve = true,
        at = true, be = true, ch = true, cz = true, dk = true, ee = true,
        fi = true, gr = true, hr = true, hu = true, ie = true, il = true,
        lt = true, lv = true, no = true, nz = true, ph = true, pt = true,
        ro = true, se = true, sg = true, sk = true, sl = true, th = true,
        tw = true, ua = true, vn = true, hk = true, id = true, my = true,
        bg = true, xa = true, ct = true, xl = true, ue = true, wt = true,
    }
    
    local known_languages = {
        en = true, pt = true, es = true, fr = true, de = true, it = true,
        nl = true, pl = true, ru = true, tr = true, ar = true, zh = true,
        ja = true, ko = true, he = true, el = true, cs = true, da = true,
        et = true, fi = true, hu = true, id = true, ms = true, no = true,
        ro = true, sk = true, sl = true, sv = true, th = true, uk = true,
        vi = true, bg = true, hr = true, lt = true, lv = true, ca = true,
        tl = true, tzh = true,
    }
    
    if #first == 2 and #second == 2 then
        if known_languages[first] and known_countries[second] then
            return second .. "-" .. first
        end
    elseif (#first == 2 and #second == 3) or (#first == 3 and #second == 2) then
        if known_languages[first] and known_countries[second] then
            return second .. "-" .. first
        elseif known_languages[second] and known_countries[first] then
            return lower_code
        end
    end
    
    return lower_code
end

local function parse_results(html)
    local results = {}
    local root = HtmlParser.parse(html)
    local nodes = find_nodes_by_class(root, "result")
    for _, node in ipairs(nodes) do
        local link_node = find_first_child_with_class(node, "a", "result__a")
        local snippet_node = find_first_child_with_class(node, "a", "result__snippet")
        if link_node then
            local href = link_node.attributes and link_node.attributes.href or ""
            local title = extract_text(link_node)
            local snippet = snippet_node and extract_text(snippet_node) or ""
            if href ~= "" and title ~= "" then
                href = Utils.decode_result_url(href)
                table.insert(results, {
                    url = href,
                    title = title,
                    snippet = snippet,
                })
            end
        end
        if #results >= DuckDuckGo.max_results then
            break
        end
    end
    return results
end

function DuckDuckGo.search(query, opts)
    local settings = opts or {}
    DuckDuckGo.base_url = settings.base_url or "https://duckduckgo.com"
    DuckDuckGo.search_path = settings.search_path or "/html/"
    local language = settings.kl or settings.language or "en-US"
    DuckDuckGo.language = normalize_language_code(language)
    DuckDuckGo.max_results = settings.max_results or 50

    local query_url = string.format("%s%s?q=%s&kl=%s&kp=1&kz=1", DuckDuckGo.base_url, DuckDuckGo.search_path, socket_url.escape(query), DuckDuckGo.language)
    local html, err = fetch(query_url)
    if not html then
        return nil, err or "Failed to fetch results"
    end

    return parse_results(html)
end

return DuckDuckGo
