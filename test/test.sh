#!/usr/bin/env bash
# End-to-end tests against the local environment (`make up`).
# Runs git and curl from the host, in an isolated HOME.
set -uo pipefail

GW="${GW_URL:-http://localhost:8080}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="$ROOT/test/data/config.json"

ALICE=local-alice-token
BOB=local-bob-token
CAROL=local-carol-token

WORK="$(mktemp -d)"
cp "$CONFIG" "$WORK/config.json.orig"
cleanup() {
  cp "$WORK/config.json.orig" "$CONFIG"
  rm -rf "$WORK"
}
trap cleanup EXIT

export HOME="$WORK/home" GIT_CONFIG_NOSYSTEM=1 GIT_TERMINAL_PROMPT=0
mkdir -p "$HOME"
git config --global user.name test
git config --global user.email test@example.com
git config --global init.defaultBranch main

passed=0
failed=0
check() {
  local name="$1"
  shift
  if "$@" >"$WORK/out" 2>&1; then
    echo "ok   $name"
    passed=$((passed + 1))
  else
    echo "FAIL $name"
    sed 's/^/     /' "$WORK/out"
    failed=$((failed + 1))
  fi
}

# status <expected> <curl args...>
status() {
  local expected="$1"
  shift
  local got
  got="$(curl -s -o /dev/null -w '%{http_code}' "$@")"
  [ "$got" = "$expected" ] || { echo "expected HTTP $expected, got $got"; return 1; }
}

# body_has <text> <curl args...>
body_has() {
  local text="$1"
  shift
  local body
  body="$(curl -sS -N "$@")"
  grep -qF -- "$text" <<<"$body" || { echo "missing '$text' in: $body"; return 1; }
}

git_as() {
  local token="$1"
  shift
  git -c "http.extraHeader=Authorization: Bearer $token" "$@"
}

set_credential() {
  python3 - "$CONFIG" "$@" <<'EOF'
import json, sys
path, field, value = sys.argv[1:]
with open(path) as f:
    doc = json.load(f)
doc["clients"]["alice-vm"]["credentials"][field] = value
with open(path, "w") as f:
    json.dump(doc, f, indent=2)
EOF
}

echo "== gateway"
check "health check" status 200 "$GW/_healthz"
check "unknown path is rejected" status 404 -H "Authorization: Bearer $ALICE" "$GW/foo"
check "unknown API version is rejected" status 404 -H "Authorization: Bearer $ALICE" "$GW/api/v4/user"
check "prefix respects segment boundaries" status 404 -H "Authorization: Bearer $ALICE" "$GW/api/v30/user"
check "encoded routing prefix is rejected" \
  status 400 --path-as-is -H "Authorization: Bearer $ALICE" "$GW/%61pi/v3/user"
check "non-git repo path is rejected" status 404 -H "Authorization: Bearer $ALICE" "$GW/acme/demo.git/HEAD"

echo "== client authentication"
check "git without token gets a Basic challenge" \
  body_has 'WWW-Authenticate: Basic' -i "$GW/acme/demo.git/info/refs?service=git-upload-pack"
check "invalid token is rejected" \
  status 401 -H "Authorization: Bearer nope" "$GW/api/v3/user"
check "client without github gets 403" \
  status 403 -H "Authorization: Bearer $CAROL" "$GW/api/v3/user"

echo "== github git"
check "clone" git_as "$ALICE" clone -q "$GW/acme/demo.git" "$WORK/demo"
echo "pushed by test" >"$WORK/demo/pushed.txt"
git -C "$WORK/demo" add pushed.txt && git -C "$WORK/demo" commit -qm "Push through gateway"
check "push" git_as "$ALICE" -C "$WORK/demo" push -q origin main
pushed="$(git -C "$WORK/demo" rev-parse HEAD)"
check "token as Basic password (credential helper style)" \
  bash -c "git ls-remote 'http://vm:$BOB@${GW#http://}/acme/demo.git' main | grep -q '^$pushed'"

echo "== github api"
check "REST uses the client's PAT (alice)" \
  body_has '"login": "alice"' -H "Authorization: Bearer $ALICE" "$GW/api/v3/user"
