#!/usr/bin/env bash
# ------------------------------------------------------------------------------
# proxyctl — Unified proxy manager for Xray and sing-box
# ------------------------------------------------------------------------------
set -o errexit
set -o nounset
set -o pipefail

readonly PROXYCTL_VERSION='0.3.0'

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
readonly PROXYCTL_SYSTEMD_UNIT_DIR="${PROXYCTL_SYSTEMD_UNIT_DIR:-/etc/systemd/system}"
readonly PROXYCTL_OPENRC_INIT_DIR="${PROXYCTL_OPENRC_INIT_DIR:-/etc/init.d}"
readonly XRAY_CONFIG="${PROXYCTL_XRAY_CONFIG:-/usr/local/etc/xray/config.json}"
readonly SINGBOX_CONFIG="${PROXYCTL_SINGBOX_CONFIG:-/etc/sing-box/config.json}"

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
source "${LIB_DIR}/inbound.sh"
source "${LIB_DIR}/xray/inbound.sh"
source "${LIB_DIR}/singbox/inbound.sh"
source "${LIB_DIR}/singbox/hy2_hop.sh"
source "${LIB_DIR}/menu.sh"

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
        restore) [[ -n "${1:-}" ]] || { error 'Usage: proxyctl backup restore <backup-id>'; return 1; }; backup_restore "$1" ;;
        *) error "Unknown backup command: ${action}"; return 1 ;;
    esac
}

cmd_core() {
    local action="${1:-status}" engine="${2:-}" answer
    [[ "$action" == status ]] || [[ -n "$engine" ]] || { error 'Usage: proxyctl core <action> <xray|singbox> [version|--yes]'; return 1; }
    case "$action" in
        status) cmd_status ;;
        install) engine_call "$engine" install "${3:-}" ;;
        update|upgrade) engine_call "$engine" update "${3:-}" ;;
        uninstall)
            if [[ "${3:-}" != --yes ]]; then confirm answer "Remove ${engine} core but preserve ProxyCTL config/certificates/backups?" n || return 1; [[ "$answer" == y ]] || return 0; fi
            engine_call "$engine" uninstall
            ;;
        start|stop|restart|enable|disable) engine_call "$engine" "$action" ;;
        logs) engine_call "$engine" logs "${3:-100}" ;;
        *) error "Unknown core action: ${action}"; return 1 ;;
    esac
}

cmd_inbound() {
    local action="${1:-list}" engine="${2:-}" answer
    case "$action" in
        list)
            if [[ -n "$engine" ]]; then inbound_list "$engine"; else
                for engine in xray singbox; do
                    echo ''; heading "${engine} inbounds"
                    if engine_call "$engine" installed >/dev/null 2>&1; then inbound_list "$engine"; else info 'Core not installed.'; fi
                done
            fi
            ;;
        add)
            [[ -n "$engine" ]] || { error 'Usage: proxyctl inbound add <xray|singbox> [--json SPEC]'; return 1; }
            if [[ "${3:-}" == --json ]]; then [[ -n "${4:-}" ]] || { error 'Missing JSON spec.'; return 1; }; inbound_add_from_spec "$engine" "$4"; else inbound_add_interactive "$engine"; fi
            ;;
        show) [[ -n "$engine" && -n "${3:-}" ]] || { error 'Usage: proxyctl inbound show <engine> <tag>'; return 1; }; inbound_show "$engine" "$3" ;;
        rename) [[ -n "$engine" && -n "${3:-}" && -n "${4:-}" ]] || { error 'Usage: proxyctl inbound rename <engine> <old> <new>'; return 1; }; inbound_rename "$engine" "$3" "$4" ;;
        delete)
            [[ -n "$engine" && -n "${3:-}" ]] || { error 'Usage: proxyctl inbound delete <engine> <tag> [--yes]'; return 1; }
            if [[ "${4:-}" != --yes ]]; then confirm answer "Delete ${engine}/${3} and all its users?" n || return 1; [[ "$answer" == y ]] || return 0; fi
            inbound_delete "$engine" "$3"
            ;;
        *) error "Unknown inbound action: ${action}"; return 1 ;;
    esac
}

cmd_client() {
    local action="${1:-list}" engine="${2:-}" tag="${3:-}" answer
    [[ -n "$engine" && -n "$tag" ]] || { error 'Usage: proxyctl client <list|add|rotate|delete> <engine> <tag> ...'; return 1; }
    case "$action" in
        list) inbound_clients "$engine" "$tag" ;;
        add) inbound_client_add "$engine" "$tag" "${4:-}" "${5:-}" ;;
        rotate) [[ -n "${4:-}" ]] || { error 'Usage: proxyctl client rotate <engine> <tag> <user> [credential]'; return 1; }; inbound_client_rotate "$engine" "$tag" "$4" "${5:-}" ;;
        delete)
            [[ -n "${4:-}" ]] || { error 'Usage: proxyctl client delete <engine> <tag> <user> [--yes]'; return 1; }
            if [[ "${5:-}" != --yes ]]; then confirm answer "Delete user ${4} from ${engine}/${tag}?" n || return 1; [[ "$answer" == y ]] || return 0; fi
            inbound_client_delete "$engine" "$tag" "$4"
            ;;
        *) error "Unknown client action: ${action}"; return 1 ;;
    esac
}

