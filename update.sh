#!/usr/bin/env bash
# =============================================================================
# update.sh - Pull the latest project changes and container images, then
# recreate the running stacks.
#
#   sudo ./update.sh
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Resolve lib/common.sh whether run from the repo or from /opt/docker/scripts.
for _cand in "${SCRIPT_DIR}/lib/common.sh" "${SCRIPT_DIR}/../lib/common.sh" "/opt/docker/lib/common.sh"; do
    # shellcheck source=lib/common.sh
    [[ -r "$_cand" ]] && { . "$_cand"; _COMMON_LOADED=1; break; }
done
[[ -n "${_COMMON_LOADED:-}" ]] || { echo "[FAIL] lib/common.sh not found." >&2; exit 1; }

require_root
load_env

# Bump the Semaphore image to the newest stable PowerShell tag (unless pinned via
# SEMAPHORE_IMAGE_AUTO=0) before pulling, so updates keep PowerShell support.
ensure_semaphore_image_tag

# Pull repo changes if this is a git checkout.
if git -C "${SCRIPT_DIR}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    log_step "Updating project repository"
    git -C "${SCRIPT_DIR}" pull --ff-only || log_warn "git pull skipped/failed; continuing."
    # Re-sync compose files, library and scripts to the runtime location.
    cp -r "${SCRIPT_DIR}/compose/." "${DOCKER_ROOT}/compose/"
    mkdir -p "${DOCKER_ROOT}/lib"
    cp "${SCRIPT_DIR}/lib/common.sh" "${DOCKER_ROOT}/lib/common.sh"
    cp "${SCRIPT_DIR}/scripts/"*.sh "${DOCKER_ROOT}/scripts/" 2>/dev/null || true
    for s in backup.sh restore.sh update.sh teardown.sh; do
        [[ -f "${SCRIPT_DIR}/${s}" ]] && cp "${SCRIPT_DIR}/${s}" "${DOCKER_ROOT}/scripts/"
    done
    chmod +x "${DOCKER_ROOT}/scripts/"*.sh 2>/dev/null || true
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
