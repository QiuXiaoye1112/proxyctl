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
export PROXYCTL_BIN="$ROOT/usr/local/sbin/proxyctl"
export PROXYCTL_LIB="$ROOT/usr/local/lib/proxyctl"
export PROXYCTL_DATA="$ROOT/var/lib/proxyctl"
export PROXYCTL_META="$PROXYCTL_DATA/meta.json"
export PROXYCTL_CERTS="$ROOT/etc/proxyctl/certs"
export PROXYCTL_BACKUP="$ROOT/var/backups/proxyctl"
export PROXYCTL_CERTBOT_VENV="$ROOT/opt/proxyctl/certbot"
export PROXYCTL_CERTBOT_CONFIG="$ROOT/var/lib/proxyctl/letsencrypt/config"
export PROXYCTL_CERTBOT_WORK="$ROOT/var/lib/proxyctl/letsencrypt/work"
export PROXYCTL_CERTBOT_LOGS="$ROOT/var/log/proxyctl/certbot"
export PROXYCTL_CLOUDFLARE_INI="$ROOT/etc/proxyctl/cloudflare.ini"
export PROXYCTL_SYSTEMD_UNIT_DIR="$ROOT/etc/systemd/system"
export PROXYCTL_OPENRC_INIT_DIR="$ROOT/etc/init.d"
export XRAY_CONFIG="$ROOT/usr/local/etc/xray/config.json"
export SINGBOX_CONFIG="$ROOT/etc/sing-box/config.json"

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
contains_file(){ grep -Fq -- "$2" "$1" && pass "$3" || fail "$3"; }

seed_manager() {
    mkdir -p "$(dirname "$PROXYCTL_BIN")" "$PROXYCTL_LIB" "$(dirname "$ROOT/usr/local/bin/proxyctl")"
    printf '#!/bin/sh\n' >"$PROXYCTL_BIN"; chmod 755 "$PROXYCTL_BIN"
    printf 'library\n' >"$PROXYCTL_LIB/marker"
    ln -sfn "$PROXYCTL_BIN" "$ROOT/usr/local/bin/proxyctl"
}
seed_state() {
    mkdir -p "$PROXYCTL_DATA" "$PROXYCTL_CERTS/example" "$PROXYCTL_BACKUP" \
        "$PROXYCTL_CERTBOT_VENV" "$PROXYCTL_CERTBOT_CONFIG" "$PROXYCTL_CERTBOT_WORK" "$PROXYCTL_CERTBOT_LOGS" \
        "$(dirname "$XRAY_CONFIG")" "$(dirname "$SINGBOX_CONFIG")" "$(dirname "$PROXYCTL_CLOUDFLARE_INI")"
    printf '{"version":1,"inbounds":{},"certificates":{},"firewall":{}}\n' >"$PROXYCTL_META"
    printf '{}\n' >"$XRAY_CONFIG"; printf '{}\n' >"$SINGBOX_CONFIG"
    printf 'cert\n' >"$PROXYCTL_CERTS/example/fullchain.pem"
    printf 'backup\n' >"$PROXYCTL_BACKUP/keep"
    printf 'venv\n' >"$PROXYCTL_CERTBOT_VENV/marker"
    printf 'config\n' >"$PROXYCTL_CERTBOT_CONFIG/marker"
    printf 'work\n' >"$PROXYCTL_CERTBOT_WORK/marker"
    printf 'logs\n' >"$PROXYCTL_CERTBOT_LOGS/marker"
    printf 'dns_cloudflare_api_token = secret\n' >"$PROXYCTL_CLOUDFLARE_INI"
}
seed_units() {
    mkdir -p "$PROXYCTL_SYSTEMD_UNIT_DIR"
    cat >"$PROXYCTL_SYSTEMD_UNIT_DIR/proxyctl-certbot-renew.service" <<EOF
# managed by ProxyCTL
[Service]
ExecStart=${PROXYCTL_BIN} cert renew-auto
EOF
    cat >"$PROXYCTL_SYSTEMD_UNIT_DIR/proxyctl-certbot-renew.timer" <<'EOF'
# managed by ProxyCTL
[Timer]
OnCalendar=daily
EOF
    cat >"$PROXYCTL_SYSTEMD_UNIT_DIR/proxyctl-hy2-hop.service" <<'EOF'
[Unit]
Description=ProxyCTL Hysteria2 port hopping redirects
EOF
}
seed_cert_dropins() {
    local group
    group=$(cert_runtime_group)
    mkdir -p "$PROXYCTL_SYSTEMD_UNIT_DIR/xray.service.d" "$PROXYCTL_SYSTEMD_UNIT_DIR/sing-box.service.d"
    printf '[Service]\nSupplementaryGroups=%s\n' "$group" >"$PROXYCTL_SYSTEMD_UNIT_DIR/xray.service.d/20-proxyctl-certificates.conf"
    printf '[Service]\nSupplementaryGroups=%s\n' "$group" >"$PROXYCTL_SYSTEMD_UNIT_DIR/sing-box.service.d/20-proxyctl-certificates.conf"
}

