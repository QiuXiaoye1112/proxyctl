#!/usr/bin/env bash
# ------------------------------------------------------------------------------
# transaction.sh — Atomic configuration transactions with rollback
#
# Phase 2.5: apply_candidate installs a new engine configuration safely:
#
#   config lock -> candidate snapshot -> core validation -> backup ->
#   same-directory temp -> atomic rename -> restart -> health check ->
#   commit, or rollback on any failure.
#
# The exact snapshot validated by the core is the exact snapshot applied. The
# formal config file is never overwritten in place: replacement always uses a
# same-directory temporary file followed by an atomic rename.
# ------------------------------------------------------------------------------

transaction_root() {
    printf '%s/transactions' "$PROXYCTL_DATA"
}

_transaction_canonical() {
    local path="$1"
    if command -v realpath >/dev/null 2>&1; then
        realpath "$path" 2>/dev/null
    elif [[ -d "$path" ]]; then
        (cd "$path" && pwd -P) 2>/dev/null
    else
        local parent base canonical_parent
        parent=$(dirname "$path")
        base=$(basename "$path")
        canonical_parent=$(_transaction_canonical "$parent") || return 1
        printf '%s/%s' "$canonical_parent" "$base"
    fi
}

transaction_dir() {
    local tx_id="$1"
    printf '%s/%s' "$(transaction_root)" "$tx_id"
}

