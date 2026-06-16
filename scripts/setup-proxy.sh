#!/usr/bin/env bash
# =============================================================================
# setup-proxy.sh - Generate a self-signed wildcard certificate, upload it to
# Nginx Proxy Manager, and create the proxy hosts for the enabled services.
#
#   sudo ./setup-proxy.sh [--reset-npm] [--yes]
#
#   --reset-npm  Wipe NPM's config DB first (factory reset), then configure it.
#                Use when the NPM admin was changed manually and the password is
#                unknown. Prompts for confirmation unless --yes is given.
#   --yes, -y    Skip the confirmation prompt.
#
# Idempotent: re-running reuses the existing certificate and skips proxy hosts
# that already exist. Requires the NPM stack to be running. Uses curl/jq/openssl.
#
# NOTE: The certificate is self-signed, so browsers will show a trust warning.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Resolve lib/common.sh whether run from the repo or from /opt/docker/scripts.
for _cand in "${SCRIPT_DIR}/lib/common.sh" "${SCRIPT_DIR}/../lib/common.sh" "/opt/docker/lib/common.sh"; do
    # shellcheck source=lib/common.sh
    [[ -r "$_cand" ]] && { . "$_cand"; _COMMON_LOADED=1; break; }
done
[[ -n "${_COMMON_LOADED:-}" ]] || { echo "[FAIL] lib/common.sh not found." >&2; exit 1; }

RESET_NPM=0
ASSUME_YES=0
for arg in "$@"; do
    case "$arg" in
        --reset-npm) RESET_NPM=1 ;;
        --yes|-y)    ASSUME_YES=1 ;;
        -h|--help)   grep -E '^#( |$)' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "Unknown option: $arg (try --help)" >&2; exit 1 ;;
    esac
done

require_root
load_env

command -v curl >/dev/null 2>&1 || die "curl is required."
command -v jq   >/dev/null 2>&1 || die "jq is required."
command -v openssl >/dev/null 2>&1 || die "openssl is required."

: "${DOMAIN:?DOMAIN not set in .env}"
NPM_API="http://localhost:${NPM_ADMIN_PORT:-81}/api"
SSL_DIR="${DOCKER_ROOT}/data/nginx-proxy-manager/custom-ssl"
CERT_NAME="LabMaster Wildcard ${DOMAIN}"
CRT="${SSL_DIR}/wildcard.crt"
KEY="${SSL_DIR}/wildcard.key"

ADMIN_EMAIL="admin@${DOMAIN}"
DEFAULT_EMAIL="admin@example.com"
DEFAULT_PASS="changeme"
# Self-heal: generate the secret on hosts provisioned before it was introduced.
ensure_secret NPM_ADMIN_PASSWORD "$(gen_secret 20)"

# -----------------------------------------------------------------------------
# 1. Generate the self-signed wildcard certificate (if missing)
# -----------------------------------------------------------------------------
log_step "Self-signed wildcard certificate"
mkdir -p "$SSL_DIR"
if [[ -f "$CRT" && -f "$KEY" ]]; then
    log_ok "Certificate already present: ${CRT}"
else
    openssl req -x509 -nodes -newkey rsa:2048 -days 3650 \
        -keyout "$KEY" -out "$CRT" \
        -subj "/CN=*.${DOMAIN}" \
        -addext "subjectAltName=DNS:${DOMAIN},DNS:*.${DOMAIN}" 2>/dev/null
    chmod 600 "$KEY"
    log_ok "Generated self-signed wildcard for *.${DOMAIN} (valid 10 years)."
fi

# -----------------------------------------------------------------------------
# 1b. Optional: reset NPM to factory defaults (--reset-npm)
# -----------------------------------------------------------------------------
if [[ "$RESET_NPM" == "1" ]]; then
    log_step "Resetting NPM to factory defaults"
    log_warn "This wipes NPM's config DB at ${DOCKER_ROOT}/data/nginx-proxy-manager/data (proxy hosts, NPM users)."
    if [[ "$ASSUME_YES" -ne 1 ]]; then
        read -r -p "Proceed with NPM reset? [y/N] " ans
        [[ "${ans:-N}" =~ ^[Yy]$ ]] || die "Aborted by user."
    fi
    compose_cmd nginx-proxy-manager down || true
    rm -rf "${DOCKER_ROOT:?}/data/nginx-proxy-manager/data/"* 2>/dev/null || true
    compose_cmd nginx-proxy-manager up -d
    log_ok "NPM reset; it will re-seed the factory admin on startup."
fi

# -----------------------------------------------------------------------------
# 2. Wait for the NPM API
# -----------------------------------------------------------------------------
log_step "Waiting for Nginx Proxy Manager API"
for _ in $(seq 1 60); do
    if curl -fsS "${NPM_API}/" >/dev/null 2>&1; then ready=1; break; fi
    sleep 2