printf '\nProxyCTL uninstall tests\n\n'

seed_manager; seed_state; seed_units
singbox_hy2_hop_count(){ printf '%s\n' 0; }
ok _uninstall_manager_only 0
absent "$PROXYCTL_BIN" 'manager-only uninstall removes binary'
absent "$PROXYCTL_LIB" 'manager-only uninstall removes library'
absent "$ROOT/usr/local/bin/proxyctl" 'manager-only uninstall removes owned symlink'
absent "$PROXYCTL_SYSTEMD_UNIT_DIR/proxyctl-certbot-renew.service" 'manager-only uninstall removes renewal service that depends on manager'
absent "$PROXYCTL_SYSTEMD_UNIT_DIR/proxyctl-hy2-hop.service" 'manager-only uninstall removes HY2 boot helper'
present "$PROXYCTL_META" 'manager-only uninstall preserves metadata'
present "$XRAY_CONFIG" 'manager-only uninstall preserves Xray config'
present "$SINGBOX_CONFIG" 'manager-only uninstall preserves sing-box config'
present "$PROXYCTL_CERTS/example/fullchain.pem" 'manager-only uninstall preserves certificates'
present "$PROXYCTL_BACKUP/keep" 'manager-only uninstall preserves backups'

# HY2 hopping must prevent an accidental manager-only removal.
seed_manager; seed_units
singbox_hy2_hop_count(){ printf '%s\n' 1; }
bad _uninstall_manager_only 0
present "$PROXYCTL_BIN" 'HY2 dependency leaves manager installed when --force is absent'
ok _uninstall_manager_only 1
absent "$PROXYCTL_BIN" 'forced manager uninstall is allowed with HY2 warning path'

# Purge is deliberately impossible without both flags.
bad proxyctl_uninstall --purge
bad proxyctl_uninstall --purge --force
bad proxyctl_uninstall --unknown

# Ownership guards: an unrelated /usr/local/bin/proxyctl symlink is preserved.
seed_manager
rm -f "$ROOT/usr/local/bin/proxyctl"
ln -s /some/other/program "$ROOT/usr/local/bin/proxyctl"
singbox_hy2_hop_count(){ printf '%s\n' 0; }
ok _uninstall_manager_only 0
present "$ROOT/usr/local/bin/proxyctl" 'unrelated proxyctl symlink is not deleted'
rm -f "$ROOT/usr/local/bin/proxyctl"

# Full purge stays entirely inside ROOT and removes both core state trees.
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
absent "$(dirname "$XRAY_CONFIG")" 'purge removes Xray config root'
absent "$(dirname "$SINGBOX_CONFIG")" 'purge removes sing-box config root'
absent "$PROXYCTL_CERTS" 'purge removes managed certificates'
absent "$PROXYCTL_DATA" 'purge removes metadata/data tree'
absent "$PROXYCTL_BACKUP" 'purge removes backup tree'
absent "$PROXYCTL_CERTBOT_VENV" 'purge removes Certbot virtualenv'
absent "$PROXYCTL_CERTBOT_CONFIG" 'purge removes Certbot lineage/config state'
absent "$PROXYCTL_CERTBOT_WORK" 'purge removes Certbot work state'
absent "$PROXYCTL_CERTBOT_LOGS" 'purge removes Certbot logs'
absent "$PROXYCTL_CLOUDFLARE_INI" 'purge removes Cloudflare credentials'
absent "$PROXYCTL_SYSTEMD_UNIT_DIR/xray.service.d/20-proxyctl-certificates.conf" 'purge recognizes legacy unmarked Xray certificate drop-in'
absent "$PROXYCTL_SYSTEMD_UNIT_DIR/sing-box.service.d/20-proxyctl-certificates.conf" 'purge recognizes legacy unmarked sing-box certificate drop-in'
absent "$PROXYCTL_BIN" 'purge removes manager binary'
absent "$PROXYCTL_LIB" 'purge removes manager library'
absent "$ROOT/usr/local/bin/proxyctl" 'purge removes owned manager symlink'

printf '\nUninstall tests: %d passed, %d failed\n' "$PASS" "$FAIL"
((FAIL == 0))
