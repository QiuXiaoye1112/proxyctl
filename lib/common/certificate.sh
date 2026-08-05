#!/usr/bin/env bash
# ------------------------------------------------------------------------------
# certificate.sh — TLS certificate management (self-signed, ACME)
# ------------------------------------------------------------------------------

# --- cert_generate_self -----------------------------------------------------
cert_generate_self() {
    local domain="$1"
    # Stub — will generate a self-signed certificate in a future phase.
    echo "Not implemented"
}

# --- cert_acme_issue --------------------------------------------------------
cert_acme_issue() {
    local domain="$1"
    # Stub — will use acme.sh or certbot in a future phase.
    echo "Not implemented"
}

# --- cert_list --------------------------------------------------------------
cert_list() {
    # Stub
    echo "Not implemented"
}
