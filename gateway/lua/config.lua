-- Reads config.json and caches the last valid snapshot per worker.
local cjson = require "cjson.safe"
local schema = require "gateway.schema"

local M = {}
local path = (os.getenv("CONFIG_DIR") or "/etc/gateway/data") .. "/config.json"
local ttl = tonumber(os.getenv("CONFIG_TTL")) or 5
local current
local loaded_at = 0

local function load()
    local file, err = io.open(path, "rb")
    if not file then
        return nil, err
    end
    local raw, read_err = file:read("*a")
    file:close()
    if not raw then
        return nil, read_err
    end

    local doc = cjson.decode(raw)
    local valid, validation_err = schema.validate(doc)
    if not valid then
        return nil, validation_err
    end

    local clients_by_hash = {}
    for id, client in pairs(doc.clients) do
        clients_by_hash[client.token_sha256:lower()] = {
            id = id,
            credentials = client.credentials,
        }
    end
    return { clients_by_hash = clients_by_hash, routes = doc.routes }
end

-- Call once per request so routing and authentication share the same snapshot.
-- Consumers treat the returned tables as read-only.
function M.get()
    local now = ngx.now()
    if not current or now - loaded_at >= ttl then
        loaded_at = now
        local next_config, err = load()
        if next_config then
            current = next_config
        else
            ngx.log(ngx.ERR, "cannot load config.json, keeping previous configuration: ", err)
        end
    end
    if not current then
        return nil, { status = 503, message = "gateway configuration unavailable" }
    end
    return current
end

return M
