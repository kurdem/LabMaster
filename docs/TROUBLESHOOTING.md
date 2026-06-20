# Troubleshooting

## Inspecting containers

```bash
docker ps -a                       # all containers and their state
docker logs -f <container>         # follow a container's logs
docker compose --project-name <stack> \
  -f /opt/docker/compose/<stack>/docker-compose.yml ps
```

## Port conflicts (80 / 443 / SSH)

A bind error like `address already in use` means another service holds the port.

```bash
sudo ss -tulpn | grep -E ':(80|443|2222)\b'
```

- Ubuntu's own SSH uses `22`; Gitea SSH is deliberately on `${GITEA_SSH_PORT}`.
- Stop/disable the conflicting service or change the port in `/opt/docker/.env`,
  then `sudo ./update.sh`.

## The `proxy` network is missing

```bash
docker network create proxy
```
Then restart the affected stack. (Re-running `install.sh` also fixes this.)

## Services not reachable via domain

- Confirm DNS points at the host's public IP.
- Check the generated route exists in `/opt/docker/data/caddy/Caddyfile`
  (`reverse_proxy <container>:<port>`). Regenerate with
  `sudo /opt/docker/scripts/setup-caddy.sh` after changing `STACKS`/subdomains.
- Caddy reaches backends by **container name** over the `proxy` network — the
  target container must be on that network (it is by default) and running.
- Inspect Caddy: `docker logs caddy` and
  `docker exec caddy caddy validate --config /etc/caddy/Caddyfile`.

## n8n / Semaphore secrets

If you lose `/opt/docker/.secrets.env`, encrypted data may become unrecoverable
(n8n credentials, Semaphore access keys). Keep it in your backups. To rotate,
edit the file and recreate the stack — note this invalidates existing encrypted data.

## Semaphore cannot connect to its database

```bash
docker logs semaphore-db
docker exec semaphore-db pg_isready -U semaphore
```
Ensure `SEMAPHORE_DB_PASSWORD` matches in `.secrets.env` and that the
`semaphore-db` container is healthy before `semaphore` starts (handled by the
`depends_on: condition: service_healthy`).

## Semaphore PowerShell image / tag resolution

Semaphore uses the PowerShell-enabled image, chosen by `SEMAPHORE_IMAGE_TAG` in
`/opt/docker/.env`. `install.sh`/`update.sh` auto-resolve the newest stable
`*-powershell` tag from Docker Hub. If the host has no internet access to the
Docker Hub API, resolution is skipped with a warning and the existing/default
tag is kept. To set it by hand, edit `.env`:

```ini
SEMAPHORE_IMAGE_AUTO=0
SEMAPHORE_IMAGE_TAG=v2.18.12-powershell7.5.0
```

then `sudo /opt/docker/scripts/update.sh` (or re-run `install.sh`). List
available tags at https://hub.docker.com/r/semaphoreui/semaphore/tags.

## Resetting a stack (destructive)

```bash
docker compose --project-name <stack> \
  -f /opt/docker/compose/<stack>/docker-compose.yml down
# remove data only if you really want to wipe it:
# sudo rm -rf /opt/docker/data/<stack>
```

## Resetting the whole environment (test cleanup)

`teardown.sh` tears the environment down so you can re-run `install.sh` from a
clean state. It keeps `.env`/`.secrets.env` and Docker itself.

```bash
sudo ./teardown.sh            # stop/remove containers + 'proxy' network (keeps data)
sudo ./teardown.sh --volumes  # also remove compose volumes
sudo ./teardown.sh --data     # also delete /opt/docker/data/*
sudo ./teardown.sh --all --yes # full reset, no prompt
```

It prints exactly what it will remove and asks for confirmation (unless
`--yes`). After teardown: `sudo ./install.sh` to provision again.

## Reverse proxy (Caddy) and TLS

Caddy's config is generated at `/opt/docker/data/caddy/Caddyfile` from `STACKS`.
Regenerate and hot-reload it with `sudo /opt/docker/scripts/setup-caddy.sh`.

```bash
docker logs caddy                                              # ACME + routing logs
docker exec caddy caddy validate --config /etc/caddy/Caddyfile # syntax check
cat /opt/docker/data/caddy/Caddyfile                           # generated routes
```

- **Image build fails (xcaddy / plugin).** The Caddy image is built locally with
  the DNS plugin (`CADDY_DNS_MODULE`, default `github.com/caddy-dns/azure`). The
  build needs outbound internet to fetch Go modules. Rebuild explicitly:
  `docker compose --project-name caddy -f /opt/docker/compose/caddy/docker-compose.yml build --no-cache`.
- **No certificate issued (ACME DNS-01 / Azure).** Check `docker logs caddy` for
  ACME errors. Common causes: missing/incorrect `AZURE_*` credentials in
  `.secrets.env`, the service principal lacks **DNS Zone Contributor** on the
  zone, the zone/resource group names are wrong, or DNS propagation is slow.
  If credentials are missing entirely, generation falls back to `tls internal`
  (self-signed) and warns — fill them in and re-run `setup-caddy.sh`.
- **Let's Encrypt rate limits.** While testing, set `CADDY_ACME_CA` to the
  staging endpoint in `.env` (issues untrusted certs but avoids rate limits),
  then switch back to production and re-run `setup-caddy.sh`.
- **Browser trust warning** — expected with `CADDY_TLS_MODE=internal`: the certs
  are self-signed. Trust Caddy's root CA (`/opt/docker/data/caddy/data/caddy/pki`)
  or switch to `letsencrypt` for publicly trusted certificates.
- **Migrating from Nginx Proxy Manager.** `update.sh` runs `migrate_npm_to_caddy`
  automatically: it stops/removes the old `nginx-proxy-manager` stack (freeing
  ports 80/443) and drops it from `STACKS`. The old NPM data under
  `data/nginx-proxy-manager` is kept and can be deleted once you're satisfied.
- **Re-running** `setup-caddy.sh` is safe and idempotent.

## Adding a new stack

1. Create `compose/<service>/docker-compose.yml`:
   - `restart: unless-stopped`
   - join the external `proxy` network
   - store data under `${DOCKER_ROOT}/data/<service>`
   - read secrets from `.secrets.env` (add new keys to `install.sh` generation)
2. `sudo ./update.sh` — new `compose/<service>` folders are added to `STACKS`
   automatically (`STACKS_AUTO=1`, the default). To wire it up by hand instead,
   set `STACKS_AUTO=0` and add `<service>` to `STACKS` in `/opt/docker/.env`.

Examples to add later: Home Assistant, Grafana, Prometheus, Uptime Kuma,
Vaultwarden.
