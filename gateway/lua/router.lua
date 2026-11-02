-- Resolves configured paths to upstream URLs. Does not authenticate or mutate requests.
local M = {}

local function prefix_matches(path, prefix)
    if path:sub(1, #prefix) ~= prefix then return false end
    return path == prefix or prefix:sub(-1) == "/" or path:sub(#prefix + 1, #prefix + 1) == "/"
end

local function matches(match, uri)
    if match.exact then return uri == match.exact end
    if match.prefix then return prefix_matches(uri, match.prefix) end
    return ngx.re.find(uri, match.regex, "jo") ~= nil
end

local function upstream_path(route, uri, raw_path)
    -- nginx decodes and normalizes uri. Reject traversal and other normalization
    -- changes while preserving ordinary percent-encoded suffixes on prefix routes.
    if raw_path:sub(1, 1) ~= "/" or ngx.unescape_uri(raw_path) ~= uri then return nil end

    if route.match.prefix then
        if not prefix_matches(raw_path, route.match.prefix) then return nil end
    elseif raw_path ~= uri then
        return nil
    end

    if route.replace_path then return route.replace_path end
    if route.strip_prefix then
        local path = raw_path:sub(#route.strip_prefix + 1)
        if path:sub(1, 1) ~= "/" then path = "/" .. path end
        return path
    end
    return raw_path
end

function M.resolve(routes, uri, request_uri)
    local raw_path, query = request_uri:match("^([^?]*)(.*)$")
    for _, route in ipairs(routes) do
        if matches(route.match, uri) then
            local path = upstream_path(route, uri, raw_path)
            if not path then
                return nil, { status = 400, message = "unsupported request path" }
            end
            return {
                id = route.id,
                target = route.upstream .. path .. query,
                client_auth = route.client_auth,
                credential = route.credential,
                headers = route.headers,
            }
        end
    end
    return nil, { status = 404, message = "not found" }
end

return M
