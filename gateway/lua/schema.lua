-- Validates the configuration contract without reading files or changing state.
local M = {}

local function object(value)
    if type(value) ~= "table" then return false end
    for key in pairs(value) do
        if type(key) ~= "string" then return false end
    end
    return true
end

local function identifier(value)
    return type(value) == "string" and value:match("^[%w_.%-]+$") ~= nil
end

local function token(value)
    return type(value) == "string" and value ~= "" and not value:find("[%s%c]")
end

local function path(value)
    return token(value) and value:sub(1, 1) == "/" and not value:find("[?#]")
end

local function only_keys(value, allowed)
    if not object(value) then return false end
    for key in pairs(value) do
        if not allowed[key] then return false end
    end
    return true
end

local function origin(value)
    if not token(value) then return false end
    local authority = value:match("^https?://(.+)$")
    if not authority then return false end
    local host, port = authority:match("^([%w.%-]+):(%d+)$")
    if port then
        if tonumber(port) < 1 or tonumber(port) > 65535 then return false end
    else
        host = authority:match("^([%w.%-]+)$")
    end
    return host ~= nil
end

local ROUTE_KEYS = {
    id = true, match = true, upstream = true, strip_prefix = true,
    replace_path = true, client_auth = true, credential = true, headers = true,
}
local RESERVED_HEADERS = {
    authorization = true, ["x-api-key"] = true, ["proxy-authorization"] = true,
    cookie = true, host = true, connection = true, ["content-length"] = true,
    ["transfer-encoding"] = true, upgrade = true, trailer = true, te = true,
}

local function valid_route(route)
    if not only_keys(route, ROUTE_KEYS) or not identifier(route.id) or not origin(route.upstream) then
        return false
    end

    local match = route.match
    if not only_keys(match, { exact = true, prefix = true, regex = true }) then return false end
    local count = 0
    for kind, value in pairs(match) do
        count = count + 1
        if kind == "regex" then
            if type(value) ~= "string" or value == "" then return false end
            local _, _, err = ngx.re.find("", value, "jo")
            if err then return false end
        elseif not path(value) then
            return false
        end
    end
    if count ~= 1 then return false end

    if route.strip_prefix ~= nil then
        if not path(route.strip_prefix) or not match.prefix then return false end
        if match.prefix ~= route.strip_prefix and match.prefix ~= route.strip_prefix .. "/" then
            return false
        end
    end
    if route.replace_path ~= nil then
        if not path(route.replace_path) or not match.exact or route.strip_prefix then return false end
    end

    if route.client_auth ~= nil and
        (not only_keys(route.client_auth, { challenge = true }) or route.client_auth.challenge ~= "basic") then
        return false
    end

    local credential = route.credential
    if not only_keys(credential, { source = true, type = true, username = true })
        or not identifier(credential.source) then return false end
    if credential.type == "basic" then
        if not token(credential.username) or credential.username:find(":", 1, true) then return false end
    elseif credential.type ~= "bearer" or credential.username ~= nil then
        return false
    end

    if route.headers ~= nil then
        if not object(route.headers) then return false end
        for name, rule in pairs(route.headers) do
            if not name:match("^[a-z][a-z0-9%-]*$") or RESERVED_HEADERS[name]
                or not only_keys(rule, { ensure_csv = true })
                or not token(rule.ensure_csv) or rule.ensure_csv:find(",", 1, true) then
                return false
            end
        end
    end
    return true
end

function M.validate(doc)
    if not only_keys(doc, { clients = true, routes = true })
        or not object(doc.clients) or type(doc.routes) ~= "table" then
        return nil, "config.json must contain clients and routes"
    end

    local hashes = {}
    for id, client in pairs(doc.clients) do
        if not identifier(id) or not only_keys(client, { token_sha256 = true, credentials = true })
            or not object(client.credentials) then
            return nil, "invalid client structure"
        end
        local hash = client.token_sha256
        if type(hash) ~= "string" or #hash ~= 64 or not hash:match("^%x+$") or hashes[hash:lower()] then
            return nil, "client tokens must be unique SHA-256 hex digests"
        end
        hashes[hash:lower()] = true
        for name, value in pairs(client.credentials) do
            if not identifier(name) or not token(value) then
                return nil, "credentials must be named, non-empty strings without whitespace or control characters"
            end
        end
    end

    local ids = {}
    local count = 0
    for index, route in pairs(doc.routes) do
        count = count + 1
        if type(index) ~= "number" or index < 1 or index % 1 ~= 0 or not valid_route(route) then
            return nil, "invalid route definition"
        end
        if ids[route.id] then return nil, "route ids must be unique" end
        ids[route.id] = true
    end
    if count ~= #doc.routes then return nil, "routes must be an ordered array" end
    return true
end

return M
