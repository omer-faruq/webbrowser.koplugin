-- Search engine backed by a local kiwix-serve instance, so offline ZIM
-- archives (Wikipedia, Wiktionary, Stack Exchange, ...) can be searched and
-- read without any internet connection.
--
-- Start a server next to your archives, then point base_url at it:
--   kiwix-serve --port=8888 wikipedia_en_physics_mini_2026-07.zim
--
-- Endpoint reference: https://kiwix-tools.readthedocs.io/en/latest/kiwix-serve.html

local WebBrowserHttp = require("webbrowser_http")
local socket_url = require("socket.url")
local socket = require("socket")
local ltn12 = require("ltn12")
local socketutil = require("socketutil")
local logger = require("logger")
local libxml = require("webbrowser_xml")
local treehdl = require("webbrowser_xml_handler")
local Utils = require("webbrowser_utils")

local Kiwix = {}

-- A local server answers instantly; long waits here only mean it is down.
local DEFAULT_TIMEOUT = 10
local DEFAULT_MAXTIME = 20
local DEFAULT_BASE_URL = "http://localhost:8888"
local DEFAULT_MAX_RESULTS = 25
local MAX_PAGE_LENGTH = 140 -- kiwix-serve caps pageLength at 140

local function fetch(url, timeout, maxtime)
    local response_chunks = {}
    socketutil:set_timeout(timeout or DEFAULT_TIMEOUT, maxtime or DEFAULT_MAXTIME)

    local code, _, status = socket.skip(1, WebBrowserHttp.request {
        url = url,
        method = "GET",
        sink = ltn12.sink.table(response_chunks),
        headers = {
            ["user-agent"] = "Mozilla/5.0 (compatible; KOReader)",
            ["accept"] = "application/xml, text/xml",
        },
    })
    socketutil:reset_timeout()

    local body = table.concat(response_chunks)

    -- On a transport failure luasocket returns the reason where the status
    -- code would be, so a non-numeric code means we never reached a server.
    local numeric_code = tonumber(code)
    if not numeric_code then
        return nil, tostring(code or status or "Request failed"), nil, body
    end

    if numeric_code < 200 or numeric_code >= 300 then
        return nil, status or ("HTTP " .. tostring(numeric_code)), numeric_code, body
    end

    return body, nil, numeric_code, body
end

local function normalize_base_url(base_url)
    local url = base_url
    if type(url) ~= "string" or url == "" then
        url = DEFAULT_BASE_URL
    end
    url = url:gsub("%s+", "")
    if not url:match("^[a-zA-Z][a-zA-Z0-9+.-]*://") then
        url = "http://" .. url
    end
    return (url:gsub("/+$", ""))
end

-- kiwix-serve error bodies are not well-formed XML (the declaration is missing
-- its "?>"), so they must never be handed to the parser.
local function extract_error_message(body, fallback)
    if type(body) ~= "string" or body == "" then
        return fallback
    end

    local details = {}
    for detail in body:gmatch("<detail>(.-)</detail>") do
        detail = Utils.clean_text(detail)
        if detail ~= "" then
            table.insert(details, detail)
        end
    end
    if #details > 0 then
        return table.concat(details, " ")
    end

    local err = body:match("<error>(.-)</error>")
    if err then
        err = Utils.clean_text(err)
        if err ~= "" then
            return err
        end
    end

    return fallback
end

-- simpleTreeHandler collapses a lone repeated element into a bare node instead
-- of a one-element array, so every repeated field needs this.
local function as_list(node)
    if type(node) ~= "table" then
        return {}
    end
    if node[1] ~= nil then
        return node
    end
    return { node }
end

local function node_text(node)
    if type(node) == "string" then
        return Utils.clean_text(node)
    end
    if type(node) == "table" then
        -- elements carrying attributes land under a nested text field
        local text = node[1]
        if type(text) == "string" then
            return Utils.clean_text(text)
        end
    end
    return ""
