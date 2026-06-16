#!/usr/bin/env bash
# =============================================================================
# restore.sh - Restore a LabMaster backup archive and restart the stacks.
#
#   sudo ./restore.sh /opt/docker/backups/labmaster-backup-YYYYmmdd-HHMMSS.tar.gz
#
# If no archive is given, the most recent one in ${DOCKER_ROOT}/backups is used.
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

ARCHIVE="${1:-}"
if [[ -z "${ARCHIVE}" ]]; then
    # shellcheck disable=SC2012
    ARCHIVE="$(ls -1t "${DOCKER_ROOT}/backups"/labmaster-backup-*.tar.gz 2>/dev/null | head -n1 || true)"
    [[ -n "${ARCHIVE}" ]] || die "No backup archive found in ${DOCKER_ROOT}/backups."
    log_info "No archive specified; using newest: ${ARCHIVE}"
fi
[[ -f "${ARCHIVE}" ]] || die "Archive not found: ${ARCHIVE}"

log_warn "This will stop all stacks and overwrite data under ${DOCKER_ROOT}."
read -r -p "Continue? [y/N] " ans
[[ "${ans:-N}" =~ ^[Yy]$ ]] || die "Aborted by user."

# --- Stop running stacks ----------------------------------------------------
log_step "Stopping stacks"
for stack in $(stacks_list); do
    [[ -f "${DOCKER_ROOT}/compose/${stack}/docker-compose.yml" ]] || continue
    compose_cmd "$stack" down || true
done

# --- Extract archive --------------------------------------------------------
log_step "Restoring files from ${ARCHIVE}"
tar xzf "${ARCHIVE}" -C "${DOCKER_ROOT}"
chmod 600 "$(SECRETS_FILE)" 2>/dev/null || true
load_env
log_ok "Files restored."

# --- Restart stacks ---------------------------------------------------------
log_step "Starting stacks"
for stack in $(stacks_list); do
    [[ -f "${DOCKER_ROOT}/compose/${stack}/docker-compose.yml" ]] || continue
    compose_cmd "$stack" up -d
done

# --- Restore Postgres dump (if present) -------------------------------------
DUMP="$(ls -1t "${DOCKER_ROOT}/data/semaphore/dump"/semaphore-*.sql 2>/dev/null | head -n1 || true)"
if [[ -n "${DUMP}" ]]; then
    log_step "Restoring Semaphore database from $(basename "${DUMP}")"
    # Wait for the DB to accept connections.
    for _ in $(seq 1 30); do
        docker exec semaphore-db pg_isready -U semaphore >/dev/null 2>&1 && break
        sleep 2
    done
    docker exec -i semaphore-db psql -U semaphore -d semaphore < "${DUMP}" \
        && log_ok "Database restored." || log_warn "Database restore reported errors."
    compose_cmd semaphore restart || true
fi

log_ok "Restore complete."
