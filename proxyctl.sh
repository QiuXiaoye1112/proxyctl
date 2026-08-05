#!/usr/bin/env bash
# ------------------------------------------------------------------------------
# proxyctl — Unified proxy manager for Xray and sing-box
# ------------------------------------------------------------------------------
set -o errexit
set -o nounset
set -o pipefail

readonly PROXYCTL_VERSION='0.2.3'

# --- paths ----------------------------------------------------------------
readonly PROXYCTL_BIN="${PROXYCTL_BIN:-/usr/local/sbin/proxyctl}"
readonly PROXYCTL_LIB="${PROXYCTL_LIB:-/usr/local/lib/proxyctl}"
readonly PROXYCTL_DATA="${PROXYCTL_DATA:-/var/lib/proxyctl}"
readonly PROXYCTL_META="${PROXYCTL_DATA}/meta.json"
readonly PROXYCTL_CERTS="${PROXYCTL_CERTS:-/etc/proxyctl/certs}"
readonly PROXYCTL_BACKUP="${PROXYCTL_BACKUP:-/var/backups/proxyctl}"
readonly PROXYCTL_LOCK_DIR="${PROXYCTL_LOCK_DIR:-/run/proxyctl}"
readonly PROXYCTL_LOCK="${PROXYCTL_LOCK:-${PROXYCTL_LOCK_DIR}/config.lock}"
readonly PROXYCTL_CERT_LOCK="${PROXYCTL_CERT_LOCK:-${PROXYCTL_LOCK_DIR}/cert.lock}"
readonly PROXYCTL_FIREWALL_LOCK="${PROXYCTL_FIREWALL_LOCK:-${PROXYCTL_LOCK_DIR}/firewall.lock}"

readonly XRAY_CONFIG='/usr/local/etc/xray/config.json'
readonly SINGBOX_CONFIG='/etc/sing-box/config.json'

# Resolve LIB_DIR with a 3-way fallback:
#   1. PROXYCTL_DEV_LIB — development override
#   2. Sibling lib/ directory relative to the script — source checkout
#   3. PROXYCTL_LIB (default /usr/local/lib/proxyctl) — installed layout
if [[ -n "${PROXYCTL_DEV_LIB:-}" ]]; then
    readonly LIB_DIR="${PROXYCTL_DEV_LIB}"
elif [[ -d "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib" ]]; then
    readonly LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib"
else
    readonly LIB_DIR="${PROXYCTL_LIB}"
fi

# --- require_runtime_dependencies -------------------------------------------
require_runtime_dependencies() {
    # Bash 4.0+ required for case modification, associative arrays, etc.
    if [[ "${BASH_VERSINFO[0]:-0}" -lt 4 ]]; then
        echo "proxyctl: Bash 4.0+ is required (found ${BASH_VERSION:-unknown})" >&2
        exit 1
    fi
}

# Run bash version check immediately — even version/help need it.
require_runtime_dependencies

# --- module loading --------------------------------------------------------
# shellcheck source=lib/core.sh
source "${LIB_DIR}/core.sh"
# shellcheck source=lib/ui.sh
source "${LIB_DIR}/ui.sh"
# shellcheck source=lib/capability.sh
source "${LIB_DIR}/capability.sh"
# shellcheck source=lib/metadata.sh
source "${LIB_DIR}/metadata.sh"
# shellcheck source=lib/transaction.sh
source "${LIB_DIR}/transaction.sh"
# shellcheck source=lib/menu.sh
source "${LIB_DIR}/menu.sh"

# shellcheck source=lib/common/system.sh
source "${LIB_DIR}/common/system.sh"
# shellcheck source=lib/common/service.sh
source "${LIB_DIR}/common/service.sh"
# shellcheck source=lib/common/network.sh
source "${LIB_DIR}/common/network.sh"
# shellcheck source=lib/common/port.sh
source "${LIB_DIR}/common/port.sh"
# shellcheck source=lib/common/lock.sh
source "${LIB_DIR}/common/lock.sh"
# shellcheck source=lib/common/certificate.sh
source "${LIB_DIR}/common/certificate.sh"
# shellcheck source=lib/common/backup.sh
source "${LIB_DIR}/common/backup.sh"
# shellcheck source=lib/common/bbr.sh
source "${LIB_DIR}/common/bbr.sh"

# shellcheck source=lib/xray/engine.sh
source "${LIB_DIR}/xray/engine.sh"
# shellcheck source=lib/singbox/engine.sh
source "${LIB_DIR}/singbox/engine.sh"

# --- dispatcher ------------------------------------------------------------
_main() {
    local cmd="${1:-}"

    case "${cmd}" in
        '')          menu_main ;;
        help|--help|-h)
            echo 'Usage: proxyctl [command]'
            echo ''
            echo 'Commands:'
            echo '  help       Show this help'
            echo '  version    Show version'
            echo '  status     Show engine status'
            echo '  menu       Launch interactive menu'
            echo ''
            echo 'Future commands:'
            echo '  inbound    Manage inbound connections'
            echo '  outbound   Manage outbound connections'
            echo '  tls        Manage TLS certificates'
            echo '  core       Manage proxy cores'
            echo '  system     System utilities'
            ;;
        version|--version|-v)
            echo "proxyctl ${PROXYCTL_VERSION}"
            ;;
        status)
            cmd_status
            ;;
        menu)
            menu_main
            ;;
        internal-init)
            metadata_init || {
                echo "proxyctl: metadata_init failed" >&2
                exit 1
            }
            metadata_validate || {
                echo "proxyctl: metadata_validate failed" >&2
                exit 1
            }
            ;;
        *)
            echo "proxyctl: unknown command '${cmd}'"
            echo 'Run "proxyctl help" for usage.'
            exit 1
            ;;
    esac
}

cmd_status() {
    heading 'ProxyCTL Status'
    echo "Version: ${PROXYCTL_VERSION}"
    echo ''

    info 'Xray'
    if engine_call xray installed; then
        echo "  Installed: yes"
        echo "  Version:   $(engine_call xray version 2>/dev/null || echo 'unknown')"
        if engine_call xray is_active; then
            echo "  Status:    active"
        else
            echo "  Status:    inactive"
        fi
    else
        echo "  Installed: no"
    fi

    echo ''

    info 'sing-box'
    if engine_call singbox installed; then
        echo "  Installed: yes"
        echo "  Version:   $(engine_call singbox version 2>/dev/null || echo 'unknown')"
        if engine_call singbox is_active; then
            echo "  Status:    active"
        else
            echo "  Status:    inactive"
        fi
    else
        echo "  Installed: no"
    fi
}

_main "$@"
