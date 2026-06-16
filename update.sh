#!/usr/bin/env bash
# =============================================================================
# update.sh - Pull the latest project changes and container images, then
# recreate the running stacks.
#
#   sudo ./update.sh
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "${SCRIPT_DIR}/lib/common.sh"

require_root
load_env

# Pull repo changes if this is a git checkout.
if git -C "${SCRIPT_DIR}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    log_step "Updating project repository"
    git -C "${SCRIPT_DIR}" pull --ff-only || log_warn "git pull skipped/failed; continuing."
    # Re-sync compose files & scripts to the runtime location.
    cp -r "${SCRIPT_DIR}/compose/." "${DOCKER_ROOT}/compose/"
    cp "${SCRIPT_DIR}/scripts/"*.sh "${DOCKER_ROOT}/scripts/" 2>/dev/null || true
fi

log_step "Pulling images and recreating stacks"
for stack in $(stacks_list); do
    [[ -f "${DOCKER_ROOT}/compose/${stack}/docker-compose.yml" ]] || continue
    log_info "Updating stack: ${stack}"
    compose_cmd "$stack" pull
    compose_cmd "$stack" up -d
done

log_step "Pruning unused images"
docker image prune -f

log_ok "Update complete."
