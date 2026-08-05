#!/usr/bin/env bash
# ------------------------------------------------------------------------------
# metadata.sh — Persistent metadata stored in /var/lib/proxyctl/meta.json
# ------------------------------------------------------------------------------

readonly META_SCHEMA_VERSION=1

readonly _META_ALLOWED_KEYS=(
    version
    inbounds
    certificates
    firewall
)

_metadata_require_jq() {
    if ! command -v jq > /dev/null 2>&1; then
        error 'jq is required for metadata operations'
        return 1
    fi
}

metadata_validate_key() {
    local key="$1"
    [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_-]*$ ]] || {
        error "Invalid metadata key: $key"
        return 1
    }

    local allowed
    for allowed in "${_META_ALLOWED_KEYS[@]}"; do
        [[ "$key" == "$allowed" ]] && return 0
    done

    error "Metadata key not allowed: $key"
    return 1
}

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

    chmod 600 "${PROXYCTL_META}" 2>/dev/null || true
}

metadata_validate() {
    if [[ ! -f "${PROXYCTL_META}" ]]; then
        error "Metadata file not found: ${PROXYCTL_META}"
        return 1
    fi

    _metadata_require_jq || return 1

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

    local key
    for key in inbounds certificates firewall; do
        if ! jq -e --arg key "$key" '.[$key]' "${PROXYCTL_META}" > /dev/null 2>&1; then
            error "Metadata missing required key: ${key}"
            return 1
        fi
    done

    return 0
}

metadata_get() {
    local key="${1#.}"
    _metadata_require_jq || return 1
    metadata_validate_key "$key" || return 1

    jq --arg key "$key" -r '.[$key]' "$PROXYCTL_META"
}

_metadata_atomic_jq() {
    local tmp
    _metadata_require_jq || return 1
    metadata_init >/dev/null || return 1
    metadata_validate || return 1

    tmp=$(mktemp "${PROXYCTL_META}.tmp.XXXXXX") || {
        error 'Failed to create temporary metadata file'
        return 1
    }

    local umask_old rc=0
    umask_old=$(umask)
    umask 077

    jq "$@" "${PROXYCTL_META}" >"$tmp" || rc=$?
    if ((rc != 0)) || [[ ! -s "$tmp" ]] || ! jq empty "$tmp" 2>/dev/null; then
        rm -f -- "$tmp"
        umask "$umask_old"
        error 'Metadata update produced invalid JSON'
        return 1
    fi

    mv -f -- "$tmp" "$PROXYCTL_META" || {
        rm -f -- "$tmp"
        umask "$umask_old"
        return 1
    }
    chmod 600 "$PROXYCTL_META"
    umask "$umask_old"
}

metadata_set_string() {
    local key="$1"
    local value="$2"
    metadata_validate_key "$key" || return 1
    _metadata_atomic_jq --arg key "$key" --arg value "$value" '.[$key] = $value'
}

metadata_set_json() {
    local key="$1"
    local json="$2"
    metadata_validate_key "$key" || return 1
    _metadata_atomic_jq --arg key "$key" --argjson value "$json" '.[$key] = $value'
}

metadata_keys() {
    _metadata_require_jq || return 1
    jq -r '.inbounds | keys[]' "${PROXYCTL_META}" 2>/dev/null || true
}

# --- certificate metadata ----------------------------------------------------
# Certificate records intentionally mirror the mature xrayctl model:
# identifier (object key) is independent from Certbot's lineage/certName.
metadata_cert_exists() {
    local identifier="${1:-}"
    metadata_init >/dev/null || return 1
    _metadata_require_jq || return 1
    jq -e --arg id "$identifier" '.certificates[$id] != null' "$PROXYCTL_META" >/dev/null 2>&1
}

metadata_cert_set() {
    local identifier="$1" subject="$2" cert_name="$3" source="$4" validation="$5"
    local auto_renew="${6:-true}"
    [[ "$auto_renew" == true || "$auto_renew" == false ]] || {
        error "Invalid certificate autoRenew value: ${auto_renew}"
        return 1
    }

    _metadata_atomic_jq \
        --arg id "$identifier" \
        --arg subject "$subject" \
        --arg certName "$cert_name" \
        --arg source "$source" \
        --arg validation "$validation" \
        --arg autoRenew "$auto_renew" \
        --arg now "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
        '.certificates[$id] = {
            subject: $subject,
            certName: $certName,
            source: $source,
            validation: $validation,
            autoRenew: ($autoRenew == "true"),
            updatedAt: $now
        }'
}

metadata_cert_get_field() {
    local identifier="$1" field="$2"
    case "$field" in
        subject|certName|source|validation|autoRenew|updatedAt) ;;
        *) error "Invalid certificate metadata field: ${field}"; return 1 ;;
    esac
    metadata_init >/dev/null || return 1
    _metadata_require_jq || return 1
    jq -r --arg id "$identifier" --arg field "$field" '
        if (.certificates[$id] != null and (.certificates[$id] | has($field))) then
            .certificates[$id][$field]
        else
            empty
        end
    ' "$PROXYCTL_META"
}

metadata_cert_list() {
    metadata_init >/dev/null || return 1
    _metadata_require_jq || return 1
    jq -r '.certificates | keys[]' "$PROXYCTL_META" 2>/dev/null
}

metadata_cert_auto_renew_list() {
    metadata_init >/dev/null || return 1
    _metadata_require_jq || return 1
    jq -r '.certificates | to_entries[] | select(.value.autoRenew == true) | .key' \
        "$PROXYCTL_META" 2>/dev/null
}

metadata_cert_delete() {
    local identifier="$1"
    _metadata_atomic_jq --arg id "$identifier" 'del(.certificates[$id])'
}
