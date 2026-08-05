#!/usr/bin/env bash
# ------------------------------------------------------------------------------
# transaction.sh — Atomic configuration transactions with rollback
# ------------------------------------------------------------------------------

# --- transaction_dir --------------------------------------------------------
# Usage: transaction_dir <tx_id>
# Returns the absolute path to the transaction staging directory.
transaction_dir() {
    local tx_id="$1"
    printf '%s/transactions/%s' "${PROXYCTL_DATA}" "${tx_id}"
}

# --- _transaction_safe_path -------------------------------------------------
# Validates that a path is inside ${PROXYCTL_DATA}/transactions/
# Exits non-zero (and refuses) if not.
_transaction_safe_path() {
    local dir="$1"
    local canonical
    canonical="$(cd "${dir}" 2>/dev/null && pwd)" || {
        error "Cannot resolve transaction path: ${dir}"
        return 1
    }
    local safe_root
    safe_root="${PROXYCTL_DATA}/transactions"

    [[ "${canonical}" == "${safe_root}/"* || "${canonical}" == "${safe_root}" ]] || {
        error "Path outside transaction directory: ${dir}"
        return 1
    }
    return 0
}

# --- transaction_begin ------------------------------------------------------
# Usage: tx_id=$(transaction_begin <label>)
# Creates a unique transaction directory and returns the transaction ID.
transaction_begin() {
    local label="$1"
    local tx_id
    tx_id="tx_$(date +%s)_${RANDOM}_${label}"

    local tx_dir
    tx_dir=$(transaction_dir "${tx_id}")
    mkdir -p "${tx_dir}"

    echo "${tx_id}"
}

# --- transaction_stage ------------------------------------------------------
# Usage: transaction_stage <tx_id> <name> <file>
# Copies <file> into the transaction staging area as <name>.
transaction_stage() {
    local tx_id="$1"
    local name="$2"
    local file="$3"

    local tx_dir
    tx_dir=$(transaction_dir "${tx_id}")
    _transaction_safe_path "${tx_dir}" || return 1

    if [[ ! -f "${file}" ]]; then
        error "Source file does not exist: ${file}"
        return 1
    fi

    mkdir -p "$(dirname "${tx_dir}/${name}")"
    cp "${file}" "${tx_dir}/${name}"
}

# --- transaction_commit -----------------------------------------------------
# Usage: transaction_commit <tx_id>
# Applies the staged transaction.
# Phase 1 stub: cleans up the staging directory.
transaction_commit() {
    local tx_id="$1"
    local tx_dir
    tx_dir=$(transaction_dir "${tx_id}")
    _transaction_safe_path "${tx_dir}" || return 1

    info "Transaction ${tx_id} committed."
    # In Phase 1 this is a stub — future phases will apply staged files.
    rm -rf "${tx_dir}"
}

# --- transaction_rollback ---------------------------------------------------
# Usage: transaction_rollback <tx_id>
# Discards the staged transaction.
# Phase 1 stub: cleans up the staging directory.
transaction_rollback() {
    local tx_id="$1"
    local tx_dir
    tx_dir=$(transaction_dir "${tx_id}")
    _transaction_safe_path "${tx_dir}" || return 1

    warn "Transaction ${tx_id} rolled back."
    # In Phase 1 this is a stub — future phases will restore from staged copies.
    rm -rf "${tx_dir}"
}
