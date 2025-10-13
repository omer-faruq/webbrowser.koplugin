local Dispatcher = require("dispatcher")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local Menu = require("ui/widget/menu")
local ButtonDialog = require("ui/widget/buttondialog")
local Geom = require("ui/geometry")
local ScrollableContainer = require("ui/widget/container/scrollablecontainer")
local VerticalGroup = require("ui/widget/verticalgroup")
local Device = require("device")
local Screen = Device.screen
local CheckButton = require("ui/widget/checkbutton")
local MultiInputDialog = require("ui/widget/multiinputdialog")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local util = require("util")
local FileManager = require("apps/filemanager/filemanager")
local FileManagerUtil = require("apps/filemanager/filemanagerutil")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local socket_http = require("socket.http")
local socket = require("socket")
local socketutil = require("socketutil")
local ltn12 = require("ltn12")
local _ = require("gettext")
local NetworkMgr = require("ui/network/manager")
local DocumentRegistry = require("document/documentregistry")

local MarkdownViewer = require("webbrowser_markdown_viewer")
local Utils = require("webbrowser_utils")
local MuPDFRenderer = require("webbrowser_renderer")
local config_loaded, config_result = pcall(require, "webbrowser_configuration")
local CONFIG = config_loaded and config_result or {}
local CONFIG_MISSING = not config_loaded
local BookmarksStore = require("webbrowser_bookmarks")
local SearchHistoryStore = require("webbrowser_history")
local Random = require("random")

local SearchEngines = {
    duckduckgo = require("webbrowser_duckduckgo"),
    brave_api = require("webbrowser_brave_api"),
}

local DEFAULT_SEARCH_ENGINE = "duckduckgo"
local DEFAULT_HISTORY_LIMIT = 10

local WebBrowser = WidgetContainer:extend{
    name = "webbrowser",
    is_doc_only = false,
}

local DEFAULT_TIMEOUT = 20
local DEFAULT_MAXTIME = 60
local fetch_markdown

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

