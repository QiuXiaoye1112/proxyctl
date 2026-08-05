#!/usr/bin/env bash
# ------------------------------------------------------------------------------
# xray/engine.sh — Xray engine adapter
# ------------------------------------------------------------------------------

_register_engine 'xray'

readonly _PROXYCTL_XRAY_INSTALLER_URL="${PROXYCTL_XRAY_INSTALLER_URL:-https://github.com/XTLS/Xray-install/raw/main/install-release.sh}"
readonly _PROXYCTL_XRAY_RELEASE_API="${PROXYCTL_XRAY_RELEASE_API:-https://api.github.com/repos/XTLS/Xray-core/releases/latest}"
readonly _PROXYCTL_XRAY_RELEASE_BASE="${PROXYCTL_XRAY_RELEASE_BASE:-https://github.com/XTLS/Xray-core/releases/download}"
readonly _PROXYCTL_XRAY_SHARE="${PROXYCTL_XRAY_SHARE:-/usr/local/share/xray}"

_engine_xray_require_root() {
    system_is_root && return 0
    error 'Xray core management requires root.'
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
  "log": {"loglevel": "warning"},
  "inbounds": [],
  "outbounds": [
    {"protocol": "freedom", "tag": "direct"},
    {"protocol": "blackhole", "tag": "blocked"}
  ],
  "routing": {"domainStrategy": "IPIfNonMatch", "rules": []}
}
JSON
    chmod 600 "$tmp" || { rm -f -- "$tmp"; return 1; }
    mv -f -- "$tmp" "$config"
}

# XTLS' systemd unit may run Xray as a non-root user. Reuse ProxyCTL's shared
# runtime group so both the core config and managed private keys stay
# non-world-readable while the service can still read them.
_engine_xray_prepare_config_access() {
    local config parent group
    config=$(engine_xray_config_file)
    parent=$(dirname "$config")
    [[ -f "$config" && ! -L "$config" && -d "$parent" && ! -L "$parent" ]] || {
        error "Unsafe Xray config path: ${config}"
        return 1
    }
    declare -F _cert_setup_runtime_access >/dev/null 2>&1 || {
        error 'Certificate runtime-access helper is unavailable.'
        return 1
    }
    _cert_setup_runtime_access || return 1
    group=$(cert_runtime_group) || return 1
    chown root:"$group" "$parent" "$config" || return 1
    chmod 750 "$parent" || return 1
    chmod 640 "$config" || return 1
}

_engine_xray_openrc_asset() {
    case "$(system_arch)" in
        amd64) printf '%s\n' 'Xray-linux-64.zip' ;;
        arm64) printf '%s\n' 'Xray-linux-arm64-v8a.zip' ;;
        armv7) printf '%s\n' 'Xray-linux-arm32-v7a.zip' ;;
        386)   printf '%s\n' 'Xray-linux-32.zip' ;;
        *) error "Unsupported Xray architecture: $(system_arch 2>/dev/null || uname -m)"; return 1 ;;
    esac
}

_engine_xray_write_openrc_service() {
    local unit="${PROXYCTL_OPENRC_INIT_DIR:-/etc/init.d}/$(engine_xray_service_name)" log_dir="${PROXYCTL_XRAY_LOG_DIR:-/var/log/xray}" bin
    bin=$(command -v xray) || return 1
    [[ ! -L "$unit" ]] || { error "Refusing symlink OpenRC service: ${unit}"; return 1; }
    mkdir -p -- "$(dirname "$unit")" "$log_dir" || return 1
    cat >"$unit" <<EOF
#!/sbin/openrc-run
# managed by ProxyCTL
name="Xray"
description="Xray service managed by ProxyCTL"
command="${bin}"
command_args="run -config $(engine_xray_config_file)"
command_background="yes"
pidfile="/run/$(engine_xray_service_name).pid"
output_log="${log_dir}/openrc.log"
error_log="${log_dir}/openrc-error.log"
depend() { need net; }
EOF
    chmod 755 "$unit"
}

