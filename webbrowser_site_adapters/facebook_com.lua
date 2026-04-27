-- Adapter for facebook.com public posts.
--
-- The regular facebook.com post page is a 350 kB React shell that never
-- contains the actual post body in its static HTML; `mbasic`, `m` and
-- `touch` subdomains now unconditionally redirect logged-out users to the
-- login page. The one surface that still works without authentication is
-- Facebook's own embed iframe:
--
--   https://www.facebook.com/plugins/post.php?href=<url>&show_text=true
--
-- That endpoint is used by publishers who embed Facebook posts on their own
-- websites, so it happily serves public posts to anonymous clients. The
-- response is a small self-contained document that includes:
--   * the page / author name
--   * the post timestamp
--   * the full post text (inside <div data-testid="post_message">)
--   * the post image (if any)
--   * a link back to the original permalink
--
-- It does NOT include comments or reactions, and there is no reliable
-- public surface that does today. The adapter therefore renders the post
-- content and ends with a short disclaimer explaining why comments are
-- missing.
--
-- If the embed endpoint fails (e.g. Facebook blocks the request, or the
-- post has been removed) the adapter falls back to whatever the original
-- page's Open Graph meta tags contain, which at least gives a truncated
-- preview instead of the empty React shell.

local logger = require("logger")
local urlmod = require("socket.url")
local util = require("util")
local http = require("webbrowser_site_adapters._http")

local USER_AGENT = "Mozilla/5.0 (compatible; KOReader webbrowser plugin)"

local HTML_ESCAPES = {
    ["&"] = "&amp;",
    ["<"] = "&lt;",
    [">"] = "&gt;",
    ['"'] = "&quot;",
    ["'"] = "&#39;",
}

local function html_escape(s)
    if s == nil then return "" end
    return (tostring(s):gsub("[&<>\"']", HTML_ESCAPES))
end

-- Decode HTML entities (named + numeric) using KOReader's UTF-8-aware helper.
local function html_decode(s)
    if not s then return "" end
    return util.htmlEntitiesToUtf8(s)
end

local function format_timestamp(unix)
    if type(unix) ~= "number" or unix <= 0 then return "" end
    return os.date("!%Y-%m-%d %H:%M UTC", unix)
end

