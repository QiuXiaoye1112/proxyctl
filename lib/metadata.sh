#!/usr/bin/env bash
# ------------------------------------------------------------------------------
# metadata.sh — Persistent metadata stored in /var/lib/proxyctl/meta.json
# ------------------------------------------------------------------------------

readonly META_SCHEMA_VERSION=1

# --- _metadata_require_jq ---------------------------------------------------
_metadata_require_jq() {
    if ! command -v jq > /dev/null 2>&1; then
        error 'jq is required for metadata operations'
        return 1
    fi
}

# --- metadata_init ----------------------------------------------------------
metadata_init() {
    mkdir -p "$(dirname "${PROXYCTL_META}")"

    if [[ ! -f "${PROXYCTL_META}" ]]; then
        local umask_old
        umask_old=$(umask)
        umask 077

        cat > "${PROXYCTL_META}" <<'EOF'
{
  "version": 1,
  "inbounds": {},
  "certificates": {},
  "firewall": {}
}
EOF
        chmod 600 "${PROXYCTL_META}"
        umask "${umask_old}"

        info "Metadata initialised at ${PROXYCTL_META}"
    fi

    # Always ensure correct permissions
    chmod 600 "${PROXYCTL_META}" 2>/dev/null || true
}

# --- metadata_validate ------------------------------------------------------
metadata_validate() {
    if [[ ! -f "${PROXYCTL_META}" ]]; then
        error "Metadata file not found: ${PROXYCTL_META}"
        return 1
    fi

    _metadata_require_jq || return 1

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
    local key
    for key in inbounds certificates firewall; do
        if ! jq -e ".${key}" "${PROXYCTL_META}" > /dev/null 2>&1; then
            error "Metadata missing required key: ${key}"
            return 1
        fi
    done

    return 0
}

# --- metadata_get -----------------------------------------------------------
# Usage: metadata_get <key>
# Prints the value at <key> to stdout.  Leading dot on key is optional.
metadata_get() {
    local key="$1"
    _metadata_require_jq || return 1
    key="${key#.}"
    jq -r ".${key}" "${PROXYCTL_META}"
}

# --- metadata_set_string ----------------------------------------------------
# Usage: metadata_set_string <key> <value>
# Sets <key> to the given string value using jq --arg (safe against injection).
metadata_set_string() {
    local key="$1"
    local value="$2"
    _metadata_require_jq || return 1

    local tmp
    tmp=$(mktemp)
    local umask_old
    umask_old=$(umask)
    umask 077

    jq --arg val "${value}" ".${key} = \$val" "${PROXYCTL_META}" > "${tmp}"
    mv "${tmp}" "${PROXYCTL_META}"
    chmod 600 "${PROXYCTL_META}"

    umask "${umask_old}"
}

# --- metadata_set_json ------------------------------------------------------
# Usage: metadata_set_json <key> <json>
# Sets <key> to the given JSON value using jq --argjson (safe against injection).
metadata_set_json() {
    local key="$1"
    local json="$2"
    _metadata_require_jq || return 1

    local tmp
    tmp=$(mktemp)
    local umask_old
    umask_old=$(umask)
    umask 077

    jq --argjson val "${json}" ".${key} = \$val" "${PROXYCTL_META}" > "${tmp}"
    mv "${tmp}" "${PROXYCTL_META}"
    chmod 600 "${PROXYCTL_META}"

    umask "${umask_old}"
}

# --- metadata_keys ----------------------------------------------------------
metadata_keys() {
    _metadata_require_jq || return 1
    jq -r '.inbounds | keys[]' "${PROXYCTL_META}" 2>/dev/null || true
}
