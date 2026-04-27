-- Adapter for X / Twitter status pages.
--
-- The X.com and twitter.com web UIs are React applications that ship a near
-- empty document and load tweet data through authenticated GraphQL calls; the
-- official public API was retired and unauthenticated reply scraping (Nitter
-- and friends) has been broken since Twitter blocked guest accounts in 2024.
--
-- For the tweet itself we use the community-maintained `api.fxtwitter.com`
-- (and `api.vxtwitter.com` as a fallback) JSON proxy: it returns the tweet
-- text, author, timestamps, media URLs, engagement counts, the parent tweet
-- (when the URL is a reply) and the quoted tweet (when applicable). No auth
-- is required.
--
-- Reply / comment trees are *not* exposed by these proxies and there is no
-- reliable unauthenticated source for them at the moment, so the adapter
-- shows the reply count and a hint at the bottom of the page instead of
-- silently pretending replies do not exist. If you want to read replies you
-- still need to open the URL in a real browser.

local rapidjson = require("rapidjson")
local logger = require("logger")
local urlmod = require("socket.url")
local http = require("webbrowser_site_adapters._http")

local USER_AGENT = "Mozilla/5.0 (KOReader webbrowser plugin)"

-- Public JSON proxies that mirror the X tweet data. Tried in order; first
-- successful response wins. Both expose the same general shape (`tweet` key
-- on fxtwitter, flat shape on vxtwitter) but we only rely on the fxtwitter
-- shape here and treat vxtwitter purely as a backup whose response is
-- normalised to the same structure.
local FXTWITTER_HOSTS = {
    "api.fxtwitter.com",
}

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

-- Convert plain-text URLs in `text` into <a> tags. The text is escaped first.
local function linkify(text)
    if not text or text == "" then return "" end
    local escaped = html_escape(text)
    -- Lua patterns can't express "https?://[non-space]+" as concisely as
    -- regex, but the following matches what we need: scheme + non-whitespace.
    return (escaped:gsub("(https?://[^%s<>\"']+)", function(url)
        -- Trim trailing punctuation that is unlikely to be part of a URL.
        local trailing = ""
        while #url > 0 and url:sub(-1):match("[%.%,%;%:%)%]%!%?]") do
            trailing = url:sub(-1) .. trailing
            url = url:sub(1, -2)
        end
        return string.format('<a href="%s">%s</a>%s', url, url, trailing)
    end))
end

local function format_timestamp(unix)
    if type(unix) ~= "number" or unix <= 0 then return "" end
    return os.date("!%Y-%m-%d %H:%M UTC", unix)
end

local function format_count(n)
    if type(n) ~= "number" then return "?" end
    if n >= 1000000 then
        return string.format("%.1fM", n / 1000000)
    elseif n >= 1000 then
        return string.format("%.1fK", n / 1000)
    end
    return tostring(math.floor(n))
end

