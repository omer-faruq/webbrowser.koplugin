-- Template for a site adapter.
--
-- Copy this file to a new lowercase, underscore-separated file name based on
-- the site's hostname (e.g. "news_example_com.lua") and replace the example
-- code below.
--
-- Adapters run AFTER the initial HTTP fetch and BEFORE asset rewriting, so
-- relative links in the returned HTML are still rewritten to absolute by the
-- renderer. Errors raised by the adapter are caught by the dispatcher.
--
-- File names beginning with "_" are ignored by the loader and may host shared
-- helpers (see _http.lua).

local http = require("webbrowser_site_adapters._http")
-- Optional: structured logging helper used by KOReader.
-- local logger = require("logger")

return {
    -- Host allowlist. The adapter activates when the page host equals one of
    -- these entries OR is a subdomain of one of them. Case-insensitive.
    hosts = {
        "example.com",
    },

    -- Optional. Custom matcher invoked when host matching fails. Return true
    -- to activate the adapter for the given URL.
    --
    -- match = function(url, parsed_url)
    --     return false
    -- end,

    -- Required. Receives ctx = { url, body, headers } and must return either
    -- a new HTML string or nil to leave the page unchanged.
    transform = function(ctx)
        -- Example: fetch extra content via an API and inject into the body.
        --
        -- local ok, extra = http.post(
        --     "https://example.com/api/content",
        --     { id = "42" },
        --     { Referer = ctx.url }
        -- )
        -- if not ok or type(extra) ~= "string" then
        --     return nil
        -- end
        -- return (ctx.body:gsub(
        --     '<div id="placeholder"></div>',
        --     function() return '<div id="placeholder">' .. extra .. '</div>' end,
        --     1
        -- ))

        return nil
    end,
}
