#!/usr/bin/env bash
# ------------------------------------------------------------------------------
# uninstall.sh — ProxyCTL self-uninstall and explicit destructive purge
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

_uninstall_has_auto_renew_certificates() {
    local id
    while IFS= read -r id; do
        [[ -n "$id" ]] || continue
        if [[ "$(metadata_cert_get_field "$id" autoRenew 2>/dev/null || true)" == true ]]; then return 0; fi
    done < <(metadata_cert_list 2>/dev/null || true)
    return 1
}

_uninstall_remove_cert_timer() {
    local unit_dir service timer file
    unit_dir=$(_uninstall_root_path "${PROXYCTL_SYSTEMD_UNIT_DIR:-/etc/systemd/system}")
    service="${unit_dir}/proxyctl-certbot-renew.service"
    timer="${unit_dir}/proxyctl-certbot-renew.timer"

    if [[ "${PROXYCTL_UNINSTALL_ROOT:-/}" == / && "$(system_init 2>/dev/null || true)" == systemd ]]; then
        systemctl disable --now proxyctl-certbot-renew.timer >/dev/null 2>&1 || true
    fi
    for file in "$service" "$timer"; do
        [[ -e "$file" || -L "$file" ]] || continue
        [[ ! -L "$file" ]] || { warn "Refusing symlink renewal unit during uninstall: ${file}"; continue; }
        if grep -Fq 'managed by ProxyCTL' "$file" 2>/dev/null || grep -Fq ' cert renew-auto' "$file" 2>/dev/null; then
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
    local bin lib link target
    bin=$(_uninstall_root_path "${PROXYCTL_BIN:-/usr/local/sbin/proxyctl}")
    lib=$(_uninstall_root_path "${PROXYCTL_LIB:-/usr/local/lib/proxyctl}")
    link=$(_uninstall_root_path '/usr/local/bin/proxyctl')

    if [[ -L "$link" ]]; then
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
    if declare -F singbox_hy2_hop_count >/dev/null 2>&1; then hop_count=$(singbox_hy2_hop_count 2>/dev/null || echo 0); fi
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
    if _uninstall_has_auto_renew_certificates; then
        warn 'Managed certificates were preserved, but ProxyCTL automatic renewal is disabled because the manager is being removed.'
    fi
    _uninstall_manager_paths || return 1
    info 'ProxyCTL manager removed. Cores, configs, certificates, metadata and backups were preserved.'
}

_uninstall_remove_cert_dropins() {
    local engine service dir file changed=0 unit_root expected_group
    [[ "$(system_init 2>/dev/null || true)" == systemd ]] || return 0
    unit_root=$(_uninstall_root_path "${PROXYCTL_SYSTEMD_UNIT_DIR:-/etc/systemd/system}")
    expected_group=$(cert_runtime_group 2>/dev/null || true)
    for engine in xray singbox; do
        service=$(engine_call "$engine" service_name 2>/dev/null || true)
        [[ -n "$service" ]] || continue
        dir="${unit_root}/${service}.service.d"
        file="${dir}/20-proxyctl-certificates.conf"
        [[ -f "$file" && ! -L "$file" ]] || continue
        # This exact filename is owned by ProxyCTL's certificate manager. Older
        # releases had no marker, so also accept the exact expected group line.
        if grep -Fq 'managed by ProxyCTL' "$file" 2>/dev/null || \
           { [[ -n "$expected_group" ]] && grep -Fxq "SupplementaryGroups=${expected_group}" "$file" 2>/dev/null; }; then
            rm -f -- "$file"; rmdir "$dir" 2>/dev/null || true; changed=1
        else
            warn "Certificate access drop-in has unexpected contents; leaving it untouched: ${file}"
        fi
    done
    if (( changed )) && [[ "${PROXYCTL_UNINSTALL_ROOT:-/}" == / ]]; then systemctl daemon-reload >/dev/null 2>&1 || true; fi
}

_uninstall_assert_safe_purge_path() {
    local path="$1"
    [[ -n "$path" && "$path" == /* && "$path" != / && "$path" != /usr && "$path" != /etc && "$path" != /var && "$path" != /usr/local ]] || {
        critical "Refusing unsafe purge path: ${path}"
        return 1
    }
    [[ ! -L "$path" ]] || { critical "Refusing symlink purge path: ${path}"; return 1; }
}

_uninstall_purge_state() {
    local path group config_xray config_singbox
    _uninstall_remove_cert_timer
    if declare -F singbox_hy2_hop_clear >/dev/null 2>&1 && [[ "${PROXYCTL_UNINSTALL_ROOT:-/}" == / ]]; then singbox_hy2_hop_clear >/dev/null 2>&1 || true; fi
    _uninstall_remove_hy2_boot_helper

    for engine in xray singbox; do
        if engine_call "$engine" installed >/dev/null 2>&1; then
            engine_call "$engine" uninstall || { error "Failed to uninstall ${engine}; purge aborted before deleting saved state."; return 1; }
        fi
    done
    _uninstall_remove_cert_dropins

    config_xray=$(_uninstall_root_path "$(dirname "$(engine_xray_config_file)")")
    config_singbox=$(_uninstall_root_path "$(dirname "$(engine_singbox_config_file)")")
    for path in \
        "$config_xray" "$config_singbox" \
        "$(_uninstall_root_path "$PROXYCTL_CERTS")" \
        "$(_uninstall_root_path "$PROXYCTL_DATA")" \
        "$(_uninstall_root_path "$PROXYCTL_BACKUP")" \
        "$(_uninstall_root_path "$(certbot_venv)")" \
        "$(_uninstall_root_path "$(certbot_config_dir)")" \
        "$(_uninstall_root_path "$(certbot_work_dir)")" \
        "$(_uninstall_root_path "$(certbot_logs_dir)")"; do
        _uninstall_assert_safe_purge_path "$path" || return 1
        rm -rf -- "$path"
    done

    path=$(_uninstall_root_path "$(cert_cloudflare_file)")
    _uninstall_assert_safe_purge_path "$path" || return 1
    rm -f -- "$path"
    rmdir "$(_uninstall_root_path /etc/proxyctl)" 2>/dev/null || true
    rmdir "$(_uninstall_root_path /var/lib/proxyctl/letsencrypt)" 2>/dev/null || true
    rmdir "$(_uninstall_root_path /var/log/proxyctl)" 2>/dev/null || true

    if [[ "${PROXYCTL_UNINSTALL_ROOT:-/}" == / ]]; then
        group=$(cert_runtime_group 2>/dev/null || true)
        if [[ "$group" == proxyctl-cert ]]; then
            if command -v groupdel >/dev/null 2>&1; then groupdel "$group" >/dev/null 2>&1 || true
            elif command -v delgroup >/dev/null 2>&1; then delgroup "$group" >/dev/null 2>&1 || true
            fi
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
