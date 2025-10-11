local DataStorage = require("datastorage")
local lfs = require("libs/libkoreader-lfs")
local socket_http = require("socket.http")
local socketutil = require("socketutil")
local ltn12 = require("ltn12")
local urlmod = require("socket.url")
local util = require("util")
local logger = require("logger")

local MuPDFRenderer = {}
MuPDFRenderer.__index = MuPDFRenderer

local DEFAULT_TIMEOUT = 20
local DEFAULT_MAXTIME = 60

local function ensureDirectory(path)
    local ok, err = util.makePath(path)
    if not ok then
        return false, err
    end
    return true
end

local function removePath(path)
    local attributes = lfs.attributes(path)
    if not attributes then
        return true
    end

    if attributes.mode == "directory" then
        for entry in lfs.dir(path) do
            if entry ~= "." and entry ~= ".." then
                local ok, err = removePath(path .. "/" .. entry)
                if not ok then
                    return false, err
                end
            end
        end
        local ok, err = lfs.rmdir(path)
        if not ok then
            return false, err
        end
        return true
    end

    local ok, err = os.remove(path)
    if not ok then
        return false, err
    end
    return true
end

local function dirname(path)
    local dir = path:match("(.+)/[^/]+$")
    return dir or ""
end

local function writeFile(path, data)
    local file, err = io.open(path, "wb")
    if not file then
        return false, err
    end
    file:write(data)
    file:close()
    return true
end

local function fetchUrl(url, timeout, maxtime)
    local chunks = {}
    socketutil:set_timeout(timeout or DEFAULT_TIMEOUT, maxtime or DEFAULT_MAXTIME)
    local ok, code, headers, status = socket_http.request{
        url = url,
        method = "GET",
        sink = ltn12.sink.table(chunks),
        headers = {
            ["user-agent"] = "Mozilla/5.0 (compatible; KOReader)",
        },
    }
    socketutil:reset_timeout()

    if not ok then
        return false, code or status or "request failed"
    end

    if code < 200 or code > 299 then
        return false, status or ("HTTP " .. tostring(code))
    end

    return true, table.concat(chunks), headers or {}
end

local function discoverAssets(html)
    local assets = {}

    for src in html:gmatch("<img%s+[^>]-src%s*=%s*['\"]%s*(.-)%s*['\"]") do
        table.insert(assets, { url = src, kind = "image" })
    end

    for href in html:gmatch("<link[^>]-rel%s*=%s*['\"]%s*stylesheet%s*['\"][^>]-href%s*=%s*['\"]%s*(.-)%s*['\"]") do
        table.insert(assets, { url = href, kind = "stylesheet" })
    end

    for src in html:gmatch("<script[^>]-src%s*=%s*['\"]%s*(.-)%s*['\"]") do
        table.insert(assets, { url = src, kind = "script" })
    end

    return assets
end

local function resolveUrl(base_url, ref)
    local parsed_ref = urlmod.parse(ref)
    if parsed_ref and parsed_ref.scheme then
        return urlmod.build(parsed_ref)
    end
    return urlmod.absolute(base_url, ref)
end

local function escapePattern(value)
    return (value:gsub("([%^%$%(%)%%%.%[%]%*%+%-%?])", "%%%1"))
end

local function relativePath(from_dir, to_path)
    if not from_dir or not to_path then
        return to_path
    end

    local function split(path)
        local parts = {}
        for part in path:gmatch("[^/]+") do
            table.insert(parts, part)
        end
        return parts
    end

    local origin = split(from_dir)
    local target = split(to_path)

    local i = 1
    while i <= #origin and i <= #target and origin[i] == target[i] do
        i = i + 1
    end

    local ups = #origin - (i - 1)
    local prefix = ups > 0 and string.rep("../", ups) or ""
    local tail = table.concat(target, "/", i)

    if tail == "" then
        return prefix ~= "" and prefix:sub(1, -2) or "./"
    end

    return prefix .. tail
end

local function rewriteRelativeLinksToAbsolute(html, page_url)
    local base_href = html:match("<base%s+[^>]-href%s*=%s*['\"]%s*(.-)%s*['\"]")
    local base = page_url

    if base_href and base_href ~= "" then
        local parsed_base = urlmod.parse(base_href)
        if parsed_base and parsed_base.scheme then
            base = urlmod.build(parsed_base)
        else
            base = urlmod.absolute(page_url, base_href)
        end
    end

    local function isRelativeLink(href)
        if not href or href == "" then
            return false
        end
        if href:sub(1, 1) == "#" then
            return false
        end
        if href:match("^[%w][%w%+%-.]*:") then
            return false
        end
        return true
    end

    html = html:gsub("(<a%s+[^>]-href%s*=%s*['\"])%s*(.-)%s*([\"'])", function(prefix, href, suffix)
        if isRelativeLink(href) then
            local absolute = urlmod.absolute(base, href)
            return prefix .. absolute .. suffix
        end
        return prefix .. href .. suffix
    end)

    return html
end

local function urlToCachePath(base_dir, url)
    local parsed = urlmod.parse(url)
    local host = parsed and parsed.host or "_"
    local path = parsed and parsed.path or "/"

    if path:sub(-1) == "/" then
        path = path .. "index"
    end

    local cleaned = (host .. path):gsub("[^%w%._%-%/]", "_")
    return base_dir .. "/" .. cleaned
