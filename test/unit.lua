-- Module contracts, executed by OpenResty in test/unit.conf.
local cjson = require "cjson.safe"
local schema = require "gateway.schema"
local router = require "gateway.router"
local auth = require "gateway.auth"
local credentials = require "gateway.credentials"

local file = assert(io.open("/etc/gateway/data/config.json", "rb"))
local raw = file:read("*a")
file:close()
local function fixture() return assert(cjson.decode(raw)) end
local passed, failed = 0, 0

local function equal(actual, expected)
    assert(actual == expected, "expected " .. tostring(expected) .. ", got " .. tostring(actual))
end

local function check(name, fn)
    local ok, err = pcall(fn)
    if ok then
        passed = passed + 1
        io.write("ok   ", name, "\n")
    else
        failed = failed + 1
        io.write("FAIL ", name, ": ", tostring(err), "\n")
    end
end

check("configuration accepts the complete fixture and clients without some credentials", function()
    assert(schema.validate(fixture()))
end)

local invalid_configs = {
    { "unknown route options", function(doc) doc.routes[1].host = "ignored.example" end },
    { "ambiguous match", function(doc) doc.routes[1].match.exact = "/x" end },
    { "malformed regex", function(doc) doc.routes[1].match.regex = "[" end },
    { "duplicate route ids", function(doc) doc.routes[2].id = doc.routes[1].id end },
    { "unordered routes", function(doc) doc.routes.extra = doc.routes[1] end },
    { "upstream userinfo", function(doc) doc.routes[1].upstream = "https://user:secret@example.com" end },
    { "upstream query", function(doc) doc.routes[1].upstream = "https://example.com?host=evil" end },
    { "invalid upstream port", function(doc) doc.routes[1].upstream = "http://example.com:99999" end },
    { "inconsistent prefix removal", function(doc) doc.routes[2].strip_prefix = "/api" end },
    { "unknown credential type", function(doc) doc.routes[2].credential.type = "oauth" end },
    { "missing Basic username", function(doc) doc.routes[1].credential.username = nil end },
    { "authentication header override", function(doc)
        doc.routes[2].headers = { authorization = { ensure_csv = "client-token" } }
    end },
    { "invalid header rule", function(doc)
        doc.routes[2].headers = { ["x-features"] = { ensure_csv = "a,b" } }
    end },
    { "empty credential", function(doc) doc.clients["alice-vm"].credentials.github = "" end },
    { "non-string credential", function(doc) doc.clients["alice-vm"].credentials.github = cjson.null end },
    { "credential with control characters", function(doc) doc.clients["alice-vm"].credentials.github = "a\r\nb" end },
    { "duplicate client token regardless of case", function(doc)
        doc.clients["bob-vm"].token_sha256 = doc.clients["alice-vm"].token_sha256:upper()
    end },
}
for _, case in ipairs(invalid_configs) do
    check("configuration rejects " .. case[1], function()
        local doc = fixture()
        case[2](doc)
        local valid, err = schema.validate(doc)
        assert(not valid and type(err) == "string")
    end)
end

local routes = fixture().routes
local routing_cases = {
    { "REST root", "/api/v3", "/api/v3", "http://mock-github:8001/" },
    { "REST path and raw query", "/api/v3/user", "/api/v3/user?q=a%2Fb&x=1", "http://mock-github:8001/user?q=a%2Fb&x=1" },
    { "GraphQL replacement and query", "/api/graphql", "/api/graphql?x=1", "http://mock-github:8001/graphql?x=1" },
    { "Git path", "/acme/demo.git/info/refs", "/acme/demo.git/info/refs?service=git-upload-pack", "http://mock-github:8000/acme/demo.git/info/refs?service=git-upload-pack" },
    { "encoded API suffix", "/api/v3/repos/a b", "/api/v3/repos/a%20b", "http://mock-github:8001/repos/a%20b" },
    { "prefix boundary", "/api/v30/user", "/api/v30/user", nil, 404 },
    { "unknown path", "/x", "/x", nil, 404 },
    { "encoded API prefix", "/api/v3/user", "/%61pi/v3/user", nil, 400 },
    { "encoded exact path", "/api/graphql", "/api/%67raphql", nil, 400 },
    { "encoded Git path", "/acme/demo.git/info/refs", "/%61cme/demo.git/info/refs", nil, 400 },
    { "normalized traversal", "/api/v3/user", "/api/v3/../v3/user", nil, 400 },
}
for _, case in ipairs(routing_cases) do
    check("router handles " .. case[1], function()
        local route, err = router.resolve(routes, case[2], case[3])
        if case[4] then
            equal(assert(route).target, case[4])
        else
            assert(not route)
            equal(err.status, case[5])
        end
    end)
