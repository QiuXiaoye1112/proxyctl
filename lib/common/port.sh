#!/usr/bin/env bash
# ------------------------------------------------------------------------------
# port.sh — Port allocation and conflict detection
# ------------------------------------------------------------------------------

# --- port_is_free -----------------------------------------------------------
port_is_free() {
    local port="$1"
    local proto="${2:-tcp}"
    # Stub — will check via ss / netstat in a future phase.
    return 0
}

# --- port_allocate ----------------------------------------------------------
port_allocate() {
    local preferred="${1:-}"
    # Stub — will find a free port in a future phase.
    if [[ -n "${preferred}" ]] && port_is_free "${preferred}"; then
        echo "${preferred}"
    else
        echo '0'
    fi
}
