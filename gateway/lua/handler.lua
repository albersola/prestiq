-- Coordinates configuration, routing, client authentication and upstream credentials.
local config = require "gateway.config"
local router = require "gateway.router"
local auth = require "gateway.auth"
local credentials = require "gateway.credentials"

local M = {}

local function respond(err, route)
    if err.status == 401 then
        local challenge = route and route.client_auth and route.client_auth.challenge
        ngx.header["WWW-Authenticate"] = challenge == "basic"
            and 'Basic realm="prestiq"' or 'Bearer realm="prestiq"'
    end
    ngx.status = err.status
    ngx.header["Content-Type"] = "text/plain; charset=utf-8"
    ngx.say(err.message)
    return ngx.exit(err.status)
end

local function forward(route, headers)
    for _, name in ipairs({ "Authorization", "x-api-key", "Proxy-Authorization", "Cookie" }) do
        ngx.req.clear_header(name)
    end
    for name, value in pairs(headers) do
        ngx.req.set_header(name, value)
    end
    ngx.var.upstream_target = route.target
end

function M.access()
    local snapshot, err = config.get()
    if not snapshot then return respond(err) end

    local route, err = router.resolve(snapshot.routes, ngx.var.uri, ngx.var.request_uri)
    if not route then return respond(err) end
    ngx.var.service = route.id

    local incoming_headers = ngx.req.get_headers()
    local client, err = auth.authenticate(snapshot.clients_by_hash, incoming_headers)
    if not client then return respond(err, route) end
    ngx.var.client_id = client.id

    local headers, err = credentials.build(route, client, incoming_headers)
    if not headers then return respond(err) end

    forward(route, headers)
end

return M
