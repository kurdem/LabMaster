# Backup Guide

## What is backed up

`backup.sh` produces a single timestamped archive in
`/opt/docker/backups/labmaster-backup-<timestamp>.tar.gz` containing:

- **Persistent data** — everything under `/opt/docker/data` (n8n, Caddy,
  Gitea, Semaphore, Dockhand), except the live Postgres data dir (a logical
  dump is used instead for consistency).
- **Compose stacks** — `/opt/docker/compose`.
- **Configuration** — `.env` and `.secrets.env`.
- **Database dump** — a consistent `pg_dump` of the Semaphore PostgreSQL DB.

## Running a backup

```bash
sudo ./backup.sh
```

## Retention

`BACKUP_RETENTION` in `.env` controls how many archives to keep (default `7`,
`0` = keep all). Older archives are pruned automatically.

## Scheduling (cron)

Run nightly at 02:30:

```bash
sudo crontab -e
```
```cron
30 2 * * * /opt/docker/scripts/backup.sh >> /var/log/labmaster-backup.log 2>&1
```

> The bootstrap copies `backup.sh`/`restore.sh` helpers into
> `/opt/docker/scripts`. You can also call them from the cloned repo.

## Off-site copies (recommended)

Local backups do not protect against full host loss. Sync `/opt/docker/backups`
off-site, e.g. with **restic** or **rclone**:

```bash
restic -r s3:s3.example.com/labmaster backup /opt/docker/backups
```
