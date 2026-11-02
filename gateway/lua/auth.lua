-- Identifies a gateway client from request headers and the configured hash index.
local resty_sha256 = require "resty.sha256"
local resty_string = require "resty.string"

local M = {}

-- Accepted forms, matching what each tool sends:
--   Authorization: Bearer <token>   git extraHeader
--   Authorization: token <token>    gh
--   Authorization: Basic <b64>      git credentials (token as password, or as user)
--   x-api-key: <token>              API clients
local function client_token(headers)
    local header = headers.authorization
    if not header then
        return type(headers["x-api-key"]) == "string" and headers["x-api-key"] or nil
    end
    if type(header) ~= "string" then return nil end

    local scheme, value = header:match("^(%S+)%s+(%S+)%s*$")
    if not scheme then
        return nil
    end
    scheme = scheme:lower()
    if scheme == "bearer" or scheme == "token" then
        return value
    end
    if scheme == "basic" then
        local decoded = ngx.decode_base64(value) or ""
        local user, pass = decoded:match("^([^:]*):(.*)$")
        if pass and pass ~= "" then
            return pass
        end
        if user and user ~= "" then
            return user
        end
    end
    return nil
end

local function hash(token)
    local sha = resty_sha256:new()
    sha:update(token)
    return resty_string.to_hex(sha:final())
end

function M.authenticate(clients_by_hash, headers)
    local token = client_token(headers)
    if not token or token == "" then
        return nil, { status = 401, message = "missing client token" }
    end
    local client = clients_by_hash[hash(token)]
    if not client then
        return nil, { status = 401, message = "invalid client token" }
    end
    return client
end

return M
