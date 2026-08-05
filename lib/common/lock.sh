#!/usr/bin/env bash
# ------------------------------------------------------------------------------
# lock.sh — ProxyCTL process locking
#
# Three logical locks map to fixed files in a dedicated runtime directory:
#
#   config   -> /run/proxyctl/config.lock
#   cert     -> /run/proxyctl/cert.lock
#   firewall -> /run/proxyctl/firewall.lock
#
# The lock is enforced by the kernel via flock(1) on a file descriptor that
# stays open for the whole time the lock is held. The lock file itself is not
# the lock and is never deleted.
#
# Security invariants:
#   * the lock parent must be a real directory, never a symlink
#   * the parent must be owned by the current EUID and not group/world-writable
#   * an existing lock path must be an owned regular file, never a symlink
#   * lock files are opened append-only, never with a truncating redirection
#
# Bash 4.0 compatible: fixed fds (200/201/202) and top-level `declare -A` are
# used; Bash 4.1+ dynamic-fd syntax and Bash 4.2+ `declare -g` are avoided.
# ------------------------------------------------------------------------------

declare -A _PROXYCTL_LOCK_HELD
declare -A _PROXYCTL_LOCK_FDS

lock_fd() {
    local name="${1:-}"
    case "${name}" in
        config)   printf '%s\n' '200' ;;
        cert)     printf '%s\n' '201' ;;
        firewall) printf '%s\n' '202' ;;
        *) echo "Unknown lock name: ${name}" >&2; return 1 ;;
    esac
}

_lock_default_dir() {
    printf '%s\n' "${PROXYCTL_LOCK_DIR:-/run/proxyctl}"
}

lock_path() {
    local name="${1:-}"
    local default_dir
    default_dir=$(_lock_default_dir)
    case "${name}" in
        config)   printf '%s\n' "${PROXYCTL_LOCK:-${default_dir}/config.lock}" ;;
        cert)     printf '%s\n' "${PROXYCTL_CERT_LOCK:-${default_dir}/cert.lock}" ;;
        firewall) printf '%s\n' "${PROXYCTL_FIREWALL_LOCK:-${default_dir}/firewall.lock}" ;;
        *) echo "Unknown lock name: ${name}" >&2; return 1 ;;
    esac
}

_lock_validate_name() {
    local name="${1:-}"
    case "${name}" in
        config|cert|firewall) return 0 ;;
        *) echo "Unknown lock name: ${name}" >&2; return 1 ;;
    esac
}

_lock_require_flock() {
    command -v flock >/dev/null 2>&1 || {
        echo 'flock is required for ProxyCTL locking.' >&2
        return 1
    }
    return 0
}

_lock_busy_message() {
    case "${1:-}" in
        config)   echo 'Another ProxyCTL config operation is already running.' ;;
        cert)     echo 'Another ProxyCTL certificate operation is already running.' ;;
        firewall) echo 'Another ProxyCTL firewall operation is already running.' ;;
    esac
}