end

check("router uses the first matching route", function()
    local doc = fixture()
    local first = {
        id = "override", match = { exact = "/api/v3/user" },
        upstream = "https://first.example", credential = { source = "github", type = "bearer" },
    }
    table.insert(doc.routes, 1, first)
    equal(router.resolve(doc.routes, "/api/v3/user", "/api/v3/user").id, "override")
end)

check("removing a root or trailing-slash prefix keeps the configured origin", function()
    for _, prefix in ipairs({ "/", "/custom/" }) do
        local path = prefix .. "attacker.example/user"
        local route = {
            id = "custom", match = { prefix = prefix }, strip_prefix = prefix,
            upstream = "https://allowed.example", credential = { source = "github", type = "bearer" },
        }
        equal(router.resolve({ route }, path, path).target, "https://allowed.example/attacker.example/user")
    end
end)

local doc = fixture()
local alice = { id = "alice-vm", credentials = doc.clients["alice-vm"].credentials }
local index = { [doc.clients["alice-vm"].token_sha256] = alice }
local auth_cases = {
    { authorization = "Bearer local-alice-token" },
    { authorization = "token local-alice-token" },
    { authorization = "Basic " .. ngx.encode_base64("vm:local-alice-token") },
    { authorization = "Basic " .. ngx.encode_base64("local-alice-token:") },
    { ["x-api-key"] = "local-alice-token" },
}
for i, headers in ipairs(auth_cases) do
    check("authentication accepts supported token form " .. i, function()
        equal(auth.authenticate(index, headers), alice)
    end)
end

check("authentication rejects duplicate and malformed authorization", function()
    for _, headers in ipairs({
        {}, { authorization = { "Bearer a", "Bearer b" } },
        { authorization = "Bearer unknown" }, { authorization = "Basic invalid" },
        { ["x-api-key"] = { "a", "b" } },
    }) do
        local client, err = auth.authenticate(index, headers)
        assert(not client)
        equal(err.status, 401)
    end
end)

check("credentials build Basic using the route username", function()
    local route = doc.routes[1]
    route.credential.username = "configured-user"
    local headers = assert(credentials.build(route, alice, {}))
    equal(headers.Authorization, "Basic " .. ngx.encode_base64("configured-user:mock-pat-alice"))
end)

check("credential source is independent of the route id", function()
    local headers = assert(credentials.build({
        id = "any-provider", credential = { source = "another-key", type = "bearer" },
    }, { credentials = { ["another-key"] = "configured-secret" } }, {}))
    equal(headers.Authorization, "Bearer configured-secret")
end)

check("missing route credential returns 403", function()
    local headers, err = credentials.build(doc.routes[2], { credentials = {} }, {})
    assert(not headers)
    equal(err.status, 403)
end)

check("required header values are preserved and never added twice", function()
    local config = fixture()
    local route = config.routes[2]
    route.headers = { ["x-features"] = { ensure_csv = "required-feature" } }
    assert(schema.validate(config))
    local cases = {
        { nil, "required-feature" },
        { "other", "other,required-feature" },
        { "other, required-feature", "other, required-feature" },
        { { "one", "required-feature" }, "one,required-feature" },
    }
    for _, case in ipairs(cases) do
        local incoming = { ["x-features"] = case[1] }
        local headers = assert(credentials.build(route, alice, incoming))
        equal(headers["x-features"], case[2])
        equal(incoming["x-features"], case[1])
    end
end)

check("configuration storage indexes clients and reuses its snapshot", function()
    local config = require "gateway.config"
    local snapshot = assert(config.get())
    equal(snapshot.clients_by_hash[doc.clients["alice-vm"].token_sha256].id, "alice-vm")
    equal(config.get(), snapshot)
end)

