#!/usr/bin/env bash
# ------------------------------------------------------------------------------
# lock.sh — ProxyCTL process locking
#
# Three logical locks map to fixed lock files:
#
#   config   -> $PROXYCTL_LOCK            (default /run/lock/proxyctl.lock)
#   cert     -> $PROXYCTL_CERT_LOCK       (default /run/lock/proxyctl-cert.lock)
#   firewall -> $PROXYCTL_FIREWALL_LOCK   (default /run/lock/proxyctl-firewall.lock)
#
# The lock is enforced by the KERNEL via flock(1) on a file descriptor that
# stays open for the whole time the lock is held. The lock file itself is
# never a lock:
#
#   * a leftover lock file means nothing — it is not a lock and is never
#     deleted (deleting it would let two processes lock different inodes
#     and both "win")
#   * when a process exits (normally, via crash, or even SIGKILL) the kernel
#     closes every open fd and the flock is released automatically — no
#     stale-lock cleanup is required
#
# Bash 4.0 compatible: locks use fixed fds (200/201/202) instead of the
# Bash 4.1+ `exec {fd}>file` form.
# ------------------------------------------------------------------------------

# name -> '1' when the CURRENT process holds the lock
declare -Ag _PROXYCTL_LOCK_HELD=()
# name -> open fd
declare -Ag _PROXYCTL_LOCK_FDS=()

# --- lock_fd ---------------------------------------------------------------
# Fixed fd for each lock. Explicit case mapping only — never build a number
# or a path from user input.
lock_fd() {
    local name="${1:-}"
    case "${name}" in
        config)   printf '%s\n' '200' ;;
        cert)     printf '%s\n' '201' ;;
        firewall) printf '%s\n' '202' ;;
        *)
            echo "Unknown lock name: ${name}" >&2
            return 1
            ;;
    esac
}

# --- lock_path -------------------------------------------------------------
# Resolve a logical lock name to its lock file path.
lock_path() {
    local name="${1:-}"
    case "${name}" in
        config)   printf '%s\n' "${PROXYCTL_LOCK:-/run/lock/proxyctl.lock}" ;;
        cert)     printf '%s\n' "${PROXYCTL_CERT_LOCK:-/run/lock/proxyctl-cert.lock}" ;;
        firewall) printf '%s\n' "${PROXYCTL_FIREWALL_LOCK:-/run/lock/proxyctl-firewall.lock}" ;;
        *)
            echo "Unknown lock name: ${name}" >&2
            return 1
            ;;
    esac
}

# --- _lock_validate_name -----------------------------------------------------
_lock_validate_name() {
    local name="${1:-}"
    case "${name}" in
        config|cert|firewall) return 0 ;;
        *)
            echo "Unknown lock name: ${name}" >&2
            return 1
            ;;
    esac
}

# --- _lock_require_flock -----------------------------------------------------
# Fail closed when flock is unavailable. This module never installs it.
# Tests may override this function directly.
_lock_require_flock() {
    command -v flock >/dev/null 2>&1 || {
        echo 'flock is required for ProxyCTL locking.' >&2
        return 1
    }
    return 0
}

# --- _lock_busy_message ------------------------------------------------------
_lock_busy_message() {
    case "${1:-}" in
        config)   echo 'Another ProxyCTL config operation is already running.' ;;
        cert)     echo 'Another ProxyCTL certificate operation is already running.' ;;
        firewall) echo 'Another ProxyCTL firewall operation is already running.' ;;
    esac
}

# --- _lock_ensure_parent -----------------------------------------------------
# mkdir -p the parent. chmod 700 only directories this module creates that are
# NOT the system-shared /run/lock — we never change system lock dir perms.
_lock_ensure_parent() {
    local path="$1"
    local parent
    parent=$(dirname "${path}")
    if [[ -d "${parent}" ]]; then
        return 0
    fi
    if ! mkdir -p "${parent}"; then
        error "Failed to create lock directory: ${parent}"
        return 1
    fi
    if [[ "${parent}" != '/run/lock' && "${parent}" != '/var/run/lock' ]]; then
        chmod 700 "${parent}" 2>/dev/null || true
    fi
    return 0
}

# --- _lock_ensure_file -------------------------------------------------------
# The lock file may already exist (see module header: a leftover file is
# fine). Create it mode 600 only when missing. Never delete it.
_lock_ensure_file() {
    local path="$1"
    if [[ ! -e "${path}" ]]; then
        ( umask 077; : > "${path}" ) 2>/dev/null || return 1
    fi
    chmod 600 "${path}" 2>/dev/null || true
    return 0
}