done
[[ "${ready:-}" == "1" ]] || die "NPM API not reachable at ${NPM_API} (is the npm container running?)"
log_ok "NPM API is up."

# -----------------------------------------------------------------------------
# 3. Authenticate
# -----------------------------------------------------------------------------
# get_token <email> <password> : echo the bearer token or empty on failure.
get_token() {
    curl -fsS -X POST "${NPM_API}/tokens" \
        -H 'Content-Type: application/json' \
        -d "$(jq -n --arg i "$1" --arg s "$2" '{identity:$i, secret:$s}')" \
        2>/dev/null | jq -r '.token // empty'
}

# npm_is_setup : echo "true" if NPM already has an admin user, else "false"
# (NPM >= 2.x exposes this via GET /api/). Empty if the field is absent.
npm_is_setup() {
    curl -fsS "${NPM_API}/" 2>/dev/null | jq -r '.setup // empty'
}

# create_first_user : on a fresh NPM (>= ~2.11 no longer ships a default admin)
# the first admin is created via an unauthenticated POST /api/users carrying the
# password in a nested auth block. No-op/ignored once a user already exists.
create_first_user() {
    log_info "No admin configured yet - creating the first admin ${ADMIN_EMAIL}."
    curl -fsS -X POST "${NPM_API}/users" \
        -H 'Content-Type: application/json' \
        -d "$(jq -n --arg e "$ADMIN_EMAIL" --arg s "$NPM_ADMIN_PASSWORD" \
            '{name:"Administrator", nickname:"Admin", email:$e, roles:["admin"],
              is_disabled:false, auth:{type:"password", secret:$s}}')" \
        >/dev/null 2>&1 || true
}

# claim_default_account : legacy path for older NPM that DID ship the factory
# default admin@example.com/changeme. Sets it to ${ADMIN_EMAIL}/${NPM_ADMIN_PASSWORD}.
claim_default_account() {
    local def_token uid
    def_token="$(get_token "$DEFAULT_EMAIL" "$DEFAULT_PASS" || true)"
    [[ -n "$def_token" ]] || return 1
    log_info "Factory default detected - claiming the admin account."
    uid="$(curl -fsS "${NPM_API}/users/me" -H "Authorization: Bearer ${def_token}" 2>/dev/null | jq -r '.id' || true)"
    curl -fsS -X PUT "${NPM_API}/users/${uid}" \
        -H "Authorization: Bearer ${def_token}" -H 'Content-Type: application/json' \
        -d "$(jq -n --arg e "$ADMIN_EMAIL" '{name:"Administrator", nickname:"Admin", email:$e, roles:["admin"], is_disabled:false}')" \
        >/dev/null 2>&1 || true
    curl -fsS -X PUT "${NPM_API}/users/${uid}/auth" \
        -H "Authorization: Bearer ${def_token}" -H 'Content-Type: application/json' \
        -d "$(jq -n --arg c "$DEFAULT_PASS" --arg s "$NPM_ADMIN_PASSWORD" '{type:"password", current:$c, secret:$s}')" \
        >/dev/null 2>&1 || true
    log_ok "Admin account set to ${ADMIN_EMAIL} with the generated password."
    return 0
}

log_step "Authenticating with NPM"
# Retry: NPM may answer /api/ before it is fully ready. Each round: try the
# configured creds; if NPM has no admin yet, bootstrap the first user; otherwise
# fall back to claiming a legacy factory-default admin.
TOKEN=""
for _ in $(seq 1 40); do
    TOKEN="$(get_token "$ADMIN_EMAIL" "$NPM_ADMIN_PASSWORD" || true)"
    [[ -n "$TOKEN" ]] && break

    if [[ "$(npm_is_setup)" == "false" ]]; then
        create_first_user
        TOKEN="$(get_token "$ADMIN_EMAIL" "$NPM_ADMIN_PASSWORD" || true)"
        [[ -n "$TOKEN" ]] && break
    fi

    if claim_default_account; then
        TOKEN="$(get_token "$ADMIN_EMAIL" "$NPM_ADMIN_PASSWORD" || true)"
        [[ -n "$TOKEN" ]] && break
    fi
    sleep 2
done

if [[ -z "$TOKEN" ]]; then
    log_error "Could not authenticate to NPM after retries."
    log_info "NPM status (GET /api/):"
    curl -sS "${NPM_API}/" 2>&1 | head -n 5 || true
    echo
    die "NPM already has an admin that is not ${ADMIN_EMAIL}/NPM_ADMIN_PASSWORD. Set NPM_ADMIN_PASSWORD in .secrets.env to the real password, or reset NPM with: sudo $0 --reset-npm  (see docs/TROUBLESHOOTING.md)."
