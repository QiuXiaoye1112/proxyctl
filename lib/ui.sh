#!/usr/bin/env bash
# ------------------------------------------------------------------------------
# ui.sh — Shared terminal UI primitives
# ------------------------------------------------------------------------------

readonly COLOR_RESET='\033[0m'
readonly COLOR_BOLD='\033[1m'
readonly COLOR_RED='\033[0;31m'
readonly COLOR_GREEN='\033[0;32m'
readonly COLOR_YELLOW='\033[0;33m'
readonly COLOR_CYAN='\033[0;36m'

_ui_translate_prompt() {
    local text="$1"
    case "$text" in
        'Select Xray protocol:') printf '%s' '选择 Xray 协议：' ;;
        'Select sing-box protocol:') printf '%s' '选择 sing-box 协议：' ;;
        'Inbound tag') printf '%s' '入站名称' ;;
        'Outbound tag') printf '%s' '出站标签（仅用于 ProxyCTL 配置）' ;;
        'Listen address') printf '%s' '监听地址' ;;
        'Listen port') printf '%s' '监听端口' ;;
        'Listen UDP port') printf '%s' '监听 UDP 端口' ;;
        'Client/server address') printf '%s' '客户端连接地址' ;;
        'Transport security:') printf '%s' '传输安全方式：' ;;
        'TLS security:') printf '%s' 'TLS 安全方式：' ;;
        'Transport:') printf '%s' '传输方式：' ;;
        'WebSocket path') printf '%s' 'WebSocket 路径' ;;
        'XHTTP path') printf '%s' 'XHTTP 路径' ;;
        'Select managed certificate:') printf '%s' '选择托管证书：' ;;
        'TLS SNI/serverName') printf '%s' 'TLS SNI / serverName' ;;
        'REALITY target (host:port)') printf '%s' 'REALITY 目标站点（host:port）' ;;
        'REALITY handshake domain') printf '%s' 'REALITY 握手域名' ;;
        'REALITY handshake port') printf '%s' 'REALITY 握手端口' ;;
        'REALITY serverName/SNI') printf '%s' 'REALITY serverName / SNI' ;;
        'User name') printf '%s' '用户名' ;;
        'Username (empty = no authentication)') printf '%s' '用户名（留空 = 无认证）' ;;
        'Password') printf '%s' '密码' ;;
        'Hysteria2 port mode:') printf '%s' 'Hysteria2 端口模式：' ;;
        'UDP hop range') printf '%s' 'UDP 跳跃端口范围' ;;
        'Upload limit Mbps (empty = unlimited)') printf '%s' '上传限速 Mbps（留空 = 不限制）' ;;
        'Download limit Mbps (empty = unlimited)') printf '%s' '下载限速 Mbps（留空 = 不限制）' ;;
        'QUIC obfuscation:') printf '%s' 'QUIC 混淆：' ;;
        'Select outbound type:') printf '%s' '选择要添加的出站类型：' ;;
        'Local source IP to bind') printf '%s' '绑定的本机出口 IP' ;;
        'Proxy server address') printf '%s' '上游代理地址' ;;
        'Proxy server port') printf '%s' '上游代理端口' ;;
        'Select outbound:') printf '%s' '选择入站使用的出站：' ;;
        'Cloudflare email') printf '%s' 'Cloudflare 邮箱' ;;
        'Cloudflare Global API Key') printf '%s' 'Cloudflare Global API Key' ;;
        'Version (empty = latest)') printf '%s' '版本号（留空 = 最新版）' ;;
        *) printf '%s' "$text" ;;
    esac
}

