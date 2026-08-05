#!/usr/bin/env bash
# ------------------------------------------------------------------------------
# tests/reconcile.sh — adopt existing xrayctl/sbctl-managed configs safely
# ------------------------------------------------------------------------------
set -o errexit
set -o nounset
set -o pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
command -v jq >/dev/null 2>&1 || { echo 'requires jq' >&2; exit 2; }

ROOT=$(mktemp -d)
trap 'rm -rf "$ROOT"' EXIT
export PROXYCTL_DATA="$ROOT/data"
export PROXYCTL_META="$PROXYCTL_DATA/meta.json"
export XRAY_CONFIG="$ROOT/xray/config.json"
export SINGBOX_CONFIG="$ROOT/singbox/config.json"
export PROXYCTL_LEGACY_XRAY_META="$ROOT/xray/xrayctl.meta.json"
export PROXYCTL_LEGACY_SBCTL_META="$ROOT/sbctl/meta.json"
mkdir -p "$(dirname "$XRAY_CONFIG")" "$(dirname "$SINGBOX_CONFIG")" "$(dirname "$PROXYCTL_LEGACY_SBCTL_META")" "$ROOT/bin"
export PATH="$ROOT/bin:$PATH"

cat >"$ROOT/bin/xray" <<'SH'
#!/usr/bin/env bash
if [[ "${1:-}" == x25519 && "${2:-}" == -i && -n "${3:-}" ]]; then
  echo 'Private key: hidden'
  echo 'Public key: derived-public-key'
  exit 0
fi
exit 1
SH
chmod +x "$ROOT/bin/xray"

source "$PROJECT_DIR/lib/ui.sh"
source "$PROJECT_DIR/lib/core.sh"
source "$PROJECT_DIR/lib/metadata.sh"
source "$PROJECT_DIR/lib/common/network.sh"
source "$PROJECT_DIR/lib/common/port.sh"
source "$PROJECT_DIR/lib/xray/engine.sh"
source "$PROJECT_DIR/lib/singbox/engine.sh"
source "$PROJECT_DIR/lib/inbound.sh"
source "$PROJECT_DIR/lib/reconcile.sh"
_inbound_with_config_lock(){ "$@"; }

cat >"$XRAY_CONFIG" <<'JSON'
{
  "inbounds":[
    {"tag":"xr","listen":"0.0.0.0","port":443,"protocol":"vless","settings":{"clients":[],"decryption":"none"},"streamSettings":{"method":"raw","security":"reality","realitySettings":{"privateKey":"legacy-private","serverNames":["www.microsoft.com"]}}},
    {"tag":"xsocks","listen":"127.0.0.1","port":1080,"protocol":"socks","settings":{"auth":"noauth"}}
  ],
  "outbounds":[{"protocol":"freedom","tag":"direct"}]
}
JSON
cat >"$PROXYCTL_LEGACY_XRAY_META" <<'JSON'
{"inbounds":{"xr":{"host":"node.example"},"xsocks":{"host":"127.0.0.1"}}}
JSON

cat >"$SINGBOX_CONFIG" <<'JSON'
{
  "inbounds":[
    {"type":"vless","tag":"sr","listen":"0.0.0.0","listen_port":8443,"users":[],"tls":{"enabled":true,"server_name":"www.microsoft.com","reality":{"enabled":true,"private_key":"private","short_id":["a1"]}}},
    {"type":"hysteria2","tag":"hy","listen":"0.0.0.0","listen_port":9443,"users":[],"tls":{"enabled":true,"server_name":"hy.example","certificate_path":"/tmp/c","key_path":"/tmp/k"}}
  ],
  "outbounds":[{"type":"direct","tag":"direct"}],"route":{"final":"direct"}
}
JSON
cat >"$PROXYCTL_LEGACY_SBCTL_META" <<'JSON'
{
  "inbounds":{
    "sr":{"host":"sb.example","realityPublicKey":"legacy-sb-public"},
    "hy":{"host":"hy.example","hysteria2PortHopping":{"enabled":true,"range":"20000-30000"}}
  }
}
JSON

metadata_init >/dev/null
# Existing ProxyCTL metadata wins over legacy data and is never downgraded.
inbound_meta_set xray xsocks current.example '' '' >/dev/null

PASS=0; FAIL=0
pass(){ echo "  PASS: $*"; ((++PASS)); }
fail(){ echo "  FAIL: $*" >&2; ((++FAIL)); }
ok(){ if "$@"; then pass "$*"; else fail "$*"; fi; }
eqv(){ [[ "$1" == "$2" ]] && pass "$3" || fail "$3 — expected '$2', got '$1'"; }

printf '\nReconcile tests\n\n'
ok reconcile_engine xray
eqv "$(inbound_meta_get xray xr clientHost)" node.example 'xrayctl host is imported'
eqv "$(inbound_meta_get xray xr realityPublicKey)" derived-public-key 'Xray REALITY public key is derived from existing private key'
eqv "$(inbound_meta_get xray xsocks clientHost)" current.example 'existing ProxyCTL metadata is preserved over legacy value'

ok reconcile_engine singbox
eqv "$(inbound_meta_get singbox sr clientHost)" sb.example 'sbctl host is imported'
eqv "$(inbound_meta_get singbox sr realityPublicKey)" legacy-sb-public 'sbctl REALITY public key is imported'
eqv "$(inbound_meta_get singbox hy hy2HopRange)" 20000-30000 'sbctl HY2 hopping range is imported'

# Unsafe legacy metadata is ignored; current ProxyCTL metadata remains usable.
mv "$PROXYCTL_LEGACY_SBCTL_META" "$ROOT/sbctl/real-meta.json"
ln -s "$ROOT/sbctl/real-meta.json" "$PROXYCTL_LEGACY_SBCTL_META"
ok reconcile_engine singbox
eqv "$(inbound_meta_get singbox sr realityPublicKey)" legacy-sb-public 'symlink legacy metadata is ignored without erasing current metadata'

printf '\nReconcile tests: %d passed, %d failed\n' "$PASS" "$FAIL"
((FAIL == 0))
