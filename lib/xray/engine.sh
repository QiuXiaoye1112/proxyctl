#!/usr/bin/env bash
# ------------------------------------------------------------------------------
# xray/engine.sh — Xray engine implementation (Phase 1: API stubs)
# ------------------------------------------------------------------------------

ENGINE_NAME='xray'
_register_engine 'xray'

# --- engine_xray_installed --------------------------------------------------
engine_xray_installed() {
    command -v xray > /dev/null 2>&1
}

# --- engine_xray_version ----------------------------------------------------
engine_xray_version() {
    if engine_xray_installed; then
        xray version 2>&1 | head -1 || echo 'unknown'
    else
        echo 'not installed'
    fi
}

# --- engine_xray_install ----------------------------------------------------
engine_xray_install() {
    # Stub — will install Xray via the official install script in a future phase.
    error 'Xray installation is not yet implemented.'
    return 1
}

# --- engine_xray_update -----------------------------------------------------
engine_xray_update() {
    # Stub
    error 'Xray update is not yet implemented.'
    return 1
}

# --- engine_xray_uninstall --------------------------------------------------
engine_xray_uninstall() {
    # Stub
    error 'Xray uninstall is not yet implemented.'
    return 1
}

# --- engine_xray_start ------------------------------------------------------
engine_xray_start() {
    service_start "$(engine_xray_service_name)"
}

# --- engine_xray_stop -------------------------------------------------------
engine_xray_stop() {
    service_stop "$(engine_xray_service_name)"
}

# --- engine_xray_restart ----------------------------------------------------
engine_xray_restart() {
    service_restart "$(engine_xray_service_name)"
}

# --- engine_xray_enable -----------------------------------------------------
engine_xray_enable() {
    service_enable "$(engine_xray_service_name)"
}

# --- engine_xray_disable ----------------------------------------------------
engine_xray_disable() {
    service_disable "$(engine_xray_service_name)"
}

# --- engine_xray_is_active --------------------------------------------------
engine_xray_is_active() {
    if ! engine_xray_installed; then
        return 1
    fi
    service_is_active "$(engine_xray_service_name)"
}

# --- engine_xray_validate ---------------------------------------------------
# Usage: engine_xray_validate <file>
# Real core validation: `xray run -test -config FILE`. A file that is merely
# valid JSON is NOT valid Xray config — only the core decides.
# Fail closed: core missing, file missing, or core returning non-zero all fail.
engine_xray_validate() {
    local config_file="${1:-${XRAY_CONFIG}}"

    if ! engine_xray_installed; then
        error 'Xray is not installed.'
        return 1
    fi
    if [[ ! -f "${config_file}" ]]; then
        error "Config file not found: ${config_file}"
        return 1
    fi

    xray run -test -config "${config_file}"
}

# --- engine_xray_logs -------------------------------------------------------
engine_xray_logs() {
    # Stub — will tail journalctl in a future phase.
    warn 'Xray logs are not yet implemented.'
    return 1
}

# --- engine_xray_config_file ------------------------------------------------
engine_xray_config_file() {
    echo "${XRAY_CONFIG}"
}

# --- engine_xray_service_name -----------------------------------------------
engine_xray_service_name() {
    echo 'xray'
}
