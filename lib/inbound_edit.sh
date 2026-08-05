#!/usr/bin/env bash
# ------------------------------------------------------------------------------
# inbound_edit.sh — shared safe edits that do not depend on engine JSON schema
# ------------------------------------------------------------------------------

inbound_modify_listen() {
    local engine="$1" tag="$2" listen="$3" port="$4" client_host="${5:-}"
    local config before candidate old_host

    inbound_exists "$engine" "$tag" || { error "Inbound not found: ${engine}/${tag}"; return 1; }
    network_validate_ip "$listen" || { error 'Listen address must be an IPv4/IPv6 address.'; return 1; }
    port_validate "$port" || { error 'Port must be 1-65535.'; return 1; }
    [[ -z "$client_host" ]] || network_validate_host "$client_host" || { error 'Client address must be an IP or domain.'; return 1; }
    inbound_port_in_config "$engine" "$port" "$tag" && { error "Port ${port} is already used by another ${engine} inbound."; return 1; }

    config=$(inbound_config_file "$engine") || return 1
    before=$(mktemp) || return 1
    candidate=$(mktemp) || { rm -f -- "$before"; return 1; }
    cp -a "$config" "$before" || { rm -f -- "$before" "$candidate"; return 1; }

    case "$engine" in
        xray)
            jq --arg tag "$tag" --arg listen "$listen" --argjson port "$port" \
                '(.inbounds[]|select(.tag==$tag)|.listen)=$listen | (.inbounds[]|select(.tag==$tag)|.port)=$port' \
                "$config" >"$candidate"
            ;;
        singbox)
            jq --arg tag "$tag" --arg listen "$listen" --argjson port "$port" \
                '(.inbounds[]|select(.tag==$tag)|.listen)=$listen | (.inbounds[]|select(.tag==$tag)|.listen_port)=$port' \
                "$config" >"$candidate"
            ;;
        *) rm -f -- "$before" "$candidate"; error "Unknown engine: ${engine}"; return 1 ;;
    esac

    if ! apply_candidate "$engine" "$candidate"; then
        rm -f -- "$before" "$candidate"
        return 1
    fi
    rm -f -- "$candidate"

    # Derived runtime state (notably HY2 redirects) must agree with the new
    # internal port. If it cannot be rebuilt, restore the old validated config.
    if ! inbound_post_change "$engine" modify-listen "$tag"; then
        error "Runtime synchronization failed after modifying ${engine}/${tag}; restoring the previous config."
        if ! apply_candidate "$engine" "$before"; then
            rm -f -- "$before"
            critical "Failed to restore ${engine}/${tag} after runtime synchronization failure."
            return 1
        fi
        inbound_post_change "$engine" rollback-modify-listen "$tag" >/dev/null 2>&1 || true
        rm -f -- "$before"
        return 1
    fi
    rm -f -- "$before"

    old_host=$(inbound_meta_get "$engine" "$tag" clientHost 2>/dev/null || true)
    [[ -n "$client_host" ]] || client_host="$old_host"
    if [[ -n "$client_host" ]]; then
        # Preserve all non-host auxiliary fields while changing only clientHost.
        if ! _metadata_atomic_jq --arg engine "$engine" --arg tag "$tag" --arg host "$client_host" --arg now "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" '
            .inbounds[$engine] = (.inbounds[$engine] // {}) |
            .inbounds[$engine][$tag] = (.inbounds[$engine][$tag] // {realityPublicKey:"",hy2HopRange:""}) |
            .inbounds[$engine][$tag].clientHost=$host |
            .inbounds[$engine][$tag].updatedAt=$now'; then
            warn 'Listen settings were changed, but auxiliary client-host metadata could not be updated.'
        fi
    fi

    info "Inbound listen updated: ${engine}/${tag} -> ${listen}:${port}"
}
