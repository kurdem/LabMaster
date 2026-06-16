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

## Resetting a stack (destructive)

```bash
docker compose --project-name <stack> \
  -f /opt/docker/compose/<stack>/docker-compose.yml down
# remove data only if you really want to wipe it:
# sudo rm -rf /opt/docker/data/<stack>
```

## Adding a new stack

1. Create `compose/<service>/docker-compose.yml`:
   - `restart: unless-stopped`
   - join the external `proxy` network
   - store data under `${DOCKER_ROOT}/data/<service>`
   - read secrets from `.secrets.env` (add new keys to `install.sh` generation)
2. Add `<service>` to `STACKS` in `/opt/docker/.env`.
3. `sudo ./update.sh`.

Examples to add later: Home Assistant, Grafana, Prometheus, Uptime Kuma,
Vaultwarden.