_transaction_safe_path() {
    local dir="$1"
    local canonical root

    canonical=$(_transaction_canonical "$dir") || {
        error "Cannot resolve transaction path: ${dir}"
        return 1
    }
    root=$(transaction_root)

    [[ "$canonical" == "$root" || "$canonical" == "$root"/* ]] || {
        error "Path outside transaction directory: ${dir}"
        return 1
    }
}

transaction_validate_label() {
    local label="${1:-}"

    [[ "$label" =~ ^[A-Za-z0-9_.-]+$ ]] || {
        error "Invalid transaction label: ${label}"
        return 1
    }
    [[ "$label" != '.' && "$label" != '..' ]] || {
        error "Invalid transaction label: ${label}"
        return 1
    }
    (( ${#label} >= 1 && ${#label} <= 64 )) || {
        error "Transaction label must be 1-64 characters: ${label}"
        return 1
    }
}

transaction_validate_id() {
    local tx_id="${1:-}"
    [[ "$tx_id" =~ ^tx_[0-9]+_[0-9]+_[A-Za-z0-9_.-]+$ ]] || {
        error "Invalid transaction ID: ${tx_id}"
        return 1
    }
}

transaction_validate_stage_name() {
    local name="${1:-}"

    [[ "$name" =~ ^[A-Za-z0-9_.-]+$ ]] || {
        error "Invalid stage name: ${name}"
        return 1
    }
    [[ "$name" != '.' && "$name" != '..' ]] || {
        error "Stage name cannot be . or ..: ${name}"
        return 1
    }
}

transaction_begin() {
    local label="${1:-}"
    transaction_validate_label "$label" || return 1

    local root tx_id tx_dir
    root=$(transaction_root)
    mkdir -p -- "$root" || return 1
    chmod 700 -- "$root" || return 1

    tx_id="tx_$(date +%s)_${RANDOM}_${label}"
    tx_dir=$(transaction_dir "$tx_id")
    mkdir -- "$tx_dir" || return 1
    chmod 700 -- "$tx_dir" || return 1

    printf '%s\n' "$tx_id"
}

transaction_stage() {
    local tx_id="${1:-}"
    local name="${2:-}"
    local file="${3:-}"

    transaction_validate_id "$tx_id" || return 1
    transaction_validate_stage_name "$name" || return 1
    [[ -f "$file" ]] || {
        error "Source file does not exist: ${file}"
        return 1
    }

    local tx_dir
    tx_dir=$(transaction_dir "$tx_id")
    _transaction_safe_path "$tx_dir" || return 1
    cp -- "$file" "${tx_dir}/${name}"
}

_transaction_cleanup_dir() {
    local tx_id="$1"
    local tx_dir canonical_tx_root canonical_tx_dir

    transaction_validate_id "$tx_id" || return 1
    tx_dir=$(transaction_dir "$tx_id")
    [[ -d "$tx_dir" ]] || {
        error "Transaction directory does not exist: ${tx_dir}"
        return 1
    }

    canonical_tx_dir=$(_transaction_canonical "$tx_dir") || {
        error "Cannot resolve transaction directory: ${tx_dir}"
        return 1
    }
    canonical_tx_root=$(_transaction_canonical "$(transaction_root)") || {
        error 'Cannot resolve transaction root'
        return 1
    }

    [[ "$canonical_tx_dir" == "$canonical_tx_root"/* ]] || {
        error 'Transaction directory outside safe root — refusing to delete'
        return 1
    }
    [[ "$canonical_tx_dir" != "$canonical_tx_root" && "$canonical_tx_dir" != '/' ]] || {
        error 'Refusing unsafe transaction deletion'
        return 1
    }

    rm -rf -- "$tx_dir"
}

transaction_commit() {
    local tx_id="${1:-}"
    transaction_validate_id "$tx_id" || return 1
    info "Transaction ${tx_id} committed."
    _transaction_cleanup_dir "$tx_id"
}

transaction_rollback() {
    local tx_id="${1:-}"
    transaction_validate_id "$tx_id" || return 1
    warn "Transaction ${tx_id} rolled back."
    _transaction_cleanup_dir "$tx_id"
}

# ============================================================================
# Phase 2.5 — apply_candidate
# ============================================================================

_transaction_validate_candidate() {
    local candidate="${1:-}"

    [[ -e "$candidate" ]] || {
        error "Candidate does not exist: ${candidate}"
        return 1
    }
    [[ -f "$candidate" ]] || {
        error "Candidate is not a regular file: ${candidate}"
        return 1
    }
    [[ ! -L "$candidate" ]] || {
        error "Candidate must not be a symlink: ${candidate}"
        return 1
    }
    [[ -r "$candidate" ]] || {
        error "Candidate is not readable: ${candidate}"
        return 1
    }
}

_transaction_config_path() {
    local engine="$1"
    local config parent

    config=$(engine_call "$engine" config_file) || return 1
    [[ "$config" == /* ]] || {
        error "Engine config path is not absolute: ${config}"
        return 1
    }

    parent=$(dirname "$config")
    [[ -d "$parent" && ! -L "$parent" ]] || {
        error "Config directory is unavailable or unsafe: ${parent}"
        return 1
    }
    [[ ! -L "$config" ]] || {
        error "Config file must not be a symlink: ${config}"
        return 1
    }

    printf '%s\n' "$config"
}

# Usage: _transaction_atomic_put DEST SOURCE MODE [OWNER:GROUP] [CONTEXT]
# CONTEXT is only used for deterministic failure injection in tests.
_transaction_atomic_put() {
    local dest="$1"
    local source="$2"
    local mode="$3"
    local owner_group="${4:-}"
    local context="${5:-apply}"
    local parent tmp

    parent=$(dirname "$dest")
    tmp=$(mktemp "${parent}/.proxyctl-config.XXXXXX") || return 1

    if [[ "$context" == 'apply' && "${PROXYCTL_TEST_FAIL_ATOMIC_COPY:-}" == '1' ]]; then
        rm -f -- "$tmp"
        return 1
    fi
    if [[ "$context" == 'rollback' && "${PROXYCTL_TEST_FAIL_ROLLBACK_RESTORE:-}" == '1' ]]; then
        rm -f -- "$tmp"
        return 1
    fi

    if ! cp -- "$source" "$tmp"; then
        rm -f -- "$tmp"
        return 1
    fi
    chmod -- "$mode" "$tmp" || {
        rm -f -- "$tmp"
        return 1
    }
    if [[ -n "$owner_group" ]]; then
        chown -- "$owner_group" "$tmp" 2>/dev/null || true
    fi
    if ! mv -f -- "$tmp" "$dest"; then
        rm -f -- "$tmp"
        return 1
    fi
}

# Restore the pre-apply state. A rollback failure is critical because the
# transaction directory contains the recovery evidence/old-config and must be
# preserved for manual intervention.
_transaction_rollback_apply() {
    local engine="$1"
    local config="$2"
    local had_old="$3"
    local old_mode="$4"
    local old_owner="$5"
    local old_group="$6"
    local tx_id="$7"
    local was_active="$8"
    local tx_dir
    tx_dir=$(transaction_dir "$tx_id")

    if (( had_old == 1 )); then
        if ! _transaction_atomic_put "$config" "${tx_dir}/old-config" \
            "$old_mode" "${old_owner}:${old_group}" rollback; then
            critical "Failed to restore previous configuration: ${config}. Manual intervention required."
            return 1
        fi
        warn 'Previous configuration restored.'
    else
        if ! rm -f -- "$config"; then
            critical "Failed to remove the newly applied configuration: ${config}. Manual intervention required."
            return 1
        fi
        warn 'New configuration removed.'
    fi

    if (( was_active == 1 )); then
        if engine_call "$engine" restart && engine_call "$engine" is_active; then
            warn 'Service restarted with the previous configuration.'
        else
            critical 'Rollback configuration restored but service failed to start. Manual intervention required.'
            return 1
        fi
    else
        warn 'Service was not running; left stopped.'
    fi
}

# Called only after the formal config may have changed. Cleanup is permitted
# only when rollback fully succeeds; otherwise the transaction is preserved.
_transaction_fail_with_rollback() {
    local engine="$1"
    local config="$2"
    local had_old="$3"
    local old_mode="$4"
    local old_owner="$5"
    local old_group="$6"
    local tx_id="$7"
    local was_active="$8"
    local tx_dir
    tx_dir=$(transaction_dir "$tx_id")

    if _transaction_rollback_apply "$engine" "$config" "$had_old" \
        "$old_mode" "$old_owner" "$old_group" "$tx_id" "$was_active"; then
        transaction_rollback "$tx_id" >/dev/null 2>&1 || \
            warn "Rollback succeeded but transaction cleanup failed: ${tx_dir}"
    else
        critical "Rollback failed. Transaction preserved at: ${tx_dir}"
    fi
    return 1
}

_apply_candidate_locked() {
    local engine="$1"
    local candidate="$2"
    local config tx_id tx_dir snapshot

    config=$(_transaction_config_path "$engine") || return 1
    _transaction_validate_candidate "$candidate" || return 1

    tx_id=$(transaction_begin "${engine}-apply") || return 1
    tx_dir=$(transaction_dir "$tx_id")
    snapshot="${tx_dir}/candidate"

    # Snapshot first. From this point on the original candidate is never read
    # again: validation and installation both consume this exact file.
    if ! cp -- "$candidate" "$snapshot"; then
        error "Failed to snapshot candidate: ${candidate}"
        transaction_rollback "$tx_id" >/dev/null 2>&1 || true
        return 1
    fi
    chmod 600 -- "$snapshot" || {
        error 'Failed to secure candidate snapshot.'
        transaction_rollback "$tx_id" >/dev/null 2>&1 || true
        return 1
    }

    # Core output is diagnostic output, so keep apply_candidate stdout clean.
    if ! engine_call "$engine" validate "$snapshot" >&2; then
        error "Candidate failed ${engine} validation."
        transaction_rollback "$tx_id" >/dev/null 2>&1 || true
        return 1
    fi

    local was_active=0
    if engine_call "$engine" is_active; then
        was_active=1
    fi

    local had_old=0
    local old_mode='600' old_owner='' old_group=''
    if [[ -e "$config" ]]; then
        [[ -f "$config" ]] || {
            error "Existing config is not a regular file: ${config}"
            transaction_rollback "$tx_id" >/dev/null 2>&1 || true
            return 1
        }
        had_old=1
        if ! cp -a -- "$config" "${tx_dir}/old-config"; then
            error "Failed to back up current configuration: ${config}"
            transaction_rollback "$tx_id" >/dev/null 2>&1 || true
            return 1
        fi
        old_mode=$(stat -c '%a' "$config" 2>/dev/null || printf '%s' '600')
        old_owner=$(stat -c '%u' "$config" 2>/dev/null || printf '%s' '')
        old_group=$(stat -c '%g' "$config" 2>/dev/null || printf '%s' '')
    fi

    local owner_group=''
    if (( had_old == 1 )) && [[ -n "$old_owner" && -n "$old_group" ]]; then
        owner_group="${old_owner}:${old_group}"
    fi

    if ! _transaction_atomic_put "$config" "$snapshot" "$old_mode" "$owner_group" apply; then
        error 'Failed to install new configuration.'
        transaction_rollback "$tx_id" >/dev/null 2>&1 || true
        return 1
    fi

    if (( was_active == 1 )); then
        if ! engine_call "$engine" restart; then
            _transaction_fail_with_rollback "$engine" "$config" "$had_old" \
                "$old_mode" "$old_owner" "$old_group" "$tx_id" "$was_active"
            return 1
        fi
        if ! engine_call "$engine" is_active; then
            _transaction_fail_with_rollback "$engine" "$config" "$had_old" \
                "$old_mode" "$old_owner" "$old_group" "$tx_id" "$was_active"
            return 1
        fi
    fi

    transaction_commit "$tx_id" >/dev/null || \
        warn "Failed to clean up transaction directory: ${tx_id}"
}

apply_candidate() {
    local engine="${1:-}"
    local candidate="${2:-}"

    if ! engine_exists "$engine"; then
        error "Unknown engine: ${engine}"
        return 1
    fi
    _transaction_validate_candidate "$candidate" || return 1

    with_lock config _apply_candidate_locked "$engine" "$candidate"
}
