#!/usr/bin/env bash
# ------------------------------------------------------------------------------
# ui.sh — Shared terminal UI primitives
# xrayctl-style terminal interaction with a clean stdout data channel.
# ------------------------------------------------------------------------------

if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
    readonly COLOR_RED=$'\033[31m'
    readonly COLOR_GREEN=$'\033[32m'
    readonly COLOR_YELLOW=$'\033[33m'
    readonly COLOR_BLUE=$'\033[34m'
    readonly COLOR_CYAN=$'\033[36m'
    readonly COLOR_BOLD=$'\033[1m'
    readonly COLOR_RESET=$'\033[0m'
else
    readonly COLOR_RED=''
    readonly COLOR_GREEN=''
    readonly COLOR_YELLOW=''
    readonly COLOR_BLUE=''
    readonly COLOR_CYAN=''
    readonly COLOR_BOLD=''
    readonly COLOR_RESET=''
fi

_ui_translate_prompt() {
    local text="$1"
    case "$text" in
        'Select Xray protocol:'|'Select sing-box protocol:') printf '%s' '选择入站协议' ;;
        'Inbound tag') printf '%s' '入站标签' ;;
        'Outbound tag') printf '%s' '出站标签' ;;
        'Listen address') printf '%s' '监听地址' ;;
        'Listen port') printf '%s' '监听端口' ;;
        'Listen UDP port') printf '%s' '监听 UDP 端口' ;;
        'Client/server address') printf '%s' '客户端连接地址' ;;
        'Transport security:'|'TLS security:') printf '%s' '选择安全方式' ;;
        'Transport:') printf '%s' '选择传输方式' ;;
        'WebSocket path') printf '%s' 'WebSocket 路径' ;;
        'XHTTP path') printf '%s' 'XHTTP 路径' ;;
        'Select managed certificate:') printf '%s' '选择托管证书' ;;
        'TLS SNI/serverName') printf '%s' 'TLS SNI / serverName' ;;
        'REALITY target (host:port)') printf '%s' 'REALITY 目标站点（host:port）' ;;
        'REALITY handshake domain') printf '%s' 'REALITY 握手域名' ;;
        'REALITY handshake port') printf '%s' 'REALITY 握手端口' ;;
        'REALITY serverName/SNI') printf '%s' 'REALITY serverName / SNI' ;;
        'User name') printf '%s' '用户名' ;;
        'Username (empty = no authentication)') printf '%s' '用户名（留空 = 无认证）' ;;
        'Password') printf '%s' '密码' ;;
        'Hysteria2 port mode:') printf '%s' '选择 Hysteria2 端口模式' ;;
        'UDP hop range') printf '%s' 'UDP 跳跃端口范围' ;;
        'Upload limit Mbps (empty = unlimited)') printf '%s' '上传限速 Mbps（留空 = 不限制）' ;;
        'Download limit Mbps (empty = unlimited)') printf '%s' '下载限速 Mbps（留空 = 不限制）' ;;
        'QUIC obfuscation:') printf '%s' '选择 QUIC 混淆' ;;
        'Select outbound type:') printf '%s' '选择出站协议' ;;
        'Local source IP to bind') printf '%s' '绑定的本机出口 IP' ;;
        'Proxy server address') printf '%s' '代理服务器地址' ;;
        'Proxy server port') printf '%s' '代理服务器端口' ;;
        'Select outbound:') printf '%s' '选择出站' ;;
        'Cloudflare email') printf '%s' 'Cloudflare 邮箱' ;;
        'Cloudflare Global API Key') printf '%s' 'Cloudflare Global API Key' ;;
        'Version (empty = latest)') printf '%s' '版本号（留空 = 最新版）' ;;
        *) printf '%s' "$text" ;;
    esac
}

_ui_translate_option() {
    local text="$1"
    case "$text" in
        xray) printf '%s' 'Xray' ;;
        singbox) printf '%s' 'sing-box' ;;
        single) printf '%s' '单端口' ;;
        hopping) printf '%s' '端口跳跃' ;;
        reality) printf '%s' 'REALITY' ;;
        tls) printf '%s' 'TLS' ;;
        none) printf '%s' '无安全层' ;;
        off) printf '%s' '关闭' ;;
        salamander) printf '%s' 'Salamander 混淆' ;;
        'Local IP') printf '%s' '本机指定出口 IP' ;;
        direct) printf '%s' 'direct（直连）' ;;
        http) printf '%s' 'HTTP-01（80 端口）' ;;
        dns-cloudflare) printf '%s' 'Cloudflare DNS 自动验证' ;;
        dns-manual) printf '%s' '手动 DNS 验证' ;;
        both) printf '%s' '全部' ;;
        *) printf '%s' "$text" ;;
    esac
}