cmd_config() {
    local action="${1:-check}" engine="${2:-}" config
    [[ -n "$engine" ]] || { error 'Usage: proxyctl config <check|show> <xray|singbox>'; return 1; }
    config=$(engine_call "$engine" config_file) || return 1
    case "$action" in
        check) engine_call "$engine" validate "$config" ;;
        show) cat "$config" ;;
        *) error "Unknown config action: ${action}"; return 1 ;;
    esac
}

show_help() {
    cat <<'EOF'
ProxyCTL — unified Xray / sing-box manager

Usage:
  proxyctl                         Interactive menu
  proxyctl status                  Show both core states
  proxyctl core install <engine> [version]
  proxyctl core update <engine> [version]
  proxyctl core uninstall <engine> [--yes]
  proxyctl core start|stop|restart|enable|disable <engine>
  proxyctl core logs <engine> [lines]

  proxyctl inbound list [engine]
  proxyctl inbound add <engine>
  proxyctl inbound add <engine> --json '<spec>'
  proxyctl inbound show <engine> <tag>
  proxyctl inbound rename <engine> <old> <new>
  proxyctl inbound delete <engine> <tag> [--yes]

  proxyctl client list <engine> <tag>
  proxyctl client add <engine> <tag> [name] [credential]
  proxyctl client rotate <engine> <tag> <name> [credential]
  proxyctl client delete <engine> <tag> <name> [--yes]
  proxyctl link <engine> <tag> [name]

  proxyctl config check|show <engine>
  proxyctl cert ...
  proxyctl backup create|list|restore ...

Engines: xray, singbox
Xray: VLESS, VMess, Trojan, SOCKS5, HTTP
sing-box: AnyTLS, VLESS, Hysteria2, Trojan, SOCKS5, HTTP
EOF
}

_main() {
    local cmd="${1:-}"
    case "$cmd" in
        '') menu_main ;;
        help|--help|-h) show_help ;;
        version|--version|-v) echo "proxyctl ${PROXYCTL_VERSION}" ;;
        status) cmd_status ;;
        menu) menu_main ;;
        core) shift || true; cmd_core "$@" ;;
        inbound) shift || true; cmd_inbound "$@" ;;
        client|user) shift || true; cmd_client "$@" ;;
        link|share) shift || true; [[ -n "${1:-}" && -n "${2:-}" ]] || { error 'Usage: proxyctl link <engine> <tag> [user]'; return 1; }; inbound_share "$1" "$2" "${3:-}" ;;
        config) shift || true; cmd_config "$@" ;;
        cert|tls) shift || true; cmd_cert "$@" ;;
        backup) shift || true; cmd_backup "$@" ;;
        start|stop|restart|enable|disable) shift || true; [[ -n "${1:-}" ]] || { error "Usage: proxyctl ${cmd} <engine>"; return 1; }; engine_call "$1" "$cmd" ;;
        logs) shift || true; [[ -n "${1:-}" ]] || { error 'Usage: proxyctl logs <engine> [lines]'; return 1; }; engine_call "$1" logs "${2:-100}" ;;
        internal-init)
            metadata_init || { echo 'proxyctl: metadata_init failed' >&2; exit 1; }
            metadata_validate || { echo 'proxyctl: metadata_validate failed' >&2; exit 1; }
            ;;
        internal-hy2-hop-restore) singbox_hy2_hop_restore ;;
        internal-hy2-hop-clear) singbox_hy2_hop_clear ;;
        *) echo "proxyctl: unknown command '${cmd}'"; echo 'Run "proxyctl help" for usage.'; exit 1 ;;
    esac
}

cmd_status() {
    local count config
    heading 'ProxyCTL Status'
    echo "Version: ${PROXYCTL_VERSION}"
    for engine in xray singbox; do
        echo ''
        info "$engine"
        if engine_call "$engine" installed; then
            echo '  Installed: yes'
            echo "  Version:   $(engine_call "$engine" version 2>/dev/null || echo unknown)"
            if engine_call "$engine" is_active; then echo '  Status:    active'; else echo '  Status:    inactive'; fi
            config=$(inbound_config_file "$engine" 2>/dev/null || true)
            if [[ -n "$config" && -f "$config" ]]; then count=$(jq '.inbounds|length' "$config" 2>/dev/null || echo '?'); else count='?'; fi
            echo "  Inbounds:  ${count}"
        else
            echo '  Installed: no'
        fi
    done
    echo ''
    echo "Certificates: $(cert_count 2>/dev/null || echo '?')"
}

_main "$@"
