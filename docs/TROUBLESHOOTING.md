# Troubleshooting

## Inspecting containers

```bash
docker ps -a                       # all containers and their state
docker logs -f <container>         # follow a container's logs
docker compose --project-name <stack> \
  -f /opt/docker/compose/<stack>/docker-compose.yml ps
```

## Port conflicts (80 / 443 / 81 / SSH)

A bind error like `address already in use` means another service holds the port.

```bash
sudo ss -tulpn | grep -E ':(80|81|443|2222)\b'
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
- In Nginx Proxy Manager, the Proxy Host must forward to the **container name**
  and internal port (e.g. `n8n` / `5678`), not `localhost`.
- NPM and the target container must share the `proxy` network (they do by default).

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

## Automatic proxy setup (setup-proxy.sh)

`setup-proxy.sh` configures NPM via its API. Common issues:

- **`NPM API not reachable`** — the `nginx-proxy-manager` container isn't running
  yet. Check `docker logs nginx-proxy-manager` and retry.
- **First admin user** — recent NPM versions (~2.11+, e.g. 2.15) no longer ship
  the `admin@example.com` / `changeme` default. On a fresh NPM the script creates
  the first admin (`admin@<domain>` + `NPM_ADMIN_PASSWORD`) automatically via the
  API; older versions that still have the factory default are claimed instead.
- **`Could not authenticate to NPM`** — NPM already has an admin that is **not**
  `admin@<domain>` + `NPM_ADMIN_PASSWORD`. This usually means the admin was set
  up manually (e.g. via the NPM web UI on port 81). Fix by either:
  - setting `NPM_ADMIN_PASSWORD` in `/opt/docker/.secrets.env` to the password
    you chose (only works if the admin email is `admin@<domain>`), or
  - **resetting NPM** (nothing valuable is configured yet) — easiest via the flag:
    ```bash
    sudo /opt/docker/scripts/setup-proxy.sh --reset-npm
    ```
    or manually:
    ```bash
    P="--project-name nginx-proxy-manager --env-file /opt/docker/.env --env-file /opt/docker/.secrets.env -f /opt/docker/compose/nginx-proxy-manager/docker-compose.yml"
    docker compose $P down
    sudo rm -rf /opt/docker/data/nginx-proxy-manager/data/*
    docker compose $P up -d
    sleep 20 && sudo /opt/docker/scripts/setup-proxy.sh
    ```
- **Browser trust warning** — expected: the wildcard cert is self-signed. Import
  it as trusted, or switch the proxy hosts to Let's Encrypt for a public setup.
- **Re-running** is safe: the existing certificate and proxy hosts are detected
  and skipped.

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
