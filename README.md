# Text-Based Web Browser Plugin for KOReader

Experience distraction-free browsing on e-ink devices with a text-only workflow powered by KOReader. This plugin is designed to keep navigation lightweight while preserving essential page content in Markdown form.

## Features
- **Search dialog**: Launch queries directly from KOReader using a custom dialog tailored for e-ink interaction.
- **Curated results list**: Browse plaintext summaries before opening pages, reducing bandwidth and rendering overhead.
- **Markdown reader**: View fetched articles in the built-in Markdown viewer with support for internal navigation and link following.
- **Bookmark manager**: Store, organize, reopen, and delete frequently referenced pages inside KOReader.
- **Offline-ready saves**: Export rendered Markdown to local storage for later reading without connectivity.

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
- **Free-tier limits**: 1 request per second and up to 2,000 queries per month. Consider caching or using DuckDuckGo for lighter usage to stay within quota.

## Limitations
- **Markdown-only rendering**: The plugin displays the Markdown-converted view of each page instead of the full original layout.
- **Conversion rate cap**: The Jina AI gateway currently allows opening up to 20 pages per minute; exceeding this limit may result in temporary rate limiting.

## Getting Started
- **Download & rename**: Clone or download this repository and rename the top-level folder to `webbrowser.koplugin/`.
- **Copy to device**: Place the folder inside your KOReader plugins directory (varies by platform):
  - Kobo: `.adds/koreader/plugins/`
  - Kindle: `koreader/plugins/`
  - PocketBook: `applications/koreader/plugins/`
  - Android: `koreader/plugins/`
  - macOS: `~/Library/Application Support/koreader/plugins/`
- **Configuration file**: In `webbrowser.koplugin/`, create or edit `webbrowser_configuration.lua` to adjust settings like search engine keys or feature toggles.
- **Search the web**: Choose "Web Browser" from the main menu under search category and enter a query in the search dialog.
- **Navigate results**: Tap a result to fetch its Markdown representation or return to the list at any time.
- **Manage bookmarks**: Save the current page, add manual entries, or revisit stored content through the bookmark dialog.
- **Save for later**: Use the save action in the viewer to archive the Markdown file in your preferred directory.

## Tips
- **Stay online**: Searching and fetching Markdown requires an active network connection.
- **Mind the rate limit**: When quickly opening multiple pages, pause briefly to avoid hitting the conversion cap.
- **Use bookmarks for caching**: Opening a saved bookmark with stored Markdown bypasses another conversion request, helping conserve API usage.

## Credits
- **Built with Windsurf**: This KOReader web browser plugin was implemented through a Windsurf-assisted development workflow.

## License
- **GPL-3.0**: Distributed under the KOReader project license. See the root `LICENSE` file for full terms.