-- Recognise individual post / story URLs on any facebook.com subdomain.
-- Returns the canonical URL to pass to the embed endpoint (the user's own
-- URL is fine as input; we normalise to https://www.facebook.com/...).
local function canonical_post_url(parsed_url)
    if not parsed_url or not parsed_url.host or not parsed_url.path then
        return nil
    end
    local host = parsed_url.host:lower()
    if not (host == "facebook.com" or host == "fb.com"
        or host:sub(-#".facebook.com") == ".facebook.com"
        or host:sub(-#".fb.com") == ".fb.com") then
        return nil
    end

    local path = parsed_url.path
    local accepts =
        path:match("^/[%w%.%-_]+/posts/") ~= nil
        or path:match("^/[%w%.%-_]+/videos/") ~= nil
        or path:match("^/[%w%.%-_]+/photos/") ~= nil
        or path:match("^/permalink%.php") ~= nil
        or path:match("^/story%.php") ~= nil
        or path:match("^/share/p/") ~= nil
        or path:match("^/watch/") ~= nil
        or path:match("^/groups/[^/]+/posts/") ~= nil
        or path:match("^/groups/[^/]+/permalink/") ~= nil
    if not accepts then
        return nil
    end

    -- Rebuild a URL pointed at the canonical `www.facebook.com` host so the
    -- embed endpoint accepts it regardless of what the user opened.
    local rebuilt = {
        scheme = "https",
        host = "www.facebook.com",
        path = path,
        query = parsed_url.query,
    }
    return urlmod.build(rebuilt)
end

local function parse_og_tags(html)
    local out = {}
    for prop, content in html:gmatch(
            '<meta%s+property="(og:[%w_:]+)"%s+content="([^"]*)"') do
        out[prop] = html_decode(content)
    end
    -- Twitter cards duplicate a few fields in a slightly different shape
    if not out["og:description"] then
        local desc = html:match(
            '<meta%s+name="description"%s+content="([^"]*)"')
        if desc then out["og:description"] = html_decode(desc) end
    end
    return out
end

-- Parse the rich pieces out of Facebook's embed response.
local function parse_embed(html)
    local info = {}

    -- Author / page name (inside the "_2_79 _50f7" span)
    info.author = html:match('<span[^>]-class="_2_79 _50f7"[^>]*>([^<]+)</span>')
    if info.author then info.author = html_decode(info.author) end

    -- Author URL, the first "/<page>?ref=embed_post" style anchor
    local author_href = html:match('<a[^>]-href="(https?://www%.facebook%.com/[^"?]+)%?ref=embed_post"')
    if author_href then
        info.author_url = html_decode(author_href)
    end

    -- Timestamp (unix seconds)
    local utime = html:match('data%-utime="(%d+)"')
    if utime then
        info.timestamp = tonumber(utime)
    end

    -- Permalink for the post itself (href with /<user>/posts/<id>?ref=embed_post)
    local perma = html:match('<a[^>]-href="(/[%w%.%-_]+/posts/[%w_]+)%?ref=embed_post"')
    if perma then
        info.permalink = "https://www.facebook.com" .. perma
    end

    -- Post message HTML
    local msg = html:match(
        '<div[^>]-data%-testid="post_message"[^>]*>(.-)</div>')
    if msg then
        info.message_html = msg
    end

    -- Post image (large preview); pick the first _1p6f image if any
    local img_src = html:match(
        '<img[^>]-class="[^"]*_1p6f[^"]*"[^>]-src="([^"]+)"')
    if img_src then
        info.image_url = html_decode(img_src)
    end

    return info
end

-- Rewrite <img> URLs inside the post body to point at an absolute URL so the
-- rest of the renderer can download them. The embed HTML already uses
-- absolute URLs, we mostly need to decode HTML entities that Facebook put
-- inside the `src` attribute (ampersands on CDN links).
local function clean_message_html(message_html)
    if not message_html then return "" end
    -- Drop Facebook's inline emoji <span> wrappers that carry background
    -- images; they do not render usefully inside CRE and leave stray markup.
    message_html = message_html:gsub('<span%s+class="_5mfr".-</span></span>', "")
    message_html = message_html:gsub('<span%s+class="_6qdm"[^>]*>(.-)</span>', "%1")
    return message_html
end

local function build_html_from_embed(embed, fallback_og, source_url)
    local author = html_escape(embed.author or (fallback_og and fallback_og["og:title"]) or "Facebook post")
    local author_url = embed.author_url or ""
    local when = html_escape(format_timestamp(embed.timestamp))
    local permalink = embed.permalink or source_url
    local message = clean_message_html(embed.message_html)
    if not message or message == "" then
        local desc = fallback_og and fallback_og["og:description"]
        if desc and desc ~= "" then
            message = "<p>" .. html_escape(desc) .. "</p>"
        end
    end
    local image_url = embed.image_url
        or (fallback_og and fallback_og["og:image"])

    local buf = {}
    buf[#buf + 1] = '<!DOCTYPE html>\n<html><head><meta charset="utf-8">\n'
    buf[#buf + 1] = '<title>' .. author .. ' on Facebook</title>\n'
    buf[#buf + 1] = [[<style>
body { font-family: serif; max-width: 42em; margin: 0 auto; padding: 0 1em; }
.fb-header { margin-bottom: 0.5em; }
.fb-author { font-size: 1.1em; }
.fb-time { font-size: 0.85em; color: #666; }
.fb-image { margin: 0.6em 0; }
.fb-image img { max-width: 100%; display: block; }
.fb-body { font-size: 1.05em; line-height: 1.5; }
.fb-body p { margin: 0.5em 0; }
.fb-note { margin-top: 1.5em; padding: 0.6em 0.8em; background: #f4f4f4;
    border-left: 3px solid #888; font-size: 0.9em; }
</style>
</head><body>
]]

    buf[#buf + 1] = '<div class="fb-header">\n'
    if author_url ~= "" then
        buf[#buf + 1] = '<div class="fb-author"><b><a href="'
            .. html_escape(author_url) .. '">' .. author .. '</a></b></div>\n'
    else
        buf[#buf + 1] = '<div class="fb-author"><b>' .. author .. '</b></div>\n'
    end
    if when ~= "" then
        buf[#buf + 1] = '<div class="fb-time">' .. when .. '</div>\n'
    end
    buf[#buf + 1] = '</div>\n'

    if image_url and image_url ~= "" then
        buf[#buf + 1] = '<div class="fb-image"><img src="'
            .. html_escape(image_url) .. '" alt=""></div>\n'
    end

    buf[#buf + 1] = '<div class="fb-body">\n' .. (message or "") .. '\n</div>\n'

    buf[#buf + 1] = '<div class="fb-note"><b>Comments are not available.</b> '
        .. 'Facebook requires authentication to fetch the comment thread of a '
        .. 'public post, and there is no reliable public mirror at the moment. '
        .. 'Open <a href="' .. html_escape(permalink) .. '">'
        .. html_escape(permalink) .. '</a> in a browser to read them.</div>\n'

    buf[#buf + 1] = string.format(
        '<hr><p style="font-size:0.8em; color:#666">Source: <a href="%s">%s</a></p>\n',
        html_escape(source_url), html_escape(source_url))
    buf[#buf + 1] = '</body></html>\n'

    return table.concat(buf)
end

-- Pure Open Graph fallback (when the embed endpoint itself cannot be used).
local function build_html_from_og(og, source_url)
    if not og then return nil end
    local title = og["og:title"] or "Facebook post"
    local description = og["og:description"] or ""
    local image = og["og:image"]

    if description == "" and not image then
        return nil
    end

    local buf = {}
    buf[#buf + 1] = '<!DOCTYPE html>\n<html><head><meta charset="utf-8">\n'
    buf[#buf + 1] = '<title>' .. html_escape(title) .. ' on Facebook</title>\n'
    buf[#buf + 1] = [[<style>
body { font-family: serif; max-width: 42em; margin: 0 auto; padding: 0 1em; }
.fb-body { font-size: 1.05em; line-height: 1.5; }
.fb-note { margin-top: 1.5em; padding: 0.6em 0.8em; background: #f4f4f4;
    border-left: 3px solid #888; font-size: 0.9em; }
img { max-width: 100%; display: block; margin: 0.6em 0; }
</style>
</head><body>
]]
    buf[#buf + 1] = '<h1>' .. html_escape(title) .. '</h1>\n'
    if image then
        buf[#buf + 1] = '<img src="' .. html_escape(image) .. '" alt="">\n'
    end
    buf[#buf + 1] = '<div class="fb-body"><p>'
        .. html_escape(description) .. '</p></div>\n'
    buf[#buf + 1] = '<div class="fb-note"><b>Limited preview.</b> Facebook did '
        .. 'not return a full embed for this post, so only the preview snippet '
        .. 'from its Open Graph metadata is shown. Open <a href="'
        .. html_escape(source_url) .. '">' .. html_escape(source_url)
        .. '</a> in a browser for the full post.</div>\n'
    buf[#buf + 1] = '</body></html>\n'
    return table.concat(buf)
end

return {
    hosts = {
        "facebook.com",
        "fb.com",
    },

    transform = function(ctx)
        local parsed = urlmod.parse(ctx.url or "")
        local canonical = canonical_post_url(parsed)
        if not canonical then
            return nil
        end

        -- Hit the embed endpoint (works unauthenticated for public posts).
        local embed_url = "https://www.facebook.com/plugins/post.php?href="
            .. urlmod.escape(canonical) .. "&show_text=true"

        local ok, embed_body = http.get(embed_url, {
            ["User-Agent"] = USER_AGENT,
            ["Accept-Language"] = "en,en-US;q=0.9",
        })

        local embed_info
        if ok and type(embed_body) == "string" and embed_body ~= "" then
            embed_info = parse_embed(embed_body)
        else
            logger.warn("facebook_com adapter", "embed fetch failed", embed_body)
        end

        -- The original page's OG tags are a useful fallback for bits the
        -- embed might miss.
        local og_tags = parse_og_tags(ctx.body or "")

        if embed_info and (embed_info.message_html or embed_info.author) then
            return build_html_from_embed(embed_info, og_tags, ctx.url)
        end

        -- Embed failed or had nothing useful: render the OG preview.
        local preview = build_html_from_og(og_tags, ctx.url)
        if preview then
            logger.info("facebook_com adapter", "using OG fallback for", ctx.url)
            return preview
        end

        return nil
    end,
}
