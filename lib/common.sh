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
