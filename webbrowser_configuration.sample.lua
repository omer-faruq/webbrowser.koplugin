return {
    engine = "brave_api", -- options: "duckduckgo", "brave_api"

    engines = {
        duckduckgo = {
            name = "duckduckgo",
            display_name = "DuckDuckGo",
            base_url = "https://duckduckgo.com",
            search_path = "/html/",
            language = "en",
            max_results = 10,
        },
        brave_api = {
            name = "brave_api",
            display_name = "Brave API",
            base_url = "https://api.search.brave.com/res/v1/web/search",
            api_key = "your-api-key", -- Get your API key from https://api-dashboard.search.brave.com/
            language = "en",
            country = "us",
            safesearch = "moderate", -- https://api-dashboard.search.brave.com/app/documentation/web-search/query
            max_results = 20,
            page_size = 20,
        },
    },

    render_type = "cre", -- options: "cre","mupdf", "markdown"  mupdf: pdf-like , cre: epub-like experience
    save_to_directory = nil, -- for markdown render_type. : when using the save button it will save into this directory.
    keep_old_website_files = true, -- for mupdf and cre render_types.
    download_images = false, --for mupdf and cre  render_types.
    use_stylesheets =false, --for mupdf and cre render_types: using stylesheets sometimes results in unreadable text. 
}