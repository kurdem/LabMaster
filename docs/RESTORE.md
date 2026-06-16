# Restore Guide

Restore a LabMaster host from a backup archive — for disaster recovery or
migrating to a new machine.

## On a new host

1. Provision a fresh Ubuntu Server LTS and run the bootstrap once so Docker and
   the directory structure exist:
   ```bash
   git clone <your-repo-url> labmaster && cd labmaster
   sudo ./install.sh
   ```
2. Copy your backup archive to the host, e.g. into `/opt/docker/backups/`.
3. Run the restore:
   ```bash
   sudo ./restore.sh /opt/docker/backups/labmaster-backup-<timestamp>.tar.gz
   ```
   With no argument, the newest archive in `/opt/docker/backups` is used.

## What restore does

1. Prompts for confirmation (it overwrites data).
2. Stops all configured stacks.
3. Extracts the archive over `/opt/docker` (data, compose, `.env`, `.secrets.env`).
4. Restarts all stacks.
5. Restores the Semaphore PostgreSQL dump once the DB is ready.

## Verifying

```bash
docker ps
docker compose --project-name semaphore \
  -f /opt/docker/compose/semaphore/docker-compose.yml ps
```

Check that each service is reachable through the proxy and that data
(workflows, repos, projects) is present.

## Notes

- `.secrets.env` is part of the archive — the restored host keeps the original
  encryption keys, so encrypted data (e.g. n8n credentials) remains decryptable.
- If you restore onto a host with different DNS, update `DOMAIN`/subdomains in
  `/opt/docker/.env` and re-run `sudo ./update.sh`.