# --- _lock_open_fd ----------------------------------------------------------
# Open the fixed fd against the lock file in the CURRENT shell. The fd must
# stay open for the lifetime of the lock — closing it releases the flock.
_lock_open_fd() {
    local name="$1"
    local path="$2"
    case "${name}" in
        config)   exec 200>"${path}" ;;
        cert)     exec 201>"${path}" ;;
        firewall) exec 202>"${path}" ;;
    esac
}

# --- _lock_close_fd ---------------------------------------------------------
_lock_close_fd() {
    case "${1:-}" in
        config)   exec 200>&- 2>/dev/null || true ;;
        cert)     exec 201>&- 2>/dev/null || true ;;
        firewall) exec 202>&- 2>/dev/null || true ;;
    esac
}

# --- lock_acquire -----------------------------------------------------------
# Usage: lock_acquire <config|cert|firewall>
# Non-blocking. Returns 0 on success, 1 if another process holds the lock.
# Idempotent per process: re-acquiring a lock this process already holds
# returns 0 without touching the open fd (recursive counting is not done).
lock_acquire() {
    local name="${1:-}"
    local path fd

    _lock_validate_name "${name}" || return 1
    _lock_require_flock || return 1

    if lock_is_held "${name}"; then
        return 0
    fi

    path=$(lock_path "${name}") || return 1
    fd=$(lock_fd "${name}") || return 1

    _lock_ensure_parent "${path}" || return 1
    _lock_ensure_file "${path}" || return 1

    if ! _lock_open_fd "${name}" "${path}" 2>/dev/null; then
        error "Failed to open lock file: ${path}"
        return 1
    fi

    if ! flock -n "${fd}"; then
        error "$(_lock_busy_message "${name}")"
        _lock_close_fd "${name}"
        return 1
    fi

    _PROXYCTL_LOCK_HELD["${name}"]=1
    _PROXYCTL_LOCK_FDS["${name}"]="${fd}"
    return 0
}

# --- lock_release -----------------------------------------------------------
# Usage: lock_release <config|cert|firewall>
# Idempotent: releasing a lock this process does not hold returns 0.
# Unlocks and closes the fd. Never deletes the lock file.
lock_release() {
    local name="${1:-}"
    local fd

    _lock_validate_name "${name}" || return 1

    if ! lock_is_held "${name}"; then
        return 0
    fi

    fd="${_PROXYCTL_LOCK_FDS[${name}]:-}"
    if [[ -n "${fd}" ]]; then
        flock -u "${fd}" 2>/dev/null || true
    fi
    _lock_close_fd "${name}"
    unset "_PROXYCTL_LOCK_HELD[${name}]"
    unset "_PROXYCTL_LOCK_FDS[${name}]"
    return 0
}

# --- lock_is_held -----------------------------------------------------------
# True only if the CURRENT process holds this lock. It says nothing about
# whether another process holds it.
lock_is_held() {
    local name="${1:-}"
    _lock_validate_name "${name}" || return 1
    [[ "${_PROXYCTL_LOCK_HELD[${name}]:-0}" == '1' ]]
}

# --- _lock_is_available -----------------------------------------------------
# Internal. True if NO process currently holds the lock. Probes via a
# temporary fd so the current process's own held state is not disturbed.
# (Not part of the public Phase 2.4 API.)
_lock_is_available() {
    local name="${1:-}"
    local path

    _lock_validate_name "${name}" || return 1
    _lock_require_flock || return 1

    path=$(lock_path "${name}") || return 1
    _lock_ensure_parent "${path}" || return 1
    _lock_ensure_file "${path}" || return 1

    if ! exec 199>"${path}" 2>/dev/null; then
        return 1
    fi
    if flock -n 199 2>/dev/null; then
        exec 199>&- 2>/dev/null || true
        return 0
    fi
    exec 199>&- 2>/dev/null || true
    return 1
}

# --- with_lock --------------------------------------------------------------
# Usage: with_lock <config|cert|firewall> <command> [args...]
# Runs the command while holding the lock. Arguments are passed verbatim
# (`"$@"`) — never eval'd. The command's exit code is preserved.
#
# Ownership rule: if this process already holds the lock before the call,
# with_lock does not re-acquire it and does NOT release it afterwards — the
# caller keeps ownership. Only locks acquired by with_lock are released here.
with_lock() {
    local name="${1:-}"
    shift || true

    if (( $# == 0 )); then
        error "with_lock: no command provided"
        return 1
    fi

    local owned_before=0
    lock_is_held "${name}" && owned_before=1

    if (( owned_before == 0 )); then
        lock_acquire "${name}" || return 1
    fi

    local rc
    if "$@"; then
        rc=0
    else
        rc=$?
    fi

    if (( owned_before == 0 )); then
        lock_release "${name}" || {
            error "Failed to release lock: ${name}"
            (( rc == 0 )) && rc=1
        }
    fi

    return "${rc}"
}
