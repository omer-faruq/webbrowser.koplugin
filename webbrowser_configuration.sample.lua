return {
    engine = "brave_api", -- options: "duckduckgo", "brave_api", "tavily_api", "exa_api", "google_api" (deprecated)
    -- RECOMMENDED: Use "brave_api" or "tavily_api" for best reliability and sustained use.
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
        tavily_api = {
            name = "tavily_api",
            display_name = "Tavily API",
            base_url = "https://api.tavily.com/search",
            api_key = "your-api-key", -- Get your API key from https://app.tavily.com/
            -- Search depth controls latency vs. relevance tradeoff:
            --   "basic": Balanced option (1 API credit)
            --   "advanced": Highest relevance with increased latency (2 API credits)
            --   "fast": Lower latency, good relevance (1 API credit)
            --   "ultra-fast": Minimizes latency (1 API credit)
            search_depth = "basic",
            -- Topic: "general" for broad searches, "news" for real-time updates, "finance" for financial data
            topic = "general",
            -- Optional: country name to boost results from specific country (lowercase, e.g., "turkey", "united states", "brazil", "china")
            -- See full list: https://docs.tavily.com/documentation/api-reference/endpoint/search#body-country
            country = nil,
            -- Optional: time range filter ("day", "week", "month", "year")
            time_range = nil,
            -- Optional: specific date range (format: "YYYY-MM-DD")
            start_date = nil,
            end_date = nil,
            -- Optional: include LLM-generated answer (false, "basic", "advanced")
            include_answer = false,
            -- Optional: include cleaned HTML content (false, "markdown", "text")
            include_raw_content = false,
            -- Optional: include images in results
            include_images = false,
            include_image_descriptions = false,
            include_favicon = false,
            -- Optional: domain filters (arrays of domain strings)
            include_domains = {},
            exclude_domains = {},
            max_results = 20,
        },
        exa_api = {
            name = "exa_api",
            display_name = "Exa API",
            base_url = "https://api.exa.ai/search",
            api_key = "your-api-key", -- Get your API key from https://dashboard.exa.ai/api-keys
            -- Search type controls the search algorithm:
            --   "neural": Embeddings-based search
            --   "fast": Streamlined search models
            --   "auto": Intelligently combines neural and other methods (default)
            --   "deep-lite": Lightweight synthesized output
            --   "deep": Light deep search
            --   "deep-reasoning": Base deep search
            --   "instant": Lowest latency, optimized for real-time applications
            search_type = "auto",
            -- Optional: Result category to focus on
            --   "company": Company pages (improved quality for finding company info)
            --   "research paper": Academic research papers
            --   "news": News articles
            --   "personal site": Personal websites and blogs
            --   "financial report": Financial reports and data
            --   "people": LinkedIn profiles (improved quality for finding people)
            -- Note: "company" and "people" categories have limited filter support
            category = nil,
            -- Optional: Two-letter ISO country code of the user (e.g., "US", "TR", "GB", "CN")
            user_location = nil,
            -- Optional: Include full page text in results (increases response size)
            include_text = false,
            max_results = 20,
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