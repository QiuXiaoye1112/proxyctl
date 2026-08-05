#!/usr/bin/env bash
# ------------------------------------------------------------------------------
# backup.sh — Backup and restore proxy configurations
# ------------------------------------------------------------------------------

# --- backup_create ----------------------------------------------------------
backup_create() {
    local label="${1:-}"
    # Stub — mutating operation, must fail closed.
    error "Backup creation is not implemented."
    return 1
}

# --- backup_list ------------------------------------------------------------
backup_list() {
    # Stub — query stub, warn and fail.
    warn "Backup listing is not implemented."
    return 1
}

# --- backup_restore ---------------------------------------------------------
backup_restore() {
    local backup_id="$1"
    # Stub — mutating operation, must fail closed.
    error "Backup restore is not implemented."
    return 1
}
