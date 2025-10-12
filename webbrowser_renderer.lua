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

local DEFAULT_TIMEOUT = 60
local DEFAULT_MAXTIME = 300

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

local function fetchUrl(url, timeout, maxtime, redirect_count, request_headers)
    redirect_count = redirect_count or 0
    if redirect_count > 5 then
        return false, "too many redirects"
    end
    local chunks = {}
    local headers = request_headers and util.tableDeepCopy(request_headers) or {
        ["user-agent"] = "Mozilla/5.0 (compatible; KOReader)",
    }
    socketutil:set_timeout(timeout or DEFAULT_TIMEOUT, maxtime or DEFAULT_MAXTIME)
    local ok, code, headers, status = socket_http.request{
        url = url,
        method = "GET",
        sink = ltn12.sink.table(chunks),
        headers = headers,
    }
    socketutil:reset_timeout()

    if not ok then
        return false, code or status or "request failed"
    end

    if code >= 300 and code <= 399 and headers and headers.location then
        local location = headers.location
        if location and location ~= "" then
            if not location:match("^[%w][%w%+%-.]*:") then
                location = urlmod.absolute(url, location)
            end
            local next_headers = request_headers and util.tableDeepCopy(request_headers) or {}
            next_headers["user-agent"] = next_headers["user-agent"] or "Mozilla/5.0 (compatible; KOReader)"
            next_headers.Referer = url
            return fetchUrl(location, timeout, maxtime, redirect_count + 1, next_headers)
        end
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
    local function normalizeExt(ext)
        ext = ext and ext:lower() or nil
        if not ext or ext == "" then
            return nil
        end
        if ext:sub(1, 1) ~= "." then
            ext = "." .. ext
        end
        return ext
    end

    local path
    if url then
        path = url:match("([^?#]+)") or url
    end
    local url_ext = path and normalizeExt(path:match("%.([%a%d]+)$")) or nil
    local function isHtmlExt(ext)
        return ext == ".html" or ext == ".htm" or ext == ".xhtml"
    end

    if url_ext and not isHtmlExt(url_ext) then
        return url_ext
    end

    if not content_type then
        if url_ext then
            return url_ext
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
    if content_type:find("pdf") then
        return ".pdf"
    end
    if content_type:find("epub") then
        return ".epub"
    end
    if content_type:find("mobi") then
        return ".mobi"
    end
    if content_type:find("application/zip") or content_type:find("application/x%-zip") then
        return ".zip"
    end
    if content_type:find("application/octet%-stream") then
        if url_ext then
            return url_ext
        end
        return ""
    end

    if url_ext then
        return url_ext
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

    local headers = type(headers_or_err) == "table" and headers_or_err or {}
    local content_type = headers["content-type"]

    local main_path_base = urlToCachePath(self.base_dir, url)
    local main_dir = dirname(main_path_base)
    if main_dir ~= "" then
        local ensured, ensure_err = ensureDirectory(main_dir)
        if not ensured then
            return false, ensure_err
        end
    end

    local extension = extensionForContentType(content_type, url)
    if extension == "" then
        extension = ".html"
    end

    local function ensureExtension(base_path, ext)
        if ext == "" then
            return base_path
        end
        if base_path:sub(-#ext):lower() == ext:lower() then
            return base_path
        end
        return base_path .. ext
    end

    local output_path = ensureExtension(main_path_base, extension)
    local is_html = extension == ".html" or extension == ".htm" or extension == ".xhtml"

    if not is_html then
        local wrote_binary, write_binary_err = writeFile(output_path, body)
        if not wrote_binary then
            return false, write_binary_err
        end
        return true, output_path
    end

    local assets = discoverAssets(body)

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

    local wrote_main, write_err = writeFile(output_path, body)
    if not wrote_main then
        return false, write_err
    end

    local sdr_path = main_path_base .. ".sdr"
    local removed_sdr, remove_sdr_err = removePath(sdr_path)
    if not removed_sdr then
        logger.warn("webbrowser_renderer", "failed to remove existing .sdr directory", sdr_path, remove_sdr_err)
    end

    return true, output_path
end

return MuPDFRenderer
