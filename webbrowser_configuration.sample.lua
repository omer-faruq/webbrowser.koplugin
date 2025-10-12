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
    save_to_directory = nil, -- for markdown ,cre ,mupdf render types. : when using the save button it will save into this directory.
    keep_old_website_files = true, -- for mupdf and cre render types.
    download_images = false, --for mupdf and cre  render types.
    use_stylesheets =false, --for mupdf and cre render types: using stylesheets sometimes results in unreadable text. 
    
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