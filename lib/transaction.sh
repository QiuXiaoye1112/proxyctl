#!/usr/bin/env bash
# ------------------------------------------------------------------------------
# transaction.sh — Atomic configuration transactions with rollback
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
