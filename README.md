# prestiq

A gateway that lets your VMs use GitHub without holding real credentials. Each VM carries its own revocable token; the gateway swaps it for the real GitHub PAT before forwarding the request.

```
VM (gateway token) ──► prestiq ──► github.com / api.github.com (real PAT)
```

## Try it locally

Requires Docker Compose, make, Git, curl and Python 3.

```sh
make up     # gateway on http://localhost:8080 with mock providers
make test
make down
```

## Deploy

Point a domain (e.g. `gateway.example.com`) at your server and open port 443.

```sh
cp .env.example .env
mkdir -p data/tls
cp config.example.json data/config.json
chmod 600 data/config.json
```

1. In `.env`, set `GATEWAY_UID`/`GATEWAY_GID` to the user that owns `data/` and `HTTPS_BIND=443`.
2. Put the certificate and key in `data/tls/fullchain.pem` and `data/tls/privkey.pem`.
3. Edit `data/config.json` (see below).
4. Start it:

```sh
docker compose up -d --build
```

## Add a VM

Generate a token per VM. Keep the token for the VM and put only its hash in the config:

```sh
TOKEN=$(openssl rand -hex 32)
echo "VM token: $TOKEN"
printf %s "$TOKEN" | sha256sum
```

In `data/config.json`, add the VM under `clients` with the hash and its real GitHub PAT:

```json
"alice-vm": {
  "token_sha256": "<hash>",
  "credentials": { "github": "<GitHub PAT>" }
}
```

`routes` lists the allowed paths and upstreams; the defaults in `config.example.json` cover Git, the REST API and GraphQL. Changes apply without a restart, and an invalid file keeps the last valid configuration. To revoke a VM, delete its entry.

## Use it from a VM

```sh
GW=gateway.example.com
TOKEN='<the VM token, not its hash>'

# Git (existing GitHub remotes keep working, over HTTPS or SSH-style URLs)
git config --global url."https://$GW/".insteadOf "https://github.com/"
git config --global --add url."https://$GW/".insteadOf "git@github.com:"
git config --global http."https://$GW/".extraHeader "Authorization: Bearer $TOKEN"

# GitHub CLI
export GH_HOST="$GW"
export GH_ENTERPRISE_TOKEN="$TOKEN"
```

Check it with `git ls-remote https://github.com/OWNER/REPO.git` and `gh api user`. Pushing requires the PAT to have write access to the repository.

## Security notes

- The real PAT never leaves the server, but any VM with a valid token can use it with the PAT's full scope. Use fine-grained PATs with minimal permissions, one per VM.
- There is no rate limiting. If the server is public, restrict access with a firewall or a VPN.
- The certificate is read at startup: restart the container after renewing it.

## More

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for the design. Licensed under [MIT](LICENSE).
