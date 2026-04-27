-- Adapter for reddit.com comment pages.
--
-- The new Reddit web UI is a React application: the static HTML returned by
-- the server contains no comments (and barely any post body either). Reddit
-- exposes a public JSON endpoint for every comment thread, however, by simply
-- appending `.json` to the URL:
--
--   https://www.reddit.com/r/<sub>/comments/<id>/<slug>/.json?raw_json=1
--
-- The response is a two-element array of Listings: the first holds the post
-- (kind "t3"), the second the comment forest (kind "t1", possibly nested via
-- the `replies` field, with stubs of kind "more" when Reddit collapses long
-- branches).
--
-- This adapter fetches that JSON, builds a clean HTML document containing
-- title + post body + nested comments, and replaces the original body so
-- KOReader's CRE/MuPDF reader can display the discussion.
--
-- The adapter only fires on actual comment pages; subreddit listings, user
-- profiles and the front page are left untouched.

local rapidjson = require("rapidjson")
local logger = require("logger")
local urlmod = require("socket.url")
local http = require("webbrowser_site_adapters._http")

local USER_AGENT = "Mozilla/5.0 (KOReader webbrowser plugin)"

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

-- Detect URLs that look like /r/<sub>/comments/<id>[/...]. Returns the
-- canonical comment path (e.g. "/r/koreader/comments/1sx4kt2/foo") or nil.
local function comment_path(parsed_url)
    if not parsed_url or not parsed_url.path then
        return nil
    end
    local path = parsed_url.path
    local sub, post_id = path:match("^/r/([^/]+)/comments/([^/]+)")
    if not sub or not post_id then
        return nil
    end
    -- Drop any trailing slug, but keep the canonical "/r/<sub>/comments/<id>"
    -- prefix that Reddit's JSON endpoint expects.
    local slug = path:match("^/r/[^/]+/comments/[^/]+/([^/]+)")
    local canonical = "/r/" .. sub .. "/comments/" .. post_id
    if slug and slug ~= "" then
        canonical = canonical .. "/" .. slug
    end
    return canonical
end

local function format_score(score)
    if type(score) ~= "number" then return "?" end
    return tostring(math.floor(score))
end

local function format_timestamp(unix)
    if type(unix) ~= "number" or unix <= 0 then return "" end
    return os.date("!%Y-%m-%d %H:%M UTC", unix)
end

