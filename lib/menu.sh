#!/usr/bin/env bash
# ------------------------------------------------------------------------------
# menu.sh — ProxyCTL 交互菜单
# ------------------------------------------------------------------------------

menu_action() {
    if "$@"; then
        info '操作完成。'
    else
        warn '操作未完成，请查看上方错误信息。'
    fi
    pause '按 Enter 返回菜单...'
    return 0
}

menu_select_engine() {
    local __out_var="$1"
    local _ms_installed_only="${2:-0}"
    local _ms_engine=''
    local _ms_seen=''
    local _ms_options=()

    # Stable user-facing order: Xray first, sing-box second.
    for _ms_engine in xray singbox; do
        engine_exists "$_ms_engine" || continue
        if [[ "$_ms_installed_only" == 1 ]] && ! engine_call "$_ms_engine" installed >/dev/null 2>&1; then
            continue
        fi
        _ms_options+=("$_ms_engine")
        _ms_seen+=" ${_ms_engine} "
    done

    # Preserve compatibility with any future registered engines.
    while IFS= read -r _ms_engine; do
        [[ -n "$_ms_engine" ]] || continue
        [[ "$_ms_seen" == *" ${_ms_engine} "* ]] && continue
        if [[ "$_ms_installed_only" == 1 ]] && ! engine_call "$_ms_engine" installed >/dev/null 2>&1; then
            continue
        fi
        _ms_options+=("$_ms_engine")
    done < <(engine_list)

    ((${#_ms_options[@]})) || { warn '没有可用的核心。'; return 1; }
    if ((${#_ms_options[@]} == 1)); then
        printf -v "$__out_var" '%s' "${_ms_options[0]}"
    else
        choose "$__out_var" '选择核心：' "${_ms_options[@]}"
    fi
}

menu_select_inbound() {
    local __out_engine="$1"
    local __out_tag="$2"
    local _msi_engine=''
    local _msi_tag=''
    local _msi_tags=()

    menu_select_engine _msi_engine 1 || return 1
    inbound_config_require "$_msi_engine" || return 1
    while IFS= read -r _msi_tag; do
        [[ -n "$_msi_tag" ]] && _msi_tags+=("$_msi_tag")
    done < <(jq -r '.inbounds[].tag' "$(inbound_config_file "$_msi_engine")")
    ((${#_msi_tags[@]})) || { warn "${_msi_engine} 当前没有入站。"; return 1; }
    if ((${#_msi_tags[@]} == 1)); then
        _msi_tag=${_msi_tags[0]}
    else
        choose _msi_tag "选择 ${_msi_engine} 入站：" "${_msi_tags[@]}" || return 1
    fi
    printf -v "$__out_engine" '%s' "$_msi_engine"
    printf -v "$__out_tag" '%s' "$_msi_tag"
}

menu_select_client() {
    local __out_var="$1"
    local _msc_engine="$2"
    local _msc_tag="$3"
    local _msc_label=''
    local _msc_labels=()

    while IFS=$'\t' read -r _msc_label _; do
        [[ -n "$_msc_label" ]] && _msc_labels+=("$_msc_label")
    done < <(inbound_clients "$_msc_engine" "$_msc_tag")
    ((${#_msc_labels[@]})) || { warn '该入站当前没有用户。'; return 1; }
    if ((${#_msc_labels[@]} == 1)); then
        printf -v "$__out_var" '%s' "${_msc_labels[0]}"
    else
        choose "$__out_var" '选择用户：' "${_msc_labels[@]}"
    fi
}

menu_select_outbound() {
    local __out_engine="$1"
    local __out_tag="$2"
    local _mso_engine=''
    local _mso_tag=''
    local _mso_tags=()

    menu_select_engine _mso_engine 1 || return 1
    while IFS= read -r _mso_tag; do
        [[ -n "$_mso_tag" ]] || continue
        outbound_exists "$_mso_engine" "$_mso_tag" && _mso_tags+=("$_mso_tag")
    done < <(outbound_meta_list_managed "$_mso_engine")
    ((${#_mso_tags[@]})) || { warn "${_mso_engine} 没有由 ProxyCTL 创建、可安全删除的出站。"; return 1; }
    if ((${#_mso_tags[@]} == 1)); then
        _mso_tag=${_mso_tags[0]}
    else
        choose _mso_tag "选择 ${_mso_engine} 出站：" "${_mso_tags[@]}" || return 1
    fi
    printf -v "$__out_engine" '%s' "$_mso_engine"
    printf -v "$__out_tag" '%s' "$_mso_tag"
}

menu_backup_ids() {
    local _mb_root _mb_path
    _mb_root=$(backup_root)
    for _mb_path in "$_mb_root"/proxyctl-*.tar.gz; do
        [[ -f "$_mb_path" && ! -L "$_mb_path" ]] || continue
        printf '%s\n' "${_mb_path##*/}"
    done | sort -r
}

menu_main() {
    local choice=''
    while true; do
        ui_clear_screen
        heading 'ProxyCTL 统一代理管理器'
        choice=''
        choose choice '主菜单' \
            '入站管理' \
            '出站管理' \
            'TLS 证书' \
            '核心管理' \
            '系统工具' \
            '备份与恢复' \
            '退出' || { echo '已退出 ProxyCTL。'; return 0; }
        case "$choice" in
            '入站管理') menu_inbound ;;
            '出站管理') menu_outbound ;;
            'TLS 证书') menu_certificates ;;
            '核心管理') menu_core ;;
            '系统工具') menu_system ;;
            '备份与恢复') menu_backup ;;
            '退出') echo '已退出 ProxyCTL。'; return 0 ;;
        esac
    done
}

menu_inbound() {
    local choice='' engine='' tag=''
    while true; do
        ui_clear_screen
        heading '入站管理'
        choice=''; engine=''; tag=''
        choose choice '入站管理' '查看全部入站' '新增入站' '管理已有入站' '返回' || return
        case "$choice" in
            '查看全部入站') menu_action cmd_inbound list ;;
            '新增入站') menu_select_engine engine 1 || { pause; continue; }; menu_action inbound_add_interactive "$engine" ;;
            '管理已有入站') menu_select_inbound engine tag || { pause; continue; }; menu_inbound_manage "$engine" "$tag" ;;
            '返回') return ;;
        esac
    done
}

menu_inbound_manage() {
    local engine="$1" tag="$2"
    local choice='' new_tag='' answer='' config='' listen='' port='' client_host=''
    while inbound_exists "$engine" "$tag"; do
        ui_clear_screen
        heading "入站 · ${engine}/${tag}"
        choice=''
        choose choice '入站操作' '查看 JSON' '分享信息 / 客户端配置' '用户管理' '设置出站' '修改监听 / 客户端地址' '重命名入站' '删除入站' '返回' || return
        case "$choice" in
            '查看 JSON') menu_action inbound_show "$engine" "$tag" ;;
            '分享信息 / 客户端配置') menu_action inbound_share "$engine" "$tag" ;;
            '用户管理') menu_clients "$engine" "$tag" ;;
            '设置出站') menu_action outbound_assign_interactive "$engine" "$tag" ;;
            '修改监听 / 客户端地址')
                config=$(inbound_config_file "$engine") || { pause; continue; }
                listen=$(jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.listen // "0.0.0.0"' "$config")
                if [[ "$engine" == xray ]]; then
                    port=$(jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.port' "$config")
                else
                    port=$(jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.listen_port' "$config")
                fi
                client_host=$(inbound_meta_get "$engine" "$tag" clientHost 2>/dev/null || true)
                prompt_value listen '监听地址' "$listen" || continue
                prompt_value port '监听端口' "$port" || continue
                prompt_optional client_host "客户端连接地址（当前：${client_host:-自动}）" || true
                menu_action inbound_modify_listen "$engine" "$tag" "$listen" "$port" "$client_host"
                ;;
            '重命名入站')
                prompt_value new_tag '新的入站名称' "$tag" || continue
                if inbound_rename "$engine" "$tag" "$new_tag"; then
                    tag=$new_tag
                    info '入站重命名完成。'
                else
                    warn '入站重命名失败。'
                fi
                pause '按 Enter 返回菜单...'
                ;;
            '删除入站')
                confirm answer "确定删除 ${engine}/${tag} 以及其中全部用户吗？" n || continue
                if [[ "$answer" == y ]]; then menu_action inbound_delete "$engine" "$tag"; return; fi
                ;;
            '返回') return ;;
        esac
    done
}

menu_clients() {
    local engine="$1" tag="$2"
    local choice='' user='' label='' new_name='' answer=''
    while true; do
        ui_clear_screen
        heading "用户管理 · ${engine}/${tag}"
        inbound_clients "$engine" "$tag" || true
        choice=''; user=''; label=''; new_name=''; answer=''
        choose choice '用户管理' '添加用户' '重命名用户' '更换凭据' '删除用户' '返回' || return
        case "$choice" in
            '添加用户')
                prompt_value label '用户名' "user-$(inbound_random_hex 2)" || continue
                menu_action inbound_client_add "$engine" "$tag" "$label"
                ;;
            '重命名用户')
                menu_select_client user "$engine" "$tag" || { pause; continue; }
                prompt_value new_name '新的用户名' "$user" || continue
                menu_action inbound_client_rename "$engine" "$tag" "$user" "$new_name"
                ;;
            '更换凭据')
                menu_select_client user "$engine" "$tag" || { pause; continue; }
                confirm answer "确定更换 ${user} 的凭据吗？旧凭据将立即失效。" n || continue
                [[ "$answer" == y ]] && menu_action inbound_client_rotate "$engine" "$tag" "$user"
                ;;
            '删除用户')
                menu_select_client user "$engine" "$tag" || { pause; continue; }
                confirm answer "确定删除用户 ${user} 吗？" n || continue
                [[ "$answer" == y ]] && menu_action inbound_client_delete "$engine" "$tag" "$user"
                ;;
            '返回') return ;;
        esac
    done
}

menu_outbound() {
    local choice='' engine='' tag='' inbound='' answer=''
    while true; do
        ui_clear_screen
        heading '出站管理'
        choice=''; engine=''; tag=''; inbound=''; answer=''
        choose choice '出站管理' '查看出站 / 绑定关系' '新增出站' '为入站设置出站' '删除 ProxyCTL 出站' '返回' || return
        case "$choice" in
            '查看出站 / 绑定关系') menu_action cmd_outbound list ;;
            '新增出站')
                menu_select_engine engine 1 || { pause; continue; }
                menu_action outbound_add_interactive "$engine"
                ;;
            '为入站设置出站')
                menu_select_inbound engine inbound || { pause; continue; }
                menu_action outbound_assign_interactive "$engine" "$inbound"
                ;;
            '删除 ProxyCTL 出站')
                menu_select_outbound engine tag || { pause; continue; }
                confirm answer "确定删除 ProxyCTL 创建的出站 ${engine}/${tag} 吗？相关入站将恢复为 direct。" n || continue
                [[ "$answer" == y ]] && menu_action outbound_delete "$engine" "$tag"
                ;;
            '返回') return ;;
        esac
    done
}