local function trim_text(value)
    return (value or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

local function is_html_file(path)
    if type(path) ~= "string" then
        return false
    end
    local lower = path:lower()
    local stripped = lower:match("([^?#]+)") or lower
    if stripped:sub(-5) == ".html" then
        return true
    end
    if stripped:sub(-4) == ".htm" then
        return true
    end
    if stripped:sub(-6) == ".xhtml" then
        return true
    end
    return false
end

function WebBrowser:removeSdrDirectoryForPath(file_path)
    if not is_html_file(file_path) then
        return
    end
    local directory, filename = file_path:match("^(.*)/([^/]+)$")
    if not filename then
        filename = file_path
        directory = ""
    end
    local name_without_ext = filename
    local base_name, _ = util.splitFileNameSuffix(filename)
    if base_name and base_name ~= "" then
        name_without_ext = base_name
    end
    local sdr_name = name_without_ext .. ".sdr"
    local sdr_path
    if directory ~= "" then
        sdr_path = directory .. "/" .. sdr_name
    else
        sdr_path = sdr_name
    end
    local ok, removed, err = pcall(removePath, sdr_path)
    if not ok then
        logger.warn("webbrowser", "exception while removing .sdr directory", sdr_path, removed)
        return
    end
    if not removed and err then
        logger.warn("webbrowser", "failed to remove .sdr directory", sdr_path, err)
    end
end

function WebBrowser:getSearchHistoryStore()
    if not self.search_history_store then
        self.search_history_store = SearchHistoryStore:new {
            max_entries = self:getSearchHistoryLimit(),
        }
    end
    return self.search_history_store
end

function WebBrowser:hasSearchHistoryEntries()
    local store = self:getSearchHistoryStore()
    if not store then
        return false
    end
    return store:hasEntries()
end

function WebBrowser:getSearchHistoryLimit()
    local limit = CONFIG.history_max_entries
    if type(limit) == "string" then
        limit = tonumber(limit)
    end
    if type(limit) == "number" then
        local floored = math.floor(limit)
        if floored > 0 then
            return floored
        end
    end
    return DEFAULT_HISTORY_LIMIT
end

function WebBrowser:addSearchHistoryEntry(query, results, engine_display, engine_name, timestamp)
    local store = self:getSearchHistoryStore()
    if not store then
        return
    end
    if type(results) ~= "table" or #results == 0 then
        return
    end
    local final_timestamp = timestamp
    if type(final_timestamp) ~= "number" then
        final_timestamp = os.time()
    end
    local entry = {
        query = query,
        engine_display = engine_display,
        engine_name = engine_name,
        timestamp = final_timestamp,
        results = results,
    }
    local ok, err = pcall(function()
        store:addEntry(entry)
    end)
    if not ok and err then
        logger.warn("webbrowser", "failed to add search history entry", err)
    end
end

function WebBrowser:showSearchHistoryEntry(entry)
    if not entry or type(entry) ~= "table" then
        return
    end
    local results = entry.results
    if type(results) ~= "table" or #results == 0 then
        UIManager:show(InfoMessage:new {
            text = _("No stored results for this entry."),
            timeout = 2,
        })
        return
    end

    local query = entry.query or ""
    local engine_display = entry.engine_display or self:getSearchEngineDisplayName()
    local engine_name = entry.engine_name or self:getSelectedEngineName()

    self:showResultsMenu(query, results, engine_display, engine_name, { skip_history_record = true })
end

function WebBrowser:showSearchHistoryDialog()
    if self.search_history_dialog then
        UIManager:close(self.search_history_dialog)
        self.search_history_dialog = nil
    end

    local store = self:getSearchHistoryStore()
    local entries = store:getAll()
    local selection = {}

    local dialog
    local function clearDialog()
        self.search_history_dialog = nil
    end

    local function refreshDialog()
        UIManager:nextTick(function()
            self:showSearchHistoryDialog()
        end)
    end

    local function formatTimestamp(value)
        if type(value) == "number" then
            local formatted = os.date("%Y-%m-%d %H:%M:%S", value)
            if type(formatted) == "string" then
                return formatted
            end
            return ""
        end
        if type(value) == "string" and value ~= "" then
            return value
        end
        return ""
    end

    local buttons = {
        {
            {
                text = _("Delete"),
                enabled = #entries > 0,
                callback = function()
                    if not dialog then
                        return
                    end
                    local selected_ids = {}
                    for _, entry in ipairs(entries) do
                        local entry_id = entry and entry.id
                        if entry_id and selection[entry_id] then
                            table.insert(selected_ids, entry_id)
                        end
                    end
                    if #selected_ids == 0 then
                        UIManager:show(InfoMessage:new {
                            text = _("Select at least one history entry to delete."),
                            timeout = 2,
                        })
                        return
                    end
                    local removed = store:removeByIds(selected_ids)
                    if removed > 0 then
                        UIManager:show(InfoMessage:new {
                            text = _("Selected history entries deleted."),
                            timeout = 2,
                        })
                    end
                    dialog:onClose()
                    clearDialog()
                    refreshDialog()
                end,
            },
            {
                text = _("Open"),
                enabled = #entries > 0,
                callback = function()
                    if not dialog then
                        return
                    end
                    local selected_entry
                    for _, entry in ipairs(entries) do
                        local entry_id = entry and entry.id
                        if entry_id and selection[entry_id] then
                            selected_entry = entry
                            break
                        end
                    end
                    if not selected_entry then
                        UIManager:show(InfoMessage:new {
                            text = _("Select a history entry to open."),
                            timeout = 2,
                        })
                        return
                    end
                    dialog:onClose()
                    clearDialog()
                    UIManager:nextTick(function()
                        self:showSearchHistoryEntry(selected_entry)
                    end)
                end,
            },
            {
                text = _("Close"),
                callback = function()
                    if dialog then
                        dialog:onClose()
                        clearDialog()
                    end
                end,
            },
        },
    }

    dialog = ButtonDialog:new {
        title = _("History"),
        buttons = buttons,
        tap_close_callback = clearDialog,
        rows_per_page = {6, 8},
    }

    self.search_history_dialog = dialog

    local history_container = VerticalGroup:new{}

    if #entries == 0 then
        local empty_widget = CheckButton:new {
            text = _("No search history saved yet."),
            parent = dialog,
            checkable = false,
            enabled = false,
        }
        empty_widget.not_focusable = true
        history_container[1] = empty_widget
    else
        local threshold_rows = 10
        local history_group = VerticalGroup:new{}
        for _, entry in ipairs(entries) do
            local entry_id = entry and entry.id
            if entry_id then
                selection[entry_id] = false
                local query_text = entry.query
                if not query_text or query_text == "" then
                    query_text = _("(No search term)")
                end
                local timestamp_text = formatTimestamp(entry.timestamp)
                local label
                if timestamp_text ~= "" then
                    label = string.format("%s • %s", query_text, timestamp_text)
                else
                    label = query_text
                end
                local checkbox
                checkbox = CheckButton:new {
                    text = label,
                    parent = dialog,
                    callback = function()
                        selection[entry_id] = checkbox.checked
                    end,
                }
                history_group[#history_group + 1] = checkbox
            end
        end

        local max_height_ratio = 0.8
        local screen_height = Screen:getHeight()
        local max_height = math.floor(screen_height * max_height_ratio)
        local content_size = history_group:getSize()
        local needs_scroll = (#entries > threshold_rows) or (content_size.h > max_height)

        if needs_scroll then
            local final_height = math.min(content_size.h, max_height)
            local scrollable = ScrollableContainer:new {
                dimen = Geom:new {
                    w = dialog.buttontable:getSize().w + ScrollableContainer:getScrollbarWidth(),
                    h = final_height,
                },
                show_parent = dialog,
                history_group,
            }
            history_container[1] = scrollable
        else
            history_container[1] = history_group
        end
    end

    if history_container[1] then
        dialog:addWidget(history_container[1])
    end

    UIManager:show(dialog)
end

local function copy_file(source_path, destination_path)
    local source, src_err = io.open(source_path, "rb")
    if not source then
        return false, src_err
    end

    local destination, dst_err = io.open(destination_path, "wb")
    if not destination then
        source:close()
        return false, dst_err
    end

    while true do
        local chunk = source:read(8192)
        if not chunk then
            break
        end
        destination:write(chunk)
    end

    source:close()
    destination:close()
    return true
end

local function build_unique_file_path(directory, filename)
    local safe_name = util.getSafeFilename(filename, directory)
    if safe_name == "" then
        safe_name = os.date("web_%Y%m%d_%H%M%S")
    end
    local name_without_ext, ext = util.splitFileNameSuffix(safe_name)
    local extension = ext ~= "" and ("." .. ext) or ""
    local base = name_without_ext ~= "" and name_without_ext or os.date("web_%Y%m%d_%H%M%S")
    local candidate = string.format("%s/%s%s", directory, base, extension)
    local counter = 1
    while util.fileExists(candidate) do
        candidate = string.format("%s/%s_%d%s", directory, base, counter, extension)
        counter = counter + 1
    end
    return candidate
end

function WebBrowser:saveExternalUrl(url)
    if type(url) ~= "string" or url == "" then
        UIManager:show(InfoMessage:new {
            text = _("Invalid URL."),
            timeout = 3,
        })
        return
    end

    local target_dir, attempts = self:determineSaveDirectory()
    if not target_dir then
        UIManager:show(InfoMessage:new {
            text = _("Unable to resolve save directory."),
            timeout = 3,
        })
        return
    end

    if attempts and #attempts > 0 then
        local failed = attempts[1]
        if failed and failed.error then
            UIManager:show(InfoMessage:new {
                text = _(string.format("Falling back to a different folder. Reason: %s", failed.error)),
                timeout = 3,
            })
        end
    end

    local renderer = self:getMuPDFRenderer()
    local info = InfoMessage:new {
        text = _("Downloading…"),
        timeout = 0,
    }
    UIManager:show(info)

    local ok, stored_path_or_error, headers = renderer:fetchAndStore(url)

    UIManager:close(info)

    if not ok then
        UIManager:show(InfoMessage:new {
            text = stored_path_or_error or _("Failed to save."),
            timeout = 3,
        })
        return
    end

    local stored_path = stored_path_or_error
    local filename = stored_path:match("[^/]+$")
    if not filename then
        UIManager:show(InfoMessage:new {
            text = _("Failed to determine saved file name."),
            timeout = 3,
        })
        return
    end

    local destination_path = build_unique_file_path(target_dir, filename)

    local copied, copy_err = copy_file(stored_path, destination_path)
    if not copied then
        UIManager:show(InfoMessage:new {
            text = _(string.format("Failed to save file: %s", copy_err)),
            timeout = 3,
        })
        return
    end

    UIManager:show(InfoMessage:new {
        text = _(string.format("Saved to %s", destination_path)),
        timeout = 3,
    })
end

function WebBrowser:shouldDownloadImages()
    local value = CONFIG.download_images
    if type(value) == "boolean" then
        return value
    end
    if type(value) == "string" then
        local normalized = value:lower()
        if normalized == "false" or normalized == "0" or normalized == "no" then
            return false
        end
        if normalized == "true" or normalized == "1" or normalized == "yes" then
            return true
        end
    end
    return true
end

function WebBrowser:shouldUseStylesheets()
    local value = CONFIG.use_stylesheets
    if type(value) == "boolean" then
        return value
    end
    if type(value) == "string" then
        local normalized = value:lower()
        if normalized == "false" or normalized == "0" or normalized == "no" then
            return false
        end
        if normalized == "true" or normalized == "1" or normalized == "yes" then
            return true
        end
    end
    return true
end

function WebBrowser:normalizeUrlInput(input)
    local trimmed = trim_text(input or "")
    if trimmed == "" then
        return nil
    end
    if not trimmed:match("^[%a][%w%+%.-]*://") then
        trimmed = "https://" .. trimmed
    end
    return trimmed
end

function WebBrowser:getRenderType()
    local render_type = CONFIG.render_type
    if type(render_type) == "string" then
        render_type = render_type:lower()
    end
    if render_type == "mupdf" then
        return "mupdf"
    end
    if render_type == "cre" then
        return "cre"
    end
    return "markdown"
end

function WebBrowser:isMarkdownRender()
    return self:getRenderType() == "markdown"
end

function WebBrowser:isMuPDFRender()
    return self:getRenderType() == "mupdf"
end

function WebBrowser:isCreRender()
    return self:getRenderType() == "cre"
end

function WebBrowser:getMuPDFRenderer()
    if not self.mupdf_renderer then
        self.mupdf_renderer = MuPDFRenderer:new {
            keep_old_files = self:shouldKeepOldWebsiteFiles(),
            download_images = self:shouldDownloadImages(),
            use_stylesheets = self:shouldUseStylesheets(),
        }
    end
    return self.mupdf_renderer
end

function WebBrowser:shouldKeepOldWebsiteFiles()
    local value = CONFIG.keep_old_website_files
    if type(value) == "boolean" then
        return value
    end
    if type(value) == "string" then
        local normalized = value:lower()
        return normalized == "true" or normalized == "1" or normalized == "yes"
    end
    return false
end

function WebBrowser:clearMuPDFCache()
    if not ((self:isMuPDFRender() or self:isCreRender()) and self:shouldKeepOldWebsiteFiles()) then
        UIManager:show(InfoMessage:new {
            text = _("Renderer cache clearing is not available."),
            timeout = 2,
        })
        return
    end

    local renderer = self:getMuPDFRenderer()
    local ok, err = renderer:forceClearCache()

    if ok then
        UIManager:show(InfoMessage:new {
            text = _("Cache cleared."),
            timeout = 2,
        })
        return
    end

    UIManager:show(InfoMessage:new {
        text = err or _("Failed to clear cache."),
        timeout = 3,
    })
end

function WebBrowser:ensureMuPDFLinkHandler()
    if not (self:isMuPDFRender() or self:isCreRender()) then
        return
    end
    if self.mu_pdf_link_handler_registered then
        return
    end

    local max_attempts = 20

    local function tryRegister(attempt)
        if self.mu_pdf_link_handler_registered then
            return
        end
        if not (self:isMuPDFRender() or self:isCreRender()) then
            return
        end
        if not (self.ui and self.ui.link and self.ui.link.addToExternalLinkDialog) then
            if attempt >= max_attempts then
                return
            end
            UIManager:nextTick(function()
                tryRegister(attempt + 1)
            end)
            return
        end

        self.ui.link:addToExternalLinkDialog("35_open_here_webbrowser_mupdf", function(external_dialog, link_url)
            return {
                text = _("Open here (MuPDF)"),
                callback = function()
                    UIManager:close(external_dialog.external_link_dialog)
                    local target_url = link_url
                    if type(target_url) ~= "string" or not target_url:match("^https?://") then
                        return
                    end
                    NetworkMgr:runWhenOnline(function()
                        self:loadMuPDFUrl(target_url, false, _("Loading page…"))
                    end)
                end,
                show_in_dialog_func = function()
                    return type(link_url) == "string" and link_url:match("^https?://") ~= nil and self:isMuPDFRender()
                end,
            }
        end)

        self.ui.link:addToExternalLinkDialog("36_open_here_webbrowser_cre", function(external_dialog, link_url)
            return {
                text = _("Open here (CRE)"),
                callback = function()
                    UIManager:close(external_dialog.external_link_dialog)
                    local target_url = link_url
                    if type(target_url) ~= "string" or not target_url:match("^https?://") then
                        return
                    end
                    NetworkMgr:runWhenOnline(function()
                        self:loadCreUrl(target_url, false, _("Loading page…"))
                    end)
                end,
                show_in_dialog_func = function()
                    return type(link_url) == "string" and link_url:match("^https?://") ~= nil and self:isCreRender()
                end,
            }
        end)

        self.ui.link:addToExternalLinkDialog("40_bookmark_webbrowser_mupdf", function(external_dialog, link_url)
            return {
                text = _("Bookmark (Browser)"),
                callback = function()
                    UIManager:close(external_dialog.external_link_dialog)
                    local target_url = link_url
                    if type(target_url) ~= "string" or not target_url:match("^https?://") then
                        UIManager:show(InfoMessage:new {
                            text = _("Bookmark URL is missing."),
                            timeout = 2,
                        })
                        return
                    end

                    local added, message = self:addBookmarkEntry(target_url)
                    if message and message ~= "" then
                        UIManager:show(InfoMessage:new {
                            text = message,
                            timeout = 2,
                        })
                    end
                end,
                show_in_dialog_func = function()
                    return type(link_url) == "string" and link_url:match("^https?://") ~= nil and (self:isMuPDFRender() or self:isCreRender())
                end,
            }
        end)

        local function save_link_callback(external_dialog, link_url)
            UIManager:close(external_dialog.external_link_dialog)
            local target_url = link_url
            if type(target_url) ~= "string" or not target_url:match("^https?://") then
                UIManager:show(InfoMessage:new {
                    text = _("Save URL is missing."),
                    timeout = 2,
                })
                return
            end
            NetworkMgr:runWhenOnline(function()
                self:saveExternalUrl(target_url)
            end)
        end

        self.ui.link:addToExternalLinkDialog("50_save_webbrowser_mupdf", function(external_dialog, link_url)
            return {
                text = _("Save"),
                callback = function()
                    save_link_callback(external_dialog, link_url)
                end,
                show_in_dialog_func = function()
                    return type(link_url) == "string" and link_url:match("^https?://") ~= nil and (self:isMuPDFRender() or self:isCreRender())
                end,
            }
        end)

        self.mu_pdf_link_handler_registered = true
    end

    tryRegister(1)
end

function WebBrowser:addBookmarkEntry(source_url, title, missing_message)
    if type(source_url) ~= "string" or source_url == "" then
        return false, missing_message or _("Bookmark URL is missing.")
    end

    local store = self:getBookmarksStore()
    local bookmarks = self:getBookmarks()
    local normalized_source = Utils.ensure_markdown_gateway(source_url)

    for index, entry in ipairs(bookmarks) do
        if entry then
            local existing_source = entry.source_url or entry.url
            local normalized_existing_source = existing_source and Utils.ensure_markdown_gateway(existing_source)
            if (existing_source and existing_source == source_url)
                or (normalized_source and normalized_existing_source and normalized_existing_source == normalized_source)
                or (title and title ~= "" and entry.title == title) then
                return false, _("Bookmark already exists.")
            end
        end
    end

    local title_to_save = (title and title ~= "" and title) or source_url
    local new_entry = {
        id = Random.uuid(true),
        title = title_to_save,
        source_url = source_url,
    }

    table.insert(bookmarks, 1, new_entry)
    store:setAll(bookmarks)
    return true, _("Bookmark added.")
end

function WebBrowser:openMuPDFDocument(file_path)
    if type(file_path) ~= "string" or file_path == "" then
        return
    end
    if not is_html_file(file_path) then
        FileManager:openFile(file_path)
        return
    end
    self:removeSdrDirectoryForPath(file_path)
    local provider = DocumentRegistry:getProviderFromKey("mupdf")
    if self.ui.document then
        self.ui:showReader(file_path, provider, true, true)
    else
        self.ui:openFile(file_path, provider)
    end
end

function WebBrowser:openCreDocument(file_path)
    if type(file_path) ~= "string" or file_path == "" then
        return
    end
    if not is_html_file(file_path) then
        FileManager:openFile(file_path)
        return
    end
    self:removeSdrDirectoryForPath(file_path)
    local provider = DocumentRegistry:getProviderFromKey("crengine")
    if not provider then
        UIManager:show(InfoMessage:new {
            text = _("CRE provider is not available."),
            timeout = 2,
        })
        return
    end
    if self.ui.document then
        self.ui:showReader(file_path, provider, true, true)
    else
        self.ui:openFile(file_path, provider)
    end
end

function WebBrowser:loadMuPDFUrl(url, reopen_results, loading_text)
    if type(url) ~= "string" or url == "" then
        self:handleFetchError(_("Invalid URL."), reopen_results)
        return false
    end

    self:ensureMuPDFLinkHandler()

    local info
    if loading_text and loading_text ~= "" then
        info = InfoMessage:new {
            text = loading_text,
            timeout = 0,
        }
        UIManager:show(info)
    end

    local ok, result_or_err = self:getMuPDFRenderer():fetchAndStore(url)

    if info then
        UIManager:close(info)
    end

    if not ok then
        self:handleFetchError(result_or_err, reopen_results)
        return false
    end

    self:openMuPDFDocument(result_or_err)
    return true
end

function WebBrowser:loadCreUrl(url, reopen_results, loading_text)
    if type(url) ~= "string" or url == "" then
        self:handleFetchError(_("Invalid URL."), reopen_results)
        return false
    end

    self:ensureMuPDFLinkHandler()

    local info
    if loading_text and loading_text ~= "" then
        info = InfoMessage:new {
            text = loading_text,
            timeout = 0,
        }
        UIManager:show(info)
    end

    local ok, result_or_err = self:getMuPDFRenderer():fetchAndStore(url)

    if info then
        UIManager:close(info)
    end

    if not ok then
        self:handleFetchError(result_or_err, reopen_results)
        return false
    end

    self:openCreDocument(result_or_err)
    return true
end

function WebBrowser:openDirectUrl(raw_input)
    local normalized = self:normalizeUrlInput(raw_input)
    if not normalized then
        UIManager:show(InfoMessage:new {
            text = _("Please enter a valid URL."),
            timeout = 2,
        })
        return
    end

    NetworkMgr:runWhenOnline(function()
        if self:isMuPDFRender() then
            self:loadMuPDFUrl(normalized, false, _("Loading page…"))
            return
        end

        if self:isCreRender() then
            self:loadCreUrl(normalized, false, _("Loading page…"))
            return
        end

        local gateway_url = Utils.ensure_markdown_gateway(normalized)
        local info = InfoMessage:new {
            text = _("Loading page…"),
            timeout = 0,
        }
        UIManager:show(info)

        local markdown, err = fetch_markdown(gateway_url)
        UIManager:close(info)

        if not markdown then
            self:handleFetchError(err, false)
            return
        end

        self:showMarkdownPage({
            title = normalized,
            source_url = normalized,
            gateway_url = gateway_url,
            markdown = markdown,
            source_context = "direct",
        }, true, true)
    end)
end

function WebBrowser:getSelectedEngineName()
    local selected = CONFIG.engine
    if type(selected) == "string" then
        selected = selected:lower()
    end

    if selected and SearchEngines[selected] then
        return selected
    end

    local engines = CONFIG.engines
    if type(engines) == "table" then
        for key, _ in pairs(engines) do
            if type(key) == "string" then
                local normalized = key:lower()
                if SearchEngines[normalized] then
                    return normalized
                end
            end
        end
    end

    return DEFAULT_SEARCH_ENGINE
end

function WebBrowser:getSearchEngineConfig()
    local engines = CONFIG.engines or {}
    local engine_name = self:getSelectedEngineName()
    local config = engines[engine_name]

    if not config or type(config) ~= "table" then
        config = engines[DEFAULT_SEARCH_ENGINE]
    end

    if not config or type(config) ~= "table" then
        config = {}
    end

    return config, engine_name
end

function WebBrowser:getSearchEngineModule()
    local config, engine_name = self:getSearchEngineConfig()
    local normalized_name = (config.name and config.name:lower()) or engine_name or DEFAULT_SEARCH_ENGINE
    local engine = SearchEngines[normalized_name] or SearchEngines[engine_name] or SearchEngines[DEFAULT_SEARCH_ENGINE]
    return engine, config, normalized_name
end

function WebBrowser:getSearchEngineDisplayName()
    local config, engine_name = self:getSearchEngineConfig()
    if config.display_name and config.display_name ~= "" then
        return config.display_name
    end
    if config.name and config.name ~= "" then
        return config.name:gsub("^%l", string.upper)
    end
    if engine_name and engine_name ~= "" then
        return engine_name:gsub("^%l", string.upper)
    end
    return "DuckDuckGo"
end

local fetch_markdown = function(url)
    local response_chunks = {}
    socketutil:set_timeout(DEFAULT_TIMEOUT, DEFAULT_MAXTIME)
    local request = {
        url = url,
        method = "GET",
        sink = ltn12.sink.table(response_chunks),
        headers = {
            ["user-agent"] = "Mozilla/5.0 (compatible; KOReader)",
        },
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

function WebBrowser:onDispatcherRegisterActions()
    Dispatcher:registerAction("webbrowser_show", {
        category = "none",
        event = "ShowWebBrowser",
        title = _("Web Browser"),
        general = true,
    })
end

function WebBrowser:init()
    self:onDispatcherRegisterActions()
    if self.ui.menu then
        self.ui.menu:registerToMainMenu(self)
    end
    self.history = {}
    self.current_page = nil
    self.results_menu = nil
    self.markdown_viewer = nil
    self.bookmarks_store = BookmarksStore:new()
    self.bookmarks_dialog = nil
    self.last_results = nil
    self.search_history_store = nil
    self.search_history_dialog = nil
    self.mupdf_renderer = nil
    self.mu_pdf_link_handler_registered = false
    if self:isMuPDFRender() or self:isCreRender() then
        self:ensureMuPDFLinkHandler()
    end
end

function WebBrowser:getHomeDirectory()
    if G_reader_settings then
        local home_dir = G_reader_settings:readSetting("home_dir")
        if home_dir and home_dir ~= "" then
            return home_dir
        end
    end
    local default_dir = FileManagerUtil.getDefaultDir and FileManagerUtil.getDefaultDir()
    return default_dir
end

function WebBrowser:getCurrentDirectory()
    if not self.ui then
        return nil
    end
    if self.ui.file_chooser and self.ui.file_chooser.path and self.ui.file_chooser.path ~= "" then
        return self.ui.file_chooser.path
    end
    if self.ui.getLastDirFile then
        local dir = self.ui:getLastDirFile()
        if type(dir) == "string" and dir ~= "" then
            return dir
        end
    end
    return nil
end

function WebBrowser:determineSaveDirectory()
    local attempted = {}
    local candidates = {}

    if CONFIG.save_to_directory and CONFIG.save_to_directory ~= "" then
        table.insert(candidates, CONFIG.save_to_directory)
    end

    local home_dir = self:getHomeDirectory()
    if home_dir and home_dir ~= "" then
        table.insert(candidates, home_dir)
    end

    local current_dir = self:getCurrentDirectory()
    if current_dir and current_dir ~= "" then
        table.insert(candidates, current_dir)
    end

    for _, dir in ipairs(candidates) do
        if dir and dir ~= "" then
            local ok, err = util.makePath(dir)
            if ok then
                return dir, attempted
            end
            table.insert(attempted, { path = dir, error = err })
        end
    end

    local fallback = lfs.currentdir()
    util.makePath(fallback)
    return fallback, attempted
end

function WebBrowser:generateMarkdownFilename(page, directory)
    local base = page.title or page.source_url or page.gateway_url or os.date("web_%Y%m%d_%H%M%S")
    if not base or base == "" then
        base = os.date("web_%Y%m%d_%H%M%S")
    end
    if not base:lower():match("%.md$") then
        base = base .. ".md"
    end

    local safe_name = util.getSafeFilename(base, directory)
    if not safe_name:lower():match("%.md$") then
        safe_name = safe_name .. ".md"
    end

    local name_only, ext = util.splitFileNameSuffix(safe_name)
    local suffix = ext and ext ~= "" and ("." .. ext) or ""
    local candidate = safe_name
    local counter = 1
    while util.fileExists(directory .. "/" .. candidate) do
        candidate = string.format("%s_%d%s", name_only, counter, suffix)
        counter = counter + 1
    end

    return candidate
end

function WebBrowser:addToMainMenu(menu_items)
    menu_items.webbrowser = {
        sorting_hint = "search",
        text = _("Web Browser"),
        callback = function()
            self:showSearchDialog()
        end,
    }
end

function WebBrowser:onShowWebBrowser()
    self:showSearchDialog()
end

function WebBrowser:showSearchDialog()
    if CONFIG_MISSING then
        UIManager:show(InfoMessage:new {
            text = _("Web browser configuration file not found. Copy 'webbrowser_configuration.sample.lua' to 'webbrowser_configuration.lua' inside the webbrowser plugin folder."),
            timeout = 10,
        })
        return
    end

    if self.search_dialog and self.search_dialog.dialog_open then
        return
    end

    local engine_display = self:getSearchEngineDisplayName()

    self.search_dialog = InputDialog:new {
        title = string.format(_("%s Search"), engine_display),
        input = "",
        input_hint = _("Enter keywords or URL"),
        buttons = {
            {
                {
                    text = _("Cancel"),
                    callback = function()
                        UIManager:close(self.search_dialog)
                        self.search_dialog = nil
                    end,
                },
                {
                    text = _("Search"),
                    is_enter_default = true,
                    callback = function()
                        local query = self.search_dialog:getInputText() or ""
                        query = query:gsub("^%s+", ""):gsub("%s+$", "")
                        if query == "" then
                            UIManager:show(InfoMessage:new {
                                text = _("Please enter a search term."),
                                timeout = 2,
                            })
                            return
                        end
                        UIManager:close(self.search_dialog)
                        self.search_dialog = nil
                        NetworkMgr:runWhenOnline(function()
                            self:performSearch(query)
                        end)
                    end,
                },
                {
                    text = _("Go"),
                    callback = function()
                        local url_input = self.search_dialog:getInputText() or ""
                        url_input = trim_text(url_input)
                        if url_input == "" then
                            UIManager:show(InfoMessage:new {
                                text = _("Please enter a URL."),
                                timeout = 2,
                            })
                            return
                        end

                        UIManager:close(self.search_dialog)
                        self.search_dialog = nil
                        NetworkMgr:runWhenOnline(function()
                            self:openDirectUrl(url_input)
                        end)
                    end,
                },
            },
            {
                {
                    text = _("History"),
                    enabled_func = function()
                        return self:hasSearchHistoryEntries()
                    end,
                    callback = function()
                        UIManager:close(self.search_dialog)
                        self.search_dialog = nil
                        self:showSearchHistoryDialog()
                    end,
                },
                {
                    text = _("Bookmarks"),
                    callback = function()
                        UIManager:close(self.search_dialog)
                        self.search_dialog = nil
                        self:showBookmarksDialog()
                    end,
                },
                {
                    text = _("Clear cache"),
                    enabled_func = function()
                        return (self:isMuPDFRender() or self:isCreRender()) and self:shouldKeepOldWebsiteFiles()
                    end,
                    callback = function()
                        self:clearMuPDFCache()
                    end,
                },
            },
        },
    }

    UIManager:show(self.search_dialog)
end

function WebBrowser:performSearch(query)
    local engine, engine_config, engine_name = self:getSearchEngineModule()
    local engine_display = self:getSearchEngineDisplayName()
    local info = InfoMessage:new {
        text = string.format(_("Searching %s…"), engine_display),
        timeout = 0,
    }
    UIManager:show(info)

    local results, err = engine.search(query, engine_config)
    UIManager:close(info)

    if not results or #results == 0 then
        UIManager:show(InfoMessage:new {
            text = err or _("No results found."),
            timeout = 3,
        })
        return
    end

    self:showResultsMenu(query, results, engine_display, engine_name)
end

function WebBrowser:showResultsMenu(query, results, engine_display, engine_name, options)
    if self.results_menu then
        UIManager:close(self.results_menu)
        self.results_menu = nil
    end

    local display_name = engine_display or self:getSearchEngineDisplayName()
    local resolved_engine_name = engine_name or self:getSelectedEngineName()
    local skip_history_record = options and options.skip_history_record
    local provided_timestamp = options and options.timestamp

    self.last_results = {
        query = query,
        items = results,
        engine_display = display_name,
        engine_name = resolved_engine_name,
    }

    if not skip_history_record then
        self:addSearchHistoryEntry(query, results, display_name, resolved_engine_name, provided_timestamp)
    end

    local item_table = {}
    for _, result in ipairs(results) do
        local sub_text = result.snippet
        if resolved_engine_name == "brave_api" and result.domain and result.domain ~= "" then
            if sub_text and sub_text ~= "" then
                sub_text = string.format("%s\n%s", result.domain, sub_text)
            else
                sub_text = result.domain
            end
        end

        local display_text = result.title or ""
        local raw_url = result.url or result.source_url or result.gateway_url
        local normalized_url = raw_url and Utils.decode_result_url(raw_url)
        normalized_url = normalized_url and trim_text(normalized_url) or ""
        if normalized_url ~= "" then
            if display_text and display_text ~= "" then
                display_text = string.format("%s — %s", display_text, normalized_url)
            else
                display_text = normalized_url
            end
        elseif not display_text or display_text == "" then
            display_text = raw_url or ""
        end

        table.insert(item_table, {
            text = display_text,
            sub_text = sub_text,
            callback = function()
                self:openResult(result)
            end,
            hold_callback = function()
                self:showResultActions(result)
            end,
            hold_keep_menu_open = true,
        })
    end

    self.results_menu = Menu:new {
        title = display_name .. ": " .. query,
        is_borderless = true,
        is_popout = false,
        item_table = item_table,
        close_callback = function()
            self.results_menu = nil
        end,
        onMenuHold = function(_, item)
            if item and item.hold_callback then
                item.hold_callback()
            end
        end,
    }

    UIManager:show(self.results_menu)
end

function WebBrowser:showResultActions(result)
    if not result then
        return
    end

    local function sanitizeText(value)
        if type(value) ~= "string" then
            return nil
        end
        local cleaned = util.htmlToPlainTextIfHtml(value)
        cleaned = trim_text(cleaned)
        if cleaned == "" then
            return nil
        end
        return cleaned
    end

    local title = sanitizeText(result.title)
    local raw_url = result.url or result.source_url or result.gateway_url
    local decoded_url = raw_url and Utils.decode_result_url(raw_url)
    local normalized_url = sanitizeText(decoded_url or raw_url)
    local snippet = sanitizeText(result.snippet)

    local dialog_title = title or normalized_url or _("Search result")

    local info_entries = {}
    if title and dialog_title ~= title then
        table.insert(info_entries, title)
    end
    if normalized_url and normalized_url ~= "" and dialog_title ~= normalized_url then
        table.insert(info_entries, normalized_url)
    end
    if snippet then
        table.insert(info_entries, snippet)
    end

    local bookmark_url = (normalized_url and normalized_url ~= "") and normalized_url or raw_url

    local dialog
    dialog = ButtonDialog:new {
        title = dialog_title,
        dismissable = true,
        buttons = {
            {
                {
                    text = _("Go"),
                    callback = function()
                        UIManager:close(dialog)
                        self:openResult(result)
                    end,
                },
                {
                    text = _("Bookmark"),
                    callback = function()
                        local added, message = self:addBookmarkEntry(bookmark_url, title, _("Bookmark URL is missing."))
                        if message and message ~= "" then
                            UIManager:show(InfoMessage:new {
                                text = message,
                                timeout = 2,
                            })
                        end
                        if added then
                            UIManager:close(dialog)
                        end
                    end,
                },
                {
                    text = _("Close"),
                    callback = function()
                        UIManager:close(dialog)
                    end,
                },
            },
        },
    }

    if #info_entries > 0 then
        for index, entry_text in ipairs(info_entries) do
            local info_widget = CheckButton:new {
                text = entry_text,
                parent = dialog,
                checkable = false,
                enabled = true,
                dim = false,
                separator = index < #info_entries,
            }
            info_widget.not_focusable = true
            dialog:addWidget(info_widget)
        end
    end

    UIManager:show(dialog)
end

function WebBrowser:openResultMarkdown(result)
    local gateway_url = Utils.ensure_markdown_gateway(result.url)
    local content, err = fetch_markdown(gateway_url)
    if not content then
        self:handleFetchError(err, true)
        return
    end

    local page = {
        title = result.title,
        source_url = result.url,
        gateway_url = gateway_url,
        markdown = content,
        source_context = "search",
    }
    self:showMarkdownPage(page, true, true)
end

function WebBrowser:openResultMuPDF(result)
    if not result then
        self:handleFetchError(_("Invalid result."), true)
        return
    end
    local raw_url = result.url or result.gateway_url or result.source_url
    raw_url = Utils.decode_result_url(raw_url)
    self:loadMuPDFUrl(raw_url, true, _("Loading page…"))
end

function WebBrowser:openResultCre(result)
    if not result then
        self:handleFetchError(_("Invalid result."), true)
        return
    end
    local raw_url = result.url or result.gateway_url or result.source_url
    raw_url = Utils.decode_result_url(raw_url)
    self:loadCreUrl(raw_url, true, _("Loading page…"))
end

function WebBrowser:openResult(result)
    NetworkMgr:runWhenOnline(function()
        if self.results_menu then
            UIManager:close(self.results_menu)
            self.results_menu = nil
        end

        if self:isMuPDFRender() then
            self:openResultMuPDF(result)
            return
        end

        if self:isCreRender() then
            self:openResultCre(result)
            return
        end

        self:openResultMarkdown(result)
    end)
end

function WebBrowser:showMarkdownPage(page, push_history, refresh_scroll)
    if push_history and self.current_page then
        table.insert(self.history, self.current_page)
    end

    if self.markdown_viewer then
        self.replacing_viewer = true
        UIManager:close(self.markdown_viewer)
        self.markdown_viewer = nil
    end

    if not page.source_context and self.current_page and self.current_page.source_context then
        page.source_context = self.current_page.source_context
    end

    self.current_page = page

    self.markdown_viewer = MarkdownViewer:new {
        title = page.title or page.source_url,
        markdown = page.markdown,
        on_back = function()
            self:onBack()
        end,
        on_link = function(link)
            self:onLinkTapped(link)
        end,
        on_close = function()
            self:onViewerClosed()
        end,
        on_save = function()
            self:onSaveCurrentPage()
        end,
        on_bookmark = function()
            self:onBookmarkCurrentPage()
        end,
    }

    UIManager:show(self.markdown_viewer)

    if refresh_scroll then
        UIManager:nextTick(function()
            if self.markdown_viewer and self.markdown_viewer.refreshAfterNavigation then
                self.markdown_viewer:refreshAfterNavigation()
            end
        end)
    end
end

function WebBrowser:onViewerClosed()
    if self.replacing_viewer then
        self.replacing_viewer = nil
        return
    end
    self.markdown_viewer = nil
    self.current_page = nil
    self.history = {}
end

function WebBrowser:onBack()
    local current_context = self.current_page and self.current_page.source_context
    if #self.history == 0 then
        if self.markdown_viewer then
            UIManager:close(self.markdown_viewer)
        end
        self.markdown_viewer = nil
        self.current_page = nil
        local last_results = self.last_results
        if current_context == "bookmarks" then
            UIManager:setDirty(nil, "full")
            UIManager:nextTick(function()
                self:showBookmarksDialog()
            end)
        elseif current_context == "search" and last_results and last_results.items and #last_results.items > 0 then
            UIManager:nextTick(function()
                self:showResultsMenu(last_results.query, last_results.items, last_results.engine_display, last_results.engine_name)
            end)
        end
        return
    end

    local previous = table.remove(self.history)
    if self.markdown_viewer then
        UIManager:close(self.markdown_viewer)
        self.markdown_viewer = nil
    end
    self:showMarkdownPage(previous, false, true)
end

function WebBrowser:onLinkTapped(link)
    if not self:isMarkdownRender() then
        return
    end
    if type(link) ~= "string" then
        return
    end

    if link == "" or not self.current_page then
        return
    end

    if link:sub(1, 1) == "#" then
        return
    end

    local absolute = Utils.absolute_url(self.current_page.source_url, link)
    if not absolute or absolute == "" then
        return
    end

    local gateway_url = Utils.ensure_markdown_gateway(absolute)

    NetworkMgr:runWhenOnline(function()
        local content, err = fetch_markdown(gateway_url)
        if not content then
            self:handleFetchError(err, false)
            return
        end

        local page = {
            title = absolute,
            source_url = absolute,
            gateway_url = gateway_url,
            markdown = content,
            source_context = self.current_page and self.current_page.source_context,
        }
        self:showMarkdownPage(page, true, true)
    end)
end

function WebBrowser:onSaveCurrentPage()
    if not self.current_page or not self.current_page.markdown then
        UIManager:show(InfoMessage:new {
            text = _("No page loaded."),
            timeout = 2,
        })
        return
    end

    local target_dir, attempts = self:determineSaveDirectory()
    if not target_dir then
        UIManager:show(InfoMessage:new {
            text = _("Unable to resolve save directory."),
            timeout = 3,
        })
        return
    end

    if attempts and #attempts > 0 then
        local failed = attempts[1]
        if failed and failed.error then
            UIManager:show(InfoMessage:new {
                text = _(string.format("Falling back to a different folder. Reason: %s", failed.error)),
                timeout = 3,
            })
        end
    end

    local filename = self:generateMarkdownFilename(self.current_page, target_dir)
    local filepath = string.format("%s/%s", target_dir, filename)

    local file, err = io.open(filepath, "w")
    if not file then
        UIManager:show(InfoMessage:new {
            text = _(string.format("Failed to save file: %s", err or "")),
            timeout = 3,
        })
        return
    end

    file:write(self.current_page.markdown)
    file:close()

    UIManager:show(InfoMessage:new {
        text = _(string.format("Saved to %s", filepath)),
        timeout = 3,
    })
end

function WebBrowser:onBookmarkCurrentPage()
    if not self.current_page then
        UIManager:show(InfoMessage:new {
            text = _("No page loaded."),
            timeout = 2,
        })
        return
    end

    local current_source_url = self.current_page.source_url or self.current_page.gateway_url
    local current_title = self.current_page.title

    local added, message = self:addBookmarkEntry(current_source_url, current_title, _("Current page URL is missing."))
    if message and message ~= "" then
        UIManager:show(InfoMessage:new {
            text = message,
            timeout = 2,
        })
    end
end

function WebBrowser:getBookmarksStore()
    if not self.bookmarks_store then
        self.bookmarks_store = BookmarksStore:new()
    end
    return self.bookmarks_store
end

function WebBrowser:getBookmarks()
    local store = self:getBookmarksStore()
    local entries = store:getAll() or {}
    local changed = false
    for _, entry in ipairs(entries) do
        if type(entry) == "table" then
            if not entry.id or entry.id == "" then
                entry.id = Random.uuid(true)
                changed = true
            end
            if entry.markdown ~= nil then
                entry.markdown = nil
                changed = true
            end
            if entry.gateway_url ~= nil then
                entry.gateway_url = nil
                changed = true
            end
            if entry.source_context ~= nil then
                entry.source_context = nil
                changed = true
            end
            if entry.url and not entry.source_url then
                entry.source_url = entry.url
                changed = true
            end
            if entry.url ~= nil then
                entry.url = nil
                changed = true
            end
        end
    end
    if changed then
        store:setAll(entries)
    end
    return entries
end

function WebBrowser:showAddBookmarkDialog(parent_dialog, clearDialogCallback)
    local add_dialog
    add_dialog = MultiInputDialog:new {
        title = _("Add Bookmark"),
        fields = {
            {
                hint = _("Title"),
                text = "",
            },
            {
                hint = _("URL"),
                text = "",
            },
        },
        buttons = {
            {
                {
                    text = _("Cancel"),
                    callback = function()
                        UIManager:close(add_dialog)
                    end,
                },
                {
                    text = _("Save"),
                    is_enter_default = true,
                    callback = function()
                        local fields = add_dialog:getFields()
                        local title_input = trim_text(fields[1])
                        local url_input = trim_text(fields[2])

                        if url_input == "" then
                            UIManager:show(InfoMessage:new {
                                text = _("Please enter a URL."),
                                timeout = 2,
                            })
                            return
                        end

                        local normalized_input = Utils.ensure_markdown_gateway(url_input)
                        local store = self:getBookmarksStore()
                        local bookmarks = self:getBookmarks()

                        for index, entry in ipairs(bookmarks) do
                            if entry then
                                local existing_source = entry.source_url
                                local normalized_existing_source = existing_source and Utils.ensure_markdown_gateway(existing_source)
                                if (existing_source and (existing_source == url_input or existing_source == normalized_input))
                                    or (normalized_existing_source and normalized_existing_source == normalized_input) then
                                    UIManager:show(InfoMessage:new {
                                        text = _("Bookmark already exists."),
                                        timeout = 2,
                                    })
                                    return
                                end
                            end
                        end

                        local display_title = title_input ~= "" and title_input or url_input
                        local new_entry = {
                            id = Random.uuid(true),
                            title = display_title,
                            source_url = url_input,
                        }

                        table.insert(bookmarks, 1, new_entry)
                        store:setAll(bookmarks)

                        UIManager:close(add_dialog)
                        UIManager:show(InfoMessage:new {
                            text = _("Bookmark added."),
                            timeout = 2,
                        })

                        if parent_dialog then
                            parent_dialog:onClose()
                            if clearDialogCallback then
                                clearDialogCallback()
                            end
                        end

                        UIManager:nextTick(function()
                            self:showBookmarksDialog()
                        end)
                    end,
                },
            },
        },
    }

    UIManager:show(add_dialog)
    add_dialog:onShowKeyboard()
end

function WebBrowser:showEditBookmarkDialog(parent_dialog, clearDialogCallback, entry, bookmarks, store)
    if not entry or not entry.id then
        return
    end

    local edit_dialog
    edit_dialog = MultiInputDialog:new {
        title = _("Edit Bookmark"),
        fields = {
            {
                hint = _("Title"),
                text = entry.title or "",
            },
            {
                hint = _("URL"),
                text = entry.source_url or entry.gateway_url or entry.url or "",
            },
        },
        buttons = {
            {
                {
                    text = _("Cancel"),
                    callback = function()
                        UIManager:close(edit_dialog)
                    end,
                },
                {
                    text = _("Save"),
                    is_enter_default = true,
                    callback = function()
                        local fields = edit_dialog:getFields()
                        local title_input = trim_text(fields[1])
                        local url_input = trim_text(fields[2])

                        if url_input == "" then
                            UIManager:show(InfoMessage:new {
                                text = _("Please enter a URL."),
                                timeout = 2,
                            })
                            return
                        end

                        local normalized_input = Utils.ensure_markdown_gateway(url_input)

                        for _, existing in ipairs(bookmarks) do
                            if existing and existing.id and existing.id ~= entry.id then
                                local existing_source = existing.source_url or existing.gateway_url or existing.url
                                local normalized_existing_source = existing_source and Utils.ensure_markdown_gateway(existing_source)
                                if (existing_source and (existing_source == url_input or existing_source == normalized_input))
                                    or (normalized_existing_source and normalized_existing_source == normalized_input) then
                                    UIManager:show(InfoMessage:new {
                                        text = _("Bookmark already exists."),
                                        timeout = 2,
                                    })
                                    return
                                end
                            end
                        end

                        local display_title = title_input ~= "" and title_input or url_input
                        entry.title = display_title
                        entry.source_url = url_input
                        entry.gateway_url = nil

                        store:setAll(bookmarks)

                        UIManager:close(edit_dialog)
                        UIManager:show(InfoMessage:new {
                            text = _("Bookmark updated."),
                            timeout = 2,
                        })

                        if parent_dialog then
                            parent_dialog:onClose()
                            if clearDialogCallback then
                                clearDialogCallback()
                            end
                        end

                        UIManager:nextTick(function()
                            self:showBookmarksDialog()
                        end)
                    end,
                },
            },
        },
    }

    UIManager:show(edit_dialog)
    edit_dialog:onShowKeyboard()
end

function WebBrowser:openBookmarkEntry(entry, bookmarks, store)
    if not entry then
        return
    end

    local url = entry.source_url or entry.url
    if not url or url == "" then
        UIManager:show(InfoMessage:new {
            text = _("Bookmark URL is missing."),
            timeout = 2,
        })
        return
    end

    local title = entry.title
    if not title or title == "" then
        title = url
        entry.title = title
        if store and bookmarks then
            store:setAll(bookmarks)
        else
            local bookmarks_store = self:getBookmarksStore()
            local all_entries = self:getBookmarks()
            local updated = false
            for _, existing in ipairs(all_entries) do
                if existing and existing.id == entry.id then
                    if not existing.title or existing.title == "" then
                        existing.title = title
                        updated = true
                    end
                    break
                end
            end
            if updated then
                bookmarks_store:setAll(all_entries)
            end
        end
    end

    local direct_url = Utils.decode_result_url(url) or url

    NetworkMgr:runWhenOnline(function()
        if self:isMuPDFRender() then
            self:loadMuPDFUrl(direct_url, false, _("Loading bookmark…"))
            return
        end

        if self:isCreRender() then
            self:loadCreUrl(direct_url, false, _("Loading bookmark…"))
            return
        end

        local gateway_url = Utils.ensure_markdown_gateway(url)
        local info = InfoMessage:new {
            text = _("Loading bookmark…"),
            timeout = 0,
        }
        UIManager:show(info)

        local markdown, err = fetch_markdown(gateway_url)
        UIManager:close(info)

        if not markdown then
            self:handleFetchError(err, false)
            return
        end

        self:showMarkdownPage({
            title = title,
            source_url = url,
            gateway_url = gateway_url,
            markdown = markdown,
            source_context = "bookmarks",
        }, true, true)
    end)
end

function WebBrowser:showBookmarksDialog()
    if self.bookmarks_dialog then
        UIManager:close(self.bookmarks_dialog)
        self.bookmarks_dialog = nil
    end

    local store = self:getBookmarksStore()
    local bookmarks = self:getBookmarks()
    local selection = {}

    local dialog
    local function clearDialog()
        self.bookmarks_dialog = nil
    end

    local buttons = {
        {
            {
                text = _("Delete"),
                enabled = #bookmarks > 0,
                callback = function()
                    if not dialog then
                        return
                    end
                    local selected_ids = {}
                    for _, entry in ipairs(bookmarks) do
                        if entry and entry.id and selection[entry.id] then
                            table.insert(selected_ids, entry.id)
                        end
                    end
                    if #selected_ids == 0 then
                        UIManager:show(InfoMessage:new {
                            text = _("Select at least one bookmark to delete."),
                            timeout = 2,
                        })
                        return
                    end
                    local removed = store:removeByIds(selected_ids)
                    if removed > 0 then
                        UIManager:show(InfoMessage:new {
                            text = _("Selected bookmarks deleted."),
                            timeout = 2,
                        })
                    end
                    dialog:onClose()
                    clearDialog()
                    UIManager:nextTick(function()
                        self:showBookmarksDialog()
                    end)
                end,
            },
            {
                text = _("Open"),
                enabled = #bookmarks > 0,
                callback = function()
                    if not dialog then
                        return
                    end
                    local selected
                    for _, entry in ipairs(bookmarks) do
                        if entry and entry.id and selection[entry.id] then
                            selected = entry
                            break
                        end
                    end
                    if not selected then
                        UIManager:show(InfoMessage:new {
                            text = _("Select a bookmark to open."),
                            timeout = 2,
                        })
                        return
                    end
                    dialog:onClose()
                    clearDialog()
                    UIManager:nextTick(function()
                        self:openBookmarkEntry(selected, bookmarks, store)
                    end)
                end,
            },
            {
                text = _("Edit"),
                enabled = #bookmarks > 0,
                callback = function()
                    if not dialog then
                        return
                    end
                    local selected
                    for _, entry in ipairs(bookmarks) do
                        if entry and entry.id and selection[entry.id] then
                            selected = entry
                            break
                        end
                    end
                    if not selected then
                        UIManager:show(InfoMessage:new {
                            text = _("Select a bookmark to edit."),
                            timeout = 2,
                        })
                        return
                    end
                    self:showEditBookmarkDialog(dialog, clearDialog, selected, bookmarks, store)
                end,
            },
            {
                text = _("Add"),
                callback = function()
                    self:showAddBookmarkDialog(dialog, clearDialog)
                end,
            },
            {
                text = _("Close"),
                callback = function()
                    if dialog then
                        dialog:onClose()
                        clearDialog()
                    end
                end,
            },
        },
    }

    dialog = ButtonDialog:new {
        title = _("Bookmarks"),
        buttons = buttons,
        tap_close_callback = clearDialog,
        rows_per_page = {6, 8},
    }

    self.bookmarks_dialog = dialog

    local bookmark_container = VerticalGroup:new{}

    if #bookmarks == 0 then
        local empty_widget = CheckButton:new {
            text = _("No bookmarks saved yet."),
            parent = dialog,
            checkable = false,
            enabled = false,
        }
        empty_widget.not_focusable = true
        bookmark_container[1] = empty_widget
    else
        local threshold_rows = 10
        local bookmarks_group = VerticalGroup:new{}
        for _, entry in ipairs(bookmarks) do
            local id = entry.id
            local title = entry.title
            if not title or title == "" then
                title = entry.source_url or entry.gateway_url or entry.url or _("(No title)")
            end
            local subtitle = entry.source_url or entry.gateway_url or entry.url
            local label
            if subtitle and subtitle ~= "" and subtitle ~= title then
                label = string.format("%s\n%s", title, subtitle)
            else
                label = title
            end
            selection[id] = false
            local checkbox
            checkbox = CheckButton:new {
                text = label,
                parent = dialog,
                callback = function()
                    selection[id] = checkbox.checked
                end,
            }
            bookmarks_group[#bookmarks_group + 1] = checkbox
        end
        local max_height_ratio = 0.8
        local screen_height = Screen:getHeight()
        local max_height = math.floor(screen_height * max_height_ratio)
        local content_size = bookmarks_group:getSize()
        local needs_scroll = (#bookmarks > threshold_rows) or (content_size.h > max_height)

        if needs_scroll then
            local final_height = math.min(content_size.h, max_height)
            local scrollable = ScrollableContainer:new {
                dimen = Geom:new {
                    w = dialog.buttontable:getSize().w + ScrollableContainer:getScrollbarWidth(),
                    h = final_height,
                },
                show_parent = dialog,
                bookmarks_group,
            }
            bookmark_container[1] = scrollable
        else
            bookmark_container[1] = bookmarks_group
        end
    end

    if bookmark_container[1] then
        dialog:addWidget(bookmark_container[1])
    end

    UIManager:show(dialog)
end

function WebBrowser:handleFetchError(err, reopen_results)
    local message = err or _("Failed to load content.")
    if message == "wantread" then
        message = _("Unable to load content. Please check your connection and try again.")
    end
    UIManager:show(InfoMessage:new {
        text = message,
        timeout = 3,
    })

    if reopen_results and self.last_results and self.last_results.items and #self.last_results.items > 0 then
        UIManager:nextTick(function()
            self:showResultsMenu(self.last_results.query, self.last_results.items, self.last_results.engine_display, self.last_results.engine_name)
        end)
    end
end

return WebBrowser
