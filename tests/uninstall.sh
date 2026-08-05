#!/usr/bin/env bash
# ------------------------------------------------------------------------------
# tests/uninstall.sh — self-uninstall safety without touching host paths
# ------------------------------------------------------------------------------
set -o errexit
set -o nounset
set -o pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
command -v jq >/dev/null 2>&1 || { echo 'requires jq' >&2; exit 2; }

ROOT=$(mktemp -d)
trap 'rm -rf "$ROOT"' EXIT
export PROXYCTL_UNINSTALL_ROOT="$ROOT"
# Keep product paths canonical. The uninstall root performs all sandbox mapping,
# exactly like install.sh's alternate-root model.
export PROXYCTL_BIN='/usr/local/sbin/proxyctl'
export PROXYCTL_LIB='/usr/local/lib/proxyctl'
export PROXYCTL_DATA='/var/lib/proxyctl'
export PROXYCTL_META='/var/lib/proxyctl/meta.json'
export PROXYCTL_CERTS='/etc/proxyctl/certs'
export PROXYCTL_BACKUP='/var/backups/proxyctl'
export PROXYCTL_CERTBOT_VENV='/opt/proxyctl/certbot'
export PROXYCTL_CERTBOT_CONFIG='/var/lib/proxyctl/letsencrypt/config'
export PROXYCTL_CERTBOT_WORK='/var/lib/proxyctl/letsencrypt/work'
export PROXYCTL_CERTBOT_LOGS='/var/log/proxyctl/certbot'
export PROXYCTL_CLOUDFLARE_INI='/etc/proxyctl/cloudflare.ini'
export PROXYCTL_SYSTEMD_UNIT_DIR='/etc/systemd/system'
export PROXYCTL_OPENRC_INIT_DIR='/etc/init.d'
export XRAY_CONFIG='/usr/local/etc/xray/config.json'
export SINGBOX_CONFIG='/etc/sing-box/config.json'

rootp(){ printf '%s%s\n' "$ROOT" "$1"; }
BIN=$(rootp "$PROXYCTL_BIN")
LIB=$(rootp "$PROXYCTL_LIB")
DATA=$(rootp "$PROXYCTL_DATA")
META=$(rootp "$PROXYCTL_META")
CERTS=$(rootp "$PROXYCTL_CERTS")
BACKUP=$(rootp "$PROXYCTL_BACKUP")
CB_VENV=$(rootp "$PROXYCTL_CERTBOT_VENV")
CB_CONFIG=$(rootp "$PROXYCTL_CERTBOT_CONFIG")
CB_WORK=$(rootp "$PROXYCTL_CERTBOT_WORK")
CB_LOGS=$(rootp "$PROXYCTL_CERTBOT_LOGS")
CF_INI=$(rootp "$PROXYCTL_CLOUDFLARE_INI")
UNIT_DIR=$(rootp "$PROXYCTL_SYSTEMD_UNIT_DIR")
XRAY_CONFIG_REAL=$(rootp "$XRAY_CONFIG")
SINGBOX_CONFIG_REAL=$(rootp "$SINGBOX_CONFIG")
LINK=$(rootp '/usr/local/bin/proxyctl')

source "$PROJECT_DIR/lib/ui.sh"
source "$PROJECT_DIR/lib/core.sh"
source "$PROJECT_DIR/lib/metadata.sh"
source "$PROJECT_DIR/lib/common/system.sh"
source "$PROJECT_DIR/lib/common/service.sh"
source "$PROJECT_DIR/lib/xray/engine.sh"
source "$PROJECT_DIR/lib/singbox/engine.sh"
source "$PROJECT_DIR/lib/common/certificate.sh"
source "$PROJECT_DIR/lib/uninstall.sh"

system_is_root(){ return 0; }
system_init(){ printf '%s\n' systemd; }
systemctl(){ return 0; }
rc-update(){ return 0; }
cert_runtime_group(){ printf '%s\n' test-proxyctl-cert; }
metadata_cert_list(){ :; }

PASS=0; FAIL=0
pass(){ echo "  PASS: $*"; ((++PASS)); }
fail(){ echo "  FAIL: $*" >&2; ((++FAIL)); }
ok(){ if "$@"; then pass "$*"; else fail "$*"; fi; }
bad(){ if "$@" >/dev/null 2>&1; then fail "$*"; else pass "$*"; fi; }
present(){ [[ -e "$1" || -L "$1" ]] && pass "$2" || fail "$2"; }
absent(){ [[ ! -e "$1" && ! -L "$1" ]] && pass "$2" || fail "$2"; }

