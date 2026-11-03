-- Publishes the last valid configuration to all workers as one atomic value.
local cjson = require "cjson.safe"
local schema = require "gateway.schema"

local M = {}
local path = (os.getenv("CONFIG_DIR") or "/etc/gateway/data") .. "/config.json"
local ttl = tonumber(os.getenv("CONFIG_TTL")) or 5
local shared = ngx.shared.gateway_config
local current
local current_raw

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

    return raw
end

local function snapshot(raw)
    local doc = assert(cjson.decode(raw)) -- Only validated documents are published.
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
    local checked_at = shared:get("checked_at")
    if not checked_at or now - checked_at >= ttl then
        -- File I/O and validation do not yield. Expiry also recovers a lock
        -- left behind by a worker that exits during a reload.
        local locked = shared:safe_add("loading", true, 30)
        if locked then
            checked_at = shared:get("checked_at")
            if not checked_at or now - checked_at >= ttl then
                local raw, err = load()
                if raw then
                    -- safe_set can discard the old value of its own key on
                    -- allocation failure. Write to the inactive slot first.
                    local slot = shared:get("active") == 1 and 2 or 1
                    local ok
                    ok, err = shared:safe_set("snapshot:" .. slot, raw)
                    if ok then ok, err = shared:safe_set("active", slot) end
                    if not ok then raw = nil end
                end
                if not raw then
                    ngx.log(ngx.ERR, "cannot load config.json, keeping previous configuration: ", err)
                end
                shared:safe_set("checked_at", now)
            end
            shared:delete("loading")
        end
    end
    -- Check on every request, including on workers with an older local copy.
    local slot = shared:get("active")
    local raw = slot and shared:get("snapshot:" .. slot)
    -- A concurrent pair of reloads may have reused the slot we just read.
    if slot and not raw then
        slot = shared:get("active")
        raw = slot and shared:get("snapshot:" .. slot)
    end
    if raw and raw ~= current_raw then
        current = snapshot(raw)
        current_raw = raw
    end
    if not current then
        return nil, { status = 503, message = "gateway configuration unavailable" }
    end
    return current
end

return M