_ui_translate_option() {
    local text="$1"
    case "$text" in
        single) printf '%s' '单端口' ;;
        hopping) printf '%s' '端口跳跃' ;;
        reality) printf '%s' 'REALITY' ;;
        tls) printf '%s' 'TLS' ;;
        none) printf '%s' '无传输安全' ;;
        off) printf '%s' '关闭' ;;
        salamander) printf '%s' 'Salamander 混淆' ;;
        'Local IP') printf '%s' '本机指定出口 IP' ;;
        '新增出站') printf '%s' '添加出站' ;;
        direct) printf '%s' 'direct（直连）' ;;
        http) printf '%s' 'HTTP-01（80 端口）' ;;
        dns-cloudflare) printf '%s' 'Cloudflare DNS 自动验证' ;;
        dns-manual) printf '%s' '手动 DNS 验证' ;;
        both) printf '%s' '全部' ;;
        *) printf '%s' "$text" ;;
    esac
}

ui_clear_screen() {
    [[ -t 1 ]] || return 0
    [[ "${TERM:-}" != dumb ]] || return 0
    printf '\033[2J\033[H'
}

heading() {
    local text="$1"
    echo ''
    echo -e "${COLOR_BOLD}${COLOR_CYAN}==> ${text}${COLOR_RESET}"
    echo ''
}

info() {
    local text="$1"
    echo -e "${COLOR_GREEN}[+]${COLOR_RESET} ${text}"
}

warn() {
    local text="$1"
    echo -e "${COLOR_YELLOW}[!]${COLOR_RESET} ${text}" >&2
}

error() {
    local text="$1"
    echo -e "${COLOR_RED}[x]${COLOR_RESET} ${text}" >&2
}

die() {
    local text="$1"
    local code="${2:-1}"
    echo -e "${COLOR_RED}[致命]${COLOR_RESET} ${text}" >&2
    exit "$code"
}

critical() {
    local text="$1"
    echo -e "${COLOR_RED}[严重]${COLOR_RESET} [CRITICAL] ${text}" >&2
}

pause() {
    local _ui_prompt="${1:-按 Enter 继续...}"
    _ui_prompt=$(_ui_translate_prompt "$_ui_prompt")
    [[ -t 0 ]] || return 0
    printf '%s' "$_ui_prompt" >&2
    read -r
}

confirm() {
    local __var="$1"
    local _ui_prompt="${2:-是否继续？}"
    local _ui_default="${3:-n}"
    local _ui_response
    _ui_prompt=$(_ui_translate_prompt "$_ui_prompt")

    if [[ ! -t 0 ]] && [[ -z "${PROXYCTL_NO_TTY_GUARD:-}" ]]; then
        error '交互确认需要在终端中执行。'
        return 1
    fi

    if [[ "$_ui_default" == y ]]; then
        printf '%s [Y/n] ' "$_ui_prompt" >&2
        read -r _ui_response || return 1
        _ui_response="${_ui_response:-y}"
    else
        printf '%s [y/N] ' "$_ui_prompt" >&2
        read -r _ui_response || return 1
        _ui_response="${_ui_response:-n}"
    fi

    case "${_ui_response,,}" in
        y|yes|是|好|确认) printf -v "$__var" '%s' y ;;
        *) printf -v "$__var" '%s' n ;;
    esac
}

