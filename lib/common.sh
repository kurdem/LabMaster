#!/usr/bin/env bash
# =============================================================================
# lib/common.sh - Shared functions for the LabMaster bootstrap scripts.
# Source this file; do not execute it directly.
# =============================================================================

# --- Logging ----------------------------------------------------------------
if [[ -t 1 ]]; then
    C_RESET=$'\033[0m'; C_INFO=$'\033[0;34m'; C_OK=$'\033[0;32m'
    C_WARN=$'\033[0;33m'; C_ERR=$'\033[0;31m'; C_BOLD=$'\033[1m'
else
    C_RESET=""; C_INFO=""; C_OK=""; C_WARN=""; C_ERR=""; C_BOLD=""
fi

log_info()  { printf '%s[INFO]%s  %s\n'  "$C_INFO" "$C_RESET" "$*"; }
log_ok()    { printf '%s[ OK ]%s  %s\n'  "$C_OK"   "$C_RESET" "$*"; }
log_warn()  { printf '%s[WARN]%s  %s\n'  "$C_WARN" "$C_RESET" "$*" >&2; }
log_error() { printf '%s[FAIL]%s  %s\n'  "$C_ERR"  "$C_RESET" "$*" >&2; }
log_step()  { printf '\n%s==>%s %s%s%s\n' "$C_INFO" "$C_RESET" "$C_BOLD" "$*" "$C_RESET"; }

die() { log_error "$*"; exit 1; }

# --- Environment / privilege checks -----------------------------------------

# require_root: abort unless running as root (sudo).
require_root() {
    if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
        die "This script must be run as root or via sudo."
    fi
}

# check_os: verify the host is Ubuntu and warn if not an LTS release.
check_os() {
    [[ -r /etc/os-release ]] || die "Cannot read /etc/os-release - unsupported OS."
    # shellcheck disable=SC1091
    . /etc/os-release
    if [[ "${ID:-}" != "ubuntu" ]]; then
        die "Unsupported OS '${ID:-unknown}'. This project targets Ubuntu Server LTS."
    fi
    # LTS releases use an even year and the .04 release (e.g. 20.04, 22.04, 24.04).
    if [[ ! "${VERSION_ID:-}" =~ ^(20|22|24|26)\.04$ ]]; then
        log_warn "Ubuntu ${VERSION_ID:-?} is not a recognised LTS release; continuing anyway."
    else
        log_ok "Detected Ubuntu ${VERSION_ID} LTS (${VERSION_CODENAME:-})."
    fi
}

# --- Paths / config ---------------------------------------------------------
# Resolve the repository root (directory containing this lib/).
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# DOCKER_ROOT default; overridden by .env if present.
DOCKER_ROOT="${DOCKER_ROOT:-/opt/docker}"

ENV_FILE() { echo "${DOCKER_ROOT}/.env"; }
SECRETS_FILE() { echo "${DOCKER_ROOT}/.secrets.env"; }

# load_env: source the runtime .env and .secrets.env (if present).
load_env() {
    local env_file secrets_file
    env_file="$(ENV_FILE)"; secrets_file="$(SECRETS_FILE)"
    if [[ -r "$env_file" ]]; then
        set -a; # shellcheck disable=SC1090
        . "$env_file"; set +a
    fi
    if [[ -r "$secrets_file" ]]; then
        set -a; # shellcheck disable=SC1090
        . "$secrets_file"; set +a
    fi
    DOCKER_ROOT="${DOCKER_ROOT:-/opt/docker}"
}

# _ask <varname> <prompt> : read a value, defaulting to the variable's current
# value (shown in brackets). Used by setup_env_interactive.
_ask() {
    local __var="$1" __prompt="$2" __default="${!1:-}" __input
    read -r -p "  ${__prompt} [${__default}]: " __input
    printf -v "$__var" '%s' "${__input:-$__default}"
}

# _set_env_value <file> <key> <value> : replace KEY=... in file, or append it.
_set_env_value() {
    local file="$1" key="$2" val="$3"
    if grep -qE "^${key}=" "$file"; then
        # '|' delimiter avoids clashing with '/' in values (e.g. timezones).
        sed -i "s|^${key}=.*|${key}=${val}|" "$file"
    else
        printf '%s=%s\n' "$key" "$val" >> "$file"
    fi
}

