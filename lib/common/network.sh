#!/usr/bin/env bash
# ------------------------------------------------------------------------------
# network.sh — Network utilities
# ------------------------------------------------------------------------------

# --- network_public_ipv4 ----------------------------------------------------
network_public_ipv4() {
    # Stub — will use an external service in a future phase.
    error 'Public IP detection is not implemented.'
    return 1
}

# --- network_public_ipv6 ----------------------------------------------------
network_public_ipv6() {
    # Stub — will use an external service in a future phase.
    error 'Public IPv6 detection is not implemented.'
    return 1
}

# --- network_check_port -----------------------------------------------------
network_check_port() {
    local port="$1"
    local proto="${2:-tcp}"
    # Stub — fail closed.
    error 'Port check is not implemented.'
    return 1
}
