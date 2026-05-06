# Site adapters

Site adapters let the webbrowser plugin pre-process pages from specific
websites before handing the HTML to the CRE / MuPDF / markdown renderer.
This is useful for pages whose body is filled by JavaScript at runtime
(KOReader's renderer does not execute JavaScript), for paywalled or
"reader-mode" friendly variants, and for any other site-specific cleanup.

## When does an adapter run?

The dispatcher (`../webbrowser_site_adapters.lua`) is invoked by the
renderer immediately after the page HTML is downloaded, before the
renderer rewrites image/CSS asset URLs. The adapter receives the raw HTML
and may return a new HTML string that replaces it.

## Module shape

Each adapter is a Lua module that returns a table:

```lua
local http = require("webbrowser_site_adapters._http")

return {
    -- Optional host list. Matches the host exactly or any subdomain.
    hosts = { "example.com" },

    -- Optional custom matcher (called only if no host entry matched).
    match = function(url, parsed_url) return false end,

    -- Required. ctx = { url, body, headers }
    transform = function(ctx)
        -- ... return new HTML or nil ...
    end,
}
```

* `transform` must return a non-empty string to apply changes; returning
  `nil` (or any non-string) leaves the page untouched.
* Errors raised inside `transform` are caught by the dispatcher and
  logged; the user still sees the original page.

## File naming

* File names use lowercase letters, digits and underscores
  (e.g. `wikicv_net.lua`, `news_example_com.lua`).
* The file name (minus `.lua`) is the adapter identifier in logs.
* Files beginning with `_` are ignored by the loader and may be used for
  shared helpers (see `_http.lua`, `_template.lua`).
* The folder itself is namespaced (`webbrowser_site_adapters`), so files
  inside do **not** need the `webbrowser_` prefix.

## HTTP requests

`_http.lua` exposes a small wrapper around `socket.http` with redirect
following and form encoding:

```lua
local http = require("webbrowser_site_adapters._http")

local ok, body, headers = http.get(url, { Referer = ctx.url })
local ok, body, headers = http.post(url, { id = "42" }, { Referer = ctx.url })
local ok, body, headers = http.request{
    url = url, method = "POST", data = "raw=body",
    headers = { ["content-type"] = "application/json" },
    timeout = 15, maxtime = 60,
}
```

## Writing a new adapter

1. Copy `_template.lua` to `<host>.lua` (e.g. `news_example_com.lua`).
2. Fill in `hosts` with the site's main hostname(s).
3. Implement `transform`: optionally fetch extra data via `_http.lua`,
   then return modified HTML.
4. Restart KOReader (or call `WebBrowser:reloadAdapters()` if available)
   to pick up the new file.

## Existing adapters

* `wikicv_net.lua` &mdash; chapter pages on `wikicv.net` ship only a short
  preview in the static HTML; the full chapter is loaded by JavaScript via
  `POST /chapters/content`. The adapter replays that POST and injects the
  full chapter body so the CRE / MuPDF reader sees the complete text.
* `reddit_com.lua` &mdash; comment threads on `reddit.com` are rendered by a
  React client and ship no comments in the static HTML. The adapter calls
  Reddit's public `<thread>.json` endpoint and renders a clean HTML document
  with the post body and the nested comment forest. Activates only on URLs of
  the form `/r/<sub>/comments/<id>[/<slug>]`.
* `twitter_com.lua` &mdash; status / tweet pages on `twitter.com` and `x.com`
  fetch through the community-maintained `api.fxtwitter.com` JSON proxy and
  render a clean tweet view (text, media, parent / quoted tweet, engagement
  stats). **Replies are not included**: X requires authenticated requests to
  fetch them and there is no reliable public mirror right now. Other X pages
  (profiles, search, home feed) are left untouched.
* `facebook_com.lua` &mdash; public post pages on `facebook.com` are rendered
  through Facebook's own embed iframe endpoint
  (`/plugins/post.php?href=<url>&show_text=true`), which still serves
  unauthenticated requests. The adapter extracts the page name, timestamp,
  full post body and primary image, then falls back to the original page's
  Open Graph metadata if the embed call fails. **Comments and reactions are
  not available**: the embed surface omits them and the only mobile/touch
  surfaces that used to expose them now redirect to a login page.
* Also check the related [**discussion** topics](https://github.com/omer-faruq/webbrowser.koplugin/discussions?discussions_q=label%3Awebsite-adapter)
