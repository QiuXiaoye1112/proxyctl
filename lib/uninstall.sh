#!/usr/bin/env bash
# ------------------------------------------------------------------------------
# uninstall.sh — ProxyCTL self-uninstall and explicit destructive purge
#
# Default: remove manager executable/library only; preserve cores, configs,
# certificates, metadata and backups. Runtime helpers that call the manager are
# disabled first. HY2 port hopping blocks manager-only uninstall unless --force
# because it would otherwise stop being restorable after reboot.
#
# Purge: explicit --purge --yes only. Removes both cores and all ProxyCTL/node
# state. This is intentionally destructive and never selected by default.
# ------------------------------------------------------------------------------

_uninstall_root_path() {
    local path="$1" root="${PROXYCTL_UNINSTALL_ROOT:-/}"
    if [[ "$root" == / ]]; then printf '%s\n' "$path"; else printf '%s%s\n' "${root%/}" "$path"; fi
}

_uninstall_require_root() {
    system_is_root && return 0
    error 'ProxyCTL uninstall requires root.'
    return 1
}

_uninstall_remove_cert_timer() {
    local unit_dir service timer
    unit_dir=$(_uninstall_root_path "${PROXYCTL_SYSTEMD_UNIT_DIR:-/etc/systemd/system}")
    service="${unit_dir}/proxyctl-certbot-renew.service"
    timer="${unit_dir}/proxyctl-certbot-renew.timer"

    if [[ "${PROXYCTL_UNINSTALL_ROOT:-/}" == / && "$(system_init 2>/dev/null || true)" == systemd ]]; then
        systemctl disable --now proxyctl-certbot-renew.timer >/dev/null 2>&1 || true
    fi
    for file in "$service" "$timer"; do
        [[ -e "$file" || -L "$file" ]] || continue
        [[ ! -L "$file" ]] || { warn "Refusing symlink renewal unit during uninstall: ${file}"; continue; }
        # Accept both the current exact ExecStart contract and future marker.
        if grep -Fq 'ProxyCTL' "$file" 2>/dev/null || grep -Fq ' cert renew-auto' "$file" 2>/dev/null; then
            rm -f -- "$file"
        else
            warn "Renewal unit is not recognizably ProxyCTL-owned; leaving it untouched: ${file}"
        fi
    done
    if [[ "${PROXYCTL_UNINSTALL_ROOT:-/}" == / && "$(system_init 2>/dev/null || true)" == systemd ]]; then
        systemctl daemon-reload >/dev/null 2>&1 || true
    fi
}

_uninstall_remove_hy2_boot_helper() {
    local init unit
    init=$(system_init 2>/dev/null || true)
    case "$init" in
        systemd)
            unit=$(_uninstall_root_path "${PROXYCTL_SYSTEMD_UNIT_DIR:-/etc/systemd/system}/proxyctl-hy2-hop.service")
            if [[ "${PROXYCTL_UNINSTALL_ROOT:-/}" == / ]]; then systemctl disable proxyctl-hy2-hop.service >/dev/null 2>&1 || true; fi
            if [[ -f "$unit" && ! -L "$unit" ]] && grep -Fq 'ProxyCTL Hysteria2' "$unit" 2>/dev/null; then rm -f -- "$unit"; fi
            if [[ "${PROXYCTL_UNINSTALL_ROOT:-/}" == / ]]; then systemctl daemon-reload >/dev/null 2>&1 || true; fi
            ;;
        openrc)
            unit=$(_uninstall_root_path "${PROXYCTL_OPENRC_INIT_DIR:-/etc/init.d}/proxyctl-hy2-hop")
            if [[ "${PROXYCTL_UNINSTALL_ROOT:-/}" == / ]]; then rc-update del proxyctl-hy2-hop default >/dev/null 2>&1 || true; fi
            if [[ -f "$unit" && ! -L "$unit" ]] && grep -Fq 'managed by ProxyCTL' "$unit" 2>/dev/null; then rm -f -- "$unit"; fi
            ;;
    esac
}

_uninstall_manager_paths() {
    local bin lib link
    bin=$(_uninstall_root_path "${PROXYCTL_BIN:-/usr/local/sbin/proxyctl}")
    lib=$(_uninstall_root_path "${PROXYCTL_LIB:-/usr/local/lib/proxyctl}")
    link=$(_uninstall_root_path '/usr/local/bin/proxyctl')

    if [[ -L "$link" ]]; then
        local target
        target=$(readlink "$link" 2>/dev/null || true)
        if [[ "$target" == "${PROXYCTL_BIN:-/usr/local/sbin/proxyctl}" || "$target" == "$bin" ]]; then
            rm -f -- "$link"
        else
            warn "Not removing unrelated proxyctl symlink target: ${link} -> ${target}"
        fi
    elif [[ -e "$link" ]]; then
        warn "Not removing non-symlink path: ${link}"
    fi

    [[ ! -L "$bin" ]] || { error "Refusing symlink manager binary path: ${bin}"; return 1; }
    [[ ! -L "$lib" ]] || { error "Refusing symlink manager library path: ${lib}"; return 1; }
    rm -f -- "$bin"
    rm -rf -- "$lib"
}