end

local function extensionForContentType(content_type, url)
    if not content_type then
        if url then
            local ext = url:match("%.([%a%d]+)$")
            if ext and ext ~= "" then
                return "." .. ext
            end
        end
        return ""
    end

    content_type = content_type:lower()

    if content_type:find("text/html") or content_type:find("application/xhtml") then
        return ".html"
    end
    if content_type:find("text/css") then
        return ".css"
    end
    if content_type:find("javascript") then
        return ".js"
    end
    if content_type:find("image/png") then
        return ".png"
    end
    if content_type:find("image/jpeg") then
        return ".jpg"
    end
    if content_type:find("image/gif") then
        return ".gif"
    end
    if content_type:find("image/webp") then
        return ".webp"
    end
    if content_type:find("image/svg") then
        return ".svg"
    end

    if url then
        local ext = url:match("%.([%a%d]+)$")
        if ext and ext ~= "" then
            return "." .. ext
        end
    end

    return ""
end

function MuPDFRenderer:new(options)
    local instance = {
        base_dir = (options and options.base_dir) or (DataStorage:getDataDir() .. "/cache/webbrowser"),
        timeout = (options and options.timeout) or DEFAULT_TIMEOUT,
        maxtime = (options and options.maxtime) or DEFAULT_MAXTIME,
        keep_old_files = options and options.keep_old_files or false,
        download_images = options and options.download_images,
        use_stylesheets = options and options.use_stylesheets,
    }

    setmetatable(instance, self)

    ensureDirectory(instance.base_dir)

    return instance
end

function MuPDFRenderer:clearBaseDirectory(force)
    if self.keep_old_files and not force then
        return true
    end
    local dir = self.base_dir
    local attributes = lfs.attributes(dir)
    if not attributes then
        ensureDirectory(dir)
        return true
    end
    for entry in lfs.dir(dir) do
        if entry ~= "." and entry ~= ".." then
            local ok, err = removePath(dir .. "/" .. entry)
            if not ok then
                return false, err
            end
        end
    end
    return true
end

function MuPDFRenderer:forceClearCache()
    local cleared, err = self:clearBaseDirectory(true)
    if not cleared then
        return false, err
    end
    local ensured, ensure_err = ensureDirectory(self.base_dir)
    if not ensured then
        return false, ensure_err
    end
    return true
end

function MuPDFRenderer:fetchAndStore(url)
    if not url or url == "" then
        return false, "invalid url"
    end

    local ok_dir, dir_err = ensureDirectory(self.base_dir)
    if not ok_dir then
        return false, dir_err
    end

    local cleared, clear_err = self:clearBaseDirectory()
    if not cleared then
        return false, clear_err
    end

    local ok, body, headers_or_err = fetchUrl(url, self.timeout, self.maxtime)
    if not ok then
        return false, headers_or_err
    end

    local assets = discoverAssets(body)

    local main_path_base = urlToCachePath(self.base_dir, url)
    local main_dir = dirname(main_path_base)
    if main_dir ~= "" then
        local ensured, ensure_err = ensureDirectory(main_dir)
        if not ensured then
            return false, ensure_err
        end
    end

    local main_html_path = main_path_base .. ".html"

    for _, asset in ipairs(assets) do
        if asset.kind ~= "script" then -- ignore javascripts
            local should_download = true
            if asset.kind == "image" and self.download_images == false then
                should_download = false
            elseif asset.kind == "stylesheet" and self.use_stylesheets == false then
                should_download = false
            end

            if should_download then
                local ref = asset.url
                local resolved = resolveUrl(url, ref)
                if resolved and resolved ~= "" then
                    local asset_ok, asset_body, asset_headers = fetchUrl(resolved, self.timeout, self.maxtime)
                    if asset_ok and asset_body then
                        local asset_base = urlToCachePath(self.base_dir, resolved)
                        local asset_ext = extensionForContentType(asset_headers and asset_headers["content-type"], resolved)
                        local asset_path = asset_base .. asset_ext
                        local asset_dir = dirname(asset_path)
                        if asset_dir ~= "" then
                            local ensured_asset_dir, ensure_asset_err = ensureDirectory(asset_dir)
                            if not ensured_asset_dir then
                                logger.warn("webbrowser_renderer", "failed to create asset directory", asset_dir, ensure_asset_err)
                            end
                        end
                        local wrote = writeFile(asset_path, asset_body)
                        if wrote then
                            local relative = relativePath(main_dir, asset_path)
                            body = body:gsub(escapePattern(resolved), relative)
                            body = body:gsub(escapePattern(ref), relative)
                        else
                            logger.warn("webbrowser_renderer", "failed to write asset", asset_path)
                        end
                    end
                end
            end
        end
    end

    body = rewriteRelativeLinksToAbsolute(body, url)

    local wrote_main, write_err = writeFile(main_html_path, body)
    if not wrote_main then
        return false, write_err
    end

    local sdr_path = main_path_base .. ".sdr"
    local removed_sdr, remove_sdr_err = removePath(sdr_path)
    if not removed_sdr then
        logger.warn("webbrowser_renderer", "failed to remove existing .sdr directory", sdr_path, remove_sdr_err)
    end

    return true, main_html_path
end

return MuPDFRenderer
