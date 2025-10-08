local Dispatcher = require("dispatcher")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local Menu = require("ui/widget/menu")
local ButtonDialog = require("ui/widget/buttondialog")
local CheckButton = require("ui/widget/checkbutton")
local MultiInputDialog = require("ui/widget/multiinputdialog")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local util = require("util")
local FileManagerUtil = require("apps/filemanager/filemanagerutil")
local lfs = require("libs/libkoreader-lfs")
local socket_http = require("socket.http")
local socket = require("socket")
local socketutil = require("socketutil")
local ltn12 = require("ltn12")
local _ = require("gettext")
local NetworkMgr = require("ui/network/manager")

local MarkdownViewer = require("webbrowser_markdown_viewer")
local Utils = require("webbrowser_utils")
local CONFIG = require("webbrowser_configuration")
local BookmarksStore = require("webbrowser_bookmarks")
local Random = require("random")

local SearchEngines = {
    duckduckgo = require("webbrowser_duckduckgo"),
    brave_api = require("webbrowser_brave_api"),
}

local DEFAULT_SEARCH_ENGINE = "duckduckgo"

local WebBrowser = WidgetContainer:extend{
    name = "webbrowser",
    is_doc_only = false,
}

local DEFAULT_TIMEOUT = 20
local DEFAULT_MAXTIME = 60

local function trim_text(value)
    return (value or ""):gsub("^%s+", ""):gsub("%s+$", "")
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

local function fetch_markdown(url)
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
            NetworkMgr:runWhenOnline(function()
                self:showSearchDialog()
            end)
        end,
    }
end

function WebBrowser:onShowWebBrowser()
    self:showSearchDialog()
end

function WebBrowser:showSearchDialog()
    if self.search_dialog and self.search_dialog.dialog_open then
        return
    end

    local engine_display = self:getSearchEngineDisplayName()

    self.search_dialog = InputDialog:new {
        title = string.format(_("%s Search"), engine_display),
        input = "",
        input_hint = _("Enter keywords"),
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
                        self:performSearch(query)
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

function WebBrowser:showResultsMenu(query, results, engine_display, engine_name)
    if self.results_menu then
        UIManager:close(self.results_menu)
        self.results_menu = nil
    end

    local display_name = engine_display or self:getSearchEngineDisplayName()
    local resolved_engine_name = engine_name or self:getSelectedEngineName()

    self.last_results = {
        query = query,
        items = results,
        engine_display = display_name,
        engine_name = resolved_engine_name,
    }

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
        table.insert(item_table, {
            text = result.title,
            sub_text = sub_text,
            callback = function()
                self:openResult(result)
            end,
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
    }

    UIManager:show(self.results_menu)
end

function WebBrowser:openResult(result)
    if self.results_menu then
        UIManager:close(self.results_menu)
        self.results_menu = nil
    end

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

    local store = self:getBookmarksStore()
    local bookmarks = self:getBookmarks()
    local current_source_url = self.current_page.source_url or self.current_page.gateway_url
    if not current_source_url or current_source_url == "" then
        UIManager:show(InfoMessage:new {
            text = _("Current page URL is missing."),
            timeout = 2,
        })
        return
    end

    local normalized_current_url = Utils.ensure_markdown_gateway(current_source_url)
    local current_title = self.current_page.title

    for _, entry in ipairs(bookmarks) do
        if entry then
            local existing_source = entry.source_url or entry.url
            local normalized_existing_source = existing_source and Utils.ensure_markdown_gateway(existing_source)
            if (existing_source and existing_source == current_source_url)
                or (normalized_current_url and normalized_existing_source and normalized_existing_source == normalized_current_url)
                or (current_title and entry.title == current_title) then
                UIManager:show(InfoMessage:new {
                    text = _("Bookmark already exists."),
                    timeout = 2,
                })
                return
            end
        end
    end

    local title_to_save = current_title and current_title ~= "" and current_title or current_source_url
    local new_entry = {
        id = Random.uuid(true),
        title = title_to_save,
        source_url = current_source_url,
    }

    table.insert(bookmarks, 1, new_entry)
    store:setAll(bookmarks)
    UIManager:show(InfoMessage:new {
        text = _("Bookmark added."),
        timeout = 2,
    })
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

    if #bookmarks == 0 then
        local empty_widget = CheckButton:new {
            text = _("No bookmarks saved yet."),
            parent = dialog,
            checkable = false,
            enabled = false,
        }
        empty_widget.not_focusable = true
        dialog:addWidget(empty_widget)
    else
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
            dialog:addWidget(checkbox)
        end
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
