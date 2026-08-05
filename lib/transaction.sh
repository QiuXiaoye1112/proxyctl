#!/usr/bin/env bash
# ------------------------------------------------------------------------------
# transaction.sh — Atomic configuration transactions with rollback
# ------------------------------------------------------------------------------

# --- transaction_begin ------------------------------------------------------
transaction_begin() {
    local label="$1"
    local tx_id
    tx_id="tx_$(date +%s)_${label}"

    local tx_dir="${PROXYCTL_DATA}/transactions/${tx_id}"
    mkdir -p "${tx_dir}"

    echo "${tx_id}"
}

# --- transaction_stage ------------------------------------------------------
transaction_stage() {
    local tx_dir="$1"
    local name="$2"
    local file="$3"

    mkdir -p "$(dirname "${tx_dir}/${name}")"
    cp "${file}" "${tx_dir}/${name}"
}

# --- transaction_commit -----------------------------------------------------
transaction_commit() {
    local tx_dir="$1"

    info "Transaction $(basename "${tx_dir}") committed."
    # In Phase 1 this is a stub — future phases will apply staged files.
    rm -rf "${tx_dir}"
}

# --- transaction_rollback ---------------------------------------------------
transaction_rollback() {
    local tx_dir="$1"

    warn "Transaction $(basename "${tx_dir}") rolled back."
    # In Phase 1 this is a stub — future phases will restore from staged copies.
    rm -rf "${tx_dir}"
}
