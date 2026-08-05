#!/usr/bin/env bash
# ------------------------------------------------------------------------------
# menu.sh — Interactive ProxyCTL menus
# All input uses ui.sh primitives; no direct read is used here.
# ------------------------------------------------------------------------------

menu_action() {
    if ! "$@"; then warn 'Operation did not complete. Review the error above.'; fi
    pause
    return 0
}

menu_select_engine() {
    local __var="$1" installed_only="${2:-0}" engine options=()
    while IFS= read -r engine; do
        [[ -n "$engine" ]] || continue
        if [[ "$installed_only" == 1 ]] && ! engine_call "$engine" installed >/dev/null 2>&1; then continue; fi
        options+=("$engine")
    done < <(engine_list)
    ((${#options[@]})) || { warn 'No matching cores are available.'; return 1; }
    if ((${#options[@]} == 1)); then printf -v "$__var" '%s' "${options[0]}"; else choose "$__var" 'Select core:' "${options[@]}"; fi
}

menu_select_inbound() {
    local __engine="$1" __tag="$2" engine tag tags=()
    menu_select_engine engine 1 || return 1
    inbound_config_require "$engine" || return 1
    while IFS= read -r tag; do [[ -n "$tag" ]] && tags+=("$tag"); done < <(jq -r '.inbounds[].tag' "$(inbound_config_file "$engine")")
    ((${#tags[@]})) || { warn "${engine} has no inbounds."; return 1; }
    if ((${#tags[@]} == 1)); then tag=${tags[0]}; else choose tag "Select ${engine} inbound:" "${tags[@]}" || return 1; fi
    printf -v "$__engine" '%s' "$engine"
    printf -v "$__tag" '%s' "$tag"
}

menu_select_client() {
    local __var="$1" engine="$2" tag="$3" label labels=()
    while IFS=$'\t' read -r label _; do [[ -n "$label" ]] && labels+=("$label"); done < <(inbound_clients "$engine" "$tag")
    ((${#labels[@]})) || { warn 'This inbound has no users.'; return 1; }
    if ((${#labels[@]} == 1)); then printf -v "$__var" '%s' "${labels[0]}"; else choose "$__var" 'Select user:' "${labels[@]}"; fi
}

menu_backup_ids() {
    local root path
    root=$(backup_root)
    for path in "$root"/proxyctl-*.tar.gz; do
        [[ -f "$path" && ! -L "$path" ]] || continue
        printf '%s\n' "${path##*/}"
    done | sort -r
}

menu_main() {
    while true; do
        heading 'ProxyCTL'
        local choice
        choose choice 'Main Menu' \
            'Inbound Management' \
            'Outbound Management' \
            'TLS Certificates' \
            'Core Management' \
            'System Tools' \
            'Backup & Restore' \
            'Exit' || { echo 'Goodbye.'; return 0; }
        case "$choice" in
            'Inbound Management') menu_inbound ;;
            'Outbound Management') warn 'Outbound management is planned for Phase 4.'; pause ;;
            'TLS Certificates') menu_certificates ;;
            'Core Management') menu_core ;;
            'System Tools') menu_system ;;
            'Backup & Restore') menu_backup ;;
            'Exit') echo 'Goodbye.'; return 0 ;;
        esac
    done
}

menu_inbound() {
    while true; do
        heading 'Inbound Management'
        local choice engine tag
        choose choice 'Inbound Management' 'List all inbounds' 'Add inbound' 'Manage inbound' 'Back' || return
        case "$choice" in
            'List all inbounds') menu_action cmd_inbound list ;;
            'Add inbound') menu_select_engine engine 1 || { pause; continue; }; menu_action inbound_add_interactive "$engine" ;;
            'Manage inbound') menu_select_inbound engine tag || { pause; continue; }; menu_inbound_manage "$engine" "$tag" ;;
            'Back') return ;;
        esac
    done
}

menu_inbound_manage() {
    local engine="$1" tag="$2" choice new_tag answer
    while inbound_exists "$engine" "$tag"; do
        heading "Inbound · ${engine}/${tag}"
        choose choice 'Inbound actions' 'Show JSON' 'Share / client config' 'User management' 'Rename' 'Delete' 'Back' || return
        case "$choice" in
            'Show JSON') menu_action inbound_show "$engine" "$tag" ;;
            'Share / client config') menu_action inbound_share "$engine" "$tag" ;;
            'User management') menu_clients "$engine" "$tag" ;;
            'Rename')
                prompt_value new_tag 'New inbound tag' "$tag" || continue
                if inbound_rename "$engine" "$tag" "$new_tag"; then tag=$new_tag; fi
                pause
                ;;
            'Delete')
                confirm answer "Delete ${engine}/${tag} and all users?" n || continue
                if [[ "$answer" == y ]]; then menu_action inbound_delete "$engine" "$tag"; return; fi
                ;;
            'Back') return ;;
        esac
    done
}

menu_clients() {
    local engine="$1" tag="$2" choice user label answer
    while true; do
        heading "Users · ${engine}/${tag}"
        inbound_clients "$engine" "$tag" || true
        choose choice 'User Management' 'Add user' 'Rotate credential' 'Delete user' 'Back' || return
        case "$choice" in
            'Add user')
                prompt_value label 'User name' "user-$(inbound_random_hex 2)" || continue
                menu_action inbound_client_add "$engine" "$tag" "$label"
                ;;
            'Rotate credential')
                menu_select_client user "$engine" "$tag" || { pause; continue; }
                confirm answer "Rotate credential for ${user}? Old credential will stop working." n || continue
                [[ "$answer" == y ]] && menu_action inbound_client_rotate "$engine" "$tag" "$user"
                ;;
            'Delete user')
                menu_select_client user "$engine" "$tag" || { pause; continue; }
                confirm answer "Delete user ${user}?" n || continue
                [[ "$answer" == y ]] && menu_action inbound_client_delete "$engine" "$tag" "$user"
                ;;
            'Back') return ;;
        esac
    done
}

