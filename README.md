# Text-Based Web Browser Plugin for KOReader

Experience distraction-free browsing on e-ink devices with a KOReader-native workflow. Choose between Markdown, CRE, or MuPDF rendering to balance readability and fidelity while keeping navigation lightweight.

## Features
- **Search dialog**: Launch queries directly from KOReader using a custom dialog tailored for e-ink interaction, and open the **History** list to revisit recent searches without retyping them.
- **Curated results list**: Browse plaintext summaries before opening pages, reducing bandwidth and rendering overhead. Long-press a result to open the context menu for quick actions such as saving a bookmark.
- **RSS Reader integration** (optional): When the [RSS Reader plugin](https://github.com/omer-faruq/rssreader.koplugin) is installed, two additional buttons appear in the search result context menu:
  - **Open sanitized**: Downloads and sanitizes the article using RSS Reader's content extraction pipeline (FiveFilters, Diffbot, Instaparser), then opens it in the Web Browser's cache directory for immediate reading.
  - **Save sanitized**: Downloads and sanitizes the article, then saves it as an EPUB (with images) or HTML file to your configured save directory.
  - **Automatic configuration**: Uses your RSS Reader sanitizer settings (API keys, active sanitizers, order) automatically.
  - **Graceful fallback**: If RSS Reader is not installed, these buttons are hidden and the Web Browser functions normally.
- **Flexible rendering modes**: Switch between Markdown, CRE, and MuPDF to match your preferred balance of readability and page fidelity.
- **Direct URL navigation**: Use the Go button in the search dialog to open any URL without performing a search first.
- **Expanded format support**: Follow links to EPUB, PDF, DJVU, CBZ, and other KOReader-supported documents directly from the results screen and continue reading in the appropriate viewer.
- **Bookmark manager**: Store, organize, reopen, and delete frequently referenced pages inside KOReader.
- **Offline-ready saves**: Export rendered Markdown to local storage for later reading without connectivity, or tap **Save** in the link popup to archive the currently highlighted page without opening it first.

## Services Used
- **DuckDuckGo HTML search endpoint** (`https://duckduckgo.com/html/`): Provides ad-free search results optimized for lightweight clients.
- **Jina AI Markdown gateway** (`https://r.jina.ai/`): Converts source web pages to Markdown before they are shown inside KOReader.
- **Brave Search API** (`https://api.search.brave.com/res/v1/web/search`): Supplies JSON search results when the Brave API engine is enabled and now supports the in-app **Load more** button to fetch additional pages without losing the current list. **Recommended for sustained use.**
- **Tavily Search API** (`https://api.tavily.com/search`): Provides LLM-optimized search results with advanced filtering options including search depth control, topic filtering, and country boosting. **Recommended for high-quality, AI-ready search results.**
- **Exa Search API** (`https://api.exa.ai/search`): Delivers embeddings-based neural search with multiple search types (neural, fast, auto, deep variants, instant) and category filtering (company, research paper, news, people, etc.). Supports up to 100 results per query with flexible search algorithms.
- **Google Custom Search API** (`https://customsearch.googleapis.com/customsearch/v1`): ⚠️ **DEPRECATED** - Google has discontinued the "entire web" search feature. Existing users can continue until January 2027, but new users cannot create search engines that cover the entire web. See [deprecation notice](https://support.google.com/programmable-search/answer/12397162). **Please migrate to Brave API or DuckDuckGo.**

## Multiple Engine Profiles
You can define multiple profiles for **any search engine type** with different API keys or settings.

### Profile Naming Rules
The profile key must be related to the engine type. The plugin matches profiles to engines in two ways:

1. **Exact prefix match**: Profile key starts with the full engine type name
   - `brave_api_personal` → matches `brave_api` engine ✓
   - `tavily_api_research` → matches `tavily_api` engine ✓

2. **First-word match**: First part (before underscore) matches the engine type's first part
   - `brave_personal` → matches `brave_api` engine ✓ (both start with "brave")
   - `tavily_research` → matches `tavily_api` engine ✓ (both start with "tavily")
   - `google_work` → matches `google_api` engine ✓ (both start with "google")
   - `exa_academic` → matches `exa_api` engine ✓ (both start with "exa")

**What doesn't work:**
- `personal_brave` → ✗ (doesn't start with "brave")
- `my_tavily` → ✗ (doesn't start with "tavily")
- `work_google` → ✗ (doesn't start with "google")

### Configuration
Each profile needs:
- **Profile key**: Must match the engine type (see rules above)
- **`name` field**: Set to the engine type (e.g., `name = "brave_api"`)
- **`display_name` field**: Unique display name shown in the selector (e.g., `display_name = "Brave (Personal)"`)
- **`visible` field** (optional): Set to `false` to hide from selector (default: `true`)
  - Useful for temporarily disabling profiles without deleting them
  - Hidden profiles can still be used if set as the active engine
- **Other settings**: Same as the default engine config (api_key, language, etc.)

### Examples
See `webbrowser_configuration.sample.lua` for complete examples:
```lua
brave_personal = {
    name = "brave_api",
    display_name = "Brave (Personal)",
    api_key = "your-personal-key",
    ...
}
brave_work = {
    name = "brave_api",
    display_name = "Brave (Work)",
    api_key = "your-work-key",
    ...
}
```

### Switching Profiles
Use the engine selector: Tools → Web Browser → Settings → Select Search Engine

## Search Engine Reliability
- **DuckDuckGo rate limiting**: While convenient, the HTML endpoint is prone to aggressive throttling and may flag repeated traffic as a bot, causing searches to fail after short sessions.
- **Brave API recommendation**: For sustained use, switch the engine to Brave and supply a personal API key. Authenticated requests are far less likely to be throttled and provide more consistent long-term access. **Recommended for general-purpose searches.**
- **Tavily API recommendation**: Optimized for LLM applications with high-quality, semantically relevant results. Offers advanced filtering (search depth, topic, country) and generous free tier (1,000 credits/month). **Recommended for high-quality, AI-ready search results.**
- **Exa API recommendation**: Provides neural search with embeddings-based ranking and multiple search algorithms. Excellent for finding specific types of content (research papers, company info, people profiles) with category filtering. Supports up to 100 results per query.
- **Google Custom Search deprecation**: Google has discontinued the "entire web" search capability. Existing search engines will work until January 2027, but new users cannot create engines that search the entire web. We strongly recommend migrating to Brave API or Tavily API for the best experience.

## Brave API Setup
- **Obtain an API key**: Create or sign in to your Brave account and generate a key at [Brave Search Dashboard](https://api-dashboard.search.brave.com/app/dashboard).
- **Configure the plugin**: Store the issued key in `plugins/webbrowser.koplugin/webbrowser_configuration.lua` under `engines.brave_api.api_key` (or your preferred secure storage method).
- **Language & Country settings**: Configure search language and region through the in-app settings dialog (Tools → Web Browser → Settings → Configure Language/Country for Brave API):
  - **Language**: Enter the language code (e.g., `en`, `pt`, `tr`, `zh-hans`, `zh-hant`)
  - **Country**: Enter the 2-letter country code (e.g., `US`, `BR`, `TR`, `GB`, `CN`, `TW`)
  - **Chinese languages**: Use `zh-hans` for Simplified Chinese or `zh-hant` for Traditional Chinese in the language field, with `CN` or `TW` in the country field
  - **How it works**: The plugin automatically combines these values when needed (e.g., `pt` + `BR` → `pt-br`, `en` + `GB` → `en-gb`, `zh-hans` + `CN` → `zh-hans`). For most languages, only the language code is sent to the API (e.g., `en` + `US` → `en`).

## Tavily API Setup
- **Obtain an API key**: Sign up at [Tavily](https://app.tavily.com/) and get your API key from the dashboard.
- **Configure the plugin**: Add your key to `webbrowser_configuration.lua` under `engines.tavily_api.api_key`.
- **Free-tier limits**: 1,000 API credits per month. Basic/fast/ultra-fast searches cost 1 credit, advanced searches cost 2 credits.
- **Configure settings**: Access Tavily-specific settings through the in-app dialog (Tools → Web Browser → Settings → Configure Settings):
  - **Search depth**: Choose between `basic` (balanced), `advanced` (highest relevance, 2 credits), `fast` (lower latency), or `ultra-fast` (minimal latency)
  - **Topic**: Select `general` for broad searches, `news` for real-time updates, or `finance` for financial data
  - **Country**: Boost results from a specific country (e.g., `turkey`, `united states`, `brazil`) - **Note**: Not supported with `fast` or `ultra-fast` search depth
- **Detailed documentation**: See [Tavily API Guide](https://github.com/omer-faruq/webbrowser.koplugin/wiki/Tavily-Search-API-Integration) for advanced configuration options including time filters, domain filtering, and content options.

## Exa API Setup
- **Obtain an API key**: Sign up at [Exa](https://exa.ai/) and generate your API key from the [dashboard](https://dashboard.exa.ai/api-keys).
- **Configure the plugin**: Add your key to `webbrowser_configuration.lua` under `engines.exa_api.api_key`.
- **Free-tier limits**: Check the [Exa pricing page](https://exa.ai/pricing) for current limits and quotas.
- **Configure settings**: Access Exa-specific settings through the in-app dialog (Tools → Web Browser → Settings → Configure Settings):
  - **Search Type**: Choose between `neural` (embeddings-based), `fast` (streamlined), `auto` (default, intelligently combines methods), `deep-lite`, `deep`, `deep-reasoning`, or `instant` (lowest latency)
  - **Result Category**: Optionally filter by category: `company`, `research paper`, `news`, `personal site`, `financial report`, or `people` (LinkedIn profiles)
  - **User Location**: Set your 2-letter country code (e.g., `US`, `TR`, `GB`, `CN`) to personalize results
- **Category limitations**: The `company` and `people` categories have limited filter support and don't support date/domain filters. See [Exa documentation](https://docs.exa.ai/) for details.

## Google Custom Search Setup
⚠️ **DEPRECATED - NOT RECOMMENDED FOR NEW USERS**

Google has [discontinued the "entire web" search feature](https://support.google.com/programmable-search/answer/12397162) for new Programmable Search Engines. Existing users can continue using their search engines until **January 2027**, but new users cannot create engines that search the entire web.

**For new users**: Please use **Brave Search API** (recommended) or **DuckDuckGo** instead.

**For existing users** (until January 2027):
- **Review the guide**: Follow the step-by-step instructions on the [Google Custom Search API Setup (Free Tier)](https://github.com/omer-faruq/webbrowser.koplugin/wiki/Google-Custom-Search-API-Setup-(Free-Tier)) wiki page to create a free programmable search engine and obtain your `api_key` and `cx` values.
- **Understand the limits**: The free tier covers up to 100 queries per day, with each request returning a maximum of ten results. No credit card is required for this quota.
- **Configure the plugin**: Add your credentials to `webbrowser_configuration.lua` under `engines.google_api` to enable the Google engine inside KOReader.
- **Migration recommended**: Consider switching to Brave API before the January 2027 deadline to avoid service interruption.

## RSS Reader Integration

The Web Browser plugin integrates seamlessly with the [RSS Reader](https://github.com/omer-faruq/rssreader.koplugin) plugin to provide advanced content extraction and sanitization capabilities.

<details>
<summary>Details:</summary>

### Requirements
- **RSS Reader plugin**: Must be installed in your KOReader plugins directory
- **Optional**: Configure sanitizer API keys in RSS Reader for enhanced extraction (Diffbot, Instaparser)

### How It Works
When you long-press a search result, two additional buttons appear if RSS Reader is installed:

1. **Open sanitized**
   - Downloads the article from the URL
   - Runs it through RSS Reader's sanitization pipeline:
     - Tries configured sanitizers in order (FiveFilters → Diffbot → Instaparser)
     - Extracts main content using CSS selectors
     - Removes scripts, styles, and other clutter
     - Adds source URL footer with QR code
   - Saves to Web Browser's cache directory
   - Opens immediately for reading

2. **Save sanitized**
   - Same sanitization process as "Open sanitized"
   - Saves to your configured directory:
     - First tries `save_to_directory` from Web Browser config
     - Falls back to user-defined home directory
     - Falls back to current directory
   - Creates EPUB with images (if available) or HTML file
   - Shows save location when complete

### Configuration
The integration automatically uses your RSS Reader configuration:
- **Sanitizers**: Uses your configured sanitizers and API keys from `rssreader_configuration.lua`
- **Order**: Respects your sanitizer priority order
- **Active/Inactive**: Only uses sanitizers marked as active
- **Features**: Applies your download_images and other feature settings

### Example Workflow
1. Search for "best coffee recipes"
2. Long-press a promising result
3. Tap "Open sanitized" to read immediately, or "Save sanitized" to archive for later
4. The article is extracted, cleaned, and ready to read without ads or clutter

### Graceful Degradation
- If RSS Reader is not installed, the sanitization buttons are hidden
- Web Browser continues to work normally with its built-in rendering modes
- No errors or warnings appear

</details>

## Rendering Modes
- **Markdown**: Fetches content through the Jina AI Markdown gateway and displays it in the lightweight Markdown viewer.
- **CRE**: Streams the downloaded HTML into the Cool Reader Engine for EPUB-like pagination, adjustable zoom, and the most consistent in-app browsing experience. If you want a web feel while staying inside KOReader, this is the recommended mode. When in CRE mode, the "Open here (CRE)" action remains available in KOReader's external link dialog so you can continue browsing in place.
- **MuPDF**: Downloads the raw HTML (plus assets) to a temporary cache and opens it through MuPDF for a closer-to-original layout. When in MuPDF mode, the "Open here (MuPDF)" action remains available in KOReader's external link dialog so you can continue browsing in place.

## Limitations
- **Markdown gateway rate cap**: The Jina AI gateway currently allows opening up to 20 pages per minute; exceeding this limit may result in temporary rate limiting.
- **Site restrictions**: Some websites block automated Markdown conversion or content extraction. In such cases, you can manually enable the **CRE** or **MuPDF** render mode in your configuration file to display the page content directly.

## Getting Started
- **Download & rename**: Either downlaod a release from the [ releases](https://github.com/omer-faruq/webbrowser.koplugin/releases) or Clone or download this repository and rename the top-level folder to `webbrowser.koplugin/`.
- **Copy to device**: Place the folder inside your KOReader plugins directory (varies by platform):
  - Kobo: `.adds/koreader/plugins/`
  - Kindle: `koreader/plugins/`
  - PocketBook: `applications/koreader/plugins/`
  - Android: `koreader/plugins/`
  - macOS: `~/Library/Application Support/koreader/plugins/`
- **Configuration file**: In `webbrowser.koplugin/`, create or edit `webbrowser_configuration.lua` to adjust settings like search engine keys, render modes, or feature toggles. You can make a copy of the file `webbrowser_configuration.sample.lua` and rename it to `webbrowser_configuration.lua`, and edit it.
- **Custom cache location** (optional): By default, cached articles are stored in `.../koreader/cache/webbrowser`. To use a custom location, set `cache_directory = "/path/to/your/folder"` in `webbrowser_configuration.lua`. This is useful for organizing offline articles in a preferred location or switching between folders easily. **Important**: When using a custom cache directory, the "Clear cache" button will be automatically disabled for safety reasons to prevent accidental deletion of important files. You will need to manually clear the cache folder if needed. 
- **Search the web**: Choose "Web Browser" from the main menu under the search category and enter a query in the search dialog.
 - **Navigate results**: Tap a result to render it with the currently selected mode (Markdown, CRE, or MuPDF). You can continue reading by opening subsequent pages through their links. In Markdown mode you can return to the previous page with the back button, while CRE and MuPDF modes rely on KOReader's history function to revisit earlier pages.
- **Manage bookmarks**: Save the current page, add manual entries, or revisit stored content through the bookmark dialog.
- **Save for later**: Use the save action (on markdown mode) in the viewer to archive the Markdown file in your preferred directory.

## Tips
- **Stay online**: Searching, fetching Markdown, and retrieving CRE or MuPDF assets require an active network connection.
- **Mind the rate limit**: The Markdown gateway and initial CRE/MuPDF downloads benefit from short pauses when opening many pages in succession.
- **Keep web cache tidy**: Disable the `keep_old_website_files` option if you prefer to discard previously downloaded CRE or MuPDF pages automatically, or periodically use the **Clear cache** button in the search dialog when that option is enabled.

## Credits
- **Built with Windsurf**: This KOReader web browser plugin was implemented through a Windsurf-assisted development workflow.
- **MuPDF workflow inspiration**: HTML-to-MuPDF handling was adapted from [Frenzie](https://github.com/Frenzie)'s repository, many thanks!

## License
- **GPL-3.0**: Distributed under the KOReader project license. See the root `LICENSE` file for full terms.
