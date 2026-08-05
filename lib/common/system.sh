#!/usr/bin/env bash
# ------------------------------------------------------------------------------
# system.sh — System-level utilities (OS, distro, arch, init, packages)
#
# All detection functions print a single value on stdout (data) and signal
# failure via the exit code. Errors/warnings go to stderr.
# ------------------------------------------------------------------------------

system_os() { uname -s | tr '[:upper:]' '[:lower:]'; }

_system_arch_from_machine() {
    local machine="$1"
    case "$machine" in
        x86_64|amd64) printf '%s\n' amd64 ;;
        aarch64|arm64) printf '%s\n' arm64 ;;
        armv7l|armv7) printf '%s\n' armv7 ;;
        i386|i686|x86) printf '%s\n' 386 ;;
        *) printf '%s\n' unsupported; return 1 ;;
    esac
}

system_arch() { _system_arch_from_machine "$(uname -m)"; }

_system_os_release_unquote() {
    local val="$1"
    val="${val%[\"\']}"; val="${val#[\"\']}"; printf '%s' "$val"
}

system_os_release_value() {
    local key="$1" file='/etc/os-release' val
    [[ -r "$file" ]] || return 1
    val=$(sed -n "s/^${key}=//p" "$file" | head -1)
    [[ -n "$val" ]] || return 1
    val=$(_system_os_release_unquote "$val")
    printf '%s' "$val" | tr '[:upper:]' '[:lower:]'
}

system_distro_id() { system_os_release_value ID; }

_system_distro_from_like() {
    local like="$1" tok
    local -a tokens=()
    read -r -a tokens <<< "$like"
    for tok in "${tokens[@]}"; do
        case "$tok" in debian|ubuntu|alpine|centos|rocky|almalinux|fedora|arch|rhel) printf '%s\n' "$tok"; return 0 ;; esac
    done
    return 1
}

system_distro() {
    local id like
    id=$(system_distro_id) || { error 'Unable to determine Linux distribution (missing /etc/os-release)'; return 1; }
    case "$id" in
        debian|ubuntu|alpine|centos|rocky|almalinux|fedora|arch) printf '%s\n' "$id"; return 0 ;;
        rhel|ol|amzn|virtuozzo) printf '%s\n' rhel; return 0 ;;
    esac
    like=$(system_os_release_value ID_LIKE 2>/dev/null || true)
    if _system_distro_from_like "$like"; then return 0; fi
    error "Unsupported distribution: ${id}"
    return 1
}

system_version() { system_os_release_value VERSION_ID; }

system_init() {
    if [[ -n "${PROXYCTL_TEST_INIT:-}" ]]; then
        case "$PROXYCTL_TEST_INIT" in systemd|openrc) printf '%s\n' "$PROXYCTL_TEST_INIT"; return 0 ;; *) printf '%s\n' unsupported; return 1 ;; esac
    fi
    if [[ -d /run/systemd/system ]]; then printf '%s\n' systemd
    elif command -v rc-service >/dev/null 2>&1; then printf '%s\n' openrc
    else printf '%s\n' unsupported; return 1
    fi
}

_system_has_dnf() { command -v dnf >/dev/null 2>&1; }

_system_package_manager_for_distro() {
    local distro="$1"
    case "$distro" in
        debian|ubuntu) printf '%s\n' apt ;;
        alpine) printf '%s\n' apk ;;
        fedora) printf '%s\n' dnf ;;
        centos|rocky|almalinux|rhel) if _system_has_dnf; then printf '%s\n' dnf; else printf '%s\n' yum; fi ;;
        arch) printf '%s\n' pacman ;;
        *) printf '%s\n' unknown; return 1 ;;
    esac
}

system_package_manager() {
    local distro pm
    if distro=$(system_distro 2>/dev/null); then
        if pm=$(_system_package_manager_for_distro "$distro" 2>/dev/null) && [[ "$pm" != unknown ]]; then printf '%s\n' "$pm"; return 0; fi
    fi
    if command -v apt-get >/dev/null 2>&1; then printf '%s\n' apt
    elif command -v apk >/dev/null 2>&1; then printf '%s\n' apk
    elif command -v dnf >/dev/null 2>&1; then printf '%s\n' dnf
    elif command -v yum >/dev/null 2>&1; then printf '%s\n' yum
    elif command -v pacman >/dev/null 2>&1; then printf '%s\n' pacman
    else printf '%s\n' unknown; return 1
    fi
}

_package_require_root() {
    if ! system_is_root; then error 'Package management requires root.'; return 1; fi
    return 0
}

package_update_index() {
    _package_require_root || return 1
    local pm; pm=$(system_package_manager) || return 1
    case "$pm" in
        apt) apt-get update ;;
        apk) apk update ;;
        dnf) dnf makecache ;;
        yum) yum makecache ;;
        pacman) pacman -Sy ;;
        *) error "No supported package manager (${pm})"; return 1 ;;
    esac
}

package_install() {
    _package_require_root || return 1
    (( $# > 0 )) || { error 'No packages specified.'; return 1; }
    local pm; pm=$(system_package_manager) || return 1
    case "$pm" in
        apt) apt-get install -y "$@" ;;
        apk) apk add "$@" ;;
        dnf) dnf install -y "$@" ;;
        yum) yum install -y "$@" ;;
        pacman) pacman -S --noconfirm "$@" ;;
        *) error "No supported package manager (${pm})"; return 1 ;;
    esac
}

package_remove() {
    _package_require_root || return 1
    (( $# > 0 )) || { error 'No packages specified.'; return 1; }
    local pm; pm=$(system_package_manager) || return 1
    case "$pm" in
        apt) apt-get remove -y "$@" ;;
        apk) apk del "$@" ;;
        dnf) dnf remove -y "$@" ;;
        yum) yum remove -y "$@" ;;
        pacman) pacman -R --noconfirm "$@" ;;
        *) error "No supported package manager (${pm})"; return 1 ;;
    esac
}

system_hostname() {
    local host
    host=$(hostname 2>/dev/null) || host=$(tr -d '[:space:]' < /etc/hostname 2>/dev/null || true)
    [[ -n "${host:-}" ]] || { error 'Unable to determine hostname'; return 1; }
    printf '%s\n' "$host"
}

system_is_root() { [[ "${EUID:-$(id -u)}" -eq 0 ]]; }

# Return a normal non-zero status instead of terminating the whole shell. This
# keeps the primitive composable inside transaction/install/service callers.
system_require_root() {
    if ! system_is_root; then
        error 'This command must be run as root.'
        return 1
    fi
    return 0
}
