#!/usr/bin/env bash
# ------------------------------------------------------------------------------
# certificate.sh — TLS certificate management (self-signed, ACME)
# ------------------------------------------------------------------------------

# --- cert_generate_self -----------------------------------------------------
cert_generate_self() {
    local domain="$1"
    # Stub — will generate a self-signed certificate in a future phase.
    # Returns 0 for display, but actual cert generation stub must not succeed.
    # Phase 1: this is a query-adjacent stub; warn and fail.
    if [[ -n "$domain" ]]; then
        error "Certificate generation is not implemented."
        return 1
    fi
    warn "Certificate generation is not implemented."
    return 1
}

# --- cert_acme_issue --------------------------------------------------------
cert_acme_issue() {
    local domain="$1"
    # Stub — will use acme.sh or certbot in a future phase.
    # Mutating operation stub — must fail closed.
    error "ACME certificate issuance is not implemented."
    return 1
}

# --- cert_list --------------------------------------------------------------
cert_list() {
    # Stub — query stub, fail with warning.
    warn "Certificate listing is not implemented."
    return 1
}
