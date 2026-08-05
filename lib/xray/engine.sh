#!/usr/bin/env bash
# ------------------------------------------------------------------------------
# xray/engine.sh — Xray engine adapter
# ------------------------------------------------------------------------------

_register_engine 'xray'

readonly _PROXYCTL_XRAY_INSTALLER_URL="${PROXYCTL_XRAY_INSTALLER_URL:-https://github.com/XTLS/Xray-install/raw/main/install-release.sh}"

_engine_xray_require_root() {
    system_is_root && return 0
    error 'Xray core management requires root.'
    return 1
}

_engine_xray_require_systemd() {
    local init
    init=$(system_init 2>/dev/null || true)
    [[ "$init" == systemd ]] && return 0
    error 'Automatic Xray installation currently requires systemd. Pre-installed Xray can still be managed through the engine adapter.'
    return 1
}

_engine_xray_download_installer() {
    local dest="$1"
    command -v curl >/dev/null 2>&1 || { error 'curl is required to install Xray.'; return 1; }
    curl --fail --location --proto '=https' --tlsv1.2 --retry 3 \
        --connect-timeout 15 --max-time 180 \
        "$_PROXYCTL_XRAY_INSTALLER_URL" -o "$dest"
}

_engine_xray_write_default_config() {
    local config parent tmp
    config=$(engine_xray_config_file)
    parent=$(dirname "$config")
    [[ "$config" == /* && ! -L "$parent" && ! -L "$config" ]] || {
        error "Unsafe Xray config path: ${config}"
        return 1
    }
    mkdir -p -- "$parent" || return 1
    tmp=$(mktemp "${parent}/.proxyctl-xray.XXXXXX") || return 1
    cat >"$tmp" <<'JSON'
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [],
  "outbounds": [
    {
      "protocol": "freedom",
      "tag": "direct"
    },
    {
      "protocol": "blackhole",
      "tag": "blocked"
    }
  ],
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": []
  }
}
JSON
    chmod 600 "$tmp" || { rm -f -- "$tmp"; return 1; }
    mv -f -- "$tmp" "$config"
}

_engine_xray_install_impl() {
    local version="${1:-}" installer had_config=0 config
    _engine_xray_require_root || return 1
    _engine_xray_require_systemd || return 1
    config=$(engine_xray_config_file)
    [[ -f "$config" && ! -L "$config" ]] && had_config=1
    installer=$(mktemp) || return 1
    if ! _engine_xray_download_installer "$installer"; then
        rm -f -- "$installer"
        return 1
    fi
    chmod 700 "$installer" || { rm -f -- "$installer"; return 1; }
    if [[ -n "$version" ]]; then
        TERM="${TERM:-xterm}" bash "$installer" install --version "${version#v}" || {
            rm -f -- "$installer"
            return 1
        }
    else
        TERM="${TERM:-xterm}" bash "$installer" install || {
            rm -f -- "$installer"
            return 1
        }
    fi
    rm -f -- "$installer"
    engine_xray_installed || { error 'Xray installer completed but the xray executable was not found.'; return 1; }
    if (( had_config == 0 )); then
        _engine_xray_write_default_config || return 1
    fi
    engine_xray_validate "$config" || return 1
    engine_xray_enable || return 1
    if engine_xray_is_active; then engine_xray_restart; else engine_xray_start; fi
}

engine_xray_installed() {
    command -v xray >/dev/null 2>&1
}

engine_xray_version() {
    if engine_xray_installed; then
        xray version 2>&1 | head -1 || echo 'unknown'
    else
        echo 'not installed'
    fi
}

engine_xray_install() {
    if engine_xray_installed && [[ -z "${1:-}" ]]; then
        info 'Xray is already installed; running the official installer in repair/update mode.'
    fi
    _engine_xray_install_impl "${1:-}"
}

engine_xray_update() {
    _engine_xray_install_impl "${1:-}"
}

engine_xray_uninstall() {
    local installer
    _engine_xray_require_root || return 1
    engine_xray_installed || { info 'Xray is not installed.'; return 0; }
    _engine_xray_require_systemd || return 1
    installer=$(mktemp) || return 1
    if _engine_xray_download_installer "$installer"; then
        chmod 700 "$installer" || { rm -f -- "$installer"; return 1; }
        # `remove` deliberately keeps configuration. ProxyCTL owns shared state.
        TERM="${TERM:-xterm}" bash "$installer" remove || {
            rm -f -- "$installer"
            error 'The XTLS installer failed to remove Xray.'
            return 1
        }
        rm -f -- "$installer"
    else
        rm -f -- "$installer"
        error 'Unable to download the official Xray uninstaller; refusing an ad-hoc destructive cleanup.'
        return 1
    fi
    info 'Xray core removed. ProxyCTL configuration, certificates, metadata and backups were preserved.'
}

engine_xray_start()   { service_start "$(engine_xray_service_name)"; }
engine_xray_stop()    { service_stop "$(engine_xray_service_name)"; }
engine_xray_restart() { service_restart "$(engine_xray_service_name)"; }
engine_xray_enable()  { service_enable "$(engine_xray_service_name)"; }
engine_xray_disable() { service_disable "$(engine_xray_service_name)"; }

engine_xray_is_active() {
    engine_xray_installed || return 1
    service_is_active "$(engine_xray_service_name)"
}

engine_xray_validate() {
    local config_file="${1:-${XRAY_CONFIG}}"
    engine_xray_installed || { error 'Xray is not installed.'; return 1; }
    [[ -f "$config_file" && ! -L "$config_file" ]] || { error "Config file not found or unsafe: ${config_file}"; return 1; }
    xray run -test -config "$config_file"
}

engine_xray_logs() {
    service_logs "$(engine_xray_service_name)" "${1:-100}"
}

engine_xray_config_file() { printf '%s\n' "${XRAY_CONFIG}"; }
engine_xray_service_name() { printf '%s\n' 'xray'; }
