#!/usr/bin/env bash
# ------------------------------------------------------------------------------
# menu.sh — ProxyCTL interactive menu
# Presentation intentionally follows xrayctl's proven terminal workflow.
# ------------------------------------------------------------------------------

menu_read_choice() {
    local __out_var="$1" _menu_value=''
    printf '请选择: '
    read -r _menu_value || { printf '\n'; return 1; }
    printf -v "$__out_var" '%s' "$_menu_value"
}

menu_action() {
    local rc=0
    "$@" || rc=$?
    if ((rc != 0)); then
        warn '操作未完成，脚本仍在运行，请检查上方错误后重试。'
    fi
    pause
    return 0
}

menu_engine_action() {
    local engine="$1" action="$2" success="$3" rc=0
    engine_call "$engine" "$action" || rc=$?
    if ((rc == 0)); then info "$success"; else warn '操作未完成，请检查上方错误后重试。'; fi
    pause
    return 0
}

menu_select_engine() {
    local __out_var="$1" _ms_installed_only="${2:-0}" _ms_engine='' _ms_seen=''
    local _ms_options=()
    for _ms_engine in xray singbox; do
        engine_exists "$_ms_engine" || continue
        if [[ "$_ms_installed_only" == 1 ]] && ! engine_call "$_ms_engine" installed >/dev/null 2>&1; then continue; fi
        _ms_options+=("$_ms_engine")
        _ms_seen+=" ${_ms_engine} "
    done
    while IFS= read -r _ms_engine; do
        [[ -n "$_ms_engine" ]] || continue
        if [[ "$_ms_seen" == *" ${_ms_engine} "* ]]; then continue; fi
        if [[ "$_ms_installed_only" == 1 ]] && ! engine_call "$_ms_engine" installed >/dev/null 2>&1; then continue; fi
        _ms_options+=("$_ms_engine")
    done < <(engine_list)
    ((${#_ms_options[@]})) || { warn '没有可用的核心。'; return 1; }
    if ((${#_ms_options[@]} == 1)); then printf -v "$__out_var" '%s' "${_ms_options[0]}"; else choose "$__out_var" '选择核心' "${_ms_options[@]}"; fi
}

menu_select_inbound() {
    local __out_engine="$1" __out_tag="$2" _msi_engine='' _msi_tag=''
    local _msi_tags=()
    menu_select_engine _msi_engine 1 || return 1
    inbound_config_require "$_msi_engine" || return 1
    while IFS= read -r _msi_tag; do if [[ -n "$_msi_tag" ]]; then _msi_tags+=("$_msi_tag"); fi; done < <(jq -r '.inbounds[].tag' "$(inbound_config_file "$_msi_engine")")
    ((${#_msi_tags[@]})) || { warn "${_msi_engine} 当前没有入站。"; return 1; }
    if ((${#_msi_tags[@]} == 1)); then _msi_tag=${_msi_tags[0]}; else choose _msi_tag "选择 ${_msi_engine} 入站" "${_msi_tags[@]}" || return 1; fi
    printf -v "$__out_engine" '%s' "$_msi_engine"
    printf -v "$__out_tag" '%s' "$_msi_tag"
}

menu_select_client() {
    local __out_var="$1" _msc_engine="$2" _msc_tag="$3" _msc_label=''
    local _msc_labels=()
    while IFS=$'\t' read -r _msc_label _; do if [[ -n "$_msc_label" ]]; then _msc_labels+=("$_msc_label"); fi; done < <(inbound_clients "$_msc_engine" "$_msc_tag")
    ((${#_msc_labels[@]})) || { warn '该入站当前没有用户。'; return 1; }
    if ((${#_msc_labels[@]} == 1)); then printf -v "$__out_var" '%s' "${_msc_labels[0]}"; else choose "$__out_var" '选择用户' "${_msc_labels[@]}"; fi
}

menu_select_outbound() {
    local __out_engine="$1" __out_tag="$2" _mso_engine='' _mso_tag=''
    local _mso_tags=()
    menu_select_engine _mso_engine 1 || return 1
    while IFS= read -r _mso_tag; do
        [[ -n "$_mso_tag" ]] || continue
        if outbound_exists "$_mso_engine" "$_mso_tag"; then _mso_tags+=("$_mso_tag"); fi
    done < <(outbound_meta_list_managed "$_mso_engine")
    ((${#_mso_tags[@]})) || { warn "${_mso_engine} 没有由 ProxyCTL 添加、可安全删除的出站。"; return 1; }
    if ((${#_mso_tags[@]} == 1)); then _mso_tag=${_mso_tags[0]}; else choose _mso_tag "选择 ${_mso_engine} 出站" "${_mso_tags[@]}" || return 1; fi
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

menu_engine_state_summary() {
    local engine="$1"
    if ! engine_call "$engine" installed >/dev/null 2>&1; then printf '未安装';
    elif engine_call "$engine" is_active >/dev/null 2>&1; then printf '运行中';
    else printf '已停止'; fi
}

menu_engine_startup_summary() {
    local engine="$1" service
    engine_call "$engine" installed >/dev/null 2>&1 || { printf '未安装'; return; }
    service=$(engine_call "$engine" service_name 2>/dev/null || true)
    [[ -n "$service" ]] || { printf '未知'; return; }
    if service_is_enabled "$service" >/dev/null 2>&1; then printf '已开启'; else printf '已关闭'; fi
}

menu_engine_version_summary() {
    local engine="$1" output first
    engine_call "$engine" installed >/dev/null 2>&1 || { printf '-'; return; }
    output=$(engine_call "$engine" version 2>/dev/null || true)
    first=${output%%$'\n'*}
    [[ -n "$first" ]] && printf '%s' "$first" || printf 'unknown'
}

menu_engine_inbound_count() {
    local engine="$1" config count
    config=$(engine_call "$engine" config_file 2>/dev/null || true)
    [[ -f "$config" && ! -L "$config" ]] || { printf '0'; return; }
    count=$(jq -r '.inbounds|length' "$config" 2>/dev/null || true)
    [[ "$count" =~ ^[0-9]+$ ]] && printf '%s' "$count" || printf '0'
}

menu_show_main_summary() {
    local xcount scount
    xcount=$(menu_engine_inbound_count xray)
    scount=$(menu_engine_inbound_count singbox)
    printf 'Xray: %s  |  sing-box: %s  |  入站: %d\n' \
        "$(menu_engine_state_summary xray)" "$(menu_engine_state_summary singbox)" "$((xcount + scount))"
}

menu_show_service_summary() {
    printf 'Xray: %s  |  开机自启: %s\n' "$(menu_engine_state_summary xray)" "$(menu_engine_startup_summary xray)"
    printf 'sing-box: %s  |  开机自启: %s\n' "$(menu_engine_state_summary singbox)" "$(menu_engine_startup_summary singbox)"
    printf 'Xray 版本: %s\n' "$(menu_engine_version_summary xray)"
    printf 'sing-box 版本: %s\n' "$(menu_engine_version_summary singbox)"
}

menu_show_main_inbounds() {
    local engine config tag protocol listen port printed=0
    heading '当前入站'
    for engine in xray singbox; do
        config=$(engine_call "$engine" config_file 2>/dev/null || true)
        [[ -f "$config" && ! -L "$config" ]] || continue
        if [[ "$engine" == xray ]]; then
            while IFS=$'\t' read -r tag protocol listen port; do
                [[ -n "$tag" ]] || continue
                printf '  %-8s %-22s %-11s %s:%s\n' 'Xray' "$tag" "$protocol" "$listen" "$port"
                printed=1
            done < <(jq -r '.inbounds[]? | [.tag,.protocol,(.listen // "0.0.0.0"),(.port|tostring)] | @tsv' "$config" 2>/dev/null || true)
        else
            while IFS=$'\t' read -r tag protocol listen port; do
                [[ -n "$tag" ]] || continue
                printf '  %-8s %-22s %-11s %s:%s\n' 'sing-box' "$tag" "$protocol" "$listen" "$port"
                printed=1
            done < <(jq -r '.inbounds[]? | [.tag,.type,(.listen // "0.0.0.0"),(.listen_port|tostring)] | @tsv' "$config" 2>/dev/null || true)
        fi
    done
    ((printed)) || printf '  暂无入站。\n'
    printf '\n'
}

menu_print_all_shares() {
    local engine config tag found=0
    for engine in xray singbox; do
        config=$(engine_call "$engine" config_file 2>/dev/null || true)
        [[ -f "$config" && ! -L "$config" ]] || continue
        while IFS= read -r tag; do
            [[ -n "$tag" ]] || continue
            found=1
            heading "${engine}/${tag}"
            inbound_share "$engine" "$tag" || warn "无法生成 ${engine}/${tag} 的分享信息。"
        done < <(jq -r '.inbounds[]?.tag' "$config" 2>/dev/null || true)
    done
    ((found)) || warn '当前没有入站。'
}

menu_main() {
    local choice=''
    while true; do
        ui_clear_screen
        printf '%sProxyCTL 统一代理管理器%s  v%s\n' "${COLOR_BOLD}${COLOR_BLUE}" "$COLOR_RESET" "$PROXYCTL_VERSION"
        menu_show_main_summary
        menu_show_main_inbounds
        printf '1) 入站管理\n2) 出站管理\n3) TLS 证书\n4) 服务管理\n5) 系统工具\n6) 备份与恢复\n7) 卸载\n0) 退出\n'
        choice=''
        menu_read_choice choice || return 0
        case "$choice" in
            1) menu_inbound ;;
            2) menu_outbound ;;
            3) menu_certificates ;;
            4) menu_core ;;
            5) menu_system ;;
            6) menu_backup ;;
            7) menu_uninstall ;;
            0) return 0 ;;
            *) warn '无效选项。'; pause ;;
        esac
    done
}

menu_inbound() {
    local choice='' engine='' tag='' answer=''
    while true; do
        ui_clear_screen
        heading '入站管理'
        cmd_inbound list || true
        printf '\n1) 新增入站\n2) 管理已有入站\n3) 全部分享信息\n4) 删除入站\n0) 返回\n'
        choice=''; engine=''; tag=''; answer=''
        menu_read_choice choice || return
        case "$choice" in
            1) menu_select_engine engine 1 || { pause; continue; }; menu_action inbound_add_interactive "$engine" ;;
            2) menu_select_inbound engine tag || { pause; continue; }; menu_inbound_manage "$engine" "$tag" ;;
            3) menu_action menu_print_all_shares ;;
            4)
                menu_select_inbound engine tag || { pause; continue; }
                confirm answer "确定删除 ${engine}/${tag} 以及其中全部用户吗？" n || continue
                [[ "$answer" == y ]] && menu_action inbound_delete "$engine" "$tag"
                ;;
            0) return ;;
            *) warn '无效选项。'; pause ;;
        esac
    done
}

menu_inbound_manage() {
    local engine="$1" tag="$2" choice='' new_tag='' answer='' config='' listen='' port='' client_host=''
    while inbound_exists "$engine" "$tag"; do
        ui_clear_screen
        heading "入站管理 · ${engine}/${tag}"
        config=$(inbound_config_file "$engine" 2>/dev/null || true)
        if [[ -n "$config" ]]; then
            local _proto=$(jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.protocol // .type // "-"' "$config" 2>/dev/null || true)
            local _port=$(jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|(.port // .listen_port // "-")|tostring' "$config" 2>/dev/null || true)
            local _listen=$(jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.listen // "0.0.0.0"' "$config" 2>/dev/null || true)
            local _transport=''
            local _security=''
            if [[ "$engine" == xray ]]; then
                _transport=$(jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.streamSettings.network // .streamSettings.method // "-"' "$config" 2>/dev/null || true)
                _security=$(jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.streamSettings.security // "none"' "$config" 2>/dev/null || true)
            else
                _transport=$(jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.transport.type // "-"' "$config" 2>/dev/null || true)
                _security=$(jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|(if .tls.reality.enabled==true then "reality" elif .tls.enabled==true then "tls" else "none" end)' "$config" 2>/dev/null || true)
            fi
            printf '协议: %s  |  端口: %s  |  传输: %s  |  安全: %s  |  监听: %s\n' "$_proto" "$_port" "$_transport" "$_security" "$_listen"
        fi
        printf '\n1) 分享信息 / 客户端配置\n2) 用户管理\n3) 修改入站信息\n4) 设置出站\n5) 查看 JSON\n6) 重命名入站\n7) 删除入站\n0) 返回列表\n'
        choice=''
        menu_read_choice choice || return
        case "$choice" in
            1) menu_action inbound_share "$engine" "$tag" ;;
            2) menu_clients "$engine" "$tag" ;;
            3)
                config=$(inbound_config_file "$engine") || { pause; continue; }
                listen=$(jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.listen // "0.0.0.0"' "$config")
                if [[ "$engine" == xray ]]; then port=$(jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.port' "$config"); else port=$(jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.listen_port' "$config"); fi
                client_host=$(inbound_meta_get "$engine" "$tag" clientHost 2>/dev/null || true)
                prompt_value listen '监听地址' "$listen" || continue
                prompt_value port '监听端口' "$port" || continue
                prompt_optional client_host "客户端连接地址（当前：${client_host:-自动}）" || true
                menu_action inbound_modify_listen "$engine" "$tag" "$listen" "$port" "$client_host"
                ;;
            4) menu_action outbound_assign_interactive "$engine" "$tag" ;;
            5) menu_action inbound_show "$engine" "$tag" ;;
            6)
                prompt_value new_tag '新的入站名称' "$tag" || continue
                if inbound_rename "$engine" "$tag" "$new_tag"; then tag=$new_tag; info '入站重命名完成。'; else warn '入站重命名失败。'; fi
                pause
                ;;
            7)
                confirm answer "确定删除 ${engine}/${tag} 以及其中全部用户吗？" n || continue
                if [[ "$answer" == y ]]; then menu_action inbound_delete "$engine" "$tag"; return; fi
                ;;
            0) return ;;
            *) warn '无效选项。'; pause ;;
        esac
    done
}

menu_clients() {
    local engine="$1" tag="$2" choice='' user='' label='' new_name='' answer=''
    while true; do
        ui_clear_screen
        heading "用户管理 · ${engine}/${tag}"
        printf '%-5s %-16s %s\n' '序号' '用户' '凭据'
        local _idx=0
        while IFS=$'\t' read -r label credential; do
            [[ -n "$label" ]] || continue
            ((_idx++))
            printf '%-5s %-16s %s\n' "$_idx" "$label" "$credential"
        done < <(inbound_clients "$engine" "$tag" 2>/dev/null || true)
        printf '\n1) 添加用户\n2) 重命名用户\n3) 更换凭据\n4) 删除用户\n0) 返回\n'
        choice=''; user=''; label=''; new_name=''; answer=''
        menu_read_choice choice || return
        case "$choice" in
            1) prompt_value label '用户名' "user-$(inbound_random_hex 2)" || continue; menu_action inbound_client_add "$engine" "$tag" "$label" ;;
            2) menu_select_client user "$engine" "$tag" || { pause; continue; }; prompt_value new_name '新的用户名' "$user" || continue; menu_action inbound_client_rename "$engine" "$tag" "$user" "$new_name" ;;
            3) menu_select_client user "$engine" "$tag" || { pause; continue; }; confirm answer "确定更换 ${user} 的凭据吗？旧凭据将立即失效。" n || continue; [[ "$answer" == y ]] && menu_action inbound_client_rotate "$engine" "$tag" "$user" ;;
            4) menu_select_client user "$engine" "$tag" || { pause; continue; }; confirm answer "确定删除用户 ${user} 吗？" n || continue; [[ "$answer" == y ]] && menu_action inbound_client_delete "$engine" "$tag" "$user" ;;
            0) return ;;
            *) warn '无效选项。'; pause ;;
        esac
    done
}

menu_outbound() {
    local choice='' engine='' tag='' inbound='' answer=''
    while true; do
        ui_clear_screen
        heading '出站管理'
        cmd_outbound list || true
        printf '\n1) 选择入站设置出站\n2) 添加出站 (SOCKS5/HTTP/本机 IP)\n3) 删除出站\n0) 返回\n'
        choice=''; engine=''; tag=''; inbound=''; answer=''
        menu_read_choice choice || return
        case "$choice" in
            1) menu_select_inbound engine inbound || { pause; continue; }; menu_action outbound_assign_interactive "$engine" "$inbound" ;;
            2) menu_select_engine engine 1 || { pause; continue; }; menu_action outbound_add_interactive "$engine" ;;
            3)
                menu_select_outbound engine tag || { pause; continue; }
                confirm answer "确定删除出站 ${engine}/${tag} 吗？相关入站将恢复为 direct。" n || continue
                [[ "$answer" == y ]] && menu_action outbound_delete "$engine" "$tag"
                ;;
            0) return ;;
            *) warn '无效选项。'; pause ;;
        esac
    done
}

