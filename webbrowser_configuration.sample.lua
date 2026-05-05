return {
    engine = "brave_api", -- options: "duckduckgo", "brave_api", "google_api" (deprecated)
    -- RECOMMENDED: Use "brave_api" for best reliability and sustained use.
    -- Google API is deprecated for new users (existing users can use until January 2027).

    engines = {
        duckduckgo = {
            name = "duckduckgo",
            display_name = "DuckDuckGo",
            base_url = "https://duckduckgo.com",
            search_path = "/html/",
            language = "en",
            country = "us",
            max_results = 10,
        },
        brave_api = {
            name = "brave_api",
            display_name = "Brave API",
            base_url = "https://api.search.brave.com/res/v1/web/search",
            api_key = "your-api-key", -- Get your API key from https://api-dashboard.search.brave.com/
            -- Language & Country: Plugin auto-combines when needed.
            -- Examples:
            --   Brazilian Portuguese: language = "pt",      country = "BR" → search_lang=pt-br, country=BR, ui_lang=pt-BR
            --   British English:      language = "en",      country = "GB" → search_lang=en-gb, country=GB, ui_lang=en-GB
            --   American English:     language = "en",      country = "US" → search_lang=en, country=US, ui_lang=en-US
            --   Turkish:              language = "tr",      country = "TR" → search_lang=tr, country=TR, ui_lang=tr-TR
            --   Simplified Chinese:   language = "zh-hans", country = "CN" → search_lang=zh-hans, country=CN, ui_lang=zh-CN
            --   Traditional Chinese:  language = "zh-hant", country = "TW" → search_lang=zh-hant, country=TW, ui_lang=zh-TW
            language = "en",
            country = "us",
            safesearch = "moderate", -- https://api-dashboard.search.brave.com/app/documentation/web-search/query
            max_results = 20,
            page_size = 20,
        },
        google_api = {
            -- DEPRECATED: Google discontinued "entire web" search for new users.
            -- Existing users can continue until January 2027.
            -- New users: Please use brave_api (recommended) or duckduckgo instead.
            -- See: https://support.google.com/programmable-search/answer/12397162
            -- Setup instructions (existing users only): https://github.com/omer-faruq/webbrowser.koplugin/wiki/Google-Custom-Search-API-Setup-(Free-Tier)
            name= "google_api",
            display_name = "Google API",
            base_url = "https://customsearch.googleapis.com/customsearch/v1",
            api_key = "YOUR_API_KEY_HERE",
            cx = "YOUR_CX_HERE",
            language = "en",
            country = "us",
            max_results = 10,
            page_size = 10,
        }
    },

    render_type = "cre", -- options: "cre","mupdf", "markdown"  mupdf: pdf-like , cre: epub-like experience
    cache_directory = nil, -- optional: custom cache folder path (default: .../koreader/cache/webbrowser). Useful for organizing offline articles.
    save_to_directory = nil, -- for markdown ,cre ,mupdf render types. : when using the save button it will save into this directory.
    keep_old_website_files = true, -- for mupdf and cre render types.
    download_images = false, --for mupdf and cre  render types.
    use_stylesheets = false, --for mupdf and cre render_types: using stylesheets sometimes results in unreadable text.
    search_history_limit = 10, -- maximum number of saved search history entries
    website_history_limit = 50, -- maximum number of saved website history entries, nil or 0 to disable.
    duplicate_entry_on_website_history = true, -- record duplicate visits to the same URL when true, false will only record the latest visit.

    supported_file_types = { -- entries outside this list are saved / opened with a fallback .html extension.
        "epub3",
        "epub",
        "pdf",
        "djvu",
        "xps",
        "cbt",
        "cbz",
        "fb2",
        "pdb",
        "txt",
        "html",
        "htm",
        "xhtml",
        "rtf",
        "chm",
        "doc",
        "mobi",
        "zip",
        "md",
        "png",
        "jpg",
        "jpeg",
        "gif",
        "bmp",
        "webp",
        "svg",
        "css",
        "js",
    },
}