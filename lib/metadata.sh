#!/usr/bin/env bash
# ------------------------------------------------------------------------------
# metadata.sh — Persistent metadata stored in /var/lib/proxyctl/meta.json
# ------------------------------------------------------------------------------

readonly META_SCHEMA_VERSION=1

# --- metadata_init ----------------------------------------------------------
metadata_init() {
    mkdir -p "$(dirname "${PROXYCTL_META}")"

    if [[ ! -f "${PROXYCTL_META}" ]]; then
        cat > "${PROXYCTL_META}" <<'EOF'
{
  "version": 1,
  "inbounds": {},
  "certificates": {},
  "firewall": {}
}
EOF
        info "Metadata initialised at ${PROXYCTL_META}"
    fi
}

# --- metadata_validate ------------------------------------------------------
metadata_validate() {
    if [[ ! -f "${PROXYCTL_META}" ]]; then
        error "Metadata file not found: ${PROXYCTL_META}"
        return 1
    fi

    if ! command -v jq > /dev/null 2>&1; then
        warn 'jq not available, skipping metadata validation'
        return 0
    fi

    local version
    version=$(jq -r '.version // 0' "${PROXYCTL_META}" 2>/dev/null) || {
        error 'Metadata file is not valid JSON'
        return 1
    }

    if ((version != META_SCHEMA_VERSION)); then
        error "Metadata version mismatch: got ${version}, expected ${META_SCHEMA_VERSION}"
        return 1
    fi

    # Ensure required keys exist
    for key in inbounds certificates firewall; do
        if ! jq -e ".${key}" "${PROXYCTL_META}" > /dev/null 2>&1; then
            error "Metadata missing required key: ${key}"
            return 1
        fi
    done

    return 0
}

# --- metadata_get -----------------------------------------------------------
metadata_get() {
    local key="$1"
    if ! command -v jq > /dev/null 2>&1; then
        error 'jq is required for metadata operations'
        return 1
    fi
    # Normalise: strip leading dot if present (jq path already starts with .)
    key="${key#.}"
    jq -r ".${key}" "${PROXYCTL_META}"
}

# --- metadata_set -----------------------------------------------------------
metadata_set() {
    local key="$1"
    local value="$2"

    if ! command -v jq > /dev/null 2>&1; then
        error 'jq is required for metadata operations'
        return 1
    fi

    local tmp
    tmp=$(mktemp)
    jq ".${key} = ${value}" "${PROXYCTL_META}" > "${tmp}"
    mv "${tmp}" "${PROXYCTL_META}"
}

# --- metadata_keys ----------------------------------------------------------
metadata_keys() {
    if ! command -v jq > /dev/null 2>&1; then
        error 'jq is required for metadata operations'
        return 1
    fi
    jq -r '.inbounds | keys[]' "${PROXYCTL_META}" 2>/dev/null || true
}