local function append(buf, s)
    buf[#buf + 1] = s
end

local function render_comment(buf, child, depth)
    if type(child) ~= "table" or type(child.data) ~= "table" then
        return
    end
    local kind = child.kind
    local data = child.data

    if kind == "more" then
        local count = type(data.count) == "number" and data.count or 0
        if count > 0 then
            append(buf, string.format(
                '<div class="rd-more" style="margin-left:%dem">'
                    .. '<em>(%d more repl%s collapsed by Reddit)</em></div>\n',
                depth, count, count == 1 and "y" or "ies"))
        end
        return
    end

    if kind ~= "t1" then return end

    local author = html_escape(data.author or "[deleted]")
    local score = format_score(data.score)
    local when = html_escape(format_timestamp(data.created_utc))
    local body_html = data.body_html or ""

    append(buf, string.format(
        '<div class="rd-comment" style="margin-left:%dem; '
            .. 'border-left:2px solid #999; padding-left:0.6em; margin-top:0.6em">\n',
        depth))
    append(buf, string.format(
        '<div class="rd-meta" style="font-size:0.85em; color:#666">'
            .. '<b>%s</b> &middot; %s point%s &middot; %s</div>\n',
        author, score, score == "1" and "" or "s", when))
    append(buf, body_html)
    append(buf, "\n")

    -- Recurse into replies (which may be the empty string when there are none)
    local replies = data.replies
    if type(replies) == "table"
        and type(replies.data) == "table"
        and type(replies.data.children) == "table" then
        for _, reply in ipairs(replies.data.children) do
            render_comment(buf, reply, depth + 1)
        end
    end

    append(buf, "</div>\n")
end

local function build_html(post, comments, source_url)
    local title = html_escape(post.title or "Reddit thread")
    local subreddit = html_escape(post.subreddit_name_prefixed or post.subreddit or "")
    local author = html_escape(post.author or "[deleted]")
    local score = format_score(post.score)
    local when = html_escape(format_timestamp(post.created_utc))
    local body_html = post.selftext_html or ""

    local link_url
    if type(post.url) == "string" and post.url ~= "" then
        link_url = post.url
        -- Skip the self-link that points back to the same post
        if link_url:find("reddit.com", 1, true)
            and link_url:find("/comments/", 1, true) then
            link_url = nil
        end
    end

    local buf = {}
    append(buf, "<!DOCTYPE html>\n<html><head><meta charset=\"utf-8\">\n")
    append(buf, "<title>" .. title .. "</title>\n")
    append(buf, [[<style>
body { font-family: serif; max-width: 48em; margin: 0 auto; padding: 0 1em; }
h1 { font-size: 1.4em; margin-bottom: 0.2em; }
.rd-header { font-size: 0.9em; color: #444; margin-bottom: 1em; }
.rd-post { margin-bottom: 1.5em; padding-bottom: 0.5em; border-bottom: 1px solid #aaa; }
.rd-comments-title { font-size: 1.1em; margin-top: 1em; }
.rd-meta { margin-top: 0.4em; }
blockquote { border-left: 3px solid #bbb; padding-left: 0.6em; color: #555; }
pre, code { font-family: monospace; }
</style>
</head><body>
]])

    append(buf, '<div class="rd-post">\n')
    append(buf, "<h1>" .. title .. "</h1>\n")
    append(buf, '<div class="rd-header">')
    if subreddit ~= "" then
        append(buf, subreddit .. " &middot; ")
    end
    append(buf, "posted by <b>" .. author .. "</b>")
    if when ~= "" then append(buf, " on " .. when) end
    append(buf, " &middot; " .. score .. " points")
    append(buf, "</div>\n")

    if link_url then
        append(buf, '<p><a href="' .. html_escape(link_url) .. '">'
            .. html_escape(link_url) .. "</a></p>\n")
    end

    if body_html ~= "" then
        append(buf, body_html)
        append(buf, "\n")
    end

    append(buf, "</div>\n")

    append(buf, '<div class="rd-comments-title"><b>Comments ('
        .. tostring(#comments) .. ' top-level)</b></div>\n')

    if #comments == 0 then
        append(buf, "<p><em>No comments yet.</em></p>\n")
    else
        for _, child in ipairs(comments) do
            render_comment(buf, child, 0)
        end
    end

    append(buf, '<hr><p style="font-size:0.8em; color:#666">Source: <a href="'
        .. html_escape(source_url) .. '">' .. html_escape(source_url)
        .. "</a></p>\n")
    append(buf, "</body></html>\n")

    return table.concat(buf)
end

return {
    hosts = {
        "reddit.com",
    },

    -- Only fire on actual comment threads (any reddit subdomain).
    match = function(url, parsed_url)
        if not parsed_url or not parsed_url.host then return false end
        local host = parsed_url.host:lower()
        if not (host == "reddit.com"
            or host:sub(-#".reddit.com") == ".reddit.com") then
            return false
        end
        return comment_path(parsed_url) ~= nil
    end,

    transform = function(ctx)
        local parsed = urlmod.parse(ctx.url or "")
        local canonical = comment_path(parsed)
        if not canonical then
            return nil
        end

        -- Always hit www.reddit.com to dodge the (occasionally redirected)
        -- old.reddit.com / new.reddit.com flavours.
        local json_url = "https://www.reddit.com" .. canonical
            .. ".json?raw_json=1&limit=500"

        local ok, body = http.get(json_url, {
            ["User-Agent"] = USER_AGENT,
            Accept = "application/json",
        })
        if not ok or type(body) ~= "string" or body == "" then
            logger.warn("reddit_com adapter", "fetch failed", body)
            return nil
        end

        local decoded, err = rapidjson.decode(body)
        if type(decoded) ~= "table" or #decoded < 2 then
            logger.warn("reddit_com adapter", "invalid JSON response", err)
            return nil
        end

        local post_listing = decoded[1]
        local comment_listing = decoded[2]
        if type(post_listing) ~= "table"
            or type(post_listing.data) ~= "table"
            or type(post_listing.data.children) ~= "table"
            or type(post_listing.data.children[1]) ~= "table"
            or type(post_listing.data.children[1].data) ~= "table" then
            logger.warn("reddit_com adapter", "unexpected post listing shape")
            return nil
        end
        local post = post_listing.data.children[1].data
        local comments = (type(comment_listing) == "table"
            and type(comment_listing.data) == "table"
            and type(comment_listing.data.children) == "table")
            and comment_listing.data.children
            or {}

        return build_html(post, comments, ctx.url)
    end,
}
