#!/usr/bin/env bash
# =============================================================================
# teardown.sh - Cleanly remove the LabMaster Docker environment. Primarily a
# TEST helper to reset between install runs.
#
#   sudo ./teardown.sh [--volumes] [--data] [--all] [--yes]
#
# Default            : stop/remove all stack containers + the 'proxy' network.
#                      Persistent data under ${DOCKER_ROOT}/data is KEPT.
#   --volumes        : also remove named/anonymous compose volumes (down -v).
#   --data           : also delete ${DOCKER_ROOT}/data/* (bind-mounted data).
#   --all            : shorthand for --volumes --data.
#   --yes            : skip the confirmation prompt (non-interactive).
#
# Does NOT touch .env / .secrets.env and does NOT uninstall Docker itself.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Resolve lib/common.sh whether run from the repo or from /opt/docker/scripts.
for _cand in "${SCRIPT_DIR}/lib/common.sh" "${SCRIPT_DIR}/../lib/common.sh" "/opt/docker/lib/common.sh"; do
    # shellcheck source=lib/common.sh
    [[ -r "$_cand" ]] && { . "$_cand"; _COMMON_LOADED=1; break; }
done
[[ -n "${_COMMON_LOADED:-}" ]] || { echo "[FAIL] lib/common.sh not found." >&2; exit 1; }

REMOVE_VOLUMES=0
REMOVE_DATA=0
ASSUME_YES=0

for arg in "$@"; do
    case "$arg" in
        --volumes) REMOVE_VOLUMES=1 ;;
        --data)    REMOVE_DATA=1 ;;
        --all)     REMOVE_VOLUMES=1; REMOVE_DATA=1 ;;
        --yes|-y)  ASSUME_YES=1 ;;
        -h|--help) grep -E '^#( |$)' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) die "Unknown option: $arg (try --help)" ;;
    esac
done

require_root
load_env

# --- Show what will happen --------------------------------------------------
log_step "Teardown plan"
echo "  - Stop & remove containers for: $(stacks_list | tr '\n' ' ')"
echo "  - Remove Docker network 'proxy' (if present)"
[[ "$REMOVE_VOLUMES" -eq 1 ]] && echo "  - Remove compose volumes (down -v)" \
    || echo "  - KEEP compose volumes"
[[ "$REMOVE_DATA" -eq 1 ]] && echo "  - DELETE ${DOCKER_ROOT}/data/* (persistent data!)" \
    || echo "  - KEEP persistent data under ${DOCKER_ROOT}/data"
echo "  - KEEP .env / .secrets.env and Docker itself"

if [[ "$ASSUME_YES" -ne 1 ]]; then
    read -r -p "Proceed? [y/N] " ans
    [[ "${ans:-N}" =~ ^[Yy]$ ]] || die "Aborted by user."
fi

# --- Stop / remove stacks ---------------------------------------------------
log_step "Stopping stacks"
down_args=()
[[ "$REMOVE_VOLUMES" -eq 1 ]] && down_args+=(-v)
for stack in $(stacks_list); do
    if [[ -f "${DOCKER_ROOT}/compose/${stack}/docker-compose.yml" ]]; then
        log_info "Removing stack: ${stack}"
        compose_cmd "$stack" down "${down_args[@]}" || log_warn "down failed for ${stack}; continuing."
    fi
done

# --- Remove the shared network ----------------------------------------------
log_step "Removing 'proxy' network"
if docker network inspect proxy >/dev/null 2>&1; then
    docker network rm proxy >/dev/null 2>&1 && log_ok "Network 'proxy' removed." \
        || log_warn "Could not remove 'proxy' (still in use?)."
else
    log_ok "Network 'proxy' not present."
fi

# --- Optionally delete persistent data --------------------------------------
if [[ "$REMOVE_DATA" -eq 1 ]]; then
    log_step "Deleting persistent data"
    if [[ -d "${DOCKER_ROOT}/data" ]]; then
        rm -rf "${DOCKER_ROOT:?}/data/"*
        log_ok "Removed contents of ${DOCKER_ROOT}/data."
    fi
fi

log_step "Teardown complete"
log_ok "Environment reset. Re-run ./install.sh to provision again."