_uninstall_manager_only() {
    local force="${1:-0}" hop_count=0
    _uninstall_require_root || return 1
    if declare -F singbox_hy2_hop_count >/dev/null 2>&1; then
        hop_count=$(singbox_hy2_hop_count 2>/dev/null || echo 0)
    fi
    if (( hop_count > 0 )) && [[ "$force" != 1 ]]; then
        error "${hop_count} Hysteria2 port-hopping inbound(s) depend on ProxyCTL for boot-time rule restoration."
        error 'Refusing manager-only uninstall. Re-run with --force only if you accept losing hop-rule restoration after reboot.'
        return 1
    fi

    _uninstall_remove_cert_timer
    _uninstall_remove_hy2_boot_helper
    if (( hop_count > 0 )); then
        warn 'Hysteria2 redirects currently installed in the kernel may keep working until reboot, but boot-time restoration is now disabled.'
    fi
    if metadata_cert_list 2>/dev/null | while IFS= read -r id; do [[ -n "$id" ]] && [[ "$(metadata_cert_get_field "$id" autoRenew 2>/dev/null || true)" == true ]] && exit 0; done; then
        warn 'Managed certificates were preserved, but ProxyCTL automatic renewal is disabled because the manager is being removed.'
    fi
    _uninstall_manager_paths || return 1
    info 'ProxyCTL manager removed. Cores, configs, certificates, metadata and backups were preserved.'
}

_uninstall_remove_cert_dropins() {
    local engine service dir file changed=0
    [[ "$(system_init 2>/dev/null || true)" == systemd ]] || return 0
    for engine in xray singbox; do
        service=$(engine_call "$engine" service_name 2>/dev/null || true)
        [[ -n "$service" ]] || continue
        dir="${PROXYCTL_SYSTEMD_UNIT_DIR:-/etc/systemd/system}/${service}.service.d"
        file="${dir}/20-proxyctl-certificates.conf"
        if [[ -f "$file" && ! -L "$file" ]] && grep -Fq 'SupplementaryGroups=' "$file" 2>/dev/null; then
            rm -f -- "$file"; rmdir "$dir" 2>/dev/null || true; changed=1
        fi
    done
    (( changed == 0 )) || systemctl daemon-reload >/dev/null 2>&1 || true
}

_uninstall_purge_state() {
    local path group
    _uninstall_remove_cert_timer
    if declare -F singbox_hy2_hop_clear >/dev/null 2>&1; then singbox_hy2_hop_clear >/dev/null 2>&1 || true; fi
    _uninstall_remove_hy2_boot_helper

    # Remove cores first while adapters and service helpers are still loaded.
    for engine in xray singbox; do
        if engine_call "$engine" installed >/dev/null 2>&1; then
            engine_call "$engine" uninstall || { error "Failed to uninstall ${engine}; purge aborted before deleting saved state."; return 1; }
        fi
    done
    _uninstall_remove_cert_dropins

    # Explicit purge deletes the real engine config roots, not just metadata.
    for path in \
        "$(dirname "$(engine_xray_config_file)")" \
        "$(dirname "$(engine_singbox_config_file)")" \
        "$PROXYCTL_CERTS" "$PROXYCTL_DATA" "$PROXYCTL_BACKUP" \
        "$(certbot_venv)" "$(certbot_config_dir)" "$(certbot_work_dir)" "$(certbot_logs_dir)"; do
        [[ -n "$path" && "$path" == /* && "$path" != / ]] || { critical "Refusing unsafe purge path: ${path}"; return 1; }
        [[ ! -L "$path" ]] || { critical "Refusing symlink purge path: ${path}"; return 1; }
        rm -rf -- "$path"
    done
    path=$(cert_cloudflare_file)
    [[ ! -L "$path" ]] || { critical "Refusing symlink credential path: ${path}"; return 1; }
    rm -f -- "$path"
    rmdir /etc/proxyctl 2>/dev/null || true
    rmdir /var/lib/proxyctl/letsencrypt 2>/dev/null || true
    rmdir /var/log/proxyctl 2>/dev/null || true

    group=$(cert_runtime_group 2>/dev/null || true)
    if [[ -n "$group" && "$group" == proxyctl-cert ]]; then
        if command -v groupdel >/dev/null 2>&1; then groupdel "$group" >/dev/null 2>&1 || true
        elif command -v delgroup >/dev/null 2>&1; then delgroup "$group" >/dev/null 2>&1 || true
        fi
    fi
    _uninstall_manager_paths || return 1
    info 'ProxyCTL, both managed cores, configurations, certificates, metadata and backups were purged.'
}

proxyctl_uninstall() {
    local purge=0 yes=0 force=0 arg answer
    for arg in "$@"; do
        case "$arg" in
            --purge) purge=1 ;;
            --yes|-y) yes=1 ;;
            --force) force=1 ;;
            *) error "Unknown uninstall option: ${arg}"; return 1 ;;
        esac
    done
    _uninstall_require_root || return 1

    if (( purge )); then
        (( yes )) || {
            error 'Destructive purge requires explicit --purge --yes.'
            error 'This removes both cores, real configs, certificates, metadata and backups.'
            return 1
        }
        _uninstall_purge_state
        return
    fi

    if (( yes == 0 )); then
        confirm answer 'Remove ProxyCTL manager only? Cores/configs/certificates/backups will be preserved.' n || return 1
        [[ "$answer" == y ]] || return 0
    fi
    _uninstall_manager_only "$force"
}
