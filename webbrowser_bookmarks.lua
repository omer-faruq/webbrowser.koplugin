local json = require("json")
local lfs = require("libs/libkoreader-lfs")
local DataStorage = require("datastorage")

local Bookmarks = {}
Bookmarks.__index = Bookmarks

local STORAGE_FILE_NAME = "webbrowser_bookmarks.json"

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
    local ok, result = pcall(json.decode, content)
    if not ok or type(result) ~= "table" then
        return {}
    end
    return result
end

local function safeEncode(value)
    local ok, encoded = pcall(json.encode, value)
    if not ok then
        return "[]"
    end
    return encoded
end

function Bookmarks:new(options)
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

function Bookmarks:load()
    if self._cache then
        return self._cache
    end
    local file = io.open(self.file_path, "r")
    if not file then
        self._cache = {}
        return self._cache
    end
    local content = file:read("*a")
    file:close()
    self._cache = safeDecode(content)
    return self._cache
end

function Bookmarks:save()
    local data = self._cache or {}
    local encoded = safeEncode(data)
    local file, err = io.open(self.file_path, "w")
    if not file then
        error(string.format("Failed to open '%s' for writing: %s", self.file_path, err or ""))
    end
    file:write(encoded)
    file:close()
end

function Bookmarks:getAll()
    local data = self:load()
    return data
end

function Bookmarks:setAll(entries)
    if type(entries) ~= "table" then
        entries = {}
    end
    self._cache = entries
    self:save()
end

function Bookmarks:removeByIds(id_list)
    if not id_list or #id_list == 0 then
        return 0
    end
    local id_map = {}
    for _, id in ipairs(id_list) do
        if id ~= nil then
            id_map[id] = true
        end
    end
    if not next(id_map) then
        return 0
    end
    local data = self:load()
    local filtered = {}
    local removed = 0
    for _, entry in ipairs(data) do
        if entry and entry.id and id_map[entry.id] then
            removed = removed + 1
        else
            table.insert(filtered, entry)
        end
    end
    if removed > 0 then
        self._cache = filtered
        self:save()
    end
    return removed
end

return Bookmarks
