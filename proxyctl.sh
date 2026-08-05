#!/usr/bin/env bash
# ------------------------------------------------------------------------------
# proxyctl — Unified proxy manager for Xray and sing-box
# ------------------------------------------------------------------------------
set -o errexit
set -o nounset
set -o pipefail

readonly PROXYCTL_VERSION='0.2.7'

readonly PROXYCTL_BIN="${PROXYCTL_BIN:-/usr/local/sbin/proxyctl}"
readonly PROXYCTL_LIB="${PROXYCTL_LIB:-/usr/local/lib/proxyctl}"
readonly PROXYCTL_DATA="${PROXYCTL_DATA:-/var/lib/proxyctl}"
readonly PROXYCTL_META="${PROXYCTL_META:-${PROXYCTL_DATA}/meta.json}"
readonly PROXYCTL_CERTS="${PROXYCTL_CERTS:-/etc/proxyctl/certs}"
readonly PROXYCTL_BACKUP="${PROXYCTL_BACKUP:-/var/backups/proxyctl}"
readonly PROXYCTL_LOCK_DIR="${PROXYCTL_LOCK_DIR:-/run/proxyctl}"
readonly PROXYCTL_LOCK="${PROXYCTL_LOCK:-${PROXYCTL_LOCK_DIR}/config.lock}"
readonly PROXYCTL_CERT_LOCK="${PROXYCTL_CERT_LOCK:-${PROXYCTL_LOCK_DIR}/cert.lock}"
readonly PROXYCTL_FIREWALL_LOCK="${PROXYCTL_FIREWALL_LOCK:-${PROXYCTL_LOCK_DIR}/firewall.lock}"
readonly PROXYCTL_CERTBOT_VENV="${PROXYCTL_CERTBOT_VENV:-/opt/proxyctl/certbot}"
readonly PROXYCTL_CERTBOT_CONFIG="${PROXYCTL_CERTBOT_CONFIG:-/var/lib/proxyctl/letsencrypt/config}"
readonly PROXYCTL_CERTBOT_WORK="${PROXYCTL_CERTBOT_WORK:-/var/lib/proxyctl/letsencrypt/work}"
readonly PROXYCTL_CERTBOT_LOGS="${PROXYCTL_CERTBOT_LOGS:-/var/log/proxyctl/certbot}"
readonly PROXYCTL_CLOUDFLARE_INI="${PROXYCTL_CLOUDFLARE_INI:-/etc/proxyctl/cloudflare.ini}"
readonly PROXYCTL_CERT_GROUP="${PROXYCTL_CERT_GROUP:-proxyctl-cert}"
readonly XRAY_CONFIG='/usr/local/etc/xray/config.json'
readonly SINGBOX_CONFIG='/etc/sing-box/config.json'

if [[ -n "${PROXYCTL_DEV_LIB:-}" ]]; then
    readonly LIB_DIR="${PROXYCTL_DEV_LIB}"
elif [[ -d "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib" ]]; then
    readonly LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib"
else
    readonly LIB_DIR="${PROXYCTL_LIB}"
fi

require_runtime_dependencies() {
    if [[ "${BASH_VERSINFO[0]:-0}" -lt 4 ]]; then
        echo "proxyctl: Bash 4.0+ is required (found ${BASH_VERSION:-unknown})" >&2
        exit 1
    fi
}
require_runtime_dependencies

source "${LIB_DIR}/core.sh"
source "${LIB_DIR}/ui.sh"
source "${LIB_DIR}/capability.sh"
source "${LIB_DIR}/metadata.sh"
source "${LIB_DIR}/transaction.sh"
source "${LIB_DIR}/menu.sh"
source "${LIB_DIR}/common/system.sh"
source "${LIB_DIR}/common/service.sh"
source "${LIB_DIR}/common/network.sh"
source "${LIB_DIR}/common/port.sh"
source "${LIB_DIR}/common/lock.sh"
source "${LIB_DIR}/common/certificate.sh"
source "${LIB_DIR}/common/backup.sh"
source "${LIB_DIR}/common/bbr.sh"
source "${LIB_DIR}/xray/engine.sh"
source "${LIB_DIR}/singbox/engine.sh"