seed_manager() {
    mkdir -p "$(dirname "$BIN")" "$LIB" "$(dirname "$LINK")"
    printf '#!/bin/sh\n' >"$BIN"; chmod 755 "$BIN"
    printf 'library\n' >"$LIB/marker"
    # Installed symlink uses the canonical target, not the sandbox-prefixed one.
    ln -sfn "$PROXYCTL_BIN" "$LINK"
}
seed_state() {
    mkdir -p "$DATA" "$CERTS/example" "$BACKUP" "$CB_VENV" "$CB_CONFIG" "$CB_WORK" "$CB_LOGS" \
        "$(dirname "$XRAY_CONFIG_REAL")" "$(dirname "$SINGBOX_CONFIG_REAL")" "$(dirname "$CF_INI")"
    printf '{"version":1,"inbounds":{},"certificates":{},"firewall":{}}\n' >"$META"
    printf '{}\n' >"$XRAY_CONFIG_REAL"; printf '{}\n' >"$SINGBOX_CONFIG_REAL"
    printf 'cert\n' >"$CERTS/example/fullchain.pem"
    printf 'backup\n' >"$BACKUP/keep"
    printf 'venv\n' >"$CB_VENV/marker"
    printf 'config\n' >"$CB_CONFIG/marker"
    printf 'work\n' >"$CB_WORK/marker"
    printf 'logs\n' >"$CB_LOGS/marker"
    printf 'dns_cloudflare_api_token = secret\n' >"$CF_INI"
}
seed_units() {
    mkdir -p "$UNIT_DIR"
    cat >"$UNIT_DIR/proxyctl-certbot-renew.service" <<EOF
# managed by ProxyCTL
[Service]
ExecStart=${PROXYCTL_BIN} cert renew-auto
EOF
    cat >"$UNIT_DIR/proxyctl-certbot-renew.timer" <<'EOF'
# managed by ProxyCTL
[Timer]
OnCalendar=daily
EOF
    cat >"$UNIT_DIR/proxyctl-hy2-hop.service" <<'EOF'
[Unit]
Description=ProxyCTL Hysteria2 port hopping redirects
EOF
}
seed_cert_dropins() {
    local group
    group=$(cert_runtime_group)
    mkdir -p "$UNIT_DIR/xray.service.d" "$UNIT_DIR/sing-box.service.d"
    printf '[Service]\nSupplementaryGroups=%s\n' "$group" >"$UNIT_DIR/xray.service.d/20-proxyctl-certificates.conf"
    printf '[Service]\nSupplementaryGroups=%s\n' "$group" >"$UNIT_DIR/sing-box.service.d/20-proxyctl-certificates.conf"
}

printf '\nProxyCTL uninstall tests\n\n'

seed_manager; seed_state; seed_units
singbox_hy2_hop_count(){ printf '%s\n' 0; }
ok _uninstall_manager_only 0
absent "$BIN" 'manager-only uninstall removes binary'
absent "$LIB" 'manager-only uninstall removes library'
absent "$LINK" 'manager-only uninstall removes owned symlink'
absent "$UNIT_DIR/proxyctl-certbot-renew.service" 'manager-only uninstall removes renewal service that depends on manager'
absent "$UNIT_DIR/proxyctl-hy2-hop.service" 'manager-only uninstall removes HY2 boot helper'
present "$META" 'manager-only uninstall preserves metadata'
present "$XRAY_CONFIG_REAL" 'manager-only uninstall preserves Xray config'
present "$SINGBOX_CONFIG_REAL" 'manager-only uninstall preserves sing-box config'
present "$CERTS/example/fullchain.pem" 'manager-only uninstall preserves certificates'
present "$BACKUP/keep" 'manager-only uninstall preserves backups'

seed_manager; seed_units
singbox_hy2_hop_count(){ printf '%s\n' 1; }
bad _uninstall_manager_only 0
present "$BIN" 'HY2 dependency leaves manager installed when --force is absent'
ok _uninstall_manager_only 1
absent "$BIN" 'forced manager uninstall is allowed with HY2 warning path'

bad proxyctl_uninstall --purge
bad proxyctl_uninstall --purge --force
bad proxyctl_uninstall --unknown

seed_manager
rm -f "$LINK"
ln -s /some/other/program "$LINK"
singbox_hy2_hop_count(){ printf '%s\n' 0; }
ok _uninstall_manager_only 0
present "$LINK" 'unrelated proxyctl symlink is not deleted'
rm -f "$LINK"

seed_manager; seed_state; seed_units; seed_cert_dropins
XRAY_REMOVED="$ROOT/xray-removed"; SINGBOX_REMOVED="$ROOT/singbox-removed"
engine_xray_installed(){ return 0; }
engine_singbox_installed(){ return 0; }
engine_xray_uninstall(){ printf 'yes\n' >"$XRAY_REMOVED"; return 0; }
engine_singbox_uninstall(){ printf 'yes\n' >"$SINGBOX_REMOVED"; return 0; }
singbox_hy2_hop_count(){ printf '%s\n' 0; }
ok proxyctl_uninstall --purge --yes
present "$XRAY_REMOVED" 'purge invokes Xray core uninstall'
present "$SINGBOX_REMOVED" 'purge invokes sing-box core uninstall'
absent "$(dirname "$XRAY_CONFIG_REAL")" 'purge removes Xray config root'
absent "$(dirname "$SINGBOX_CONFIG_REAL")" 'purge removes sing-box config root'
absent "$CERTS" 'purge removes managed certificates'
absent "$DATA" 'purge removes metadata/data tree'
absent "$BACKUP" 'purge removes backup tree'
absent "$CB_VENV" 'purge removes Certbot virtualenv'
absent "$CB_CONFIG" 'purge removes Certbot lineage/config state'
absent "$CB_WORK" 'purge removes Certbot work state'
absent "$CB_LOGS" 'purge removes Certbot logs'
absent "$CF_INI" 'purge removes Cloudflare credentials'
absent "$UNIT_DIR/xray.service.d/20-proxyctl-certificates.conf" 'purge recognizes legacy unmarked Xray certificate drop-in'
absent "$UNIT_DIR/sing-box.service.d/20-proxyctl-certificates.conf" 'purge recognizes legacy unmarked sing-box certificate drop-in'
absent "$BIN" 'purge removes manager binary'
absent "$LIB" 'purge removes manager library'
absent "$LINK" 'purge removes owned manager symlink'

printf '\nUninstall tests: %d passed, %d failed\n' "$PASS" "$FAIL"
((FAIL == 0))
