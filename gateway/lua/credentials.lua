-- Builds upstream authentication headers from a route's credential policy.
local M = {}

local function ensure_csv(value, required)
    if type(value) == "table" then value = table.concat(value, ",") end
    if not value or value == "" then return required end
    for item in value:gmatch("[^,%s]+") do
        if item == required then return value end
    end
    return value .. "," .. required
end

function M.build(route, client, incoming_headers)
    local policy = route.credential
    local value = client.credentials[policy.source]
    if not value then
        return nil, { status = 403, message = "client has no credential for this route" }
    end

    local headers = {}
    if policy.type == "basic" then
        headers.Authorization = "Basic " .. ngx.encode_base64(policy.username .. ":" .. value)
    else
        headers.Authorization = "Bearer " .. value
    end
    for name, rule in pairs(route.headers or {}) do
        headers[name] = ensure_csv(incoming_headers[name], rule.ensure_csv)
    end
    return headers
end

return M
