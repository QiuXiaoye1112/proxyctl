#!/usr/bin/env bash
# ------------------------------------------------------------------------------
# core.sh — Engine dispatcher and shared constants
# ------------------------------------------------------------------------------

# --- engine registry --------------------------------------------------------
# Bash 3.2 compatible — plain variable, not an associative array.
_PROXYCTL_ENGINE_LIST=''

_register_engine() {
    local name="$1"
    _PROXYCTL_ENGINE_LIST="${_PROXYCTL_ENGINE_LIST}${name}"$'\n'
}

# The standard API every engine must expose:
#   engine_installed
#   engine_version
#   engine_install
#   engine_update
#   engine_uninstall
#   engine_start
#   engine_stop
#   engine_restart
#   engine_enable
#   engine_disable
#   engine_is_active
#   engine_validate
#   engine_logs
#   engine_config_file
#   engine_service_name

_KNOWN_ENGINE_APIS=(
    installed version install update uninstall
    start stop restart enable disable
    is_active validate logs config_file service_name
)

# --- engine_call ------------------------------------------------------------
# Usage: engine_call <engine> <method> [args...]
#
# Dispatches to engine_<engine>_<method>.
engine_call() {
    local engine="$1"
    local method="$2"
    shift 2 || true

    local func="engine_${engine}_${method}"

    if ! declare -F "${func}" > /dev/null 2>&1; then
        error "Engine '${engine}' does not implement '${method}'"
        return 1
    fi

    "${func}" "$@"
}

# --- engine_list ------------------------------------------------------------
engine_list() {
    printf '%s' "${_PROXYCTL_ENGINE_LIST}" | sort -u
}

# --- engine_exists ----------------------------------------------------------
engine_exists() {
    local engine="$1"
    local pattern=$'\n'"${engine}"$'\n'
    [[ $'\n'"${_PROXYCTL_ENGINE_LIST}" == *"${pattern}"* ]]
}

# --- engine_require ---------------------------------------------------------
engine_require() {
    local engine="$1"
    if ! engine_exists "${engine}"; then
        die "Unknown engine: ${engine}"
    fi
}

# --- protocol helpers (delegates to capability.sh) -------------------------
engine_protocols() {
    local engine="$1"
    engine_require "${engine}"
    _capability_protocols "${engine}"
}

protocol_transports() {
    local engine="$1"
    local protocol="$2"
    engine_require "${engine}"

    # Validate protocol exists for this engine
    local valid
    valid=$(_capability_protocols "${engine}")
    local found=0
    local p
    while IFS= read -r p; do
        [[ "${p}" == "${protocol}" ]] && found=1 && break
    done <<< "${valid}"

    if ((found == 0)); then
        error "Engine '${engine}' does not support protocol '${protocol}'"
        return 1
    fi

    _capability_transports "${engine}" "${protocol}"
}