_ui_inside_data_collector() {
    local fn
    for fn in "${FUNCNAME[@]:1}"; do
        case "$fn" in *collect_spec*|*_collect_certificate_spec) return 0 ;; esac
    done
    return 1
}

ui_clear_screen() { clear 2>/dev/null || printf '\033[2J\033[H' 2>/dev/null || true; }
heading() { printf '\n%s%s%s\n' "${COLOR_BOLD}${COLOR_CYAN}" "$1" "$COLOR_RESET"; }

info() {
    printf '%s[信息]%s %s\n' "$COLOR_GREEN" "$COLOR_RESET" "$1" >&2
}
warn() { printf '%s[警告]%s %s\n' "$COLOR_YELLOW" "$COLOR_RESET" "$1" >&2; }
error() { printf '%s[错误]%s %s\n' "$COLOR_RED" "$COLOR_RESET" "$1" >&2; }
die() { error "$1"; exit "${2:-1}"; }
critical() { printf '%s[严重]%s [CRITICAL] %s\n' "$COLOR_RED" "$COLOR_RESET" "$1" >&2; }

pause() {
    [[ -t 0 ]] || return 0
    printf '%s\n' "${1:-按回车键继续...}"
    read -r _ || true
}

confirm() {
    local __var="$1" _ui_prompt="${2:-确定继续吗？}" _ui_default="${3:-n}" _ui_answer='' _ui_suffix
    [[ "$_ui_default" == y ]] && _ui_suffix='[Y/n]' || _ui_suffix='[y/N]'
    if [[ ! -t 0 && -z "${PROXYCTL_NO_TTY_GUARD:-}" ]]; then error '交互确认需要在终端中执行。'; return 1; fi
    printf '%s %s ' "$_ui_prompt" "$_ui_suffix" >&2
    read -r _ui_answer || { printf '\n' >&2; _ui_answer="$_ui_default"; }
    _ui_answer="${_ui_answer:-$_ui_default}"
    case "${_ui_answer,,}" in y|yes|是|好|确认) printf -v "$__var" '%s' y ;; *) printf -v "$__var" '%s' n ;; esac
}

