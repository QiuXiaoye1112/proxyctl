#!/usr/bin/env bash
# ------------------------------------------------------------------------------
# system.sh — System-level utilities (architecture, package manager, etc.)
# ------------------------------------------------------------------------------

# --- system_arch ------------------------------------------------------------
system_arch() {
    uname -m
}

# --- system_os --------------------------------------------------------------
system_os() {
    uname -s | tr '[:upper:]' '[:lower:]'
}

# --- system_is_root ---------------------------------------------------------
system_is_root() {
    [[ "${EUID:-$(id -u)}" -eq 0 ]]
}

# --- system_require_root ----------------------------------------------------
system_require_root() {
    if ! system_is_root; then
        die 'This command must be run as root.'
    fi
}

# --- system_package_manager -------------------------------------------------
system_package_manager() {
    if command -v apt-get > /dev/null 2>&1; then
        echo 'apt'
    elif command -v yum > /dev/null 2>&1; then
        echo 'yum'
    elif command -v dnf > /dev/null 2>&1; then
        echo 'dnf'
    elif command -v pacman > /dev/null 2>&1; then
        echo 'pacman'
    elif command -v apk > /dev/null 2>&1; then
        echo 'apk'
    else
        echo 'unknown'
    fi
}
