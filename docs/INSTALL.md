# Installation Guide

## Prerequisites

- A fresh **Ubuntu Server LTS** (20.04 / 22.04 / 24.04) machine.
- Root or `sudo` access.
- Outbound internet access (to fetch packages and images).
- DNS records for your subdomains pointing to the host's public IP
  (can be configured after installation).

## 1. Get the project

Git is required to clone the repository. On a fresh Ubuntu it is usually not
installed yet:

```bash
sudo apt update
sudo apt install -y git
```

Then clone and enter the project:

```bash
git clone <your-repo-url> labmaster
cd labmaster
```

> Optional, if you commit from this host:
> ```bash
> git config --global user.name  "Your Name"
> git config --global user.email "you@example.com"
> ```
> For SSH (instead of HTTPS) clones, create a key and add it to your Git host:
> ```bash
> ssh-keygen -t ed25519 -C "you@example.com"
> ```

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
2. **Reverse proxy (Caddy):** routes are generated from `STACKS` automatically —
   there is no UI to configure. Pick a TLS strategy in `/opt/docker/.env`:
   - **ACME with Azure DNS-01 (default, recommended).** Create an Azure service
     principal with **DNS Zone Contributor** on your DNS zone, then put its
     credentials in `/opt/docker/.secrets.env`:
     ```ini
     AZURE_TENANT_ID=...
     AZURE_CLIENT_ID=...
     AZURE_CLIENT_SECRET=...
     AZURE_SUBSCRIPTION_ID=...
     AZURE_RESOURCE_GROUP_NAME=...
     ```
     (Leave `tenant/client/secret` empty to use a Managed Identity.) Then
     regenerate the config and reload Caddy:
     ```bash
     sudo /opt/docker/scripts/setup-caddy.sh
     ```
     Caddy obtains real certificates via DNS validation — no open ports needed.
     Test against the staging CA first by uncommenting `CADDY_ACME_CA` in `.env`.
   - **Self-signed (offline/homelab):** set `CADDY_TLS_MODE=internal` in `.env`
     and run `setup-caddy.sh`. Browsers warn until you trust Caddy's root CA.
   - **Other DNS providers / HTTP challenge:** set `CADDY_DNS_PROVIDER`
     (+ matching `CADDY_DNS_MODULE`) for another `caddy-dns/*` plugin, or leave
     `CADDY_DNS_PROVIDER` empty to use the HTTP/TLS-ALPN challenge (needs public
     DNS for each subdomain and reachable ports 80/443). Re-run `update.sh` to
     rebuild the image when changing the plugin module.
3. **Semaphore:** log in as `admin` with the password from
   `/opt/docker/.secrets.env` (`SEMAPHORE_ADMIN_PASSWORD`). By default Semaphore
   runs the **PowerShell-enabled** image: `install.sh`/`update.sh` auto-resolve
   the newest stable `*-powershell` tag into `SEMAPHORE_IMAGE_TAG` (set
   `SEMAPHORE_IMAGE_AUTO=0` in `.env` to pin a tag manually).
4. **Gitea:** complete the web setup at `https://git.<domain>`.
5. **Dockhand:** Docker management UI at `https://dockhand.<domain>`. It mounts
   the Docker socket (root-equivalent host control), so keep it behind the proxy
   and never expose its port publicly.
6. **Firewall (optional):** `sudo /opt/docker/scripts/firewall.sh` then `ufw enable`.

## Verifying

```bash
docker ps                                   # all containers Up
docker network inspect proxy                # contains the services
cat /opt/docker/.secrets.env                # generated secrets (root only)
```
