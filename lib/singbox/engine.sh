#!/usr/bin/env bash
# ------------------------------------------------------------------------------
# singbox/engine.sh — sing-box engine adapter
# Phase 3 targets systemd Linux first (Debian/Ubuntu and similar distributions).
# ------------------------------------------------------------------------------

_register_engine 'singbox'

readonly _PROXYCTL_SINGBOX_INSTALLER_URL="${PROXYCTL_SINGBOX_INSTALLER_URL:-https://sing-box.app/install.sh}"

_engine_singbox_require_root() {
    system_is_root && return 0
    error 'sing-box core management requires root.'
    return 1
}

_engine_singbox_require_systemd() {
    local init
    init=$(system_init 2>/dev/null || true)
    [[ "$init" == systemd ]] && return 0
    error 'Automatic sing-box installation currently requires systemd. Alpine/OpenRC support is deferred until the systemd path is complete.'
    return 1
}

_engine_singbox_version_number() {
    engine_singbox_installed || return 1
    sing-box version 2>/dev/null | sed -nE '1s/^sing-box version ([0-9]+\.[0-9]+\.[0-9]+).*/\1/p'
}

_engine_singbox_version_ge() {
    local have="$1" need="$2" h1 h2 h3 n1 n2 n3
    IFS=. read -r h1 h2 h3 <<<"$have"
    IFS=. read -r n1 n2 n3 <<<"$need"
    h1=${h1:-0}; h2=${h2:-0}; h3=${h3:-0}; n1=${n1:-0}; n2=${n2:-0}; n3=${n3:-0}
    ((10#$h1 > 10#$n1)) && return 0
    ((10#$h1 < 10#$n1)) && return 1
    ((10#$h2 > 10#$n2)) && return 0
    ((10#$h2 < 10#$n2)) && return 1
    ((10#$h3 >= 10#$n3))
}

_engine_singbox_require_supported() {
    local version
    version=$(_engine_singbox_version_number) || { error 'Unable to determine sing-box version.'; return 1; }
    _engine_singbox_version_ge "$version" 1.12.0 || {
        error "ProxyCTL requires sing-box >= 1.12.0; found ${version}."
        return 1
    }
}

_engine_singbox_write_default_config() {
    local config parent tmp
    config=$(engine_singbox_config_file)
    parent=$(dirname "$config")
    [[ "$config" == /* && ! -L "$parent" && ! -L "$config" ]] || {
        error "Unsafe sing-box config path: ${config}"
        return 1
    }
    mkdir -p -- "$parent" || return 1
    tmp=$(mktemp "${parent}/.proxyctl-singbox.XXXXXX") || return 1
    cat >"$tmp" <<'JSON'
{
  "log": {
    "level": "warn",
    "timestamp": true
  },
  "inbounds": [],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    }
  ],
  "route": {
    "final": "direct"
  }
}
JSON
    chmod 600 "$tmp" || { rm -f -- "$tmp"; return 1; }
    mv -f -- "$tmp" "$config"
}

_engine_singbox_write_service() {
    local bin data unit
    _engine_singbox_require_systemd || return 1
    bin=$(command -v sing-box) || return 1
    data="${PROXYCTL_SINGBOX_DATA:-/var/lib/sing-box}"
    unit="/etc/systemd/system/$(engine_singbox_service_name).service"
    [[ ! -L "$unit" ]] || { error "Refusing symlink service unit: ${unit}"; return 1; }
    mkdir -p -- "$data" || return 1
    cat >"$unit" <<EOF
[Unit]
Description=sing-box service managed by ProxyCTL
Documentation=https://sing-box.sagernet.org/
After=network-online.target
Wants=network-online.target

[Service]
# managed by ProxyCTL
Type=simple
User=root
Group=root
ExecStart=${bin} run -D ${data} -c $(engine_singbox_config_file)
Restart=on-failure
RestartSec=3
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
}

_engine_singbox_install_impl() {
    local version="${1:-}" installer config had_config=0
    _engine_singbox_require_root || return 1
    _engine_singbox_require_systemd || return 1
    command -v curl >/dev/null 2>&1 || { error 'curl is required to install sing-box.'; return 1; }
    config=$(engine_singbox_config_file)
    [[ -f "$config" && ! -L "$config" ]] && had_config=1
    installer=$(mktemp) || return 1
    if ! curl --fail --location --proto '=https' --tlsv1.2 --retry 3 \
        --connect-timeout 15 --max-time 180 "$_PROXYCTL_SINGBOX_INSTALLER_URL" -o "$installer"; then
        rm -f -- "$installer"
        return 1
    fi
    chmod 700 "$installer" || { rm -f -- "$installer"; return 1; }
    if [[ -n "$version" ]]; then
        bash "$installer" --version "${version#v}" || { rm -f -- "$installer"; return 1; }
    else
        bash "$installer" || { rm -f -- "$installer"; return 1; }
    fi
    rm -f -- "$installer"
    engine_singbox_installed || { error 'sing-box installation finished but the executable was not found.'; return 1; }
    _engine_singbox_require_supported || return 1
    if (( had_config == 0 )); then
        # Official installers/packages may ship a demo config; ProxyCTL starts empty.
        _engine_singbox_write_default_config || return 1
    fi
    _engine_singbox_write_service || return 1
    engine_singbox_validate "$config" || return 1
    engine_singbox_enable || return 1
    if engine_singbox_is_active; then engine_singbox_restart; else engine_singbox_start; fi
}

engine_singbox_installed() { command -v sing-box >/dev/null 2>&1; }

engine_singbox_version() {
    if engine_singbox_installed; then sing-box version 2>&1 | head -1 || echo 'unknown'; else echo 'not installed'; fi
}

engine_singbox_install() { _engine_singbox_install_impl "${1:-}"; }
engine_singbox_update()  { _engine_singbox_install_impl "${1:-}"; }

engine_singbox_uninstall() {
    local unit
    _engine_singbox_require_root || return 1
    _engine_singbox_require_systemd || return 1
    engine_singbox_installed || { info 'sing-box is not installed.'; return 0; }
    engine_singbox_stop >/dev/null 2>&1 || true
    engine_singbox_disable >/dev/null 2>&1 || true

    # The official installer configures the package repository/package. Use the
    # distro package API for removal; never delete shared ProxyCTL state here.
    package_remove sing-box || return 1

    unit="/etc/systemd/system/$(engine_singbox_service_name).service"
    if [[ -f "$unit" ]] && grep -q 'managed by ProxyCTL' "$unit" 2>/dev/null; then
        rm -f -- "$unit"
        systemctl daemon-reload >/dev/null 2>&1 || true
    fi
    info 'sing-box core removed. ProxyCTL configuration, certificates, metadata and backups were preserved.'
}

engine_singbox_start()   { service_start "$(engine_singbox_service_name)"; }
engine_singbox_stop()    { service_stop "$(engine_singbox_service_name)"; }
engine_singbox_restart() { service_restart "$(engine_singbox_service_name)"; }
engine_singbox_enable()  { service_enable "$(engine_singbox_service_name)"; }
engine_singbox_disable() { service_disable "$(engine_singbox_service_name)"; }

engine_singbox_is_active() {
    engine_singbox_installed || return 1
    service_is_active "$(engine_singbox_service_name)"
}

engine_singbox_validate() {
    local config_file="${1:-${SINGBOX_CONFIG}}"
    engine_singbox_installed || { error 'sing-box is not installed.'; return 1; }
    [[ -f "$config_file" && ! -L "$config_file" ]] || { error "Config file not found or unsafe: ${config_file}"; return 1; }
    sing-box check -c "$config_file"
}

engine_singbox_logs() { service_logs "$(engine_singbox_service_name)" "${1:-100}"; }
engine_singbox_config_file() { printf '%s\n' "${SINGBOX_CONFIG}"; }
engine_singbox_service_name() { printf '%s\n' 'sing-box'; }