choose() {
    local __var="$1"
    local _ui_prompt="$2"
    shift 2
    local _ui_options=("$@")
    local _ui_count="${#_ui_options[@]}"
    local _ui_i _ui_display _ui_selection
    _ui_prompt=$(_ui_translate_prompt "$_ui_prompt")

    if (( _ui_count == 0 )); then
        error '没有可选项。'
        return 1
    fi

    [[ -t 0 ]] || [[ -n "${PROXYCTL_NO_TTY_GUARD:-}" ]] || {
        error '交互选择需要在终端中执行。'
        return 1
    }

    case "$_ui_prompt" in
        '主菜单'|'入站管理'|'入站操作'|'用户管理'|'出站管理'|'核心管理'|'证书管理'|'备份管理'|'系统工具') ui_clear_screen ;;
    esac

    # Interactive presentation must never share stdout with data-producing
    # helpers. collect_spec functions are intentionally used inside $(...), so
    # menu text belongs on stderr while stdout remains a clean data channel.
    printf '\n%s\n\n' "$_ui_prompt" >&2

    for _ui_i in "${!_ui_options[@]}"; do
        _ui_display=$(_ui_translate_option "${_ui_options[$_ui_i]}")
        printf '  %d) %s\n' "$((_ui_i + 1))" "$_ui_display" >&2
    done

    printf '\n' >&2
    while true; do
        printf '请选择 [1-%s]：' "$_ui_count" >&2
        read -r _ui_selection || {
            printf '\n' >&2
            return 1
        }
        if [[ "$_ui_selection" =~ ^[0-9]+$ ]] && (( _ui_selection >= 1 && _ui_selection <= _ui_count )); then
            printf -v "$__var" '%s' "${_ui_options[$((_ui_selection - 1))]}"
            return 0
        fi
        warn "输入无效，请输入 1-${_ui_count}。"
    done
}

prompt_value() {
    local __var="$1"
    local _ui_prompt="$2"
    local _ui_default="${3:-}"
    local _ui_value
    _ui_prompt=$(_ui_translate_prompt "$_ui_prompt")

    if [[ -n "$_ui_default" ]]; then
        [[ -t 0 ]] || {
            printf -v "$__var" '%s' "$_ui_default"
            return 0
        }
        printf '%s [%s]：' "$_ui_prompt" "$_ui_default" >&2
        read -r _ui_value || return 1
        printf -v "$__var" '%s' "${_ui_value:-$_ui_default}"
    else
        [[ -t 0 ]] || {
            error '该操作需要在终端中输入值。'
            return 1
        }
        while true; do
            printf '%s：' "$_ui_prompt" >&2
            read -r _ui_value || {
                printf '\n' >&2
                return 1
            }
            if [[ -n "$_ui_value" ]]; then
                printf -v "$__var" '%s' "$_ui_value"
                return 0
            fi
            warn '该项不能为空。'
        done
    fi
}

prompt_optional() {
    local __var="$1"
    local _ui_prompt="$2"
    local _ui_default="${3:-}"
    local _ui_value
    _ui_prompt=$(_ui_translate_prompt "$_ui_prompt")

    [[ -t 0 ]] || {
        printf -v "$__var" '%s' "$_ui_default"
        return 0
    }

    printf '%s：' "$_ui_prompt" >&2
    read -r _ui_value || return 1
    printf -v "$__var" '%s' "${_ui_value:-$_ui_default}"
}

prompt_secret() {
    local __var="$1"
    local _ui_prompt="$2"
    local _ui_value
    _ui_prompt=$(_ui_translate_prompt "$_ui_prompt")

    [[ -t 0 ]] || {
        error '密码输入需要在终端中执行。'
        return 1
    }

    printf '%s：' "$_ui_prompt" >&2
    read -r -s _ui_value || {
        printf '\n' >&2
        return 1
    }
    printf '\n' >&2
    printf -v "$__var" '%s' "$_ui_value"
}

prompt_hidden_secret() {
    local __var="$1"
    local _ui_prompt="$2"
    local _ui_value
    _ui_prompt=$(_ui_translate_prompt "$_ui_prompt")

    [[ -t 0 ]] || {
        error '敏感信息输入需要在终端中执行。'
        return 1
    }

    printf '%s：' "$_ui_prompt" >&2
    read -r -s _ui_value || {
        printf '\n' >&2
        return 1
    }
    printf '\n' >&2
    printf -v "$__var" '%s' "$_ui_value"
}

table_header() {
    printf '\n'
    printf '  %-40s %s\n' "$1" "$2"
    printf '  %-40s %s\n' '----------------------------------------' '----------'
}

table_row() {
    printf '  %-40s %s\n' "$1" "$2"
}

table_footer() {
    printf '\n'
}