menu_core() {
    while true; do
        heading 'Core Management'
        local choice engine version answer
        choose choice 'Core Management' 'View core status' 'Install / repair core' 'Update core' 'Uninstall core' 'Start core' 'Stop core' 'Restart core' 'Enable auto-start' 'Disable auto-start' 'View logs' 'Back' || return
        case "$choice" in
            'View core status') menu_action cmd_status ;;
            'Install / repair core'|'Update core')
                menu_select_engine engine 0 || { pause; continue; }
                prompt_optional version 'Version (empty = latest)' || true
                if [[ "$choice" == 'Install / repair core' ]]; then menu_action engine_call "$engine" install "$version"; else menu_action engine_call "$engine" update "$version"; fi
                ;;
            'Uninstall core')
                menu_select_engine engine 1 || { pause; continue; }
                confirm answer "Remove ${engine} core? Config, certificates and backups will be kept." n || continue
                [[ "$answer" == y ]] && menu_action engine_call "$engine" uninstall
                ;;
            'Start core'|'Stop core'|'Restart core'|'Enable auto-start'|'Disable auto-start')
                menu_select_engine engine 1 || { pause; continue; }
                case "$choice" in
                    'Start core') menu_action engine_call "$engine" start ;;
                    'Stop core') menu_action engine_call "$engine" stop ;;
                    'Restart core') menu_action engine_call "$engine" restart ;;
                    'Enable auto-start') menu_action engine_call "$engine" enable ;;
                    'Disable auto-start') menu_action engine_call "$engine" disable ;;
                esac
                ;;
            'View logs') menu_select_engine engine 1 || { pause; continue; }; menu_action engine_call "$engine" logs 100 ;;
            'Back') return ;;
        esac
    done
}

menu_certificates() {
    while true; do
        heading 'TLS Certificates'
        local choice subject email validation id cert key answer
        cert_list || true
        choose choice 'Certificate Management' 'Issue certificate' 'Generate self-signed' 'Import certificate' 'Renew certificate' 'Delete certificate' 'Configure Cloudflare' 'Back' || return
        case "$choice" in
            'Issue certificate')
                prompt_value subject 'Domain or public IP' || continue
                prompt_value email 'ACME email' || continue
                choose validation 'Validation method' http dns-cloudflare dns-manual || continue
                menu_action cert_acme_issue "$subject" "$email" "$validation" 0
                ;;
            'Generate self-signed') prompt_value subject 'Domain or IP' || continue; menu_action cert_generate_self "$subject" ;;
            'Import certificate')
                prompt_value id 'Certificate identifier' || continue
                prompt_value cert 'Fullchain path' || continue
                prompt_value key 'Private-key path' || continue
                menu_action cert_import "$id" "$cert" "$key"
                ;;
            'Renew certificate')
                local ids=(); while IFS= read -r id; do [[ -n "$id" ]] && ids+=("$id"); done < <(metadata_cert_list)
                ((${#ids[@]})) || { warn 'No managed certificates.'; pause; continue; }
                if ((${#ids[@]} == 1)); then id=${ids[0]}; else choose id 'Select certificate:' "${ids[@]}" || continue; fi
                menu_action cert_renew "$id"
                ;;
            'Delete certificate')
                local ids=(); while IFS= read -r id; do [[ -n "$id" ]] && ids+=("$id"); done < <(metadata_cert_list)
                ((${#ids[@]})) || { warn 'No managed certificates.'; pause; continue; }
                if ((${#ids[@]} == 1)); then id=${ids[0]}; else choose id 'Select certificate:' "${ids[@]}" || continue; fi
                confirm answer "Delete managed certificate ${id}?" n || continue
                [[ "$answer" == y ]] && menu_action cert_delete "$id"
                ;;
            'Configure Cloudflare') menu_action cmd_cert cloudflare ;;
            'Back') return ;;
        esac
    done
}

menu_backup() {
    while true; do
        heading 'Backup & Restore'
        local choice label id answer ids=()
        backup_list || true
        choose choice 'Backup Management' 'Create backup' 'Restore backup' 'Back' || return
        case "$choice" in
            'Create backup') prompt_optional label 'Backup label (optional)' || true; menu_action backup_create "$label" ;;
            'Restore backup')
                ids=()
                while IFS= read -r id; do [[ -n "$id" ]] && ids+=("$id"); done < <(menu_backup_ids)
                ((${#ids[@]})) || { warn 'No backups found.'; pause; continue; }
                if ((${#ids[@]} == 1)); then id=${ids[0]}; else choose id 'Select backup:' "${ids[@]}" || continue; fi
                confirm answer "Restore ${id}? Current state will be snapshotted for rollback." n || continue
                [[ "$answer" == y ]] && menu_action proxyctl_backup_restore "$id"
                ;;
            'Back') return ;;
        esac
    done
}

menu_system() {
    heading 'System Tools'
    local choice
    choose choice 'System Tools' 'Check BBR status' 'Back' || return
    case "$choice" in
        'Check BBR status') menu_action bbr_status ;;
        'Back') return ;;
    esac
}