_engine_xray_install_openrc() {
    local version="${1:-}" asset base work archive digest expected actual config had_config=0
    command -v curl >/dev/null 2>&1 || { error 'curl is required to install Xray.'; return 1; }
    command -v jq >/dev/null 2>&1 || { error 'jq is required to resolve Xray releases.'; return 1; }
    command -v sha256sum >/dev/null 2>&1 || { error 'sha256sum is required to verify Xray releases.'; return 1; }
    command -v unzip >/dev/null 2>&1 || package_install unzip || return 1

    config=$(engine_xray_config_file)
    [[ -f "$config" && ! -L "$config" ]] && had_config=1
    asset=$(_engine_xray_openrc_asset) || return 1
    if [[ -n "$version" ]]; then
        version="v${version#v}"
    else
        version=$(curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 \
            --connect-timeout 15 --max-time 60 "$_PROXYCTL_XRAY_RELEASE_API" | jq -r '.tag_name // empty') || return 1
        [[ "$version" == v* ]] || { error 'Unable to determine the latest Xray version.'; return 1; }
    fi
    base="${_PROXYCTL_XRAY_RELEASE_BASE}/${version}"
    work=$(mktemp -d) || return 1
    archive="$work/$asset"; digest="$archive.dgst"
    if ! curl --fail --location --proto '=https' --tlsv1.2 --retry 3 --connect-timeout 15 --max-time 180 "$base/$asset" -o "$archive" \
        || ! curl --fail --location --proto '=https' --tlsv1.2 --retry 3 --connect-timeout 15 --max-time 60 "$base/$asset.dgst" -o "$digest"; then
        rm -rf -- "$work"
        return 1
    fi
    expected=$(awk -F'= ' '$1=="SHA2-256" {print $2; exit}' "$digest")
    actual=$(sha256sum "$archive" | awk '{print $1}')
    [[ -n "$expected" && "$actual" == "$expected" ]] || { rm -rf -- "$work"; error 'Xray SHA-256 verification failed.'; return 1; }
    mkdir -p -- "$work/unpacked" || { rm -rf -- "$work"; return 1; }
    unzip -q "$archive" -d "$work/unpacked" || { rm -rf -- "$work"; return 1; }
    install -d -m 755 "${PROXYCTL_XRAY_BIN_DIR:-/usr/local/bin}" "$_PROXYCTL_XRAY_SHARE" || { rm -rf -- "$work"; return 1; }
    install -m 755 "$work/unpacked/xray" "${PROXYCTL_XRAY_BIN:-/usr/local/bin/xray}" || { rm -rf -- "$work"; return 1; }
    [[ ! -f "$work/unpacked/geoip.dat" ]] || install -m 644 "$work/unpacked/geoip.dat" "$_PROXYCTL_XRAY_SHARE/geoip.dat"
    [[ ! -f "$work/unpacked/geosite.dat" ]] || install -m 644 "$work/unpacked/geosite.dat" "$_PROXYCTL_XRAY_SHARE/geosite.dat"
    rm -rf -- "$work"
    if (( had_config == 0 )); then _engine_xray_write_default_config || return 1; fi
    _engine_xray_write_openrc_service || return 1
    _engine_xray_prepare_config_access || return 1
    engine_xray_validate "$config" || return 1
    engine_xray_enable || return 1
    if engine_xray_is_active; then engine_xray_restart; else engine_xray_start; fi
}