menu_core() {
    local choice='' engine='' version='' answer=''
    while true; do
        ui_clear_screen
        heading '核心管理'
        choice=''; engine=''; version=''; answer=''
        choose choice '核心管理' '查看核心状态' '安装 / 修复核心' '更新核心' '卸载核心' '启动核心' '停止核心' '重启核心' '开启开机自启' '关闭开机自启' '查看日志' '返回' || return
        case "$choice" in
            '查看核心状态') menu_action cmd_status ;;
            '安装 / 修复核心'|'更新核心')
                menu_select_engine engine 0 || { pause; continue; }
                prompt_optional version '版本号（留空 = 最新版）' || true
                if [[ "$choice" == '安装 / 修复核心' ]]; then
                    menu_action engine_call "$engine" install "$version"
                else
                    menu_action engine_call "$engine" update "$version"
                fi
                ;;
            '卸载核心')
                menu_select_engine engine 1 || { pause; continue; }
                confirm answer "确定卸载 ${engine} 核心吗？配置、证书和备份都会保留。" n || continue
                [[ "$answer" == y ]] && menu_action engine_call "$engine" uninstall
                ;;
            '启动核心'|'停止核心'|'重启核心'|'开启开机自启'|'关闭开机自启')
                menu_select_engine engine 1 || { pause; continue; }
                case "$choice" in
                    '启动核心') menu_action engine_call "$engine" start ;;
                    '停止核心') menu_action engine_call "$engine" stop ;;
                    '重启核心') menu_action engine_call "$engine" restart ;;
                    '开启开机自启') menu_action engine_call "$engine" enable ;;
                    '关闭开机自启') menu_action engine_call "$engine" disable ;;
                esac
                ;;
            '查看日志') menu_select_engine engine 1 || { pause; continue; }; menu_action engine_call "$engine" logs 100 ;;
            '返回') return ;;
        esac
    done
}

