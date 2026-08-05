#!/usr/bin/env bash
# ------------------------------------------------------------------------------
# metadata.sh — Persistent metadata stored in /var/lib/proxyctl/meta.json
# ------------------------------------------------------------------------------

readonly META_SCHEMA_VERSION=1

# Allowed top-level metadata keys (Phase 1.1 schema).
readonly _META_ALLOWED_KEYS=(
    version
    inbounds
    certificates
    firewall
    # Test keys allowed for smoke tests
    test_key
    test_obj
)

# --- _metadata_require_jq ---------------------------------------------------
_metadata_require_jq() {
    if ! command -v jq > /dev/null 2>&1; then
        error 'jq is required for metadata operations'
        return 1
    fi
}

# --- metadata_validate_key --------------------------------------------------
# Usage: metadata_validate_key <key>
# Only allows whitelisted top-level keys matching [A-Za-z_][A-Za-z0-9_-]*.
metadata_validate_key() {
    local key="$1"

    # Reject keys with dangerous characters or patterns
    [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_-]*$ ]] || {
        error "Invalid metadata key: $key"
        return 1
    }

    # Check against allowlist
    local allowed
    for allowed in "${_META_ALLOWED_KEYS[@]}"; do
        [[ "$key" == "$allowed" ]] && return 0
    done

    error "Metadata key not allowed: $key"
    return 1
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

    # Check file is valid JSON
    if ! jq empty "${PROXYCTL_META}" 2>/dev/null; then
        error 'Metadata file is not valid JSON'
        return 1
    fi

    local version
    version=$(jq -r '.version // 0' "${PROXYCTL_META}") || {
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
        if ! jq -e --arg key "$key" '.[$key]' "${PROXYCTL_META}" > /dev/null 2>&1; then
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
    local key="${1#.}"
    _metadata_require_jq || return 1
    metadata_validate_key "$key" || return 1

    jq --arg key "$key" -r '.[$key]' "$PROXYCTL_META"
}

# --- metadata_set_string ----------------------------------------------------
# Usage: metadata_set_string <key> <value>
# Sets <key> to the given string value using jq --arg (safe against injection).
metadata_set_string() {
    local key="$1"
    local value="$2"
    _metadata_require_jq || return 1
    metadata_validate_key "$key" || return 1

    # Create temp file in same directory as metadata for atomic rename
    local tmp
    tmp=$(mktemp "${PROXYCTL_META}.tmp.XXXXXX") || {
        error 'Failed to create temporary file'
        return 1
    }

    local umask_old
    umask_old=$(umask)
    umask 077

    local rc=0
    jq --arg key "$key" --arg value "$value" \
        '.[$key] = $value' "$PROXYCTL_META" > "$tmp" || rc=$?

    if ((rc != 0)); then
        rm -f "$tmp"
        umask "${umask_old}"
        error 'jq failed to update metadata'
        return 1
    fi

    # Verify output is non-empty and valid JSON
    if [[ ! -s "$tmp" ]] || ! jq empty "$tmp" 2>/dev/null; then
        rm -f "$tmp"
        umask "${umask_old}"
        error 'Metadata write produced invalid JSON'
        return 1
    fi

    mv "$tmp" "$PROXYCTL_META"
    chmod 600 "$PROXYCTL_META"
    umask "${umask_old}"
}

# --- metadata_set_json ------------------------------------------------------
# Usage: metadata_set_json <key> <json>
# Sets <key> to the given JSON value using jq --argjson (safe against injection).
metadata_set_json() {
    local key="$1"
    local json="$2"
    _metadata_require_jq || return 1
    metadata_validate_key "$key" || return 1

    # Create temp file in same directory as metadata for atomic rename
    local tmp
    tmp=$(mktemp "${PROXYCTL_META}.tmp.XXXXXX") || {
        error 'Failed to create temporary file'
        return 1
    }

    local umask_old
    umask_old=$(umask)
    umask 077

    local rc=0
    jq --arg key "$key" --argjson value "$json" \
        '.[$key] = $value' "$PROXYCTL_META" > "$tmp" || rc=$?

    if ((rc != 0)); then
        rm -f "$tmp"
        umask "${umask_old}"
        error 'jq failed to update metadata with JSON value'
        return 1
    fi

    # Verify output is non-empty and valid JSON
    if [[ ! -s "$tmp" ]] || ! jq empty "$tmp" 2>/dev/null; then
        rm -f "$tmp"
        umask "${umask_old}"
        error 'Metadata write produced invalid JSON'
        return 1
    fi

    mv "$tmp" "$PROXYCTL_META"
    chmod 600 "$PROXYCTL_META"
    umask "${umask_old}"
}

# --- metadata_keys ----------------------------------------------------------
metadata_keys() {
    _metadata_require_jq || return 1
    jq -r '.inbounds | keys[]' "${PROXYCTL_META}" 2>/dev/null || true
}
