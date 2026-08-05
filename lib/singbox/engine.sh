#!/usr/bin/env bash
# ------------------------------------------------------------------------------
# singbox/engine.sh — sing-box engine implementation (Phase 1: API stubs)
# ------------------------------------------------------------------------------

_register_engine 'singbox'

# --- engine_singbox_installed -----------------------------------------------
engine_singbox_installed() {
    command -v sing-box > /dev/null 2>&1
}

# --- engine_singbox_version -------------------------------------------------
engine_singbox_version() {
    if engine_singbox_installed; then
        sing-box version 2>&1 | head -1 || echo 'unknown'
    else
        echo 'not installed'
    fi
}

# --- engine_singbox_install -------------------------------------------------
engine_singbox_install() {
    # Stub — will install sing-box via the official install script in a future phase.
    error 'sing-box installation is not yet implemented.'
    return 1
}

# --- engine_singbox_update --------------------------------------------------
engine_singbox_update() {
    # Stub
    error 'sing-box update is not yet implemented.'
    return 1
}

# --- engine_singbox_uninstall -----------------------------------------------
engine_singbox_uninstall() {
    # Stub
    error 'sing-box uninstall is not yet implemented.'
    return 1
}

# --- engine_singbox_start ---------------------------------------------------
engine_singbox_start() {
    # Stub
    if engine_singbox_installed && systemctl is-active --quiet sing-box 2>/dev/null; then
        info 'sing-box is already running.'
    else
        error 'sing-box start is not yet implemented.'
        return 1
    fi
}

# --- engine_singbox_stop ----------------------------------------------------
engine_singbox_stop() {
    # Stub
    error 'sing-box stop is not yet implemented.'
    return 1
}

# --- engine_singbox_restart -------------------------------------------------
engine_singbox_restart() {
    # Stub
    error 'sing-box restart is not yet implemented.'
    return 1
}

# --- engine_singbox_enable --------------------------------------------------
engine_singbox_enable() {
    # Stub
    error 'sing-box enable (auto-start) is not yet implemented.'
    return 1
}

# --- engine_singbox_disable -------------------------------------------------
engine_singbox_disable() {
    # Stub
    error 'sing-box disable (auto-start) is not yet implemented.'
    return 1
}

# --- engine_singbox_is_active -----------------------------------------------
engine_singbox_is_active() {
    if ! engine_singbox_installed; then
        return 1
    fi
    systemctl is-active --quiet sing-box 2>/dev/null
}

# --- engine_singbox_validate ------------------------------------------------
engine_singbox_validate() {
    local config_file="${1:-${SINGBOX_CONFIG}}"
    # Stub — will run `sing-box check` in a future phase.
    # Fail closed: unimplemented validation must not report success.
    if [[ ! -f "${config_file}" ]]; then
        error "Config file not found: ${config_file}"
        return 1
    fi
    error 'sing-box config validation is not implemented.'
    return 1
}

# --- engine_singbox_logs ----------------------------------------------------
engine_singbox_logs() {
    # Stub — will tail journalctl in a future phase.
    warn 'sing-box logs are not yet implemented.'
    return 1
}

# --- engine_singbox_config_file ---------------------------------------------
engine_singbox_config_file() {
    echo "${SINGBOX_CONFIG}"
}

# --- engine_singbox_service_name --------------------------------------------
engine_singbox_service_name() {
    echo 'sing-box'
}
