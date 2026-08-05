#!/usr/bin/env bash
# ------------------------------------------------------------------------------
# service.sh — Unified service control (systemd / OpenRC)
#
# Upper layers call service_* without caring which init system is in use.
# All write operations require root; read-only operations do not.
# ------------------------------------------------------------------------------

# --- _service_validate_name --------------------------------------------------
# Service names become command arguments; restrict to safe characters.
# First character must be alphanumeric so "." and ".." are rejected outright.
_service_validate_name() {
    local service="$1"
    [[ -n "$service" && "$service" =~ ^[A-Za-z0-9][A-Za-z0-9_.@-]*$ ]] || {
        error "Invalid service name: ${service}"
        return 1
    }
    return 0
}

# --- _service_validate_lines -------------------------------------------------
# Log line count must be an integer in [1, 10000].
_service_validate_lines() {
    local lines="$1"
    [[ "$lines" =~ ^[0-9]+$ ]] || return 1
    (( lines >= 1 && lines <= 10000 )) || return 1
    return 0
}

# --- _service_require_root ---------------------------------------------------
# Write operations need root. Returns 1 (does not die) so callers can compose.
_service_require_root() {
    if ! system_is_root; then
        error 'Service control requires root.'
        return 1
    fi
    return 0
}

# --- service_exists ----------------------------------------------------------
# Usage: service_exists <service>
service_exists() {
    local service="$1"
    _service_validate_name "$service" || return 1

    local init
    init=$(system_init) || return 1
    case "$init" in
        systemd)
            systemctl list-unit-files --type=service "${service}.service" > /dev/null 2>&1
            ;;
        openrc)
            [[ -x "/etc/init.d/${service}" ]]
            ;;
    esac
}

# --- service_start -----------------------------------------------------------
service_start() {
    local service="$1"
    _service_validate_name "$service" || return 1
    _service_require_root || return 1

    local init
    init=$(system_init) || return 1
    case "$init" in
        systemd) systemctl start "$service" ;;
        openrc)  rc-service "$service" start ;;
    esac
}

# --- service_stop ------------------------------------------------------------
service_stop() {
    local service="$1"
    _service_validate_name "$service" || return 1
    _service_require_root || return 1

    local init
    init=$(system_init) || return 1
    case "$init" in
        systemd) systemctl stop "$service" ;;
        openrc)  rc-service "$service" stop ;;
    esac
}

# --- service_restart ---------------------------------------------------------
service_restart() {
    local service="$1"
    _service_validate_name "$service" || return 1
    _service_require_root || return 1

    local init
    init=$(system_init) || return 1
    case "$init" in
        systemd) systemctl restart "$service" ;;
        openrc)  rc-service "$service" restart ;;
    esac
}

# --- service_enable ----------------------------------------------------------
service_enable() {
    local service="$1"
    _service_validate_name "$service" || return 1
    _service_require_root || return 1

    local init
    init=$(system_init) || return 1
    case "$init" in
        systemd) systemctl enable "$service" ;;
        openrc)  rc-update add "$service" default ;;
    esac
}

# --- service_disable ---------------------------------------------------------
service_disable() {
    local service="$1"
    _service_validate_name "$service" || return 1
    _service_require_root || return 1

    local init
    init=$(system_init) || return 1
    case "$init" in
        systemd) systemctl disable "$service" ;;
        openrc)  rc-update del "$service" default ;;
    esac
}

# --- service_is_active -------------------------------------------------------
service_is_active() {
    local service="$1"
    _service_validate_name "$service" || return 1

    local init
    init=$(system_init) || return 1
    case "$init" in
        systemd) systemctl is-active --quiet "$service" ;;
        openrc)  rc-service "$service" status > /dev/null 2>&1 ;;
    esac
}

# --- service_is_enabled ------------------------------------------------------
service_is_enabled() {
    local service="$1"
    _service_validate_name "$service" || return 1

    local init
    init=$(system_init) || return 1
    case "$init" in
        systemd) systemctl is-enabled --quiet "$service" ;;
        # Exact first-field match — service names may contain "." and "-"
        # which grep would otherwise treat as regex.
        openrc)  rc-update show | awk -v svc="$service" '$1 == svc {found=1} END {exit !found}' ;;
    esac
}

# --- service_logs ------------------------------------------------------------
# Usage: service_logs <service> [lines]
service_logs() {
    local service="$1"
    local lines="${2-50}"   # default only when unset, so an explicit "" is rejected
    _service_validate_name "$service" || return 1
    _service_validate_lines "$lines" || {
        error "Invalid log line count: ${lines} (must be 1-10000)"
        return 1
    }

    local init
    init=$(system_init) || return 1
    case "$init" in
        systemd)
            journalctl -u "$service" -n "$lines" --no-pager
            ;;
        openrc)
            # OpenRC has no journal; prefer a log file, otherwise be explicit.
            local log
            for log in "/var/log/${service}.log" "/var/log/${service}/system.log"; do
                if [[ -f "$log" ]]; then
                    tail -n "$lines" "$log"
                    return 0
                fi
            done
            error "No log file found for OpenRC service '${service}'"
            return 1
            ;;
    esac
}
