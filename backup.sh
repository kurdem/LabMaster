#!/usr/bin/env bash
# =============================================================================
# backup.sh - Back up volumes, compose files and configuration into a single
# timestamped archive under ${DOCKER_ROOT}/backups.
#
#   sudo ./backup.sh
#
# Produces a consistent Postgres dump for Semaphore, then archives the data
# tree, compose stacks, .env and .secrets.env.
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

TS="$(date -u +%Y%m%d-%H%M%S)"
BACKUP_DIR="${DOCKER_ROOT}/backups"
ARCHIVE="${BACKUP_DIR}/labmaster-backup-${TS}.tar.gz"
mkdir -p "${BACKUP_DIR}"

# --- Consistent DB dump (Semaphore Postgres) --------------------------------
DUMP_DIR="${DOCKER_ROOT}/data/semaphore/dump"
if docker ps --format '{{.Names}}' | grep -q '^semaphore-db$'; then
    log_step "Dumping Semaphore PostgreSQL database"
    mkdir -p "${DUMP_DIR}"
    docker exec semaphore-db pg_dump -U semaphore -d semaphore \
        > "${DUMP_DIR}/semaphore-${TS}.sql"
    log_ok "Database dump written."
fi

# --- Archive ----------------------------------------------------------------
log_step "Creating archive"
tar czf "${ARCHIVE}" \
    -C "${DOCKER_ROOT}" \
    --exclude='./backups' \
    --exclude='./data/semaphore/postgres' \
    data compose .env .secrets.env 2>/dev/null

log_ok "Backup created: ${ARCHIVE} ($(du -h "${ARCHIVE}" | cut -f1))"

# --- Retention --------------------------------------------------------------
RETENTION="${BACKUP_RETENTION:-7}"
if [[ "${RETENTION}" =~ ^[0-9]+$ && "${RETENTION}" -gt 0 ]]; then
    log_info "Applying retention: keeping ${RETENTION} most recent archives"
    # shellcheck disable=SC2012
    ls -1t "${BACKUP_DIR}"/labmaster-backup-*.tar.gz 2>/dev/null \
        | tail -n +"$((RETENTION + 1))" \
        | while read -r old; do
            log_info "Removing old backup: $(basename "$old")"
            rm -f "$old"
        done
fi

log_ok "Backup finished."