_lock_parent_is_secure() {
    local parent="$1"
    local mode perm owner

    [[ ! -L "${parent}" ]] || {
        error "Refusing symlink lock directory: ${parent}"
        return 1
    }
    [[ -d "${parent}" ]] || {
        error "Lock parent is not a directory: ${parent}"
        return 1
    }

    owner=$(stat -c '%u' "${parent}" 2>/dev/null) || {
        error "Unable to inspect lock directory owner: ${parent}"
        return 1
    }
    if [[ "${owner}" != "${EUID}" ]]; then
        error "Refusing lock directory not owned by current user: ${parent}"
        return 1
    fi

    mode=$(stat -c '%a' "${parent}" 2>/dev/null) || {
        error "Unable to inspect lock directory permissions: ${parent}"
        return 1
    }
    perm=$((8#${mode}))
    if (( perm & 0022 )); then
        error "Refusing insecure lock directory permissions: ${parent}"
        return 1
    fi
    return 0
}

# Create only the final directory component. Its parent must already exist;
# this avoids mkdir -p traversing attacker-controlled symlink chains.
_lock_ensure_parent() {
    local path="$1"
    local parent grandparent
    parent=$(dirname "${path}")

    if [[ -e "${parent}" || -L "${parent}" ]]; then
        _lock_parent_is_secure "${parent}"
        return $?
    fi

    grandparent=$(dirname "${parent}")
    [[ ! -L "${grandparent}" && -d "${grandparent}" ]] || {
        error "Lock directory parent is unavailable or unsafe: ${grandparent}"
        return 1
    }

    if ! ( umask 077; mkdir -m 700 "${parent}" ); then
        error "Failed to create lock directory: ${parent}"
        return 1
    fi

    _lock_parent_is_secure "${parent}"
}

# Existing paths must be owned plain regular files. Symlinks and special files
# are rejected before chmod/open, so ProxyCTL never follows a planted symlink.
_lock_ensure_file() {
    local path="$1"
    local owner

    if [[ -L "${path}" ]]; then
        error "Refusing symlink lock file: ${path}"
        return 1
    fi

    if [[ -e "${path}" ]]; then
        [[ -f "${path}" ]] || {
            error "Lock path is not a regular file: ${path}"
            return 1
        }
        owner=$(stat -c '%u' "${path}" 2>/dev/null) || {
            error "Unable to inspect lock file owner: ${path}"
            return 1
        }
        if [[ "${owner}" != "${EUID}" ]]; then
            error "Refusing lock file not owned by current user: ${path}"
            return 1
        fi
    else
        if ! ( umask 077; : > "${path}" ); then
            error "Failed to create lock file: ${path}"
            return 1
        fi
    fi

    chmod 600 "${path}" 2>/dev/null || {
        error "Failed to secure lock file permissions: ${path}"
        return 1
    }
    return 0
}

# Append-only open avoids truncating an existing regular lock file.
_lock_open_fd() {
    local name="$1"
    local path="$2"
    case "${name}" in
        config)   exec 200>>"${path}" ;;
        cert)     exec 201>>"${path}" ;;
        firewall) exec 202>>"${path}" ;;
    esac
}

_lock_close_fd() {
    case "${1:-}" in
        config)   exec 200>&- 2>/dev/null || true ;;
        cert)     exec 201>&- 2>/dev/null || true ;;
        firewall) exec 202>&- 2>/dev/null || true ;;
    esac
}

# Non-blocking and idempotent for locks already held by this process.
lock_acquire() {
    local name="${1:-}"
    local path fd

    _lock_validate_name "${name}" || return 1

    # Check ownership before requiring flock again: duplicate acquire is a true
    # no-op and never reopens/disturbs the held fd.
    if lock_is_held "${name}"; then
        return 0
    fi

    _lock_require_flock || return 1
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

# True only when the current process owns this logical lock.
lock_is_held() {
    local name="${1:-}"
    _lock_validate_name "${name}" || return 1
    [[ "${_PROXYCTL_LOCK_HELD[${name}]:-0}" == '1' ]]
}

# Internal probe. File existence is never used as a lock-state signal.
_lock_is_available() {
    local name="${1:-}"
    local path

    _lock_validate_name "${name}" || return 1
    _lock_require_flock || return 1
    path=$(lock_path "${name}") || return 1
    _lock_ensure_parent "${path}" || return 1
    _lock_ensure_file "${path}" || return 1

    if ! exec 199>>"${path}" 2>/dev/null; then
        return 1
    fi
    if flock -n 199 2>/dev/null; then
        exec 199>&- 2>/dev/null || true
        return 0
    fi
    exec 199>&- 2>/dev/null || true
    return 1
}

# Runs a command under a lock, preserving arguments and the command's exit code.
# If the caller already owned the lock, with_lock leaves that ownership intact.
with_lock() {
    local name="${1:-}"
    shift || true

    if (( $# == 0 )); then
        error 'with_lock: no command provided'
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