choose() {
    local __var="$1" _ui_prompt="$2"
    shift 2
    local _ui_options=("$@") _ui_selection='' _ui_display=''
    local _ui_count="${#_ui_options[@]}" _ui_i
    _ui_prompt=$(_ui_translate_prompt "$_ui_prompt")
    ((_ui_count > 0)) || { error '没有可选项。'; return 1; }
    [[ -t 0 || -n "${PROXYCTL_NO_TTY_GUARD:-}" ]] || { error '交互选择需要在终端中执行。'; return 1; }
    printf '%s\n' "$_ui_prompt"
    for _ui_i in "${!_ui_options[@]}"; do
        _ui_display=$(_ui_translate_option "${_ui_options[$_ui_i]}")
        printf '  %d) %s\n' "$((_ui_i + 1))" "$_ui_display"
    done
    while true; do
        printf '请选择 [1-%s]: ' "$_ui_count"
        read -r _ui_selection || { printf '\n'; return 1; }
        if [[ "$_ui_selection" =~ ^[0-9]+$ ]] && ((10#$_ui_selection >= 1 && 10#$_ui_selection <= _ui_count)); then
            printf -v "$__var" '%s' "${_ui_options[$((10#$_ui_selection - 1))]}"
            return 0
        fi
        warn '无效选项。'
    done
}

prompt_value() {
    local __var="$1" _ui_prompt="$2" _ui_default="${3:-}" _ui_value=''
    _ui_prompt=$(_ui_translate_prompt "$_ui_prompt")
    while true; do
        if [[ -n "$_ui_default" ]]; then
            if [[ ! -t 0 && -z "${PROXYCTL_NO_TTY_GUARD:-}" ]]; then printf -v "$__var" '%s' "$_ui_default"; return 0; fi
            printf '%s [%s]: ' "$_ui_prompt" "$_ui_default"
            read -r _ui_value || { printf '\n'; warn '输入已中断。'; return 1; }
            _ui_value="${_ui_value:-$_ui_default}"
        else
            [[ -t 0 || -n "${PROXYCTL_NO_TTY_GUARD:-}" ]] || { error '该操作需要在终端中输入值。'; return 1; }
            printf '%s: ' "$_ui_prompt"
            read -r _ui_value || { printf '\n'; warn '输入已中断。'; return 1; }
            [[ -n "$_ui_value" ]] || { warn '此项不能为空，请重新输入。'; continue; }
        fi
        printf -v "$__var" '%s' "$_ui_value"
        return 0
    done
}

prompt_optional() {
    local __var="$1" _ui_prompt="$2" _ui_default="${3:-}" _ui_value=''
    _ui_prompt=$(_ui_translate_prompt "$_ui_prompt")
    if [[ ! -t 0 && -z "${PROXYCTL_NO_TTY_GUARD:-}" ]]; then printf -v "$__var" '%s' "$_ui_default"; return 0; fi
    printf '%s: ' "$_ui_prompt"
    read -r _ui_value || { printf '\n'; warn '输入已中断。'; return 1; }
    printf -v "$__var" '%s' "${_ui_value:-$_ui_default}"
}

prompt_secret() {
    local __var="$1" _ui_prompt="$2" _ui_value=''
    _ui_prompt=$(_ui_translate_prompt "$_ui_prompt")
    [[ -t 0 || -n "${PROXYCTL_NO_TTY_GUARD:-}" ]] || { error '密码输入需要在终端中执行。'; return 1; }
    printf '%s: ' "$_ui_prompt"
    read -r _ui_value || { printf '\n'; warn '输入已中断。'; return 1; }
    [[ -n "$_ui_value" ]] || { warn '密码不能为空。'; return 1; }
    printf -v "$__var" '%s' "$_ui_value"
}

prompt_hidden_secret() {
    local __var="$1" _ui_prompt="$2" _ui_value=''
    _ui_prompt=$(_ui_translate_prompt "$_ui_prompt")
    [[ -t 0 || -n "${PROXYCTL_NO_TTY_GUARD:-}" ]] || { error '敏感信息输入需要在终端中执行。'; return 1; }
    while [[ -z "$_ui_value" ]]; do
        printf '%s: ' "$_ui_prompt" >&2
        if [[ -t 0 ]]; then read -r -s _ui_value || { printf '\n' >&2; return 1; }; else read -r _ui_value || return 1; fi
        printf '\n' >&2
        [[ -n "$_ui_value" ]] || warn '不能为空，请重新输入。'
    done
    printf -v "$__var" '%s' "$_ui_value"
}

# Width-aware table primitives are copied from xrayctl's interaction layer so
# Chinese headers and mixed CJK/ASCII values stay aligned in terminals.
display_width() {
    local __var="$1" value="$2" char code computed_width=0 i
    for ((i=0; i<${#value}; i++)); do
        char=${value:i:1}
        printf -v code '%d' "'$char"
        if ((code < 0 || code > 127)); then ((computed_width+=2)); else ((computed_width+=1)); fi
    done
    printf -v "$__var" '%s' "$computed_width"
}
print_table_cell() {
    local value="$1" target_width="$2" width padding
    display_width width "$value"
    padding=$((target_width-width)); ((padding > 0)) || padding=1
    printf '%s%*s' "$value" "$padding" ''
}
print_table_cell_clipped() {
    local value="$1" target_width="$2" width limit clipped='' used=0 char char_width i
    display_width width "$value"
    if ((width < target_width)); then print_table_cell "$value" "$target_width"; return; fi
    limit=$((target_width-4)); ((limit > 0)) || limit=1
    for ((i=0; i<${#value}; i++)); do
        char=${value:i:1}; display_width char_width "$char"
        ((used+char_width <= limit)) || break
        clipped+=$char; ((used+=char_width))
    done
    print_table_cell "${clipped}..." "$target_width"
}

table_header() {
    printf '\n'
    printf '  %-40s %s\n' "$1" "$2"
    printf '  %-40s %s\n' '----------------------------------------' '----------'
}
table_row() { printf '  %-40s %s\n' "$1" "$2"; }
table_footer() { printf '\n'; }