cmd_cert() {
    local action="${1:-list}"; shift || true
    case "$action" in
        list) cert_list ;;
        info) [[ -n "${1:-}" ]] || { error 'Usage: proxyctl cert info <identifier>'; return 1; }; cert_info "$1" ;;
        paths) [[ -n "${1:-}" ]] || { error 'Usage: proxyctl cert paths <identifier>'; return 1; }; printf '%s\n%s\n' "$(cert_fullchain "$1")" "$(cert_privkey "$1")" ;;
        issue)
            [[ -n "${1:-}" && -n "${2:-}" ]] || { error 'Usage: proxyctl cert issue <domain|ip> <email> [http|dns-cloudflare|dns-manual] [force=0|1]'; return 1; }
            cert_acme_issue "$1" "$2" "${3:-http}" "${4:-0}" ;;
        self) [[ -n "${1:-}" ]] || { error 'Usage: proxyctl cert self <domain|ip>'; return 1; }; cert_generate_self "$1" ;;
        import)
            [[ -n "${1:-}" && -n "${2:-}" && -n "${3:-}" ]] || { error 'Usage: proxyctl cert import <identifier> <fullchain.pem> <privkey.pem>'; return 1; }
            cert_import "$1" "$2" "$3" ;;
        renew) [[ -n "${1:-}" ]] || { error 'Usage: proxyctl cert renew <identifier>'; return 1; }; cert_renew "$1" ;;
        renew-auto) cert_renew_all ;;
        delete) [[ -n "${1:-}" ]] || { error 'Usage: proxyctl cert delete <identifier>'; return 1; }; cert_delete "$1" ;;
        cloudflare)
            local email api_key
            prompt_value email 'Cloudflare email' || return 1
            prompt_hidden_secret api_key 'Cloudflare Global API Key' || return 1
            cert_save_cloudflare_credentials "$email" "$api_key" ;;
        cloudflare-delete) cert_delete_cloudflare_credentials ;;
        *) error "Unknown certificate command: ${action}"; return 1 ;;
    esac
}

cmd_backup() {
    local action="${1:-list}"; shift || true
    case "$action" in
        create) backup_create "${1:-}" ;;
        list) backup_list ;;
        restore)
            [[ -n "${1:-}" ]] || { error 'Usage: proxyctl backup restore <backup-id>'; return 1; }
            backup_restore "$1" ;;
        *) error "Unknown backup command: ${action}"; return 1 ;;
    esac
}

_main() {
    local cmd="${1:-}"
    case "${cmd}" in
        '') menu_main ;;
        help|--help|-h)
            echo 'Usage: proxyctl [command]'
            echo ''
            echo 'Commands:'
            echo '  help       Show this help'
            echo '  version    Show version'
            echo '  status     Show engine status'
            echo '  menu       Launch interactive menu'
            echo '  cert       Manage shared TLS certificates'
            echo '  backup     Create/list/restore portable backups'
            echo ''
            echo 'Certificate commands:'
            echo '  cert list'
            echo '  cert info <identifier>'
            echo '  cert paths <identifier>'
            echo '  cert issue <domain|ip> <email> [http|dns-cloudflare|dns-manual] [force]'
            echo '  cert self <domain|ip>'
            echo '  cert import <identifier> <fullchain.pem> <privkey.pem>'
            echo '  cert renew <identifier>'
            echo '  cert renew-auto'
            echo '  cert delete <identifier>'
            echo '  cert cloudflare'
            echo ''
            echo 'Backup commands:'
            echo '  backup create [label]'
            echo '  backup list'
            echo '  backup restore <backup-id>'
            ;;
        version|--version|-v) echo "proxyctl ${PROXYCTL_VERSION}" ;;
        status) cmd_status ;;
        menu) menu_main ;;
        cert|tls) shift || true; cmd_cert "$@" ;;
        backup) shift || true; cmd_backup "$@" ;;
        internal-init)
            metadata_init || { echo "proxyctl: metadata_init failed" >&2; exit 1; }
            metadata_validate || { echo "proxyctl: metadata_validate failed" >&2; exit 1; }
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
        if engine_call xray is_active; then echo '  Status:    active'; else echo '  Status:    inactive'; fi
    else
        echo '  Installed: no'
    fi
    echo ''
    info 'sing-box'
    if engine_call singbox installed; then
        echo "  Installed: yes"
        echo "  Version:   $(engine_call singbox version 2>/dev/null || echo 'unknown')"
        if engine_call singbox is_active; then echo '  Status:    active'; else echo '  Status:    inactive'; fi
    else
        echo '  Installed: no'
    fi
}

_main "$@"