menu_core_install_update() {
    local engine='' action='' version=''
    menu_select_engine engine 0 || { pause; return; }
    choose action '选择操作' '安装 / 修复' '更新' '返回' || return
    [[ "$action" != '返回' ]] || return
    prompt_optional version '版本号（留空 = 最新版）' || true
    if [[ "$action" == '安装 / 修复' ]]; then menu_action engine_call "$engine" install "$version"; else menu_action engine_call "$engine" update "$version"; fi
}

menu_core() {
    local choice='' engine='' answer='' service=''
    while true; do
        ui_clear_screen
        heading '服务管理'
        menu_show_service_summary
        printf '\n1) 启动/停止\n2) 重启服务\n3) 开关开机自启\n4) 查看日志\n5) 安装/更新/修复核心\n6) 卸载核心\n0) 返回\n'
        choice=''; engine=''; answer=''; service=''
        menu_read_choice choice || return
        case "$choice" in
            1)
                menu_select_engine engine 1 || { pause; continue; }
                if engine_call "$engine" is_active >/dev/null 2>&1; then menu_engine_action "$engine" stop "${engine} 已停止。"; else menu_engine_action "$engine" start "${engine} 已启动。"; fi
                ;;
            2) menu_select_engine engine 1 || { pause; continue; }; menu_engine_action "$engine" restart "${engine} 已重启。" ;;
            3)
                menu_select_engine engine 1 || { pause; continue; }
                service=$(engine_call "$engine" service_name 2>/dev/null || true)
                if [[ -n "$service" ]] && service_is_enabled "$service" >/dev/null 2>&1; then menu_engine_action "$engine" disable "${engine} 开机自启已关闭。"; else menu_engine_action "$engine" enable "${engine} 开机自启已开启。"; fi
                ;;
            4) menu_select_engine engine 1 || { pause; continue; }; menu_action engine_call "$engine" logs 100 ;;
            5) menu_core_install_update ;;
            6)
                menu_select_engine engine 1 || { pause; continue; }
                confirm answer "确定卸载 ${engine} 核心吗？配置、证书和备份都会保留。" n || continue
                [[ "$answer" == y ]] && menu_action engine_call "$engine" uninstall
                ;;
            0) return ;;
            *) warn '无效选项。'; pause ;;
        esac
    done
}

