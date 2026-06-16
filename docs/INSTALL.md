# Installation Guide

## Prerequisites

- A fresh **Ubuntu Server LTS** (20.04 / 22.04 / 24.04) machine.
- Root or `sudo` access.
- Outbound internet access (to fetch packages and images).
- DNS records for your subdomains pointing to the host's public IP
  (can be configured after installation).

## 1. Get the project

```bash
git clone <your-repo-url> labmaster
cd labmaster
```

## 2. Run the bootstrap

```bash
sudo ./install.sh
```

> The repository ships the scripts with the executable bit set. If your
> environment stripped it (or you downloaded a zip), either run
> `chmod +x install.sh` first or simply use `sudo bash install.sh`.

The script runs nine steps: OS check → dependencies → Docker → `proxy`
network → directory tree → deploy compose → start containers → status →
final report. It is **idempotent** — re-running it is safe.

### First-run configuration

If `/opt/docker/.env` does not exist yet, the installer **prompts interactively**
for the central values, using the defaults from `.env.example`:

```
First-time configuration - press Enter to accept each [default]:
  Base domain [example.com]: mylab.net
  Timezone [Europe/Berlin]:
  n8n subdomain [n8n]:
  Gitea subdomain [git]:
  Semaphore subdomain [automation]:
  Gitea SSH port [2222]:
  ...
```

Pressing Enter keeps the default. For **unattended installs** (no terminal, or
`ASSUME_DEFAULTS=1 sudo -E ./install.sh`), the template is copied unchanged —
adjust `/opt/docker/.env` afterwards and re-run `sudo ./update.sh`.

Secrets (passwords, encryption keys) are generated separately into
`/opt/docker/.secrets.env` and never need manual input.

## 3. Post-install

1. **DNS:** point `n8n.<domain>`, `git.<domain>`, `automation.<domain>` to the host.
2. **Nginx Proxy Manager:** open `http://<host-ip>:81`.
   - Default login: `admin@example.com` / `changeme` → **change it immediately**.
   - Add a Proxy Host per service, forwarding to the container name and port:
     - `n8n` → `n8n:5678`
     - `gitea` → `gitea:3000`
     - `semaphore` → `semaphore:3000`
   - Request Let's Encrypt certificates in the SSL tab.
3. **Semaphore:** log in as `admin` with the password from
   `/opt/docker/.secrets.env` (`SEMAPHORE_ADMIN_PASSWORD`).
4. **Gitea:** complete the web setup at `https://git.<domain>`.
5. **Firewall (optional):** `sudo /opt/docker/scripts/firewall.sh` then `ufw enable`.

## Verifying

```bash
docker ps                                   # all containers Up
docker network inspect proxy                # contains the services
cat /opt/docker/.secrets.env                # generated secrets (root only)
```
