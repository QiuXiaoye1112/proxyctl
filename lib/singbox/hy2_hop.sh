#!/usr/bin/env bash
# ------------------------------------------------------------------------------
# singbox/hy2_hop.sh — dedicated Hysteria2 UDP port-hopping redirects
# ------------------------------------------------------------------------------

singbox_hy2_hop_count() {
    metadata_init >/dev/null || return 1
    jq '[.inbounds.singbox // {} | to_entries[] | select((.value.hy2HopRange // "") != "")]|length' "$PROXYCTL_META"
}

singbox_hy2_hop_clear_locked() {
    local cmd
    if command -v nft >/dev/null 2>&1; then
        nft delete table inet proxyctl_hy2_hop >/dev/null 2>&1 || true
    fi
    for cmd in iptables ip6tables; do
        command -v "$cmd" >/dev/null 2>&1 || continue
        "$cmd" -t nat -D PREROUTING -p udp -j PROXYCTL_HY2_HOP >/dev/null 2>&1 || true
        "$cmd" -t nat -F PROXYCTL_HY2_HOP >/dev/null 2>&1 || true
        "$cmd" -t nat -X PROXYCTL_HY2_HOP >/dev/null 2>&1 || true
    done
}

singbox_hy2_hop_clear() {
    with_lock firewall singbox_hy2_hop_clear_locked
}

_singbox_hy2_hop_backend() {
    if command -v nft >/dev/null 2>&1; then printf '%s\n' nft; return 0; fi
    if command -v iptables >/dev/null 2>&1; then printf '%s\n' iptables; return 0; fi
    system_is_root || { error 'Hysteria2 port hopping requires nftables/iptables and root to install it.'; return 1; }
    package_install nftables || return 1
    command -v nft >/dev/null 2>&1 || { error 'nftables installation did not provide nft.'; return 1; }
    printf '%s\n' nft
}