check "REST uses the client's PAT (bob, gh style)" \
  body_has '"login": "bob"' -H "Authorization: token $BOB" "$GW/api/v3/user"
check "REST accepts an x-api-key client token" \
  body_has '"login": "alice"' -H "x-api-key: $ALICE" "$GW/api/v3/user"
check "REST keeps path and query" \
  body_has '"path": "/repos/acme/demo/pulls?state=open"' \
  -H "Authorization: Bearer $ALICE" "$GW/api/v3/repos/acme/demo/pulls?state=open"
check "GraphQL" \
  body_has '"login": "alice"' -H "Authorization: Bearer $ALICE" \
  -X POST -d '{"query":"{ viewer { login } }"}' "$GW/api/graphql"

echo "== hot reload"
set_credential github mock-pat-bob
sleep 2
check "inline PAT rotation applies without restart" \
  body_has '"login": "bob"' -H "Authorization: Bearer $ALICE" "$GW/api/v3/user"

set_credential github ''
sleep 2
check "empty credential keeps the last valid configuration" \
  body_has '"login": "bob"' -H "Authorization: Bearer $ALICE" "$GW/api/v3/user"

set_credential github $'invalid\r\nheader'
sleep 2
check "credential with control characters keeps the last valid configuration" \
  body_has '"login": "bob"' -H "Authorization: Bearer $ALICE" "$GW/api/v3/user"

printf '{invalid json' > "$CONFIG"
sleep 2
check "malformed JSON keeps the last valid configuration" \
  body_has '"login": "bob"' -H "Authorization: Bearer $ALICE" "$GW/api/v3/user"

cp "$WORK/config.json.orig" "$CONFIG"
sleep 2
check "valid configuration restores the original PAT" \
  body_has '"login": "alice"' -H "Authorization: Bearer $ALICE" "$GW/api/v3/user"

echo "== configured routes"
check "custom route does not exist yet" \
  status 404 -H "Authorization: Bearer $ALICE" "$GW/custom-api/user"
python3 - "$CONFIG" <<'EOF'
import copy, json, sys
path = sys.argv[1]
with open(path) as f:
    doc = json.load(f)
route = copy.deepcopy(next(r for r in doc["routes"] if r["id"] == "github-rest"))
route.update(id="custom-api", match={"prefix": "/custom-api"}, strip_prefix="/custom-api")
route["client_auth"] = {"challenge": "basic"}
doc["routes"].insert(0, route)
with open(path, "w") as f:
    json.dump(doc, f, indent=2)
EOF
sleep 2
check "new route and its credential policy apply without restart" \
  body_has '"login": "alice"' -H "Authorization: Bearer $ALICE" "$GW/custom-api/user"
check "Basic challenge is configured independently of upstream Bearer auth" \
  body_has 'WWW-Authenticate: Basic' -i "$GW/custom-api/user"

python3 - "$CONFIG" <<'EOF'
import json, sys
path = sys.argv[1]
with open(path) as f:
    doc = json.load(f)
doc["clients"] = {}
doc["routes"][0]["credential"]["type"] = "unsupported"
with open(path, "w") as f:
    json.dump(doc, f, indent=2)
EOF
sleep 2
check "invalid routes preserve the complete snapshot, including clients" \
  body_has '"login": "alice"' -H "Authorization: Bearer $ALICE" "$GW/custom-api/user"

cp "$WORK/config.json.orig" "$CONFIG"
sleep 2
check "removed route stops forwarding without restart" \
  status 404 -H "Authorization: Bearer $ALICE" "$GW/custom-api/user"

python3 - "$CONFIG" <<'EOF'
import json, sys
path = sys.argv[1]
doc = json.load(open(path))
del doc["clients"]["bob-vm"]
json.dump(doc, open(path, "w"), indent=2)
EOF
sleep 2
check "removed client is revoked without restart" \
  status 401 -H "Authorization: Bearer $BOB" "$GW/api/v3/user"
cp "$WORK/config.json.orig" "$CONFIG"
sleep 2
check "restored client works again" \
  status 200 -H "Authorization: Bearer $BOB" "$GW/api/v3/user"

echo
echo "$passed passed, $failed failed"
[ "$failed" -eq 0 ]
