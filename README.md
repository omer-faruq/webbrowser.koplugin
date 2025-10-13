# Text-Based Web Browser Plugin for KOReader

Experience distraction-free browsing on e-ink devices with a KOReader-native workflow. Choose between Markdown, CRE, or MuPDF rendering to balance readability and fidelity while keeping navigation lightweight.

## Features
- **Search dialog**: Launch queries directly from KOReader using a custom dialog tailored for e-ink interaction, and open the **History** list to revisit recent searches without retyping them.
- **Curated results list**: Browse plaintext summaries before opening pages, reducing bandwidth and rendering overhead. Long-press a result to open the context menu for quick actions such as saving a bookmark.
- **Flexible rendering modes**: Switch between Markdown, CRE, and MuPDF to match your preferred balance of readability and page fidelity.
- **Direct URL navigation**: Use the Go button in the search dialog to open any URL without performing a search first.
- **Expanded format support**: Follow links to EPUB, PDF, DJVU, CBZ, and other KOReader-supported documents directly from the results screen and continue reading in the appropriate viewer.
- **Bookmark manager**: Store, organize, reopen, and delete frequently referenced pages inside KOReader.
- **Offline-ready saves**: Export rendered Markdown to local storage for later reading without connectivity, or tap **Save** in the link popup to archive the currently highlighted page without opening it first.

## Services Used
- **DuckDuckGo HTML search endpoint** (`https://duckduckgo.com/html/`): Provides ad-free search results optimized for lightweight clients.
- **Jina AI Markdown gateway** (`https://r.jina.ai/`): Converts source web pages to Markdown before they are shown inside KOReader.
- **Brave Search API** (`https://api.search.brave.com/res/v1/web/search`): Supplies JSON search results when the Brave API engine is enabled.

## Search Engine Reliability
- **DuckDuckGo rate limiting**: While convenient, the HTML endpoint is prone to aggressive throttling and may flag repeated traffic as a bot, causing searches to fail after short sessions.
- **Brave API recommendation**: For sustained use, switch the engine to Brave and supply a personal API key. Authenticated requests are far less likely to be throttled and provide more consistent long-term access.

## Brave API Setup
- **Obtain an API key**: Create or sign in to your Brave account and generate a key at [Brave Search Dashboard](https://api-dashboard.search.brave.com/app/dashboard).
- **Configure the plugin**: Store the issued key in `plugins/webbrowser.koplugin/webbrowser_configuration.lua` under `engines.brave_api.api_key` (or your preferred secure storage method).
- **Free-tier limits**: 1 request per second and up to 2,000 queries per month. Consider caching or using DuckDuckGo for lighter usage to stay within the quota.

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
