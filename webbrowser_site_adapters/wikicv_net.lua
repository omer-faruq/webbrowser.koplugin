-- Adapter for wikicv.net (and the related dichtienghoa.com network).
--
-- Chapter pages such as
--   https://wikicv.net/truyen/<book>/<part>-<id>
-- ship only a short preview in the static HTML. The real chapter body is
-- loaded by an in-page JavaScript call:
--
--   loadChapterContent = function() {
--       $.ajax({
--           type: "POST",
--           url:  "/chapters/content",
--           data: {
--               id: chapterId,
--               type: transType,
--               editName: editName,
--               signKey: signKey,
--               sign: signFunc(fuzzySign(signKey + transType + editName)),
--           },
--           success: function (f) { $(".content-body-wrapper").html(f); }
--       });
--   };
--
-- `signFunc` is a SHA-256 implementation. `fuzzySign(s)` is a per-page
-- left-rotation by N characters:
--
--   function fuzzySign(text) {
--       return text.substring(N) + text.substring(0, N);
--   }
--
-- N is randomised per page-load (observed values: 0, 1, 2, 3, ...). The
-- adapter parses N out of the inline script and applies the rotation before
-- hashing.
--
-- This adapter mirrors the JavaScript behaviour: it pulls the variables out
-- of the static HTML, replays the POST and substitutes the existing
-- `<div id="bookContentBody">` block with the response.

local sha2 = require("ffi/sha2")
local logger = require("logger")
local urlmod = require("socket.url")
local http = require("webbrowser_site_adapters._http")

local function extract_string_var(html, name)
    -- Matches:  var <name> = "value";
    return html:match('var%s+' .. name .. '%s*=%s*"([^"]*)"%s*;')
end

local function extract_bool_var(html, name)
    -- Matches:  var <name> = true;  or  var <name> = false;
    return html:match('var%s+' .. name .. '%s*=%s*([%w]+)%s*;')
end

-- Parse the rotation amount N from the per-page fuzzySign() definition. The
-- function body is consistently of the form:
--   return text.substring(N) + text.substring(0, N);
-- Returns the integer N (0 if it could not be parsed and the body is the
-- expected shape; nil if the body has an unknown form so callers can bail).
local function extract_fuzzy_rotation(html)
    local body = html:match("function%s+fuzzySign%s*%([^)]*%)%s*{(.-)}")
    if not body then
        return nil
    end
    local n_str, m_str = body:match("text%.substring%s*%(%s*(%d+)%s*%)%s*%+%s*text%.substring%s*%(%s*0%s*,%s*(%d+)%s*%)")
    if not n_str or not m_str or n_str ~= m_str then
        return nil
    end
    return tonumber(n_str)
end

local function rotate_left(s, n)
    if not n or n <= 0 or n >= #s then
        return s
    end
    return s:sub(n + 1) .. s:sub(1, n)
end

local function origin_for(url)
    local parsed = urlmod.parse(url or "")
    local scheme = parsed and parsed.scheme or "https"
    local host = parsed and parsed.host or "wikicv.net"
    local origin = scheme .. "://" .. host
    if parsed and parsed.port and parsed.port ~= "" then
        origin = origin .. ":" .. parsed.port
    end
    return origin
end

return {
    hosts = {
        "wikicv.net",
    },

    transform = function(ctx)
        local html = ctx.body
        if type(html) ~= "string" or html == "" then
            return nil
        end

        -- Only act on chapter pages; landing / book-list pages do not call
        -- loadChapterContent and have all their content inline already.
        if not html:find("loadChapterContent", 1, true) then
            return nil
        end

        local sign_key   = extract_string_var(html, "signKey")
        local chapter_id = extract_string_var(html, "chapterId")
        local trans_type = extract_string_var(html, "transType")
        if not sign_key or sign_key == ""
            or not chapter_id or chapter_id == ""
            or not trans_type or trans_type == "" then
            logger.warn("wikicv_net adapter", "missing chapter variables")
            return nil
        end

        local edit_name_raw = extract_bool_var(html, "editName")
        local edit_name = (edit_name_raw == "true") and "true" or "false"

        local rotation = extract_fuzzy_rotation(html)
        if rotation == nil then
            logger.warn("wikicv_net adapter", "unrecognised fuzzySign form, skipping")
            return nil
        end

        local fuzzed = rotate_left(sign_key .. trans_type .. edit_name, rotation)
        local sign = sha2.sha256(fuzzed)

        local endpoint = origin_for(ctx.url) .. "/chapters/content"
        local ok, fetched = http.post(
            endpoint,
            {
                id       = chapter_id,
                type     = trans_type,
                editName = edit_name,
                signKey  = sign_key,
                sign     = sign,
            },
            {
                Referer            = ctx.url,
                Origin             = origin_for(ctx.url),
                ["X-Requested-With"] = "XMLHttpRequest",
                Accept             = "*/*",
            }
        )

        if not ok or type(fetched) ~= "string" or fetched == "" then
            logger.warn("wikicv_net adapter", "fetch failed", fetched)
            return nil
        end

        -- Replace the existing <div id="bookContentBody" ...>...</div> block
        -- with the freshly fetched content. The chapter body contains only
        -- <p> tags (no nested <div>s), so a non-greedy search is safe. We
        -- splice manually instead of using gsub to avoid any pattern-style
        -- interpretation of characters inside the fetched payload.
        local open_start, open_end = html:find('<div id="bookContentBody"[^>]*>')
        if not open_start then
            logger.warn("wikicv_net adapter", "could not find bookContentBody placeholder")
            return nil
        end
        local close_start, close_end = html:find("</div>", open_end + 1, true)
        if not close_start then
            logger.warn("wikicv_net adapter", "unbalanced bookContentBody placeholder")
            return nil
        end
        return html:sub(1, open_start - 1) .. fetched .. html:sub(close_end + 1)
    end,
}