singbox_hy2_hop_check_conflicts() {
    local tag="$1" range="$2" internal_port="${3:-}" start end config other other_port other_range os_port os oe
    _singbox_validate_hop_range "$range" || return 1
    start=${range%-*}; end=${range#*-}
    [[ -z "$internal_port" ]] || ! (( internal_port >= 10#$start && internal_port <= 10#$end )) || {
        error 'Hysteria2 internal port cannot be inside its hop range.'
        return 1
    }
    config=$(engine_singbox_config_file)
    if [[ -f "$config" ]]; then
        while IFS=$'\t' read -r other other_port; do
            [[ "$other" == "$tag" || -z "$other_port" ]] && continue
            if ((10#$other_port >= 10#$start && 10#$other_port <= 10#$end)); then
                error "Hop range ${range} contains existing sing-box inbound port ${other_port} (${other})."
                return 1
            fi
        done < <(jq -r '.inbounds[]?|[.tag,(.listen_port//""|tostring)]|@tsv' "$config")
    fi
    while IFS=$'\t' read -r other other_range; do
        [[ "$other" == "$tag" || -z "$other_range" ]] && continue
        os=${other_range%-*}; oe=${other_range#*-}
        if ((10#$start <= 10#$oe && 10#$end >= 10#$os)); then
            error "Hop range ${range} overlaps ${other} (${other_range})."
            return 1
        fi
    done < <(jq -r '.inbounds.singbox // {} | to_entries[] | select((.value.hy2HopRange//"")!="") | [.key,.value.hy2HopRange]|@tsv' "$PROXYCTL_META" 2>/dev/null)

    # Inspect current UDP listeners once. Never redirect a range that would
    # capture an unrelated UDP service; the HY2 internal port itself is exempt.
    if command -v ss >/dev/null 2>&1; then
        while IFS= read -r os_port; do
            [[ "$os_port" =~ ^[0-9]+$ ]] || continue
            if (( os_port >= 10#$start && os_port <= 10#$end && os_port != internal_port )); then
                error "Hop range ${range} overlaps an existing UDP listener on port ${os_port}."
                return 1
            fi
        done < <(ss -H -lun 2>/dev/null | awk '{p=$5; sub(/^.*:/,"",p); if(p~/^[0-9]+$/) print p}' | sort -nu)
    fi
}

_singbox_hy2_hop_validate_all() {
    local config tag range target
    config=$(engine_singbox_config_file)
    [[ -f "$config" ]] || return 0
    while IFS=$'\t' read -r tag range; do
        [[ -n "$tag" && -n "$range" ]] || continue
        target=$(jq -r --arg tag "$tag" '.inbounds[]?|select(.tag==$tag and .type=="hysteria2")|.listen_port // empty' "$config")
        port_validate "$target" || { error "Hysteria2 hop metadata references a missing/invalid inbound: ${tag}"; return 1; }
        singbox_hy2_hop_check_conflicts "$tag" "$range" "$target" || return 1
    done < <(jq -r '.inbounds.singbox // {} | to_entries[] | select((.value.hy2HopRange//"")!="") | [.key,.value.hy2HopRange]|@tsv' "$PROXYCTL_META")
}

singbox_hy2_hop_restore_locked() {
    local count backend config tag range target start end cmd
    config=$(engine_singbox_config_file)
    count=$(singbox_hy2_hop_count) || return 1
    if (( count == 0 )) || [[ ! -f "$config" ]]; then
        singbox_hy2_hop_clear_locked
        return 0
    fi
    _singbox_hy2_hop_validate_all || return 1
    backend=$(_singbox_hy2_hop_backend) || return 1
    singbox_hy2_hop_clear_locked
    if [[ "$backend" == nft ]]; then
        nft add table inet proxyctl_hy2_hop || return 1
        nft 'add chain inet proxyctl_hy2_hop prerouting { type nat hook prerouting priority dstnat; policy accept; }' || return 1
        while IFS=$'\t' read -r tag range; do
            target=$(jq -r --arg tag "$tag" '.inbounds[]?|select(.tag==$tag and .type=="hysteria2")|.listen_port // empty' "$config")
            port_validate "$target" || continue
            _singbox_validate_hop_range "$range" || continue
            nft add rule inet proxyctl_hy2_hop prerouting udp dport "$range" redirect to ":${target}" comment "proxyctl:${tag}" || return 1
        done < <(jq -r '.inbounds.singbox // {} | to_entries[] | select((.value.hy2HopRange//"")!="") | [.key,.value.hy2HopRange]|@tsv' "$PROXYCTL_META")
    else
        for cmd in iptables ip6tables; do
            command -v "$cmd" >/dev/null 2>&1 || continue
            "$cmd" -t nat -N PROXYCTL_HY2_HOP >/dev/null 2>&1 || true
            "$cmd" -t nat -F PROXYCTL_HY2_HOP || return 1
            "$cmd" -t nat -C PREROUTING -p udp -j PROXYCTL_HY2_HOP >/dev/null 2>&1 || "$cmd" -t nat -A PREROUTING -p udp -j PROXYCTL_HY2_HOP || return 1
        done
        while IFS=$'\t' read -r tag range; do
            target=$(jq -r --arg tag "$tag" '.inbounds[]?|select(.tag==$tag and .type=="hysteria2")|.listen_port // empty' "$config")
            port_validate "$target" || continue
            _singbox_validate_hop_range "$range" || continue
            start=${range%-*}; end=${range#*-}
            for cmd in iptables ip6tables; do
                command -v "$cmd" >/dev/null 2>&1 || continue
                "$cmd" -t nat -A PROXYCTL_HY2_HOP -p udp --dport "${start}:${end}" -j REDIRECT --to-ports "$target" || return 1
            done
        done < <(jq -r '.inbounds.singbox // {} | to_entries[] | select((.value.hy2HopRange//"")!="") | [.key,.value.hy2HopRange]|@tsv' "$PROXYCTL_META")
    fi
}

singbox_hy2_hop_restore() {
    with_lock firewall singbox_hy2_hop_restore_locked
}

_singbox_hy2_hop_boot_service_remove() {
    local systemd_dir="${PROXYCTL_SYSTEMD_UNIT_DIR:-/etc/systemd/system}" openrc_dir="${PROXYCTL_OPENRC_INIT_DIR:-/etc/init.d}"
    case "$(system_init 2>/dev/null || true)" in
        systemd)
            systemctl disable proxyctl-hy2-hop.service >/dev/null 2>&1 || true
            rm -f -- "${systemd_dir}/proxyctl-hy2-hop.service"
            systemctl daemon-reload >/dev/null 2>&1 || true
            ;;
        openrc)
            rc-update del proxyctl-hy2-hop default >/dev/null 2>&1 || true
            rm -f -- "${openrc_dir}/proxyctl-hy2-hop"
            ;;
    esac
}

_singbox_hy2_hop_boot_service_install() {
    local target="${PROXYCTL_BIN:-/usr/local/sbin/proxyctl}" unit
    local systemd_dir="${PROXYCTL_SYSTEMD_UNIT_DIR:-/etc/systemd/system}" openrc_dir="${PROXYCTL_OPENRC_INIT_DIR:-/etc/init.d}"
    case "$(system_init 2>/dev/null || true)" in
        systemd)
            unit="${systemd_dir}/proxyctl-hy2-hop.service"
            [[ ! -L "$unit" ]] || { error "Refusing symlink unit: ${unit}"; return 1; }
            mkdir -p -- "$systemd_dir" || return 1
            cat >"$unit" <<EOF
[Unit]
Description=ProxyCTL Hysteria2 port hopping redirects
After=network-online.target
Wants=network-online.target
Before=sing-box.service

[Service]
Type=oneshot
ExecStart=${target} internal-hy2-hop-restore
ExecStop=${target} internal-hy2-hop-clear
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
            systemctl daemon-reload || return 1
            systemctl enable proxyctl-hy2-hop.service >/dev/null || return 1
            ;;
        openrc)
            unit="${openrc_dir}/proxyctl-hy2-hop"
            [[ ! -L "$unit" ]] || { error "Refusing symlink service: ${unit}"; return 1; }
            mkdir -p -- "$openrc_dir" || return 1
            cat >"$unit" <<EOF
#!/sbin/openrc-run
# managed by ProxyCTL
name="ProxyCTL Hysteria2 port hopping"
description="Restore ProxyCTL Hysteria2 UDP redirects"
depend() { need net; before sing-box; }
start() { ebegin "Restoring Hysteria2 port hopping"; ${target} internal-hy2-hop-restore; eend \$?; }
stop() { ebegin "Removing Hysteria2 port hopping"; ${target} internal-hy2-hop-clear; eend \$?; }
EOF
            chmod 755 "$unit"
            rc-update add proxyctl-hy2-hop default >/dev/null || return 1
            ;;
        *) error 'Unsupported init system for Hysteria2 port hopping.'; return 1 ;;
    esac
}

singbox_hy2_hop_sync() {
    local count
    system_is_root || { error 'Hysteria2 port hopping requires root.'; return 1; }
    count=$(singbox_hy2_hop_count) || return 1
    if (( count > 0 )); then
        _singbox_hy2_hop_validate_all || return 1
        _singbox_hy2_hop_boot_service_install || return 1
        singbox_hy2_hop_restore
    else
        singbox_hy2_hop_clear || return 1
        _singbox_hy2_hop_boot_service_remove
    fi
}

engine_singbox_inbound_post_change() {
    # Validate before writing NAT state. The shared inbound layer rolls a newly
    # created inbound back if this post-create hook fails.
    _singbox_hy2_hop_validate_all || return 1
    if (( $(singbox_hy2_hop_count 2>/dev/null || echo 0) > 0 )); then
        singbox_hy2_hop_sync
    else
        singbox_hy2_hop_clear >/dev/null 2>&1 || true
        _singbox_hy2_hop_boot_service_remove
    fi
}