menu_certificates() {
    local choice='' subject='' email='' validation='' id='' cert='' key='' answer=''
    local ids=()
    while true; do
        ui_clear_screen
        heading 'TLS 证书'
        printf '托管证书: %s\n\n' "$(cert_count 2>/dev/null || echo 0)"
        printf "1) Let's Encrypt 自动签发\n2) 导入已有证书\n3) 查看托管证书\n4) 续期证书\n5) 删除证书\n6) Cloudflare DNS 凭据\n7) 生成自签名证书\n0) 返回\n"
        choice=''; subject=''; email=''; validation=''; id=''; cert=''; key=''; answer=''; ids=()
        menu_read_choice choice || return
        case "$choice" in
            1) prompt_value subject '域名或公网 IP' || continue; prompt_value email 'ACME 邮箱' || continue; choose validation '选择验证方式' http dns-cloudflare dns-manual || continue; menu_action cert_acme_issue "$subject" "$email" "$validation" 0 ;;
            2) prompt_value id '证书标识' || continue; prompt_value cert '完整证书链路径' || continue; prompt_value key '私钥路径' || continue; menu_action cert_import "$id" "$cert" "$key" ;;
            3) menu_action cert_list ;;
            4)
                while IFS= read -r id; do [[ -n "$id" ]] && ids+=("$id"); done < <(metadata_cert_list)
                ((${#ids[@]})) || { warn '当前没有托管证书。'; pause; continue; }
                if ((${#ids[@]} == 1)); then id=${ids[0]}; else choose id '选择证书' "${ids[@]}" || continue; fi
                menu_action cert_renew "$id"
                ;;
            5)
                while IFS= read -r id; do [[ -n "$id" ]] && ids+=("$id"); done < <(metadata_cert_list)
                ((${#ids[@]})) || { warn '当前没有托管证书。'; pause; continue; }
                if ((${#ids[@]} == 1)); then id=${ids[0]}; else choose id '选择证书' "${ids[@]}" || continue; fi
                confirm answer "确定删除托管证书 ${id} 吗？" n || continue
                [[ "$answer" == y ]] && menu_action cert_delete "$id"
                ;;
            6) menu_action cmd_cert cloudflare ;;
            7) prompt_value subject '域名或 IP' || continue; menu_action cert_generate_self "$subject" ;;
            0) return ;;
            *) warn '无效选项。'; pause ;;
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
        printf '\n1) 创建备份\n2) 恢复备份\n0) 返回\n'
        choice=''; label=''; id=''; answer=''; ids=()
        menu_read_choice choice || return
        case "$choice" in
            1) prompt_optional label '备份标签（可留空）' || true; menu_action backup_create "$label" ;;
            2)
                while IFS= read -r id; do [[ -n "$id" ]] && ids+=("$id"); done < <(menu_backup_ids)
                ((${#ids[@]})) || { warn '没有可用备份。'; pause; continue; }
                if ((${#ids[@]} == 1)); then id=${ids[0]}; else choose id '选择备份' "${ids[@]}" || continue; fi
                confirm answer "确定恢复 ${id} 吗？恢复前会自动保存当前状态用于回滚。" n || continue
                [[ "$answer" == y ]] && menu_action proxyctl_backup_restore "$id"
                ;;
            0) return ;;
            *) warn '无效选项。'; pause ;;
        esac
    done
}

menu_system() {
    local choice='' engine=''
    while true; do
        ui_clear_screen
        heading '系统工具'
        printf '1) 查看 BBR 状态\n2) 接管 / 同步已有配置\n0) 返回\n'
        choice=''; engine=''
        menu_read_choice choice || return
        case "$choice" in
            1) menu_action bbr_status ;;
            2) choose engine '选择要同步的配置' xray singbox both || continue; if [[ "$engine" == both ]]; then menu_action proxyctl_reconcile; else menu_action proxyctl_reconcile "$engine"; fi ;;
            0) return ;;
            *) warn '无效选项。'; pause ;;
        esac
    done
}

menu_uninstall() {
    local choice='' answer=''
    while true; do
        ui_clear_screen
        heading '卸载'
        printf '1) 卸载 ProxyCTL — 保留 Xray/sing-box、配置、证书和备份\n2) 完全卸载 — 删除 ProxyCTL、两个核心及全部托管数据\n0) 返回\n'
        choice=''; answer=''
        menu_read_choice choice || return
        case "$choice" in
            1)
                confirm answer '确定只卸载 ProxyCTL 管理器吗？节点数据会保留。' n || continue
                if [[ "$answer" == y ]]; then proxyctl_uninstall --yes && exit 0; fi
                ;;
            2)
                warn '完全卸载会删除两个核心、真实配置、证书、metadata 和备份。'
                confirm answer '确定完全卸载吗？此操作不可撤销。' n || continue
                if [[ "$answer" == y ]]; then proxyctl_uninstall --purge --yes && exit 0; fi
                ;;
            0) return ;;
            *) warn '无效选项。'; pause ;;
        esac
    done
}