# setup_env_interactive : create ${DOCKER_ROOT}/.env on first run.
# Interactive (TTY) -> prompt for the central values using .env.example as the
# default source. Non-interactive (no TTY or ASSUME_DEFAULTS=1) -> copy the
# template unchanged so unattended installs still work.
setup_env_interactive() {
    local example="${REPO_ROOT}/.env.example"
    local target; target="$(ENV_FILE)"
    [[ -f "$example" ]] || die "Template not found: $example"

    if [[ "${ASSUME_DEFAULTS:-0}" == "1" || ! -t 0 ]]; then
        cp "$example" "$target"
        log_warn "Non-interactive mode: created ${target} from defaults. Review DOMAIN/TIMEZONE before production use."
        return 0
    fi

    # Load the template values as defaults for the prompts.
    local DOMAIN TIMEZONE N8N_SUBDOMAIN GITEA_SUBDOMAIN SEMAPHORE_SUBDOMAIN \
          GITEA_SSH_PORT CADDY_HTTP_PORT CADDY_HTTPS_PORT CADDY_TLS_MODE
    set -a; # shellcheck disable=SC1090
    . "$example"; set +a

    log_info "First-time configuration - press Enter to accept each [default]:"
    _ask DOMAIN             "Base domain"
    _ask TIMEZONE           "Timezone"
    _ask N8N_SUBDOMAIN      "n8n subdomain"
    _ask GITEA_SUBDOMAIN    "Gitea subdomain"
    _ask SEMAPHORE_SUBDOMAIN "Semaphore subdomain"
    _ask GITEA_SSH_PORT     "Gitea SSH port"
    _ask CADDY_HTTP_PORT    "Caddy HTTP port"
    _ask CADDY_HTTPS_PORT   "Caddy HTTPS port"
    _ask CADDY_TLS_MODE     "TLS mode (letsencrypt/internal)"

    # Start from the template, then override the prompted keys.
    cp "$example" "$target"
    local k
    for k in DOMAIN TIMEZONE N8N_SUBDOMAIN GITEA_SUBDOMAIN SEMAPHORE_SUBDOMAIN \
             GITEA_SSH_PORT CADDY_HTTP_PORT CADDY_HTTPS_PORT CADDY_TLS_MODE; do
        _set_env_value "$target" "$k" "${!k}"
    done
    log_ok "Configuration written to ${target}"
}

# --- Secrets ----------------------------------------------------------------
# gen_secret [bytes] : URL-safe random secret (base64, default 32 bytes).
gen_secret() {
    local bytes="${1:-32}"
    openssl rand -base64 "$bytes" | tr -d '\n/+=' | cut -c1-"${bytes}"
}

# gen_hex [bytes] : random hex string (default 16 bytes => 32 chars).
gen_hex() {
    openssl rand -hex "${1:-16}"
}

# ensure_secret <KEY> <value> : guarantee KEY exists in the secrets file.
# Keeps an existing value; otherwise appends <value> and exports it. Lets hosts
# provisioned before a new secret was introduced self-heal on the next run.
ensure_secret() {
    local key="$1" val="$2" file; file="$(SECRETS_FILE)"
    if [[ -f "$file" ]] && grep -qE "^${key}=" "$file"; then
        return 0
    fi
    umask 077
    mkdir -p "$(dirname "$file")"
    printf '%s=%s\n' "$key" "$val" >> "$file"
    chmod 600 "$file"
    export "${key}=${val}"
    log_info "Added missing secret ${key} to ${file}"
}

# --- Semaphore image selection ----------------------------------------------
# Semaphore executes its tasks inside the server container (no separate runner
# in this setup), so PowerShell support depends on which image tag is used.
# The PowerShell-enabled images only exist as pinned tags of the form
# vX.Y.Z-powershellN.N.N - there is no rolling "latest-powershell" tag, and
# plain "latest" is the thin image WITHOUT PowerShell.

