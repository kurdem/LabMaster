#!/usr/bin/env bash
# =============================================================================
# firewall.sh - OPTIONAL UFW rules for the Docker host.
# Run manually: sudo ./scripts/firewall.sh
# Review the rules before enabling - this opens the listed ports.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# When deployed under /opt/docker/scripts, lib/ may live next to the repo.
if [[ -r "${SCRIPT_DIR}/../lib/common.sh" ]]; then
    # shellcheck source=../lib/common.sh
    . "${SCRIPT_DIR}/../lib/common.sh"
else
    echo "[FAIL] lib/common.sh not found." >&2; exit 1
fi

require_root
load_env

command -v ufw >/dev/null 2>&1 || { log_info "Installing ufw..."; apt-get install -y ufw; }

log_step "Configuring UFW rules"
ufw default deny incoming
ufw default allow outgoing

ufw allow 22/tcp                       comment 'SSH (host)'
ufw allow "${NPM_HTTP_PORT:-80}/tcp"   comment 'NPM HTTP'
ufw allow "${NPM_HTTPS_PORT:-443}/tcp" comment 'NPM HTTPS'
ufw allow "${NPM_ADMIN_PORT:-81}/tcp"  comment 'NPM admin UI'
ufw allow "${GITEA_SSH_PORT:-2222}/tcp" comment 'Gitea SSH'

log_warn "Review the rules above. Enable with: ufw enable"
log_info "Current (pending) rules:"
ufw show added