end

local function parse_results(xml_body, base_url, limit)
    local handler = treehdl.simpleTreeHandler()
    local ok, err = pcall(function()
        libxml.xmlParser(handler):parse(xml_body)
    end)
    if not ok then
        logger.warn("webbrowser", "kiwix: failed to parse search feed", err)
        return nil, "Could not parse the kiwix-serve response."
    end

    local root = handler.root
    local channel = root and root.rss and root.rss.channel
    if type(channel) ~= "table" then
        return nil, "Unexpected kiwix-serve response."
    end

    local results = {}
    for _, item in ipairs(as_list(channel.item)) do
        if type(item) == "table" then
            local title = node_text(item.title)
            local link = node_text(item.link)
            if title ~= "" and link ~= "" then
                local entry = {
                    url = Utils.absolute_url(base_url, link),
                    title = title,
                    snippet = node_text(item.description),
                }

                -- the archive name reads better than "localhost" in the list
                local book = item.book
                if type(book) == "table" then
                    local book_title = node_text(book.title)
                    if book_title ~= "" then
                        entry.domain = book_title
                    end
                end

                table.insert(results, entry)
            end
        end
        if #results >= limit then
            break
        end
    end

    local metadata = {}
    local total = tonumber(node_text(channel["opensearch:totalResults"]))
    if total then
        metadata.total_results = total
    end
    local start_index = tonumber(node_text(channel["opensearch:startIndex"]))
    if start_index then
        metadata.start_index = start_index
    end
    if metadata.total_results or metadata.start_index then
        results._metadata = metadata
    end

    return results
end

-- kiwix-serve keeps two disjoint ways of naming an archive:
--   books.name        the file name the server was started with ("ray-charles")
--   books.filter.name the name stored inside the archive, which is also what
--                     the catalogue reports ("wikipedia_en_ray-charles")
-- Passing a name to the wrong one is answered with HTTP 400, and both are
-- plausible things for a user to have written down, so each is tried in turn.
-- The parameter that worked is remembered, keyed by server and archive, so the
-- extra request happens once rather than on every search.
local BOOK_PARAMS = { "books.name", "books.filter.name" }
local resolved_book_param = {}

local function book_param_order(base_url, books)
    local cached = resolved_book_param[base_url .. "\0" .. table.concat(books, "\0")]
    if not cached then
        return BOOK_PARAMS
    end
    local order = { cached }
    for _, param in ipairs(BOOK_PARAMS) do
        if param ~= cached then
            table.insert(order, param)
        end
    end
    return order
end

local function remember_book_param(base_url, books, param)
    resolved_book_param[base_url .. "\0" .. table.concat(books, "\0")] = param
end

local function collect_books(settings)
    local books = {}
    if type(settings.books) == "table" then
        for _, name in ipairs(settings.books) do
            if type(name) == "string" and name ~= "" then
                table.insert(books, name)
            end
        end
    end
    if type(settings.book_name) == "string" and settings.book_name ~= "" then
        table.insert(books, settings.book_name)
    end
    return books
end

local function build_query_url(base_url, query, settings, books, book_param, start_index, page_length)
    local parts = {
        "pattern=" .. socket_url.escape(query),
        "format=xml",
        "pageLength=" .. tostring(page_length),
        "start=" .. tostring(start_index),
    }

    for _, name in ipairs(books) do
        -- strip a trailing .zim: the server registers books without it
        local book = name:gsub("%.zim$", "")
        table.insert(parts, book_param .. "=" .. socket_url.escape(book))
    end

    if type(settings.filter_lang) == "string" and settings.filter_lang ~= "" then
        table.insert(parts, "books.filter.lang=" .. socket_url.escape(settings.filter_lang))
    end

    return base_url .. "/search?" .. table.concat(parts, "&")
end