_engine_xray_install_systemd() {
    local version="${1:-}" installer had_config=0 config
    config=$(engine_xray_config_file)
    [[ -f "$config" && ! -L "$config" ]] && had_config=1
    installer=$(mktemp) || return 1
    if ! _engine_xray_download_installer "$installer"; then rm -f -- "$installer"; return 1; fi
    chmod 700 "$installer" || { rm -f -- "$installer"; return 1; }
    if [[ -n "$version" ]]; then
        TERM="${TERM:-xterm}" bash "$installer" install --version "${version#v}" || { rm -f -- "$installer"; return 1; }
    else
        TERM="${TERM:-xterm}" bash "$installer" install || { rm -f -- "$installer"; return 1; }
    fi
    rm -f -- "$installer"
    engine_xray_installed || { error 'Xray installer completed but the xray executable was not found.'; return 1; }
    if (( had_config == 0 )); then _engine_xray_write_default_config || return 1; fi
    _engine_xray_prepare_config_access || return 1
    engine_xray_validate "$config" || return 1
    engine_xray_enable || return 1
    if engine_xray_is_active; then engine_xray_restart; else engine_xray_start; fi
}

_engine_xray_install_impl() {
    _engine_xray_require_root || return 1
    case "$(system_init 2>/dev/null || true)" in
        systemd) _engine_xray_install_systemd "${1:-}" ;;
        openrc)  _engine_xray_install_openrc "${1:-}" ;;
        *) error 'Automatic Xray installation requires systemd or OpenRC.'; return 1 ;;
    esac
}

engine_xray_installed() { command -v xray >/dev/null 2>&1; }
engine_xray_version() { if engine_xray_installed; then xray version 2>&1 | head -1 || echo 'unknown'; else echo 'not installed'; fi; }
engine_xray_install() { _engine_xray_install_impl "${1:-}"; }
engine_xray_update() { _engine_xray_install_impl "${1:-}"; }

engine_xray_uninstall() {
    local installer unit
    _engine_xray_require_root || return 1
    engine_xray_installed || { info 'Xray is not installed.'; return 0; }
    case "$(system_init 2>/dev/null || true)" in
        systemd)
            installer=$(mktemp) || return 1
            if ! _engine_xray_download_installer "$installer"; then rm -f -- "$installer"; error 'Unable to download the official Xray uninstaller.'; return 1; fi
            chmod 700 "$installer" || { rm -f -- "$installer"; return 1; }
            TERM="${TERM:-xterm}" bash "$installer" remove || { rm -f -- "$installer"; return 1; }
            rm -f -- "$installer"
            ;;
        openrc)
            engine_xray_stop >/dev/null 2>&1 || true
            engine_xray_disable >/dev/null 2>&1 || true
            unit="${PROXYCTL_OPENRC_INIT_DIR:-/etc/init.d}/$(engine_xray_service_name)"
            if [[ -f "$unit" ]] && grep -q 'managed by ProxyCTL' "$unit" 2>/dev/null; then rm -f -- "$unit"; fi
            rm -f -- "${PROXYCTL_XRAY_BIN:-/usr/local/bin/xray}" "$_PROXYCTL_XRAY_SHARE/geoip.dat" "$_PROXYCTL_XRAY_SHARE/geosite.dat"
            ;;
        *) error 'Unsupported init system.'; return 1 ;;
    esac
    info 'Xray core removed. ProxyCTL configuration, certificates, metadata and backups were preserved.'
}

engine_xray_start()   { service_start "$(engine_xray_service_name)"; }
engine_xray_stop()    { service_stop "$(engine_xray_service_name)"; }
engine_xray_restart() { service_restart "$(engine_xray_service_name)"; }
engine_xray_enable()  { service_enable "$(engine_xray_service_name)"; }
engine_xray_disable() { service_disable "$(engine_xray_service_name)"; }
engine_xray_is_active() { engine_xray_installed || return 1; service_is_active "$(engine_xray_service_name)"; }
engine_xray_validate() {
    local config_file="${1:-${XRAY_CONFIG}}"
    engine_xray_installed || { error 'Xray is not installed.'; return 1; }
    [[ -f "$config_file" && ! -L "$config_file" ]] || { error "Config file not found or unsafe: ${config_file}"; return 1; }
    xray run -test -config "$config_file"
}
engine_xray_logs() { service_logs "$(engine_xray_service_name)" "${1:-100}"; }
engine_xray_config_file() { printf '%s\n' "${XRAY_CONFIG}"; }
engine_xray_service_name() { printf '%s\n' 'xray'; }
