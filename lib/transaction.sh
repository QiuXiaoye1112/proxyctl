#!/usr/bin/env bash
# ------------------------------------------------------------------------------
# transaction.sh — Atomic configuration transactions with rollback
#
# Phase 2.5: apply_candidate installs a new engine configuration safely:
#
#   config lock -> candidate checks -> core validation -> backup ->
#   same-directory temp -> atomic rename -> restart -> health check ->
#   commit, or rollback on any failure.
#
# The formal config file is NEVER overwritten in place — it is replaced with
# an atomic rename of a temp file in the same directory, so a reader never
# sees a half-written config and the move never crosses filesystems.
# ------------------------------------------------------------------------------

# --- transaction_root --------------------------------------------------------
# Canonical source for the transaction root directory.
transaction_root() {
    printf '%s/transactions' "$PROXYCTL_DATA"
}

# --- _transaction_canonical --------------------------------------------------
# Resolves a path to its canonical form.
# Uses realpath if available, otherwise falls back to cd+pwd -P.
_transaction_canonical() {
    local path="$1"
    if command -v realpath > /dev/null 2>&1; then
        realpath "$path" 2>/dev/null
    elif [[ -d "$path" ]]; then
        (cd "$path" && pwd -P) 2>/dev/null
    else
        # For files or non-existent paths, resolve parent
        local parent
        parent=$(dirname "$path")
        local base
        base=$(basename "$path")
        local canonical_parent
        canonical_parent=$(_transaction_canonical "$parent") || return 1
        printf '%s/%s' "$canonical_parent" "$base"
    fi
}

# --- transaction_dir --------------------------------------------------------
# Usage: transaction_dir <tx_id>
# Returns the absolute path to the transaction staging directory.
transaction_dir() {
    local tx_id="$1"
    printf '%s/%s' "$(transaction_root)" "$tx_id"
}