# resolve_semaphore_powershell_tag : echo the newest STABLE -powershell tag from
# Docker Hub (alpha/beta excluded). Returns non-zero if none could be resolved.
resolve_semaphore_powershell_tag() {
    local api="https://hub.docker.com/v2/repositories/semaphoreui/semaphore/tags/?page_size=100"
    local tag
    tag="$(curl -fsSL "$api" 2>/dev/null \
        | jq -r '.results[].name' 2>/dev/null \
        | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+-powershell[0-9.]+$' \
        | sort -V | tail -n1)"
    [[ -n "$tag" ]] || return 1
    printf '%s\n' "$tag"
}

# ensure_semaphore_image_tag : keep SEMAPHORE_IMAGE_TAG pointed at a PowerShell
# image. When SEMAPHORE_IMAGE_AUTO=1 (default) resolve the newest stable tag and
# persist it to the runtime .env; on failure keep the existing/default value and
# warn. When SEMAPHORE_IMAGE_AUTO=0 leave the manually pinned value untouched.
ensure_semaphore_image_tag() {
    local target; target="$(ENV_FILE)"
    [[ -f "$target" ]] || return 0
    if [[ "${SEMAPHORE_IMAGE_AUTO:-1}" != "1" ]]; then
        log_info "SEMAPHORE_IMAGE_AUTO=0 - keeping pinned SEMAPHORE_IMAGE_TAG=${SEMAPHORE_IMAGE_TAG:-<unset>}."
        return 0
    fi
    local tag
    if tag="$(resolve_semaphore_powershell_tag)"; then
        if [[ "$tag" != "${SEMAPHORE_IMAGE_TAG:-}" ]]; then
            _set_env_value "$target" SEMAPHORE_IMAGE_TAG "$tag"
            export SEMAPHORE_IMAGE_TAG="$tag"
            log_ok "Semaphore PowerShell image set to ${tag}."
        else
            log_ok "Semaphore PowerShell image already current (${tag})."
        fi
    else
        log_warn "Could not resolve latest Semaphore PowerShell tag (network/API?); keeping SEMAPHORE_IMAGE_TAG=${SEMAPHORE_IMAGE_TAG:-<default>}."
    fi
}

# --- Docker helpers ---------------------------------------------------------
# compose_cmd <service> <args...> : run docker compose for a stack using the
# central env + secrets files.
compose_cmd() {
    local service="$1"; shift
    local file="${DOCKER_ROOT}/compose/${service}/docker-compose.yml"
    [[ -f "$file" ]] || die "Compose file not found: $file"
    docker compose \
        --project-name "$service" \
        --env-file "$(ENV_FILE)" \
        --env-file "$(SECRETS_FILE)" \
        -f "$file" "$@"
}

# stacks_list : echo the configured STACKS (falls back to all compose folders).
stacks_list() {
    if [[ -n "${STACKS:-}" ]]; then
        echo "$STACKS"
    else
        find "${DOCKER_ROOT}/compose" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null
    fi
}

# sync_stacks : add newly shipped compose/<stack> folders to STACKS in the
# runtime .env so project updates roll out without manual .env edits. Opt out
# with STACKS_AUTO=0.
#
# Removal-aware via the bookkeeping key STACKS_KNOWN (every stack ever offered).
# A shipped stack is "new" only if it is not in STACKS_KNOWN, so a stack you
# delete from STACKS afterwards stays gone. STACKS_KNOWN is seeded from the
# currently enabled STACKS on first run; consequently, if you had already
# removed a default stack before this feature existed, it may be re-added once.
sync_stacks() {
    local target; target="$(ENV_FILE)"
    [[ -f "$target" ]] || return 0
    if [[ "${STACKS_AUTO:-1}" != "1" ]]; then
        log_info "STACKS_AUTO=0 - not auto-updating STACKS."
        return 0
    fi
    local compose_dir="${DOCKER_ROOT}/compose"
    [[ -d "$compose_dir" ]] || return 0

    # Seed the "known" set from the enabled stacks the first time we run.
    local seeded=0
    [[ -z "${STACKS_KNOWN:-}" ]] && { STACKS_KNOWN="${STACKS:-}"; seeded=1; }

    local -a enabled=(${STACKS:-}) known=(${STACKS_KNOWN:-}) added=()
    local s h found
    for s in $(find "$compose_dir" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | sort); do
        [[ -f "${compose_dir}/${s}/docker-compose.yml" ]] || continue
        found=0
        for h in "${known[@]}"; do [[ "$h" == "$s" ]] && { found=1; break; }; done
        if [[ "$found" -eq 0 ]]; then
            enabled+=("$s"); known+=("$s"); added+=("$s")
        fi
    done

    if [[ "${#added[@]}" -gt 0 ]]; then
        _set_env_value "$target" STACKS "\"${enabled[*]}\""
        export STACKS="${enabled[*]}"
        log_ok "Added new stack(s) to STACKS: ${added[*]}"
    fi
    if [[ "${#added[@]}" -gt 0 || "$seeded" -eq 1 ]]; then
        _set_env_value "$target" STACKS_KNOWN "\"${known[*]}\""
        export STACKS_KNOWN="${known[*]}"
    fi
}

