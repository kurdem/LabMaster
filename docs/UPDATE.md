# Update Guide

## Updating everything

```bash
sudo ./update.sh
```

This will:

1. `git pull` the project (if it is a git checkout) and re-sync compose files
   and scripts into `/opt/docker`.
2. `docker compose pull` the latest images for each stack in `STACKS`.
3. Recreate the containers (`up -d`).
4. Prune dangling images.

## Updating a single stack

```bash
docker compose --project-name n8n \
  --env-file /opt/docker/.env --env-file /opt/docker/.secrets.env \
  -f /opt/docker/compose/n8n/docker-compose.yml pull

docker compose --project-name n8n \
  --env-file /opt/docker/.env --env-file /opt/docker/.secrets.env \
  -f /opt/docker/compose/n8n/docker-compose.yml up -d
```

## Pinning versions

The compose files use `:latest` for convenience. For production, pin explicit
image tags (e.g. `gitea/gitea:1.22`, `postgres:16-alpine`) and bump them
deliberately. Always run `./backup.sh` before a major upgrade.

## Automating

Consider [Watchtower](https://containrrr.dev/watchtower/) for automatic image
updates, or schedule `update.sh` via cron after backups. Test upgrades on a
staging host first where possible.
