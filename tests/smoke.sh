#!/usr/bin/env bash
# ------------------------------------------------------------------------------
# tests/smoke.sh — fast cross-module contract smoke test
# Deep behavior lives in the dedicated per-module suites.
# ------------------------------------------------------------------------------
set -o errexit
set -o nounset
set -o pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

PASS=0; FAIL=0
pass(){ echo "  PASS: $*"; ((++PASS)); }
fail(){ echo "  FAIL: $*" >&2; ((++FAIL)); }
eqv(){ [[ "$1" == "$2" ]] && pass "$3" || fail "$3 — expected '$2', got '$1'"; }
contains(){ [[ "$1" == *"$2"* ]] && pass "$3" || fail "$3 — missing '$2'"; }
ok(){ if eval "$1"; then pass "$2"; else fail "$2"; fi; }
bad(){ if eval "$1" >/dev/null 2>&1; then fail "$2"; else pass "$2"; fi; }
perm(){ local got; got=$(stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1" 2>/dev/null); eqv "$got" "$2" "$3"; }

ROOT=$(mktemp -d)
trap 'rm -rf "$ROOT"' EXIT
export PROXYCTL_DEV_LIB="$PROJECT_DIR/lib"
export PROXYCTL_DATA="$ROOT/data"
export PROXYCTL_META="$PROXYCTL_DATA/meta.json"
export PROXYCTL_CERTS="$ROOT/certs"
export PROXYCTL_BACKUP="$ROOT/backups"
export PROXYCTL_LOCK_DIR="$ROOT/locks"
export PROXYCTL_LOCK="$PROXYCTL_LOCK_DIR/config.lock"
export PROXYCTL_CERT_LOCK="$PROXYCTL_LOCK_DIR/cert.lock"
export PROXYCTL_FIREWALL_LOCK="$PROXYCTL_LOCK_DIR/firewall.lock"
export PROXYCTL_XRAY_CONFIG="$ROOT/xray/config.json"
export PROXYCTL_SINGBOX_CONFIG="$ROOT/singbox/config.json"

load_all(){
    source "$PROJECT_DIR/lib/core.sh"
    source "$PROJECT_DIR/lib/ui.sh"
    source "$PROJECT_DIR/lib/capability.sh"
    source "$PROJECT_DIR/lib/metadata.sh"
    source "$PROJECT_DIR/lib/transaction.sh"
    source "$PROJECT_DIR/lib/common/system.sh"
    source "$PROJECT_DIR/lib/common/service.sh"
    source "$PROJECT_DIR/lib/common/network.sh"
    source "$PROJECT_DIR/lib/common/port.sh"
    source "$PROJECT_DIR/lib/common/lock.sh"
    source "$PROJECT_DIR/lib/common/certificate.sh"
    source "$PROJECT_DIR/lib/common/backup.sh"
    source "$PROJECT_DIR/lib/common/bbr.sh"
    source "$PROJECT_DIR/lib/xray/engine.sh"
    source "$PROJECT_DIR/lib/singbox/engine.sh"
    source "$PROJECT_DIR/lib/inbound.sh"
    source "$PROJECT_DIR/lib/inbound_edit.sh"
    source "$PROJECT_DIR/lib/xray/inbound.sh"
    source "$PROJECT_DIR/lib/singbox/inbound.sh"
    source "$PROJECT_DIR/lib/singbox/clients.sh"
    source "$PROJECT_DIR/lib/client_rename.sh"
    source "$PROJECT_DIR/lib/outbound.sh"
    source "$PROJECT_DIR/lib/xray/outbound.sh"
    source "$PROJECT_DIR/lib/singbox/outbound.sh"
    source "$PROJECT_DIR/lib/singbox/hy2_hop.sh"
    source "$PROJECT_DIR/lib/runtime.sh"
    source "$PROJECT_DIR/lib/reconcile.sh"
    source "$PROJECT_DIR/lib/uninstall.sh"
    source "$PROJECT_DIR/lib/menu.sh"
}
load_all

printf '\nProxyCTL smoke tests\n\n'

# 1. Syntax across every shell artifact.
syntax_fail=0
while IFS= read -r -d '' file; do bash -n "$file" || syntax_fail=1; done < <(find "$PROJECT_DIR" -name '*.sh' -print0)
((syntax_fail==0)) && pass 'all shell files pass bash -n' || fail 'all shell files pass bash -n'

# 2. Source layout entrypoint.
out=$(bash "$PROJECT_DIR/proxyctl.sh" version 2>&1)
eqv "$out" 'proxyctl 0.3.0' 'source-layout version is 0.3.0'
out=$(bash "$PROJECT_DIR/proxyctl.sh" help 2>&1)
contains "$out" 'proxyctl inbound add' 'help exposes inbound management'
contains "$out" 'proxyctl outbound add' 'help exposes outbound management'
contains "$out" 'proxyctl outbound assign' 'help exposes inbound-to-outbound assignment'
contains "$out" 'proxyctl client add' 'help exposes user management'
contains "$out" 'proxyctl core install' 'help exposes core lifecycle'
contains "$out" 'proxyctl reconcile' 'help exposes existing-config reconciliation'
contains "$out" 'proxyctl backup' 'help exposes backup management'
contains "$out" 'proxyctl uninstall' 'help exposes manager uninstall'

# 3. Installed-layout simulation.
INST="$ROOT/installed"
mkdir -p "$INST/usr/local/sbin" "$INST/usr/local/lib/proxyctl"
cp "$PROJECT_DIR/proxyctl.sh" "$INST/usr/local/sbin/proxyctl"
cp -r "$PROJECT_DIR/lib/"* "$INST/usr/local/lib/proxyctl/"
out=$(PROXYCTL_LIB="$INST/usr/local/lib/proxyctl" bash "$INST/usr/local/sbin/proxyctl" version 2>&1)
eqv "$out" 'proxyctl 0.3.0' 'installed-layout entrypoint loads every current module'

# 4. Engine registration contract.
ok 'engine_validate_registration xray' 'Xray engine implements standard API'
ok 'engine_validate_registration singbox' 'sing-box engine implements standard API'
eqv "$(engine_list | tr '\n' ' ')" 'singbox xray ' 'engine registry is deterministic'

# 5. Protocol capability contract.
contains "$(engine_protocols xray)" VLESS 'Xray VLESS capability'
contains "$(engine_protocols xray)" SOCKS5 'Xray SOCKS5 capability'
contains "$(engine_protocols singbox)" AnyTLS 'sing-box AnyTLS capability'
contains "$(engine_protocols singbox)" Hysteria2 'sing-box Hysteria2 capability'
eqv "$(protocol_transports xray VLESS | tr '\n' ' ')" 'RAW XHTTP WebSocket ' 'Xray VLESS transport scope'
eqv "$(protocol_transports singbox VLESS | tr '\n' ' ')" 'RAW WebSocket ' 'sing-box VLESS transport scope'
eqv "$(protocol_transports singbox Hysteria2)" '' 'Hysteria2 uses dedicated transport flow'
bad 'protocol_transports xray NoSuchProtocol' 'unknown protocol is rejected'

# 6. Metadata initialization and key safety.
metadata_init >/dev/null
[[ -f "$PROXYCTL_META" ]] && pass 'metadata_init creates meta.json' || fail 'metadata_init creates meta.json'
perm "$PROXYCTL_META" 600 'metadata is mode 600'
ok 'metadata_validate' 'fresh metadata validates'
bad "metadata_get '../../x'" 'metadata path traversal is rejected'
bad "metadata_set_json '../../x' '{}'" 'metadata write traversal is rejected'

# 7. Transaction ID/path guards.
tx=$(transaction_begin smoke)
[[ "$tx" =~ ^tx_[0-9]+_[0-9]+_smoke$ ]] && pass 'transaction id format' || fail 'transaction id format'
ok "transaction_commit '$tx'" 'transaction commit accepts owned transaction'
bad "transaction_commit '../../etc'" 'transaction commit rejects traversal id'

# 8. Network/port validation.
ok 'network_validate_ipv4 127.0.0.1' 'IPv4 validator accepts loopback'
bad 'network_validate_ipv4 999.1.1.1' 'IPv4 validator rejects bad octet'
ok 'network_validate_ip 2001:db8::1' 'IP validator accepts IPv6'
ok 'port_validate 443' 'port validator accepts 443'
bad 'port_validate 0' 'port validator rejects zero'

# 9. Lock mapping.
eqv "$(lock_path config)" "$PROXYCTL_LOCK" 'config lock mapping'
eqv "$(lock_path cert)" "$PROXYCTL_CERT_LOCK" 'cert lock mapping'
eqv "$(lock_path firewall)" "$PROXYCTL_FIREWALL_LOCK" 'firewall lock mapping'
bad 'lock_path nope' 'unknown lock is rejected'

# 10. Certificate lightweight contract.
ok 'cert_validate_identifier example.com' 'certificate identifier accepts domain'
bad 'cert_validate_identifier ../escape' 'certificate identifier rejects traversal'
eqv "$(cert_fullchain example.com)" "$PROXYCTL_CERTS/example.com/fullchain.pem" 'certificate fullchain path'
eqv "$(cert_privkey example.com)" "$PROXYCTL_CERTS/example.com/privkey.pem" 'certificate private-key path'

# 11. Backup lightweight contract.
eqv "$(backup_root)" "$PROXYCTL_BACKUP" 'backup root mapping'
ok '_backup_validate_label nightly' 'backup label accepts safe value'
bad '_backup_validate_label ../bad' 'backup label rejects traversal'
ok '_backup_validate_id proxyctl-20260805-120000-123-nightly.tar.gz' 'backup id accepts generated format'
bad '_backup_validate_id ../../bad.tar.gz' 'backup id rejects traversal'

# 12. Inbound/outbound/helper contract.
ok 'inbound_validate_tag node-1' 'inbound tag accepts safe value'
bad 'inbound_validate_tag ../node' 'inbound tag rejects traversal'
eqv "$(_xray_spec_protocol SOCKS5)" socks 'Xray SOCKS5 maps to core socks protocol'
ok '_singbox_validate_hop_range 20000-50000' 'HY2 hop range accepts valid range'
bad '_singbox_validate_hop_range 50000-20000' 'HY2 hop range rejects reversed range'
ok 'outbound_validate_tag proxy-1' 'outbound tag accepts safe value'
bad 'outbound_validate_tag direct' 'reserved outbound tag is rejected'
eqv "$(_xray_outbound_protocol SOCKS5)" socks 'Xray outbound SOCKS5 maps to socks'
eqv "$(_singbox_outbound_type HTTP)" http 'sing-box outbound HTTP maps to http'
eqv "$(reconcile_legacy_xray_meta)" '/usr/local/etc/xray/xrayctl.meta.json' 'xrayctl legacy metadata path mapping'
eqv "$(reconcile_legacy_singbox_meta)" '/var/lib/sbctl/meta.json' 'sbctl legacy metadata path mapping'

# 13. Random credential primitives.
hex=$(inbound_random_hex 8)
[[ "$hex" =~ ^[0-9a-f]{16}$ ]] && pass 'random hex has requested size' || fail 'random hex has requested size'
uuid=$(inbound_generate_uuid)
[[ "$uuid" =~ ^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$ ]] && pass 'UUID generator returns canonical UUID' || fail 'UUID generator returns canonical UUID'

# 14. Fail-closed entrypoints without cores/files.
bad "bash '$PROJECT_DIR/proxyctl.sh' config check xray" 'Xray config check fails closed when core/config unavailable'
bad "bash '$PROJECT_DIR/proxyctl.sh' inbound show xray missing" 'missing inbound show fails closed'
bad "bash '$PROJECT_DIR/proxyctl.sh' outbound show xray missing" 'missing outbound show fails closed'
bad "bash '$PROJECT_DIR/proxyctl.sh' client list singbox missing" 'missing user list fails closed'
bad "bash '$PROJECT_DIR/proxyctl.sh' reconcile nope" 'invalid reconcile engine is rejected'
bad "bash '$PROJECT_DIR/proxyctl.sh' uninstall --purge" 'destructive purge requires explicit --yes'
bad "bash '$PROJECT_DIR/proxyctl.sh' something-invalid" 'unknown CLI command returns non-zero'

printf '\nSmoke tests: %d passed, %d failed\n' "$PASS" "$FAIL"
((FAIL == 0))
