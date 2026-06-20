#!/usr/bin/env bash
# =============================================================================
# setup-caddy.sh - (Re)generate the Caddy reverse-proxy configuration from the
# enabled stacks and hot-reload Caddy.
#
#   sudo ./setup-caddy.sh
#
# Caddy obtains TLS certificates automatically (ACME). The TLS strategy is
# chosen in /opt/docker/.env:
#   CADDY_TLS_MODE=letsencrypt   real certificates via ACME (default)
#   CADDY_TLS_MODE=internal      self-signed via Caddy's internal CA (offline)
#   CADDY_DNS_PROVIDER=azure     DNS-01 challenge (default; no open ports needed)
# Azure service-principal credentials live in /opt/docker/.secrets.env.
#
# Idempotent: run it any time after changing STACKS, subdomains or the TLS
# settings. install.sh/update.sh call the same generation step automatically.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Resolve lib/common.sh whether run from the repo or from /opt/docker/scripts.
for _cand in "${SCRIPT_DIR}/lib/common.sh" "${SCRIPT_DIR}/../lib/common.sh" "/opt/docker/lib/common.sh"; do
    # shellcheck source=../lib/common.sh
    [[ -r "$_cand" ]] && { . "$_cand"; _COMMON_LOADED=1; break; }
done
[[ -n "${_COMMON_LOADED:-}" ]] || { echo "[FAIL] lib/common.sh not found." >&2; exit 1; }

case "${1:-}" in
    -h|--help) grep -E '^#( |$)' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
esac

require_root
load_env

: "${DOMAIN:?DOMAIN not set in .env}"

log_step "Generating the Caddy configuration"
generate_caddyfile
reload_caddy

log_step "Caddy proxy setup complete"
cat <<EOF

${C_OK}${C_BOLD}Caddy is configured.${C_RESET}

  Caddyfile  : ${DOCKER_ROOT}/data/caddy/Caddyfile
  TLS mode   : ${CADDY_TLS_MODE:-letsencrypt}  (DNS provider: ${CADDY_DNS_PROVIDER:-azure})

  Routes (HTTPS):
EOF
for stack in $(stacks_list); do
    case "$stack" in
        n8n)       printf '    https://%s.%s  ->  n8n:5678\n'       "${N8N_SUBDOMAIN:-n8n}" "$DOMAIN" ;;
        gitea)     printf '    https://%s.%s  ->  gitea:3000\n'     "${GITEA_SUBDOMAIN:-git}" "$DOMAIN" ;;
        semaphore) printf '    https://%s.%s  ->  semaphore:3000\n' "${SEMAPHORE_SUBDOMAIN:-automation}" "$DOMAIN" ;;
        dockhand)  printf '    https://%s.%s  ->  dockhand:3000\n'  "${DOCKHAND_SUBDOMAIN:-dockhand}" "$DOMAIN" ;;
    esac
done
cat <<EOF

  For ACME (letsencrypt), ensure DNS for the above names resolves and the Azure
  credentials in $(SECRETS_FILE) are set (or a Managed Identity is available).
  With CADDY_TLS_MODE=internal the certificates are self-signed - browsers warn
  until you trust Caddy's root CA (data/caddy/data/caddy/pki).

EOF
