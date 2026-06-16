#!/usr/bin/env bash
# =============================================================================
# install.sh - One-command bootstrap for an Ubuntu Server LTS Docker host.
#
#   sudo ./install.sh
#
# Idempotent: safe to re-run. Steps:
#   1. Check OS        4. Create network    7. Start containers
#   2. Dependencies    5. Create dirs       8. Check status
#   3. Install Docker  6. Deploy compose    9. Final report
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "${SCRIPT_DIR}/lib/common.sh"

# -----------------------------------------------------------------------------
# 1. Check operating system & privileges
# -----------------------------------------------------------------------------
log_step "1/9 Checking operating system"
require_root
check_os
export DEBIAN_FRONTEND=noninteractive

# -----------------------------------------------------------------------------
# 2. Install base dependencies
# -----------------------------------------------------------------------------
log_step "2/9 Installing base dependencies"
apt-get update -qq
apt-get install -y \
    ca-certificates curl gnupg git unzip jq python3 python3-pip
log_ok "Base packages installed."

# -----------------------------------------------------------------------------
# 3. Install Docker Engine + Compose plugin (official APT repository)
# -----------------------------------------------------------------------------
log_step "3/9 Installing Docker Engine"
if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    log_ok "Docker and the compose plugin are already installed; skipping."
else
    install -m 0755 -d /etc/apt/keyrings
    if [[ ! -f /etc/apt/keyrings/docker.asc ]]; then
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
            -o /etc/apt/keyrings/docker.asc
        chmod a+r /etc/apt/keyrings/docker.asc
    fi
    # shellcheck disable=SC1091
    . /etc/os-release
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
https://download.docker.com/linux/ubuntu ${VERSION_CODENAME} stable" \
        > /etc/apt/sources.list.d/docker.list
    apt-get update -qq
    apt-get install -y \
        docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    systemctl enable --now docker
    log_ok "Docker installed: $(docker --version)"
fi

# -----------------------------------------------------------------------------
# 4. Create the shared 'proxy' network
# -----------------------------------------------------------------------------
log_step "4/9 Creating Docker network 'proxy'"
if docker network inspect proxy >/dev/null 2>&1; then
    log_ok "Network 'proxy' already exists."
else
    docker network create proxy
    log_ok "Network 'proxy' created."
fi

# -----------------------------------------------------------------------------
# 5. Prepare configuration & create the directory structure
# -----------------------------------------------------------------------------
log_step "5/9 Preparing configuration and directories"

# Create the runtime .env on first run (interactive prompt, or template copy
# when running non-interactively), then load it.
mkdir -p "${DOCKER_ROOT}"
if [[ ! -f "$(ENV_FILE)" ]]; then
    setup_env_interactive
fi
load_env

# Generate secrets once and persist them (never overwrite existing ones).
SECRETS="$(SECRETS_FILE)"
if [[ ! -f "$SECRETS" ]]; then
    log_info "Generating random secrets -> ${SECRETS}"
    umask 077
    cat > "$SECRETS" <<EOF
# Auto-generated secrets - DO NOT commit. Generated $(date -u +%FT%TZ)
N8N_ENCRYPTION_KEY=$(gen_secret 32)
SEMAPHORE_DB_PASSWORD=$(gen_secret 24)
SEMAPHORE_ADMIN_PASSWORD=$(gen_secret 20)
SEMAPHORE_ACCESS_KEY_ENCRYPTION=$(openssl rand -base64 32)
SEMAPHORE_COOKIE_HASH=$(openssl rand -base64 32)
SEMAPHORE_COOKIE_ENCRYPTION=$(openssl rand -base64 32)
GITEA_ADMIN_PASSWORD=$(gen_secret 20)
EOF
    chmod 600 "$SECRETS"
    log_ok "Secrets written (chmod 600)."
else
    log_ok "Secrets file already present; keeping existing values."
fi
load_env