fi
AUTH=(-H "Authorization: Bearer ${TOKEN}")
log_ok "Authenticated as ${ADMIN_EMAIL}."

# -----------------------------------------------------------------------------
# 4. Upload the certificate (reuse if it already exists)
# -----------------------------------------------------------------------------
log_step "Registering the certificate in NPM"
CERT_ID="$(curl -fsS "${NPM_API}/nginx/certificates" "${AUTH[@]}" \
    | jq -r --arg n "$CERT_NAME" '.[] | select(.nice_name==$n) | .id' | head -n1)"

if [[ -n "$CERT_ID" ]]; then
    log_ok "Certificate already registered (id ${CERT_ID})."
else
    CERT_ID="$(curl -fsS -X POST "${NPM_API}/nginx/certificates" "${AUTH[@]}" \
        -H 'Content-Type: application/json' \
        -d "$(jq -n --arg n "$CERT_NAME" '{provider:"other", nice_name:$n}')" \
        | jq -r '.id')"
    [[ -n "$CERT_ID" && "$CERT_ID" != "null" ]] || die "Failed to create certificate entry."
    curl -fsS -X POST "${NPM_API}/nginx/certificates/${CERT_ID}/upload" "${AUTH[@]}" \
        -F "certificate=@${CRT}" \
        -F "certificate_key=@${KEY}" >/dev/null
    log_ok "Certificate uploaded (id ${CERT_ID})."
fi

# -----------------------------------------------------------------------------
# 5. Create proxy hosts for the enabled services
# -----------------------------------------------------------------------------
log_step "Creating proxy hosts"

# stack -> "subdomain_value forward_host forward_port websocket(0/1)"
declare -A FORWARD=(
    [n8n]="${N8N_SUBDOMAIN:-n8n} n8n 5678 1"
    [gitea]="${GITEA_SUBDOMAIN:-git} gitea 3000 0"
    [semaphore]="${SEMAPHORE_SUBDOMAIN:-automation} semaphore 3000 1"
)

EXISTING="$(curl -fsS "${NPM_API}/nginx/proxy-hosts" "${AUTH[@]}" | jq -r '.[].domain_names[]')"

create_proxy_host() {
    local fqdn="$1" host="$2" port="$3" ws="$4"
    if grep -qxF "$fqdn" <<<"$EXISTING"; then
        log_ok "Proxy host already exists: ${fqdn}"
        return 0
    fi
    local payload
    payload="$(jq -n \
        --arg d "$fqdn" --arg h "$host" --argjson p "$port" \
        --argjson cid "$CERT_ID" --argjson ws "$([[ "$ws" == "1" ]] && echo true || echo false)" \
        '{domain_names:[$d], forward_scheme:"http", forward_host:$h, forward_port:$p,
          certificate_id:$cid, ssl_forced:true, http2_support:true, hsts_enabled:false,
          block_exploits:true, caching_enabled:false, allow_websocket_upgrade:$ws,
          access_list_id:0, advanced_config:"", locations:[], meta:{}}')"
    if curl -fsS -X POST "${NPM_API}/nginx/proxy-hosts" "${AUTH[@]}" \
        -H 'Content-Type: application/json' -d "$payload" >/dev/null; then
        log_ok "Created proxy host: ${fqdn} -> ${host}:${port}"
    else
        log_warn "Failed to create proxy host for ${fqdn}."
    fi
}

for stack in $(stacks_list); do
    [[ -n "${FORWARD[$stack]:-}" ]] || continue
    read -r sub host port ws <<<"${FORWARD[$stack]}"
    create_proxy_host "${sub}.${DOMAIN}" "$host" "$port" "$ws"
done

# -----------------------------------------------------------------------------
# 6. Report
# -----------------------------------------------------------------------------
log_step "Proxy setup complete"
cat <<EOF

${C_OK}${C_BOLD}NPM is configured.${C_RESET}

  Wildcard certificate : *.${DOMAIN}  (self-signed, id ${CERT_ID})
  NPM admin login       : ${ADMIN_EMAIL}  (password in $(SECRETS_FILE))

  Proxy hosts (HTTPS, SSL forced):
EOF
for stack in $(stacks_list); do
    [[ -n "${FORWARD[$stack]:-}" ]] || continue
    read -r sub host port ws <<<"${FORWARD[$stack]}"
    printf '    https://%s.%s  ->  %s:%s\n' "$sub" "$DOMAIN" "$host" "$port"
done
cat <<EOF

  NOTE: the certificate is self-signed - browsers will warn until you trust it.
  Ensure DNS for the above names resolves to this host.

EOF