menu_certificates() {
    local choice='' subject='' email='' validation='' id='' cert='' key='' answer=''
    local ids=()
    while true; do
        ui_clear_screen
        heading 'TLS 证书管理'
        cert_list || true
        choice=''; subject=''; email=''; validation=''; id=''; cert=''; key=''; answer=''; ids=()
        choose choice '证书管理' '签发证书' '生成自签名证书' '导入已有证书' '续期证书' '删除证书' '配置 Cloudflare' '返回' || return
        case "$choice" in
            '签发证书')
                prompt_value subject '域名或公网 IP' || continue
                prompt_value email 'ACME 邮箱' || continue
                choose validation '选择验证方式' http dns-cloudflare dns-manual || continue
                menu_action cert_acme_issue "$subject" "$email" "$validation" 0
                ;;
            '生成自签名证书') prompt_value subject '域名或 IP' || continue; menu_action cert_generate_self "$subject" ;;
            '导入已有证书')
                prompt_value id '证书标识' || continue
                prompt_value cert '完整证书链路径' || continue
                prompt_value key '私钥路径' || continue
                menu_action cert_import "$id" "$cert" "$key"
                ;;
            '续期证书')
                while IFS= read -r id; do [[ -n "$id" ]] && ids+=("$id"); done < <(metadata_cert_list)
                ((${#ids[@]})) || { warn '当前没有托管证书。'; pause; continue; }
                if ((${#ids[@]} == 1)); then id=${ids[0]}; else choose id '选择证书：' "${ids[@]}" || continue; fi
                menu_action cert_renew "$id"
                ;;
            '删除证书')
                while IFS= read -r id; do [[ -n "$id" ]] && ids+=("$id"); done < <(metadata_cert_list)
                ((${#ids[@]})) || { warn '当前没有托管证书。'; pause; continue; }
                if ((${#ids[@]} == 1)); then id=${ids[0]}; else choose id '选择证书：' "${ids[@]}" || continue; fi
                confirm answer "确定删除托管证书 ${id} 吗？" n || continue
                [[ "$answer" == y ]] && menu_action cert_delete "$id"
                ;;
            '配置 Cloudflare') menu_action cmd_cert cloudflare ;;
            '返回') return ;;
        esac
    done
}

menu_backup() {
    local choice='' label='' id='' answer=''
    local ids=()
    while true; do
        ui_clear_screen
        heading '备份与恢复'
        backup_list || true
        choice=''; label=''; id=''; answer=''; ids=()
        choose choice '备份管理' '创建备份' '恢复备份' '返回' || return
        case "$choice" in
            '创建备份') prompt_optional label '备份标签（可留空）' || true; menu_action backup_create "$label" ;;
            '恢复备份')
                while IFS= read -r id; do [[ -n "$id" ]] && ids+=("$id"); done < <(menu_backup_ids)
                ((${#ids[@]})) || { warn '没有可用备份。'; pause; continue; }
                if ((${#ids[@]} == 1)); then id=${ids[0]}; else choose id '选择备份：' "${ids[@]}" || continue; fi
                confirm answer "确定恢复 ${id} 吗？恢复前会自动保存当前状态用于回滚。" n || continue
                [[ "$answer" == y ]] && menu_action proxyctl_backup_restore "$id"
                ;;
            '返回') return ;;
        esac
    done
}

menu_system() {
    local choice='' engine=''
    while true; do
        ui_clear_screen
        heading '系统工具'
        choice=''; engine=''
        choose choice '系统工具' '查看 BBR 状态' '接管 / 同步已有配置' '返回' || return
        case "$choice" in
            '查看 BBR 状态') menu_action bbr_status ;;
            '接管 / 同步已有配置')
                choose engine '选择要同步的配置' xray singbox both || continue
                if [[ "$engine" == both ]]; then menu_action proxyctl_reconcile; else menu_action proxyctl_reconcile "$engine"; fi
                ;;
            '返回') return ;;
        esac
    done
}
