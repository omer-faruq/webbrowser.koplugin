local json = require("json")
local lfs = require("libs/libkoreader-lfs")
local DataStorage = require("datastorage")

local LastQueryStore = {}
LastQueryStore.__index = LastQueryStore

local STORAGE_FILE_NAME = "webbrowser_lastquery.json"

local function ensureDirectory(path)
    local mode = lfs.attributes(path, "mode")
    if mode ~= "directory" then
        local ok, err = lfs.mkdir(path)
        if not ok then
            error(string.format("Could not create directory '%s': %s", path, err))
        end
    end
end

local function safeDecode(content)
    if not content or content == "" then
        return {}
    end
    local ok, result = pcall(function()
        return json.decode(content)
    end)
    if not ok or type(result) ~= "table" then
        return {}
    end
    return result
end

local function safeEncode(value)
    local ok, encoded = pcall(function()
        return json.encode(value)
    end)
    if not ok then
        return "{}"
    end
    return encoded
end

function LastQueryStore:new(options)
    local instance = setmetatable({}, self)
    instance.storage_dir = DataStorage:getDataDir() .. "/plugins/webbrowser.koplugin"
    if options and options.storage_dir then
        instance.storage_dir = options.storage_dir
    end
    ensureDirectory(instance.storage_dir)
    instance.file_path = instance.storage_dir .. "/" .. STORAGE_FILE_NAME
    instance._cache = nil
    return instance
end

function LastQueryStore:load()
    if self._cache ~= nil then
        return self._cache
    end
    local file = io.open(self.file_path, "r")
    if not file then
        self._cache = nil
        return self._cache
    end
    local content = file:read("*a")
    file:close()
    local decoded = safeDecode(content)
    if not next(decoded) then
        decoded = nil
    end
    self._cache = decoded
    return self._cache
end

function LastQueryStore:save(data)
    local to_write = data
    if type(to_write) ~= "table" then
        to_write = nil
    end
    local encoded = safeEncode(to_write or {})
    local file, err = io.open(self.file_path, "w")
    if not file then
        error(string.format("Failed to open '%s' for writing: %s", self.file_path, err or ""))
    end
    file:write(encoded)
    file:close()
    self._cache = to_write
end

function LastQueryStore:get()
    return self:load()
end

function LastQueryStore:set(data)
    self:save(data)
end

function LastQueryStore:clear()
    self:save(nil)
end

return LastQueryStore
