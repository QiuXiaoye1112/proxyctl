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
        'Outbound tag') printf '%s' '出站名称' ;;
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
        'Select outbound type:') printf '%s' '选择出站类型：' ;;
        'Local source IP to bind') printf '%s' '绑定的本机出口 IP' ;;
        'Proxy server address') printf '%s' '代理服务器地址' ;;
        'Proxy server port') printf '%s' '代理服务器端口' ;;
        'Select outbound:') printf '%s' '选择出站：' ;;
        'Cloudflare email') printf '%s' 'Cloudflare 邮箱' ;;
        'Cloudflare Global API Key') printf '%s' 'Cloudflare Global API Key' ;;
        'Version (empty = latest)') printf '%s' '版本号（留空 = 最新版）' ;;
        *) printf '%s' "$text" ;;
    esac
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
    echo -e "${COLOR_RED}[严重]${COLOR_RESET} ${text}" >&2
}

pause() {
    local prompt="${1:-按 Enter 继续...}"
    prompt=$(_ui_translate_prompt "$prompt")
    [[ -t 0 ]] || return 0
    read -r -p "$prompt"
}

confirm() {
    local __var="$1"
    local prompt="${2:-是否继续？}"
    local default="${3:-n}"
    local response
    prompt=$(_ui_translate_prompt "$prompt")

    if [[ ! -t 0 ]] && [[ -z "${PROXYCTL_NO_TTY_GUARD:-}" ]]; then
        error '交互确认需要在终端中执行。'
        return 1
    fi

    if [[ "$default" == y ]]; then
        read -r -p "${prompt} [Y/n] " response
        response="${response:-y}"
    else
        read -r -p "${prompt} [y/N] " response
        response="${response:-n}"
    fi

    case "${response,,}" in
        y|yes|是|好|确认) printf -v "$__var" '%s' y ;;
        *) printf -v "$__var" '%s' n ;;
    esac
}

choose() {
    local __var="$1"
    local prompt="$2"
    shift 2
    local options=("$@")
    local count="${#options[@]}"
    prompt=$(_ui_translate_prompt "$prompt")

    if (( count == 0 )); then
        error '没有可选项。'
        return 1
    fi

    [[ -t 0 ]] || [[ -n "${PROXYCTL_NO_TTY_GUARD:-}" ]] || {
        error '交互选择需要在终端中执行。'
        return 1
    }

    echo ''
    echo "$prompt"
    echo ''

    local i
    for i in "${!options[@]}"; do
        printf '  %d) %s\n' "$((i + 1))" "${options[$i]}"
    done

    echo ''
    local choice
    while true; do
        read -r -p "请选择 [1-${count}]：" choice || {
            echo ''
            return 1
        }
        if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= count )); then
            printf -v "$__var" '%s' "${options[$((choice - 1))]}"
            return 0
        fi
        warn "输入无效，请输入 1-${count}。"
    done
}

prompt_value() {
    local __var="$1"
    local prompt="$2"
    local default="${3:-}"
    local value
    prompt=$(_ui_translate_prompt "$prompt")

    if [[ -n "$default" ]]; then
        [[ -t 0 ]] || {
            printf -v "$__var" '%s' "$default"
            return 0
        }
        read -r -p "${prompt} [${default}]：" value
        printf -v "$__var" '%s' "${value:-$default}"
    else
        [[ -t 0 ]] || {
            error '该操作需要在终端中输入值。'
            return 1
        }
        while true; do
            read -r -p "${prompt}：" value || {
                echo ''
                return 1
            }
            if [[ -n "$value" ]]; then
                printf -v "$__var" '%s' "$value"
                return 0
            fi
            warn '该项不能为空。'
        done
    fi
}

prompt_optional() {
    local __var="$1"
    local prompt="$2"
    local default="${3:-}"
    local value
    prompt=$(_ui_translate_prompt "$prompt")

    [[ -t 0 ]] || {
        printf -v "$__var" '%s' "$default"
        return 0
    }

    read -r -p "${prompt}：" value
    printf -v "$__var" '%s' "${value:-$default}"
}

prompt_secret() {
    local __var="$1"
    local prompt="$2"
    local value
    prompt=$(_ui_translate_prompt "$prompt")

    [[ -t 0 ]] || {
        error '密码输入需要在终端中执行。'
        return 1
    }

    read -r -s -p "${prompt}：" value || {
        echo ''
        return 1
    }
    echo ''
    printf -v "$__var" '%s' "$value"
}

prompt_hidden_secret() {
    local __var="$1"
    local prompt="$2"
    local value
    prompt=$(_ui_translate_prompt "$prompt")

    [[ -t 0 ]] || {
        error '敏感信息输入需要在终端中执行。'
        return 1
    }

    read -r -s -p "${prompt}：" value || {
        echo ''
        return 1
    }
    echo ''
    printf -v "$__var" '%s' "$value"
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