# --- Reverse proxy (Caddy) --------------------------------------------------
# Caddy replaces Nginx Proxy Manager: TLS is automatic (ACME) and configuration
# is a generated Caddyfile, so there is no admin UI/API or admin password.

# _caddy_azure_ready : true if the Azure DNS-01 challenge can be used. Both the
# subscription and resource group are always required; tenant/client/secret may
# be empty when a Managed Identity is used instead of a service principal.
_caddy_azure_ready() {
    [[ -n "${AZURE_SUBSCRIPTION_ID:-}" && -n "${AZURE_RESOURCE_GROUP_NAME:-}" ]]
}

# _caddy_dns_block : emit the provider-specific `dns` directive (indented for a
# per-site `tls { ... }` block). Credentials are referenced as {$ENV} so they
# stay in the container environment and never land in the Caddyfile on disk.
_caddy_dns_block() {
    case "${CADDY_DNS_PROVIDER:-azure}" in
        azure)
            printf '\t\tdns azure {\n'
            printf '\t\t\tsubscription_id {$AZURE_SUBSCRIPTION_ID}\n'
            printf '\t\t\tresource_group_name {$AZURE_RESOURCE_GROUP_NAME}\n'
            printf '\t\t\ttenant_id {$AZURE_TENANT_ID}\n'
            printf '\t\t\tclient_id {$AZURE_CLIENT_ID}\n'
            printf '\t\t\tclient_secret {$AZURE_CLIENT_SECRET}\n'
            printf '\t\t}\n'
            ;;
        *)
            # Other caddy-dns/* providers read their own {$ENV} config; emit a
            # bare directive and let the provider pick its environment up.
            printf '\t\tdns %s\n' "${CADDY_DNS_PROVIDER}"
            ;;
    esac
}

