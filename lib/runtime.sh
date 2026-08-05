#!/usr/bin/env bash
# ------------------------------------------------------------------------------
# runtime.sh — runtime state derived from durable ProxyCTL configuration
# ------------------------------------------------------------------------------

# hy2_hop.sh owns the original sing-box post-change hook. Runtime is sourced
# after outbound adapters, so compose both concerns here instead of letting one
# module silently overwrite the other.
engine_singbox_inbound_post_change() {
    local action="$1" tag="${2:-}" old="${3:-}"

    if declare -F singbox_outbound_inbound_post_change >/dev/null 2>&1; then
        singbox_outbound_inbound_post_change "$action" "$tag" "$old" || return 1
    fi

    _singbox_hy2_hop_validate_all || return 1
    if (( $(singbox_hy2_hop_count 2>/dev/null || echo 0) > 0 )); then
        singbox_hy2_hop_sync
    else
        singbox_hy2_hop_clear >/dev/null 2>&1 || true
        _singbox_hy2_hop_boot_service_remove
    fi
}

proxyctl_runtime_sync() {
    local rc=0

    # Certificate copies are restored through _cert_replace_pair, which already
    # fixes ownership/mode. Refresh drop-ins/groups once more after a migration
    # because the destination machine's service users may differ.
    if declare -F _cert_setup_runtime_access >/dev/null 2>&1 && system_is_root; then
        _cert_setup_runtime_access || rc=1
    fi

    # Hysteria2 hop rules and their boot service are derived from sing-box config
    # + metadata and are intentionally not stored in backup archives.
    if declare -F singbox_hy2_hop_count >/dev/null 2>&1; then
        if (( $(singbox_hy2_hop_count 2>/dev/null || echo 0) > 0 )); then
            if engine_call singbox installed >/dev/null 2>&1; then
                singbox_hy2_hop_sync || rc=1
            else
                warn 'Hysteria2 hop metadata was restored, but sing-box is not installed; runtime redirects will be recreated after core installation.'
            fi
        else
            # Remove stale runtime state when the restored snapshot has no hops.
            if system_is_root; then
                singbox_hy2_hop_clear >/dev/null 2>&1 || rc=1
                _singbox_hy2_hop_boot_service_remove
            fi
        fi
    fi

    return "$rc"
}

proxyctl_backup_restore() {
    local id="$1"
    backup_restore "$id" || return 1
    if ! proxyctl_runtime_sync; then
        critical 'Backup files/configuration were restored, but derived runtime state could not be synchronized completely.'
        critical 'Review certificate service access and Hysteria2 port-hopping rules before considering the migration complete.'
        return 1
    fi
}