# --- _transaction_safe_path -------------------------------------------------
# Validates that a canonical path is inside the transaction root.
# Exits non-zero (and refuses) if not.
_transaction_safe_path() {
    local dir="$1"
    local canonical root

    canonical=$(_transaction_canonical "$dir") || {
        error "Cannot resolve transaction path: ${dir}"
        return 1
    }

    root=$(transaction_root)

    # Must be exactly root OR start with root/
    [[ "$canonical" == "$root" || "$canonical" == "$root"/* ]] || {
        error "Path outside transaction directory: ${dir}"
        return 1
    }
    return 0
}

# --- transaction_validate_label ----------------------------------------------
# Usage: transaction_validate_label <label>
# Only allows A-Z, a-z, 0-9, _, -, .  Length 1-64.
transaction_validate_label() {
    local label="$1"

    [[ "$label" =~ ^[A-Za-z0-9_.-]+$ ]] || {
        error "Invalid transaction label: ${label}"
        return 1
    }

    # Reject . and .. (path traversal)
    [[ "$label" == '.' || "$label" == '..' ]] && {
        error "Invalid transaction label: ${label}"
        return 1
    }

    local len
    len=${#label}
    if ((len < 1 || len > 64)); then
        error "Transaction label must be 1-64 characters: ${label}"
        return 1
    fi

    return 0
}

# --- transaction_validate_id ------------------------------------------------
# Usage: transaction_validate_id <tx_id>
# Only accepts ProxyCTL-generated IDs: tx_<timestamp>_<random>_<label>
transaction_validate_id() {
    local tx_id="$1"

    [[ "$tx_id" =~ ^tx_[0-9]+_[0-9]+_[A-Za-z0-9_.-]+$ ]] || {
        error "Invalid transaction ID: ${tx_id}"
        return 1
    }

    return 0
}

# --- transaction_validate_stage_name -----------------------------------------
# Usage: transaction_validate_stage_name <name>
# Phase 1: only single filenames with safe characters, no path separators.
transaction_validate_stage_name() {
    local name="$1"

    # Reject: slashes, backslashes, spaces, dots-only, control chars
    [[ "$name" =~ ^[A-Za-z0-9_.-]+$ ]] || {
        error "Invalid stage name: ${name}"
        return 1
    }

    # Reject . and ..
    [[ "$name" == '.' || "$name" == '..' ]] && {
        error "Stage name cannot be . or ..: ${name}"
        return 1
    }

    return 0
}

# --- transaction_begin ------------------------------------------------------
# Usage: tx_id=$(transaction_begin <label>)
# Creates a unique transaction directory and returns the transaction ID.
transaction_begin() {
    local label="$1"

    transaction_validate_label "$label" || return 1

    local tx_id
    tx_id="tx_$(date +%s)_${RANDOM}_${label}"

    # Enforce the transaction root permission invariant here, so the module
    # does not depend on the installer having created it.
    local root
    root=$(transaction_root)
    mkdir -p "$root"
    chmod 700 "$root"

    local tx_dir
    tx_dir=$(transaction_dir "$tx_id")
    mkdir -p "$tx_dir"
    chmod 700 "$tx_dir"

    echo "$tx_id"
}

# --- transaction_stage ------------------------------------------------------
# Usage: transaction_stage <tx_id> <name> <file>
# Copies <file> into the transaction staging area as <name>.
transaction_stage() {
    local tx_id="$1"
    local name="$2"
    local file="$3"

    # Step 1: validate tx_id format
    transaction_validate_id "$tx_id" || return 1

    # Step 2: validate stage name
    transaction_validate_stage_name "$name" || return 1

    # Step 3: confirm source exists
    if [[ ! -f "$file" ]]; then
        error "Source file does not exist: ${file}"
        return 1
    fi

    # Step 4: resolve tx_dir and check safe root
    local tx_dir
    tx_dir=$(transaction_dir "$tx_id")
    _transaction_safe_path "$tx_dir" || return 1

    # Step 5: copy into transaction (name already validated as simple filename)
    cp "$file" "${tx_dir}/${name}"
}

# --- transaction_commit -----------------------------------------------------
# Usage: transaction_commit <tx_id>
# Applies the staged transaction.
# Phase 1 stub: cleans up the staging directory.
transaction_commit() {
    local tx_id="$1"

    # Validate tx_id format
    transaction_validate_id "$tx_id" || return 1

    local tx_dir
    tx_dir=$(transaction_dir "$tx_id")

    # Safety checks before rm -rf
    [[ -d "$tx_dir" ]] || {
        error "Transaction directory does not exist: ${tx_dir}"
        return 1
    }

    local canonical_tx_root canonical_tx_dir
    canonical_tx_dir=$(_transaction_canonical "$tx_dir") || {
        error "Cannot resolve transaction directory: ${tx_dir}"
        return 1
    }
    canonical_tx_root=$(_transaction_canonical "$(transaction_root)") || {
        error "Cannot resolve transaction root"
        return 1
    }

    # Must be inside transaction root
    [[ "$canonical_tx_dir" == "$canonical_tx_root" || "$canonical_tx_dir" == "$canonical_tx_root"/* ]] || {
        error "Transaction directory outside safe root — refusing to delete"
        return 1
    }

    # Must not be the transaction root itself
    [[ "$canonical_tx_dir" != "$canonical_tx_root" ]] || {
        error "Refusing to delete transaction root"
        return 1
    }

    # Must not be /
    [[ "$canonical_tx_dir" != '/' ]] || {
        error "Refusing to delete root filesystem"
        return 1
    }

    info "Transaction ${tx_id} committed."
    # In Phase 1 this is a stub — future phases will apply staged files.
    rm -rf "$tx_dir"
}

# --- transaction_rollback ---------------------------------------------------
# Usage: transaction_rollback <tx_id>
# Discards the staged transaction.
# Phase 1 stub: cleans up the staging directory.
transaction_rollback() {
    local tx_id="$1"

    # Validate tx_id format
    transaction_validate_id "$tx_id" || return 1

    local tx_dir
    tx_dir=$(transaction_dir "$tx_id")

    # Safety checks before rm -rf
    [[ -d "$tx_dir" ]] || {
        error "Transaction directory does not exist: ${tx_dir}"
        return 1
    }

    local canonical_tx_root canonical_tx_dir
    canonical_tx_dir=$(_transaction_canonical "$tx_dir") || {
        error "Cannot resolve transaction directory: ${tx_dir}"
        return 1
    }
    canonical_tx_root=$(_transaction_canonical "$(transaction_root)") || {
        error "Cannot resolve transaction root"
        return 1
    }

    # Must be inside transaction root
    [[ "$canonical_tx_dir" == "$canonical_tx_root" || "$canonical_tx_dir" == "$canonical_tx_root"/* ]] || {
        error "Transaction directory outside safe root — refusing to delete"
        return 1
    }

    # Must not be the transaction root itself
    [[ "$canonical_tx_dir" != "$canonical_tx_root" ]] || {
        error "Refusing to delete transaction root"
        return 1
    }

    # Must not be /
    [[ "$canonical_tx_dir" != '/' ]] || {
        error "Refusing to delete root filesystem"
        return 1
    }

    warn "Transaction ${tx_id} rolled back."
    # In Phase 1 this is a stub — future phases will restore from staged copies.
    rm -rf "$tx_dir"
}

# ============================================================================
# Phase 2.5 — apply_candidate (config transaction apply)
# ============================================================================

# --- _transaction_validate_candidate -----------------------------------------
# A candidate must be an existing, readable regular file that is NOT a symlink
# — no odd path behaviour during apply.
_transaction_validate_candidate() {
    local candidate="$1"

    if [[ ! -e "$candidate" ]]; then
        error "Candidate does not exist: ${candidate}"
        return 1
    fi
    if [[ ! -f "$candidate" ]]; then
        error "Candidate is not a regular file: ${candidate}"
        return 1
    fi
    if [[ -L "$candidate" ]]; then
        error "Candidate must not be a symlink: ${candidate}"
        return 1
    fi
    if [[ ! -r "$candidate" ]]; then
        error "Candidate is not readable: ${candidate}"
        return 1
    fi
    return 0
}

# --- _transaction_config_path ------------------------------------------------
# Resolves the engine's formal config path (single source of truth: the
# engine's config_file API) and validates it is safe to write: absolute path,
# parent exists, parent is a real directory (not a symlink).
_transaction_config_path() {
    local engine="$1"
    local config
    config=$(engine_call "$engine" config_file) || return 1

    if [[ "$config" != /* ]]; then
        error "Engine config path is not absolute: ${config}"
        return 1
    fi

    local parent
    parent=$(dirname "$config")
    if [[ ! -d "$parent" ]]; then
        error "Config directory does not exist: ${parent}"
        return 1
    fi
    if [[ -L "$parent" ]]; then
        error "Config directory must not be a symlink: ${parent}"
        return 1
    fi

    printf '%s\n' "$config"
}

# --- _transaction_atomic_put -------------------------------------------------
# Usage: _transaction_atomic_put <dest> <source> <mode> [owner:group]
# Installs <source> at <dest> atomically: same-directory temp -> chmod/chown
# -> mv. <dest> is never partially written and the temp never crosses a
# filesystem. Existing mode is preserved when given (owner/group best-effort).
_transaction_atomic_put() {
    local dest="$1"
    local source="$2"
    local mode="$3"
    local owner_group="${4:-}"
    local parent tmp

    parent=$(dirname "$dest")
    tmp=$(mktemp "${parent}/.proxyctl-config.XXXXXX") || return 1

    # Test-only failure injection (see tests/transaction.sh) — the temp exists
    # but the copy is made to fail before <dest> is touched.
    if [[ "${PROXYCTL_TEST_FAIL_ATOMIC_COPY:-}" == '1' ]]; then
        rm -f "$tmp"
        return 1
    fi
    if ! cp "$source" "$tmp"; then
        rm -f "$tmp"
        return 1
    fi
    chmod "$mode" "$tmp" || {
        rm -f "$tmp"
        return 1
    }
    if [[ -n "$owner_group" ]]; then
        chown "$owner_group" "$tmp" 2>/dev/null || true
    fi
    if ! mv -f "$tmp" "$dest"; then
        rm -f "$tmp"
        return 1
    fi
    return 0
}

# --- _transaction_rollback_apply ---------------------------------------------
# Restores the previous state after a failed apply. Restores (or removes) the
# config atomically, then handles the service according to how it was before:
# was_active -> restart + health check; inactive -> left stopped.
# Returns 0 on a fully successful rollback, non-zero if rollback had problems.
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

    local ok=1

    if (( had_old == 1 )); then
        if _transaction_atomic_put "$config" "${tx_dir}/old-config" \
            "$old_mode" "${old_owner}:${old_group}"; then
            warn 'Previous configuration restored.'
        else
            error "Failed to restore previous configuration: ${config}"
            ok=0
        fi
    else
        if rm -f "$config"; then
            warn 'New configuration removed.'
        else
            error "Failed to remove applied configuration: ${config}"
            ok=0
        fi
    fi

    if (( ok == 1 )); then
        if (( was_active == 1 )); then
            if engine_call "$engine" restart && engine_call "$engine" is_active; then
                warn 'Service restarted with the previous configuration.'
            else
                critical 'Rollback configuration restored but service failed to start. Manual intervention required.'
                ok=0
            fi
        else
            warn 'Service was not running; left stopped.'
        fi
    fi

    return $(( ok == 1 ? 0 : 1 ))
}

# --- _apply_candidate_locked -------------------------------------------------
# Runs under the config lock. Performs the full apply lifecycle.
_apply_candidate_locked() {
    local engine="$1"
    local candidate="$2"

    local config
    config=$(_transaction_config_path "$engine") || return 1

    # Re-check the candidate under the lock (cheap; guards TOCTOU on symlink).
    _transaction_validate_candidate "$candidate" || return 1

    local tx_id
    tx_id=$(transaction_begin "${engine}-apply") || return 1
    local tx_dir
    tx_dir=$(transaction_dir "$tx_id")

    # Real core validation must pass before the formal config is touched.
    if ! engine_call "$engine" validate "$candidate"; then
        error "Candidate failed ${engine} validation."
        transaction_rollback "$tx_id" >/dev/null 2>&1 || true
        return 1
    fi

    # Record the service state before touching anything.
    local was_active=0
    if engine_call "$engine" is_active; then
        was_active=1
    fi

    # Back up the current state into the transaction directory.
    local had_old=0
    local old_mode='600' old_owner='' old_group=''
    if [[ -e "$config" ]]; then
        had_old=1
        if ! cp -a "$config" "${tx_dir}/old-config"; then
            error "Failed to back up current configuration: ${config}"
            transaction_rollback "$tx_id" >/dev/null 2>&1 || true
            return 1
        fi
        old_mode=$(stat -c '%a' "$config" 2>/dev/null || echo '600')
        old_owner=$(stat -c '%U' "$config" 2>/dev/null || echo '')
        old_group=$(stat -c '%G' "$config" 2>/dev/null || echo '')
    fi
    if ! cp "$candidate" "${tx_dir}/candidate"; then
        error "Failed to stage candidate: ${candidate}"
        transaction_rollback "$tx_id" >/dev/null 2>&1 || true
        return 1
    fi

    # Atomic replace. New file keeps the old mode/owner when there was an old
    # config, otherwise defaults to 600.
    local new_mode="$old_mode"
    local new_owner_group=''
    if (( had_old == 1 )); then
        new_owner_group="${old_owner}:${old_group}"
    fi
    if ! _transaction_atomic_put "$config" "$candidate" "$new_mode" "$new_owner_group"; then
        error 'Failed to install new configuration.'
        transaction_rollback "$tx_id" >/dev/null 2>&1 || true
        return 1
    fi

    # Restart + health check only if the service was already running; an
    # inactive service is left stopped (validate + replace only).
    if (( was_active == 1 )); then
        if ! engine_call "$engine" restart; then
            _transaction_rollback_apply "$engine" "$config" "$had_old" \
                "$old_mode" "$old_owner" "$old_group" "$tx_id" "$was_active"
            transaction_rollback "$tx_id" >/dev/null 2>&1 || true
            return 1
        fi
        if ! engine_call "$engine" is_active; then
            _transaction_rollback_apply "$engine" "$config" "$had_old" \
                "$old_mode" "$old_owner" "$old_group" "$tx_id" "$was_active"
            transaction_rollback "$tx_id" >/dev/null 2>&1 || true
            return 1
        fi
    fi

    transaction_commit "$tx_id" >/dev/null || \
        warn "Failed to clean up transaction directory: ${tx_id}"
    return 0
}

# --- apply_candidate ---------------------------------------------------------
# Usage: apply_candidate <engine> <candidate>
# Safely applies a new configuration for an engine. Holds only the config
# lock (never cert/firewall — avoids lock-ordering issues). stdout stays clean
# on success; failures write to stderr.
apply_candidate() {
    local engine="${1:-}"
    local candidate="${2:-}"

    # Fast parameter validation before taking the config lock.
    if ! engine_exists "${engine}"; then
        error "Unknown engine: ${engine}"
        return 1
    fi
    _transaction_validate_candidate "$candidate" || return 1

    with_lock config _apply_candidate_locked "$engine" "$candidate"
}