# generate_caddyfile : render ${DOCKER_ROOT}/data/caddy/Caddyfile from the
# enabled STACKS. TLS strategy follows CADDY_TLS_MODE (default letsencrypt) and
# CADDY_DNS_PROVIDER (default azure); falls back to self-signed (tls internal)
# when ACME-DNS is requested but its credentials are missing, so the proxy
# always starts.
generate_caddyfile() {
    local out="${DOCKER_ROOT}/data/caddy/Caddyfile"
    local mode="${CADDY_TLS_MODE:-letsencrypt}"
    # Note '-' (not ':-'): an unset provider defaults to azure, but an explicitly
    # empty CADDY_DNS_PROVIDER means "use the HTTP/TLS-ALPN challenge".
    local provider="${CADDY_DNS_PROVIDER-azure}"
    local email="${CADDY_ACME_EMAIL:-admin@${DOMAIN:-localhost}}"

    [[ -n "${DOMAIN:-}" ]] || { log_warn "DOMAIN not set; skipping Caddyfile generation."; return 0; }

    # Decide the effective TLS strategy: internal | acme-dns | acme-http.
    local strategy
    if [[ "$mode" == "internal" ]]; then
        strategy="internal"
    elif [[ -z "$provider" ]]; then
        strategy="acme-http"
    elif [[ "$provider" == "azure" ]] && _caddy_azure_ready; then
        strategy="acme-dns"
    elif [[ "$provider" == "azure" ]]; then
        log_warn "CADDY_TLS_MODE=letsencrypt with azure DNS, but AZURE_SUBSCRIPTION_ID/AZURE_RESOURCE_GROUP_NAME are unset; falling back to self-signed (tls internal). Fill them in $(SECRETS_FILE), then run setup-caddy.sh."
        strategy="internal"
    else
        strategy="acme-dns"   # other providers: trust the user's configuration
    fi

    # stack -> "subdomain_value forward_host forward_port" (Caddy handles
    # WebSockets automatically, so no per-route flag is needed).
    declare -A FORWARD=(
        [n8n]="${N8N_SUBDOMAIN:-n8n} n8n 5678"
        [gitea]="${GITEA_SUBDOMAIN:-git} gitea 3000"
        [semaphore]="${SEMAPHORE_SUBDOMAIN:-automation} semaphore 3000"
        [dockhand]="${DOCKHAND_SUBDOMAIN:-dockhand} dockhand 3000"
    )

    mkdir -p "$(dirname "$out")"
    {
        printf '# Managed by LabMaster (generate_caddyfile) - do not edit by hand.\n'
        printf '# TLS strategy: %s\n\n' "$strategy"
        if [[ "$strategy" == acme-* ]]; then
            printf '{\n\temail %s\n' "$email"
            [[ -n "${CADDY_ACME_CA:-}" ]] && printf '\tacme_ca %s\n' "$CADDY_ACME_CA"
            printf '}\n\n'
        fi
        local stack sub host port
        for stack in $(stacks_list); do
            [[ -n "${FORWARD[$stack]:-}" ]] || continue
            read -r sub host port <<<"${FORWARD[$stack]}"
            printf '%s.%s {\n' "$sub" "$DOMAIN"
            case "$strategy" in
                internal)  printf '\ttls internal\n' ;;
                acme-dns)  printf '\ttls {\n'; _caddy_dns_block; printf '\t}\n' ;;
                acme-http) : ;;   # Caddy negotiates ACME (HTTP/TLS-ALPN) itself
            esac
            printf '\treverse_proxy %s:%s\n' "$host" "$port"
            printf '}\n\n'
        done
    } > "$out"
    log_ok "Caddyfile written to ${out} (TLS: ${strategy})."
}

# reload_caddy : hot-reload the running Caddy container after a Caddyfile change
# (a file-only change does not trigger a compose recreate). No-op if not running.
reload_caddy() {
    docker ps --format '{{.Names}}' 2>/dev/null | grep -qx caddy || return 0
    if docker exec caddy caddy reload --config /etc/caddy/Caddyfile >/dev/null 2>&1; then
        log_ok "Caddy configuration reloaded."
    else
        log_warn "caddy reload failed; restarting the caddy stack."
        compose_cmd caddy restart || true
    fi
}

# migrate_npm_to_caddy : one-time migration on hosts provisioned with Nginx
# Proxy Manager. Stops/removes the NPM stack (freeing ports 80/443), drops it
# from STACKS/STACKS_KNOWN in the runtime .env, and keeps NPM's data dir. No-op
# on fresh hosts (the runtime .env is never overwritten, hence the need for this).
migrate_npm_to_caddy() {
    local npm_dir="${DOCKER_ROOT}/compose/nginx-proxy-manager"
    [[ -f "${npm_dir}/docker-compose.yml" ]] || return 0
    local target; target="$(ENV_FILE)"
    log_step "Migrating reverse proxy: Nginx Proxy Manager -> Caddy"
    compose_cmd nginx-proxy-manager down 2>/dev/null || true
    rm -rf "$npm_dir"
    log_info "Removed the nginx-proxy-manager stack (data/nginx-proxy-manager is kept)."
    if [[ -f "$target" ]]; then
        local key cur s
        for key in STACKS STACKS_KNOWN; do
            cur="${!key:-}"
            local -a kept=()
            for s in $cur; do [[ "$s" == "nginx-proxy-manager" ]] || kept+=("$s"); done
            _set_env_value "$target" "$key" "\"${kept[*]}\""
            export "${key}=${kept[*]}"
        done
    fi
    log_ok "Caddy now replaces NPM as the reverse proxy."
}
