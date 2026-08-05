#!/usr/bin/env bash
# ------------------------------------------------------------------------------
# inbound_edit.sh — shared safe edits that do not depend on engine JSON schema
# ------------------------------------------------------------------------------

# The entrypoint always loads inbound_edit.sh after inbound.sh. Load the strict
# port-availability override here so add and edit operations share the same
# cross-engine/OS checks without bloating the orchestration module.
_inbound_safety_path="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/inbound_safety.sh"
if [[ -r "$_inbound_safety_path" ]]; then
    # shellcheck disable=SC1090
    source "$_inbound_safety_path"
else
    error "Missing inbound safety module: ${_inbound_safety_path}"
    return 1
fi
unset _inbound_safety_path

_inbound_modify_listen_locked() {
    local engine="$1" tag="$2" listen="$3" port="$4" client_host="${5:-}"
    local config before meta_before candidate old_host old_port skip_os=0

    inbound_exists "$engine" "$tag" || { error "Inbound not found: ${engine}/${tag}"; return 1; }
    network_validate_ip "$listen" || { error 'Listen address must be an IPv4/IPv6 address.'; return 1; }
    port_validate "$port" || { error 'Port must be 1-65535.'; return 1; }
    [[ -z "$client_host" ]] || network_validate_host "$client_host" || { error 'Client address must be an IP or domain.'; return 1; }

    config=$(inbound_config_file "$engine") || return 1
    case "$engine" in
        xray) old_port=$(jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.port' "$config") ;;
        singbox) old_port=$(jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.listen_port' "$config") ;;
        *) error "Unknown engine: ${engine}"; return 1 ;;
    esac
    [[ "$port" != "$old_port" ]] || skip_os=1
    inbound_port_require_available "$engine" "$port" "$tag" "$skip_os" || return 1

    before=$(mktemp) || return 1
    meta_before=$(mktemp) || { rm -f -- "$before"; return 1; }
    candidate=$(mktemp) || { rm -f -- "$before" "$meta_before"; return 1; }
    cp -a -- "$config" "$before" || { rm -f -- "$before" "$meta_before" "$candidate"; return 1; }
    _inbound_snapshot_metadata "$meta_before" || { rm -f -- "$before" "$meta_before" "$candidate"; return 1; }

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
    esac

    if ! apply_candidate "$engine" "$candidate"; then
        rm -f -- "$before" "$meta_before" "$candidate"
        return 1
    fi
    rm -f -- "$candidate"

    old_host=$(inbound_meta_get "$engine" "$tag" clientHost 2>/dev/null || true)
    [[ -n "$client_host" ]] || client_host="$old_host"
    if [[ -n "$client_host" ]]; then
        if ! _metadata_atomic_jq --arg engine "$engine" --arg tag "$tag" --arg host "$client_host" --arg now "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" '
            .inbounds[$engine] = (.inbounds[$engine] // {}) |
            .inbounds[$engine][$tag] = (.inbounds[$engine][$tag] // {realityPublicKey:"",hy2HopRange:""}) |
            .inbounds[$engine][$tag].clientHost=$host |
            .inbounds[$engine][$tag].updatedAt=$now'; then
            error "Metadata update failed after modifying ${engine}/${tag}; rolling back."
            if _inbound_rollback_mutation "$engine" "$before" "$meta_before" modify-listen "$tag"; then
                rm -f -- "$before" "$meta_before"
            else
                critical "Listen-edit rollback is incomplete. Recovery snapshots preserved: ${before} ${meta_before}"
            fi
            return 1
        fi
    fi

    if ! inbound_post_change "$engine" modify-listen "$tag"; then
        error "Runtime synchronization failed after modifying ${engine}/${tag}; rolling back."
        if _inbound_rollback_mutation "$engine" "$before" "$meta_before" modify-listen "$tag"; then
            rm -f -- "$before" "$meta_before"
        else
            critical "Listen-edit rollback is incomplete. Recovery snapshots preserved: ${before} ${meta_before}"
        fi
        return 1
    fi

    rm -f -- "$before" "$meta_before"
    info "Inbound listen updated: ${engine}/${tag} -> ${listen}:${port}"
}

inbound_modify_listen() {
    _inbound_with_config_lock _inbound_modify_listen_locked "$@"
}