-- Recognise X / Twitter status URLs and extract { user, id }. Returns nil if
-- the URL does not look like an individual status page.
local function parse_status(parsed_url)
    if not parsed_url or not parsed_url.host or not parsed_url.path then
        return nil
    end
    local host = parsed_url.host:lower()
    if not (host == "x.com" or host == "twitter.com"
        or host:sub(-#".x.com") == ".x.com"
        or host:sub(-#".twitter.com") == ".twitter.com") then
        return nil
    end

    local path = parsed_url.path
    -- /<user>/status/<id> (most common)
    local user, id = path:match("^/([%w_]+)/status/(%d+)")
    if user and id then
        return { user = user, id = id }
    end
    -- /i/web/status/<id> (legacy share links without a known username)
    id = path:match("^/i/web/status/(%d+)") or path:match("^/i/status/(%d+)")
    if id then
        return { user = "i", id = id }
    end
    return nil
end

local function fetch_tweet(user, id)
    for _, mirror in ipairs(FXTWITTER_HOSTS) do
        local api_url = string.format("https://%s/%s/status/%s", mirror, user, id)
        local ok, body = http.get(api_url, {
            ["User-Agent"] = USER_AGENT,
            Accept = "application/json",
        })
        if ok and type(body) == "string" and body ~= "" then
            local decoded = rapidjson.decode(body)
            if type(decoded) == "table"
                and type(decoded.tweet) == "table"
                and type(decoded.tweet.text) == "string" then
                return decoded.tweet, mirror
            end
            logger.warn("twitter_com adapter", "unexpected response from", mirror)
        else
            logger.warn("twitter_com adapter", "fetch failed from", mirror, body)
        end
    end
    return nil
end

local function append(buf, s)
    buf[#buf + 1] = s
end

local function render_media(buf, media)
    if type(media) ~= "table" then return end
    local items = media.all
    if type(items) ~= "table" or #items == 0 then return end

    append(buf, '<div class="tw-media" style="margin:0.6em 0">\n')
    for _, m in ipairs(items) do
        if type(m) == "table" and type(m.url) == "string" then
            local alt = html_escape(m.altText or m.alt_text or "")
            if m.type == "photo" then
                append(buf, string.format(
                    '<div><img src="%s" alt="%s" style="max-width:100%%; margin:0.3em 0"></div>\n',
                    html_escape(m.url), alt))
            elseif m.type == "video" or m.type == "gif" then
                local thumb = m.thumbnail_url
                if type(thumb) == "string" and thumb ~= "" then
                    append(buf, string.format(
                        '<div><a href="%s"><img src="%s" alt="%s video thumbnail" style="max-width:100%%"></a><br>'
                            .. '<small>(%s &mdash; <a href="%s">open</a>)</small></div>\n',
                        html_escape(m.url), html_escape(thumb), m.type, m.type, html_escape(m.url)))
                else
                    append(buf, string.format(
                        '<div>(%s) <a href="%s">%s</a></div>\n',
                        m.type, html_escape(m.url), html_escape(m.url)))
                end
            end
        end
    end
    append(buf, '</div>\n')
end

-- Render a tweet (or quoted/parent context) as an HTML block. `class_name`
-- controls outer styling.
local function render_tweet_block(buf, tweet, class_name, label)
    if type(tweet) ~= "table" then return end
    local author = type(tweet.author) == "table" and tweet.author or {}
    local screen = html_escape(author.screen_name or "")
    local name = html_escape(author.name or screen)
    local when = html_escape(format_timestamp(tweet.created_timestamp))

    append(buf, string.format('<div class="%s">\n', class_name))
    if label then
        append(buf, string.format('<div class="tw-label">%s</div>\n', html_escape(label)))
    end
    append(buf, string.format(
        '<div class="tw-author"><b>%s</b> <span class="tw-handle">@%s</span>',
        name, screen))
    if when ~= "" then
        append(buf, string.format(' &middot; <span class="tw-time">%s</span>', when))
    end
    append(buf, '</div>\n')
    append(buf, '<div class="tw-text">' .. linkify(tweet.text or "") .. '</div>\n')
    render_media(buf, tweet.media)
    append(buf, '</div>\n')
end

local function build_html(tweet, source_url, mirror)
    local author = type(tweet.author) == "table" and tweet.author or {}
    local title = string.format("%s (@%s) on X",
        author.name or author.screen_name or "?",
        author.screen_name or "?")

    local buf = {}
    append(buf, '<!DOCTYPE html>\n<html><head><meta charset="utf-8">\n')
    append(buf, '<title>' .. html_escape(title) .. '</title>\n')
    append(buf, [[<style>
body { font-family: serif; max-width: 42em; margin: 0 auto; padding: 0 1em; }
h1 { font-size: 1.2em; margin-bottom: 0.4em; }
.tw-label { font-size: 0.8em; color: #666; margin-bottom: 0.2em; }
.tw-author { font-size: 0.95em; }
.tw-handle, .tw-time { color: #666; }
.tw-text { margin: 0.5em 0; font-size: 1.05em; line-height: 1.45; white-space: pre-wrap; }
.tw-stats { font-size: 0.85em; color: #555; margin-top: 0.5em; }
.tw-context, .tw-quote {
    border-left: 3px solid #bbb; padding: 0.3em 0.7em;
    margin: 0.5em 0; color: #444; font-size: 0.95em;
}
.tw-main { margin: 0.6em 0 1em; }
.tw-note { margin-top: 1.5em; padding: 0.6em 0.8em; background: #f4f4f4;
    border-left: 3px solid #888; font-size: 0.9em; }
img { display: block; }
</style>
</head><body>
]])

    -- Parent tweet context, if this status is a reply
    if type(tweet.replying_to_status) == "table" then
        render_tweet_block(buf, tweet.replying_to_status, "tw-context",
            "In reply to @" .. (tweet.replying_to or
                (tweet.replying_to_status.author or {}).screen_name or ""))
    end

    -- Main tweet
    render_tweet_block(buf, tweet, "tw-main", nil)

    -- Quoted tweet, if any
    if type(tweet.quote) == "table" then
        render_tweet_block(buf, tweet.quote, "tw-quote", "Quoting:")
    end

    -- Engagement stats
    append(buf, '<div class="tw-stats">')
    append(buf, string.format(
        '%s repl%s &middot; %s repost%s &middot; %s like%s',
        format_count(tweet.replies), tweet.replies == 1 and "y" or "ies",
        format_count(tweet.retweets), tweet.retweets == 1 and "" or "s",
        format_count(tweet.likes), tweet.likes == 1 and "" or "s"))
    if type(tweet.views) == "number" then
        append(buf, " &middot; " .. format_count(tweet.views) .. " views")
    end
    append(buf, '</div>\n')

    -- Honest disclaimer about replies
    local reply_count = tonumber(tweet.replies) or 0
    if reply_count > 0 then
        append(buf, string.format(
            '<div class="tw-note"><b>Comments are not available.</b> '
                .. 'X requires authenticated requests to fetch the %s '
                .. 'repl%s and there is no reliable public mirror at the '
                .. 'moment. Open <a href="%s">%s</a> in a browser to read '
                .. 'them.</div>\n',
            format_count(reply_count),
            reply_count == 1 and "y" or "ies",
            html_escape(source_url),
            html_escape(source_url)))
    end

    append(buf, string.format(
        '<hr><p style="font-size:0.8em; color:#666">Source: '
            .. '<a href="%s">%s</a> &middot; via %s</p>\n',
        html_escape(source_url), html_escape(source_url), html_escape(mirror)))
    append(buf, '</body></html>\n')

    return table.concat(buf)
end

return {
    hosts = {
        "twitter.com",
        "x.com",
    },

    -- The host list above already pulls in every twitter.com / x.com URL,
    -- so non-status pages (profiles, search, the home feed, ...) reach this
    -- adapter too. We bail out early in `transform` for anything that is not
    -- a single status page so those pages render through the normal path.

    transform = function(ctx)
        local parsed = urlmod.parse(ctx.url or "")
        local status = parse_status(parsed)
        if not status then return nil end

        local tweet, mirror = fetch_tweet(status.user, status.id)
        if not tweet then
            logger.warn("twitter_com adapter", "no tweet returned for", ctx.url)
            return nil
        end

        return build_html(tweet, ctx.url, mirror or "fxtwitter")
    end,
}