check("configuration storage returns 503 without any readable configuration", function()
    ngx.shared.gateway_config:flush_all()
    ngx.shared.gateway_config:flush_expired()
    local previous = package.loaded["gateway.config"]
    local getenv = os.getenv
    package.loaded["gateway.config"] = nil
    os.getenv = function(name)
        if name == "CONFIG_DIR" then return "/tmp/missing-gateway-config" end
        return getenv(name)
    end
    local config = require "gateway.config"
    os.getenv = getenv
    package.loaded["gateway.config"] = previous
    local snapshot, err = config.get()
    assert(not snapshot)
    equal(err.status, 503)
end)

-- Independent module instances model workers with separate Lua state, while
-- using the real OpenResty shared dictionary. Replace only the file boundary.
local function config_scenario(fn)
    local shared = ngx.shared.gateway_config
    shared:flush_all()
    shared:flush_expired()
    local open = io.open
    local contents = raw
    local reads = 0
    io.open = function()
        reads = reads + 1
        if not contents then return nil, "missing file" end
        return { read = function() return contents end, close = function() end }
    end
    local ok, err = pcall(fn, function(value)
        contents = value
        shared:delete("checked_at") -- Advance to the next reload without sleeping.
    end, function()
        return assert(loadfile("/opt/gateway/config.lua"))()
    end, function() return reads end)
    io.open = open
    shared:flush_all()
    shared:flush_expired()
    assert(ok, err)
end

check("configuration publishes rotations to both idle and existing workers", function()
    config_scenario(function(update, worker, reads)
        local first, idle = worker(), worker()
        local old = assert(first.get())
        local rotated = fixture()
        rotated.clients["alice-vm"].credentials.github = "mock-pat-bob"
        update(assert(cjson.encode(rotated)))
        local publisher = worker()
        assert(publisher.get())
        local expected_reads = reads()
        local hash = rotated.clients["alice-vm"].token_sha256
        equal(assert(idle.get()).clients_by_hash[hash].credentials.github, "mock-pat-bob")
        equal(assert(first.get()).clients_by_hash[hash].credentials.github, "mock-pat-bob")
        equal(reads(), expected_reads) -- One shared TTL, no per-worker file reads.
        equal(old.clients_by_hash[hash].credentials.github, "mock-pat-alice")
        -- Repeat the original failure with a worker that has never loaded a copy.
        update("{invalid json")
        equal(assert(worker().get()).clients_by_hash[hash].credentials.github, "mock-pat-bob")
        local invalid = fixture()
        invalid.clients["alice-vm"].credentials.github = "invalid\r\nheader"
        update(assert(cjson.encode(invalid)))
        equal(assert(worker().get()).clients_by_hash[hash].credentials.github, "mock-pat-bob")
        update(nil)
        equal(assert(worker().get()).clients_by_hash[hash].credentials.github, "mock-pat-bob")
        update(raw)
        equal(assert(idle.get()).clients_by_hash[hash].credentials.github, "mock-pat-alice")
    end)
end)

check("configuration preserves the shared snapshot when a replacement exceeds capacity", function()
    config_scenario(function(update, worker)
        assert(worker().get())
        local huge = fixture()
        huge.clients["alice-vm"].credentials.github = string.rep("x", 11 * 1024 * 1024)
        update(assert(cjson.encode(huge)))
        local hash = huge.clients["alice-vm"].token_sha256
        equal(assert(worker().get()).clients_by_hash[hash].credentials.github, "mock-pat-alice")
        equal(ngx.shared.gateway_config:get("snapshot:" .. ngx.shared.gateway_config:get("active")), raw)
    end)
end)

check("configuration recovers after startup without a valid file", function()
    config_scenario(function(update, worker)
        update("{invalid json")
        local first = worker()
        local value, err = first.get()
        assert(not value)
        equal(err.status, 503)
        update(raw)
        assert(worker().get())
        assert(first.get())
    end)
end)

io.write(string.format("\n%d module tests passed, %d failed\n", passed, failed))
os.exit(failed == 0 and 0 or 1)
