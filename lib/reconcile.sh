#!/usr/bin/env bash
# ------------------------------------------------------------------------------
# reconcile.sh — adopt existing Xray/sing-box configs without rewriting them
#
# The engine config remains the source of truth. Reconciliation only backfills
# ProxyCTL auxiliary metadata from legacy xrayctl/sbctl state and derives Xray
# REALITY public keys when the installed Xray core can do so.
# ------------------------------------------------------------------------------

reconcile_legacy_xray_meta() { printf '%s\n' "${PROXYCTL_LEGACY_XRAY_META:-/usr/local/etc/xray/xrayctl.meta.json}"; }
reconcile_legacy_singbox_meta() { printf '%s\n' "${PROXYCTL_LEGACY_SBCTL_META:-/var/lib/sbctl/meta.json}"; }

_reconcile_legacy_meta_safe() {
    local file="$1"
    [[ -f "$file" && ! -L "$file" && -r "$file" ]] || return 1
    jq -e 'type=="object" and ((.inbounds // {})|type=="object")' "$file" >/dev/null 2>&1
}

_reconcile_legacy_field() {
    local file="$1" tag="$2" field="$3"
    _reconcile_legacy_meta_safe "$file" || return 1
    case "$field" in
        host) jq -r --arg tag "$tag" '.inbounds[$tag].host // empty' "$file" ;;
        realityPublicKey) jq -r --arg tag "$tag" '.inbounds[$tag].realityPublicKey // empty' "$file" ;;
        hy2HopRange) jq -r --arg tag "$tag" '.inbounds[$tag].hysteria2PortHopping.range // empty' "$file" ;;
        *) return 1 ;;
    esac
}

_reconcile_xray_public_key() {
    local tag="$1" config private output public
    config=$(engine_xray_config_file)
    private=$(jq -r --arg tag "$tag" '.inbounds[]?|select(.tag==$tag)|.streamSettings.realitySettings.privateKey // empty' "$config")
    [[ -n "$private" ]] || return 1
    command -v xray >/dev/null 2>&1 || return 1
    output=$(xray x25519 -i "$private" 2>/dev/null) || return 1
    public=$(awk -F': *' 'tolower($1) ~ /(public|password)/ {print $2; exit}' <<<"$output" | tr -d '"')
    [[ -n "$public" ]] || return 1
    printf '%s\n' "$public"
}

_reconcile_engine_locked() {
    local engine="$1" config legacy tag host public hop existing_host existing_public existing_hop
    local adopted=0 incomplete=0 protocol
    engine_exists "$engine" || { error "Unknown engine: ${engine}"; return 1; }
    metadata_init >/dev/null || return 1
    metadata_validate || return 1
    config=$(engine_call "$engine" config_file) || return 1
    [[ -f "$config" && ! -L "$config" && -r "$config" ]] || {
        info "${engine}: no existing config to reconcile."
        return 0
    }
    jq -e 'type=="object" and (.inbounds|type=="array")' "$config" >/dev/null 2>&1 || {
        error "${engine}: existing config has no valid inbound array; leaving it untouched."
        return 1
    }

    case "$engine" in
        xray) legacy=$(reconcile_legacy_xray_meta) ;;
        singbox) legacy=$(reconcile_legacy_singbox_meta) ;;
    esac
    if [[ -e "$legacy" || -L "$legacy" ]]; then
        if _reconcile_legacy_meta_safe "$legacy"; then info "${engine}: importing auxiliary state from ${legacy}."
        else warn "${engine}: legacy metadata exists but is unsafe/invalid; ignoring ${legacy}."; legacy=''; fi
    else
        legacy=''
    fi

    while IFS= read -r tag; do
        [[ -n "$tag" ]] || continue
        if ! inbound_validate_tag "$tag"; then
            warn "${engine}: inbound tag cannot be represented safely in ProxyCTL metadata; leaving unmanaged metadata: ${tag}"
            incomplete=$((incomplete + 1))
            continue
        fi

        existing_host=$(inbound_meta_get "$engine" "$tag" clientHost 2>/dev/null || true)
        existing_public=$(inbound_meta_get "$engine" "$tag" realityPublicKey 2>/dev/null || true)
        existing_hop=$(inbound_meta_get "$engine" "$tag" hy2HopRange 2>/dev/null || true)
        host="$existing_host"; public="$existing_public"; hop="$existing_hop"

        if [[ -n "$legacy" ]]; then
            [[ -n "$host" ]] || host=$(_reconcile_legacy_field "$legacy" "$tag" host 2>/dev/null || true)
            [[ -n "$public" ]] || public=$(_reconcile_legacy_field "$legacy" "$tag" realityPublicKey 2>/dev/null || true)
            [[ -n "$hop" ]] || hop=$(_reconcile_legacy_field "$legacy" "$tag" hy2HopRange 2>/dev/null || true)
        fi

        if [[ "$engine" == xray && -z "$public" ]]; then
            public=$(_reconcile_xray_public_key "$tag" 2>/dev/null || true)
        fi

        inbound_meta_set "$engine" "$tag" "$host" "$public" "$hop" || return 1
        adopted=$((adopted + 1))

        if [[ "$engine" == xray ]]; then
            protocol=$(jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.protocol // empty' "$config")
            if [[ "$protocol" =~ ^(vless|vmess|trojan|socks|http)$ && -z "$host" ]]; then
                warn "${engine}/${tag}: client/server address is unknown. Use 'proxyctl inbound modify xray ${tag} <listen> <port> <client-host>' before exporting links."
                incomplete=$((incomplete + 1))
            fi
            if jq -e --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.streamSettings.security=="reality"' "$config" >/dev/null 2>&1 && [[ -z "$public" ]]; then
                warn "${engine}/${tag}: REALITY public key could not be recovered automatically."
                incomplete=$((incomplete + 1))
            fi
        else
            protocol=$(jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.type // empty' "$config")
            if [[ "$protocol" =~ ^(anytls|vless|hysteria2|trojan|socks|http)$ && -z "$host" ]]; then
                warn "${engine}/${tag}: client/server address is unknown. Use 'proxyctl inbound modify singbox ${tag} <listen> <port> <client-host>' before exporting links."
                incomplete=$((incomplete + 1))
            fi
            if jq -e --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.tls.reality.enabled==true' "$config" >/dev/null 2>&1 && [[ -z "$public" ]]; then
                warn "${engine}/${tag}: REALITY public key is not present in ProxyCTL/legacy metadata and cannot be safely guessed."
                incomplete=$((incomplete + 1))
            fi
        fi
    done < <(jq -r '.inbounds[]?.tag // empty' "$config")

    info "${engine}: reconciled ${adopted} inbound(s); ${incomplete} auxiliary field(s) still need attention."
}

reconcile_engine() {
    _inbound_with_config_lock _reconcile_engine_locked "$1"
}

proxyctl_reconcile() {
    local engine="${1:-}" rc=0
    if [[ -n "$engine" ]]; then
        reconcile_engine "$engine"
        return
    fi
    for engine in xray singbox; do
        reconcile_engine "$engine" || rc=1
    done
    return "$rc"
}
