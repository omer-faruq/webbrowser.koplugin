-- Site adapter dispatcher for the webbrowser plugin.
--
-- Adapters live in the webbrowser_site_adapters/ subfolder. Each adapter is
-- a Lua module that returns a table with the following shape:
--
--   return {
--       hosts = { "example.com", "www.example.com" }, -- optional host list
--       match = function(url, parsed_url) return true end, -- optional matcher
--       transform = function(ctx) return new_html end,     -- required
--   }
--
-- transform() receives a ctx table with:
--   ctx.url     - original page URL
--   ctx.body    - fetched HTML body
--   ctx.headers - response headers table
-- It should return a new HTML string to replace the body, or nil to skip.
--
-- Files whose name starts with "_" are treated as shared helpers and are
-- skipped by the loader (see _http.lua, _template.lua).
--
-- Host matching is case-insensitive and matches the exact host or any
-- subdomain. If no host entry matches, an optional `match` function may be
-- provided for custom logic.

local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local urlmod = require("socket.url")

local SiteAdapters = {}

local cached_adapters

local function adapter_dir()
    local info = debug.getinfo(1, "S").source
    if info:sub(1, 1) == "@" then
        info = info:sub(2)
    end
    local dir = info:gsub("[\\/][^\\/]+$", "")
    return dir .. "/webbrowser_site_adapters"
end

local function load_adapter(name)
    local ok, mod = pcall(require, "webbrowser_site_adapters." .. name)
    if not ok then
        logger.warn("webbrowser_site_adapters", "failed to load", name, mod)
        return nil
    end
    if type(mod) ~= "table" or type(mod.transform) ~= "function" then
        logger.warn("webbrowser_site_adapters", "invalid adapter", name)
        return nil
    end
    mod._name = name
    return mod
end

local function load_all()
    if cached_adapters then
        return cached_adapters
    end
    cached_adapters = {}
    local dir = adapter_dir()
    local attr = lfs.attributes(dir)
    if not attr or attr.mode ~= "directory" then
        return cached_adapters
    end
    for entry in lfs.dir(dir) do
        if entry ~= "." and entry ~= ".."
            and entry:sub(-4) == ".lua"
            and entry:sub(1, 1) ~= "_" then
            local adapter_name = entry:sub(1, -5)
            local adapter = load_adapter(adapter_name)
            if adapter then
                table.insert(cached_adapters, adapter)
            end
        end
    end
    return cached_adapters
end

local function host_matches(adapter, host)
    if type(adapter.hosts) ~= "table" or host == "" then
        return false
    end
    for _, candidate in ipairs(adapter.hosts) do
        if type(candidate) == "string" and candidate ~= "" then
            local needle = candidate:lower()
            if host == needle then
                return true
            end
            if #host > #needle and host:sub(-(#needle + 1)) == "." .. needle then
                return true
            end
        end
    end
    return false
end

function SiteAdapters:reload()
    cached_adapters = nil
end

function SiteAdapters:list()
    local out = {}
    for _, adapter in ipairs(load_all()) do
        table.insert(out, adapter._name)
    end
    return out
end

function SiteAdapters:find(url)
    if type(url) ~= "string" or url == "" then
        return nil
    end
    local parsed = urlmod.parse(url)
    local host = parsed and parsed.host and parsed.host:lower() or ""
    for _, adapter in ipairs(load_all()) do
        if host_matches(adapter, host) then
            return adapter
        end
        if type(adapter.match) == "function" then
            local ok, matched = pcall(adapter.match, url, parsed)
            if ok and matched then
                return adapter
            end
        end
    end
    return nil
end

-- Apply the matching adapter (if any) to a fetched page.
-- ctx fields: { url, body, headers }
-- Returns: (new_body, adapter_name) or nil.
function SiteAdapters:apply(ctx)
    if type(ctx) ~= "table"
        or type(ctx.url) ~= "string"
        or type(ctx.body) ~= "string" then
        return nil
    end
    local adapter = self:find(ctx.url)
    if not adapter then
        return nil
    end
    local ok, new_body = pcall(adapter.transform, ctx)
    if not ok then
        logger.warn("webbrowser_site_adapters", "adapter error", adapter._name, new_body)
        return nil
    end
    if type(new_body) == "string" and new_body ~= "" then
        logger.info("webbrowser_site_adapters", "applied adapter", adapter._name, "for", ctx.url)
        return new_body, adapter._name
    end
    return nil
end

return SiteAdapters
