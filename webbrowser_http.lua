-- HTTP client that picks its transport from the URL scheme.
--
-- socket.http speaks plaintext only; handed an https:// URL it puts the
-- absolute URI in the request line and talks cleartext, which a proxy answers
-- on port 80. ssl.https does TLS but refuses to proxy at all: "proxy not
-- supported" while socket.http.PROXY is set, "create function not permitted"
-- for a caller-supplied connector. So proxied https drives socket.http with a
-- connector that opens a CONNECT tunnel and wraps it in TLS. See
-- koreader/koreader#14693.

local socket = require("socket")
local socket_http = require("socket.http")
local socket_url = require("socket.url")
local mime = require("mime")
local ssl = require("ssl")
local https = require("ssl.https")
local logger = require("logger")

local WebBrowserHttp = {}

-- Mirrors ssl.https' defaults, so tunnelled requests behave like direct ones.
local SSL_PARAMS = {
    mode = "client",
    protocol = "any",
    options = { "all", "no_sslv2", "no_sslv3", "no_tlsv1" },
    verify = "none",
}

local DEFAULT_PROXY_PORT = 3128
local HANDSHAKE_TIMEOUT = 60

-- NetworkMgr:setHTTPProxy() writes the whole configuration, credentials
-- included, into socket.http.PROXY, and clears it when the setting is off.
local function getProxy(reqt)
    local proxy = (type(reqt) == "table" and reqt.proxy) or socket_http.PROXY
    if type(proxy) ~= "string" or proxy == "" then
        return nil
    end
    local parsed = socket_url.parse(proxy, { scheme = "http" })
    if not parsed or not parsed.host then
        logger.warn("webbrowser: ignoring unparseable proxy", proxy)
        return nil
    end
    return parsed.host, tonumber(parsed.port) or DEFAULT_PROXY_PORT,
        parsed.user, parsed.password
end

-- Raw, still percent-encoded userinfo is used on purpose: byte for byte what
-- socket.http sends on the plaintext path, so one proxy URL serves both.
local function proxyAuthorization(user, password)
    if not user or not password then
        return ""
    end
    return "Proxy-Authorization: Basic " .. mime.b64(user .. ":" .. password) .. "\r\n"
end

-- As LuaSec does after wrapping: expose the TLS socket's methods on the
-- connection object socket.http drives.
local function registerSocketMethods(conn)
    local index = getmetatable(conn.sock).__index
    if type(index) ~= "table" then
        return
    end
    for name, method in pairs(index) do
        if type(method) == "function" and conn[name] == nil then
            conn[name] = function(_, ...)
                return method(conn.sock, ...)
            end
        end
    end
end

local function readConnectResponse(sock)
    local line, err = sock:receive("*l")
    if not line then
        return nil, err or "no response to CONNECT"
    end
    local status = tonumber(line:match("^HTTP/%d%.%d%s+(%d%d%d)"))
    if status ~= 200 then
        return nil, "proxy refused CONNECT: " .. line
    end
    -- The tunnel starts at the blank line.
    repeat
        local header
        header, err = sock:receive("*l")
        if not header then
            return nil, err or "proxy closed during CONNECT"
        end
    until header == ""
    return true
end

-- Connect to the proxy, ask it to tunnel, handshake inside the tunnel.
local function proxyTunnelFactory(proxy_host, proxy_port, proxy_user, proxy_password)
    local authorization = proxyAuthorization(proxy_user, proxy_password)
    return function()
        local conn = { timeout = HANDSHAKE_TIMEOUT }
        local sock, err = socket.tcp()
        if not sock then
            return nil, err
        end
        conn.sock = sock

        function conn:settimeout(value, mode)
            self.timeout = value or self.timeout
            return self.sock:settimeout(value, mode)
        end

        function conn:connect(host, port)
            local ok, cerr = self.sock:connect(proxy_host, proxy_port)
            if not ok then
                return nil, cerr
            end

            local request = string.format(
                "CONNECT %s:%d HTTP/1.1\r\nHost: %s:%d\r\n%s\r\n",
                host, port, host, port, authorization)
            local sent, serr = self.sock:send(request)
            if not sent then
                return nil, serr
            end

            local tunnelled, terr = readConnectResponse(self.sock)
            if not tunnelled then
                return nil, terr
            end

            local wrapped, werr = ssl.wrap(self.sock, SSL_PARAMS)
            if not wrapped then
                return nil, werr
            end
            self.sock = wrapped
            self.sock:settimeout(self.timeout)
            self.sock:sni(host)

            local shook, herr = self.sock:dohandshake()
            if not shook then
                return nil, herr
            end

            registerSocketMethods(self)
            return 1
        end

        return conn
    end
end

-- Signature and return values match socket.http.request.
function WebBrowserHttp.request(reqt, body)
    local url = type(reqt) == "table" and reqt.url or reqt
    if type(url) ~= "string" then
        return nil, "invalid url"
    end

    local parsed = socket_url.parse(url)
    if not parsed or parsed.scheme ~= "https" then
        return socket_http.request(reqt, body)
    end

    -- A string request leaves nowhere to hang the socket factory.
    if type(reqt) ~= "table" then
        reqt = { url = url }
    end

    local proxy_host, proxy_port, proxy_user, proxy_password = getProxy(reqt)

    -- The tunnel replaces the proxy for this request, and a visible PROXY would
    -- have socket.http dial it directly and send an absolute-form URI.
    reqt.proxy = nil
    local saved_proxy = socket_http.PROXY
    socket_http.PROXY = nil

    local transport = https
    if proxy_host then
        if not reqt.create then
            reqt.create = proxyTunnelFactory(proxy_host, proxy_port, proxy_user, proxy_password)
        end
        -- socket.http knows nothing about https and would default to port 80.
        if not parsed.port then
            reqt.port = 443
        end
        transport = socket_http
    end

    local ok, a, b, c, d = pcall(transport.request, reqt, body)
    socket_http.PROXY = saved_proxy
    if not ok then
        error(a, 0)
    end
    return a, b, c, d
end

return WebBrowserHttp