function Kiwix.search(query, opts)
    local settings = opts or {}
    local base_url = normalize_base_url(settings.base_url)

    local page_length = tonumber(settings.max_results) or DEFAULT_MAX_RESULTS
    if page_length < 1 then
        page_length = 1
    elseif page_length > MAX_PAGE_LENGTH then
        page_length = MAX_PAGE_LENGTH
    end

    local start_index = tonumber(settings.start_index) or 0
    if start_index < 0 then
        start_index = 0
    end

    local books = collect_books(settings)
    local url, body, err, code, raw_body

    if #books > 0 then
        for _, param in ipairs(book_param_order(base_url, books)) do
            url = build_query_url(base_url, query, settings, books, param, start_index, page_length)
            body, err, code, raw_body = fetch(url, settings.timeout, settings.maxtime)
            if body then
                remember_book_param(base_url, books, param)
                break
            end
            if code ~= 400 then
                -- not a naming mismatch, so trying the other parameter is pointless
                break
            end
        end

        -- The name matches neither scheme. Rather than failing outright, search
        -- everything the server has loaded.
        if not body and code == 400 then
            logger.warn("webbrowser", "kiwix: unknown archive name, retrying across the whole library",
                extract_error_message(raw_body, err))
            url = build_query_url(base_url, query, settings, {}, BOOK_PARAMS[1], start_index, page_length)
            body, err, code, raw_body = fetch(url, settings.timeout, settings.maxtime)
        end
    else
        url = build_query_url(base_url, query, settings, {}, BOOK_PARAMS[1], start_index, page_length)
        body, err, code, raw_body = fetch(url, settings.timeout, settings.maxtime)
    end

    if not body then
        local message = extract_error_message(raw_body, err)
        logger.warn("webbrowser", "kiwix: search request failed", url, message)
        if not code then
            -- no HTTP status at all: nothing is listening on that address
            return nil, string.format(
                "Could not reach kiwix-serve at %s. Is the server running?", base_url)
        end
        return nil, message or "kiwix-serve search failed."
    end

    return parse_results(body, base_url, page_length)
end

-- Lists the archives a server has loaded, so they can be picked from a menu
-- instead of typed from memory. `name` is the catalogue name, which search
-- reaches through books.filter.name.
function Kiwix.list_archives(opts)
    local settings = opts or {}
    local base_url = normalize_base_url(settings.base_url)

    -- count=-1 asks for the whole catalogue rather than the first page
    local url = base_url .. "/catalog/v2/entries?count=-1"
    local body, err, code, raw_body = fetch(url, settings.timeout, settings.maxtime)

    if not body then
        if not code then
            return nil, string.format(
                "Could not reach kiwix-serve at %s. Is the server running?", base_url)
        end
        return nil, extract_error_message(raw_body, err) or "Could not read the archive list."
    end

    local handler = treehdl.simpleTreeHandler()
    local ok, parse_err = pcall(function()
        libxml.xmlParser(handler):parse(body)
    end)
    if not ok then
        logger.warn("webbrowser", "kiwix: failed to parse catalogue", parse_err)
        return nil, "Could not parse the archive list."
    end

    local feed = handler.root and handler.root.feed
    if type(feed) ~= "table" then
        return nil, "Unexpected catalogue response."
    end

    local archives = {}
    for _, entry in ipairs(as_list(feed.entry)) do
        if type(entry) == "table" then
            -- entry.name is the archive; author/publisher carry their own
            -- nested <name>, which stays out of the way under those keys
            local name = node_text(entry.name)
            if name ~= "" then
                table.insert(archives, {
                    name = name,
                    title = node_text(entry.title),
                    language = node_text(entry.language),
                    flavour = node_text(entry.flavour),
                    article_count = tonumber(node_text(entry.articleCount)),
                })
            end
        end
    end

    table.sort(archives, function(a, b)
        local left = (a.title ~= "" and a.title) or a.name
        local right = (b.title ~= "" and b.title) or b.name
        return left:lower() < right:lower()
    end)

    return archives
end

return Kiwix
