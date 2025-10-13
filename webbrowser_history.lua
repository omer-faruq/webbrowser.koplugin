local json = require("json")
local lfs = require("libs/libkoreader-lfs")
local DataStorage = require("datastorage")

local SearchHistoryStore = {}
SearchHistoryStore.__index = SearchHistoryStore

local STORAGE_FILE_NAME = "webbrowser_history.json"
local DEFAULT_MAX_ENTRIES = 10

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
        return "[]"
    end
    return encoded
end

local function sanitizeResults(results)
    local sanitized = {}
    if type(results) ~= "table" then
        return sanitized
    end
    for _, result in ipairs(results) do
        if type(result) == "table" then
            local copy = {}
            for key, value in pairs(result) do
                if type(value) ~= "function" then
                    copy[key] = value
                end
            end
            table.insert(sanitized, copy)
        end
    end
    return sanitized
end

local function sanitizeEntry(entry)
    if type(entry) ~= "table" then
        return { results = {} }
    end
    local sanitized = {}
    for key, value in pairs(entry) do
        if key ~= "results" and type(value) ~= "function" then
            sanitized[key] = value
        end
    end
    sanitized.results = sanitizeResults(entry.results)
    return sanitized
end

function SearchHistoryStore:new(options)
    local instance = setmetatable({}, self)
    instance.storage_dir = DataStorage:getDataDir() .. "/plugins/webbrowser.koplugin"
    if options and options.storage_dir then
        instance.storage_dir = options.storage_dir
    end
    ensureDirectory(instance.storage_dir)
    instance.file_path = instance.storage_dir .. "/" .. STORAGE_FILE_NAME
    instance._cache = nil
    instance.max_entries = DEFAULT_MAX_ENTRIES
    if options and options.max_entries then
        local numeric_limit = tonumber(options.max_entries)
        if numeric_limit then
            local floored = math.floor(numeric_limit)
            if floored > 0 then
                instance.max_entries = floored
            end
        end
    end
    return instance
end

function SearchHistoryStore:load()
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
    local decoded = safeDecode(content)
    if type(decoded) ~= "table" then
        decoded = {}
    end
    table.sort(decoded, function(a, b)
        local id_a = (type(a) == "table" and type(a.id) == "number") and a.id or 0
        local id_b = (type(b) == "table" and type(b.id) == "number") and b.id or 0
        return id_a > id_b
    end)
    local max_entries = self.max_entries or DEFAULT_MAX_ENTRIES
    if #decoded > max_entries then
        while #decoded > max_entries do
            table.remove(decoded)
        end
    end
    self._cache = decoded
    return self._cache
end

function SearchHistoryStore:save()
    local data = self._cache or {}
    local encoded = safeEncode(data)
    local file, err = io.open(self.file_path, "w")
    if not file then
        error(string.format("Failed to open '%s' for writing: %s", self.file_path, err or ""))
    end
    file:write(encoded)
    file:close()
end

function SearchHistoryStore:getAll()
    local data = self:load()
    return data
end

local function nextId(entries)
    local max_id = 0
    if type(entries) ~= "table" then
        return 1
    end
    for _, item in ipairs(entries) do
        if type(item) == "table" and type(item.id) == "number" and item.id > max_id then
            max_id = item.id
        end
    end
    return max_id + 1
end

function SearchHistoryStore:addEntry(entry)
    local data = self:load()
    local stored_entry = sanitizeEntry(entry)
    stored_entry.id = nextId(data)
    stored_entry.timestamp = stored_entry.timestamp or os.time()
    table.insert(data, 1, stored_entry)
    local max_entries = self.max_entries or DEFAULT_MAX_ENTRIES
    while #data > max_entries do
        table.remove(data)
    end
    self._cache = data
    self:save()
    return stored_entry.id
end

function SearchHistoryStore:removeByIds(id_list)
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
    self._cache = filtered
    self:save()
    return removed
end

function SearchHistoryStore:hasEntries()
    local data = self:load()
    return data and #data > 0
end

return SearchHistoryStore