# Directory structure under ${DOCKER_ROOT}.
log_info "Creating directory tree under ${DOCKER_ROOT}"
mkdir -p \
    "${DOCKER_ROOT}/compose" \
    "${DOCKER_ROOT}/backups" \
    "${DOCKER_ROOT}/scripts" \
    "${DOCKER_ROOT}/data/n8n" \
    "${DOCKER_ROOT}/data/nginx-proxy-manager/data" \
    "${DOCKER_ROOT}/data/nginx-proxy-manager/letsencrypt" \
    "${DOCKER_ROOT}/data/semaphore/data" \
    "${DOCKER_ROOT}/data/semaphore/postgres" \
    "${DOCKER_ROOT}/data/gitea"
log_ok "Directory structure ready."

# -----------------------------------------------------------------------------
# 6. Deploy compose files & helper scripts
# -----------------------------------------------------------------------------
log_step "6/9 Deploying compose files and scripts"
cp -r "${SCRIPT_DIR}/compose/." "${DOCKER_ROOT}/compose/"
# Deploy the shared library and operational scripts so they can also be run
# from /opt/docker (e.g. via cron). The scripts resolve lib/common.sh from here.
mkdir -p "${DOCKER_ROOT}/lib"
cp "${SCRIPT_DIR}/lib/common.sh" "${DOCKER_ROOT}/lib/common.sh"
cp "${SCRIPT_DIR}/scripts/"*.sh "${DOCKER_ROOT}/scripts/" 2>/dev/null || true
for s in backup.sh restore.sh update.sh teardown.sh; do
    [[ -f "${SCRIPT_DIR}/${s}" ]] && cp "${SCRIPT_DIR}/${s}" "${DOCKER_ROOT}/scripts/"
done
chmod +x "${DOCKER_ROOT}/scripts/"*.sh 2>/dev/null || true
log_ok "Compose stacks, library and scripts copied."

# -----------------------------------------------------------------------------
# 7. Start the containers
# -----------------------------------------------------------------------------
log_step "7/9 Starting containers"
for stack in $(stacks_list); do
    if [[ -f "${DOCKER_ROOT}/compose/${stack}/docker-compose.yml" ]]; then
        log_info "Starting stack: ${stack}"
        compose_cmd "$stack" up -d
    else
        log_warn "No compose file for '${stack}', skipping."
    fi
done

# -----------------------------------------------------------------------------
# 8. Check status
# -----------------------------------------------------------------------------
log_step "8/9 Checking container status"
sleep 3
for stack in $(stacks_list); do
    [[ -f "${DOCKER_ROOT}/compose/${stack}/docker-compose.yml" ]] || continue
    printf '%s--- %s ---%s\n' "$C_BOLD" "$stack" "$C_RESET"
    compose_cmd "$stack" ps
done

# -----------------------------------------------------------------------------
# 9. Final report
# -----------------------------------------------------------------------------
log_step "9/9 Installation complete"
cat <<EOF

${C_OK}${C_BOLD}LabMaster Docker host is ready.${C_RESET}

  Reverse proxy admin : http://<host-ip>:${NPM_ADMIN_PORT}
       NPM first login : admin@example.com / changeme  (change immediately!)

  Service URLs (configure proxy hosts in NPM, pointing to the container names):
    n8n        -> https://${N8N_SUBDOMAIN}.${DOMAIN}        (n8n:5678)
    Gitea      -> https://${GITEA_SUBDOMAIN}.${DOMAIN}      (gitea:3000)  SSH: ${GITEA_SSH_PORT}
    Semaphore  -> https://${SEMAPHORE_SUBDOMAIN}.${DOMAIN}  (semaphore:3000)

  Semaphore admin user : admin
  Generated secrets    : $(SECRETS_FILE)  (chmod 600)
  Config file          : $(ENV_FILE)

  Next steps:
    - Point your DNS records to this host's public IP.
    - In NPM, add Proxy Hosts + request Let's Encrypt certificates.
    - (Optional) harden the firewall: sudo ${DOCKER_ROOT}/scripts/firewall.sh
    - Set up backups: see docs/BACKUP.md

EOF
