#!/usr/bin/env bash
# ------------------------------------------------------------------------------
# tests/inbounds.sh — Phase 3 inbound/user lifecycle with mocked core boundary
# ------------------------------------------------------------------------------
set -o errexit
set -o nounset
set -o pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
for c in jq openssl; do command -v "$c" >/dev/null 2>&1 || { echo "requires $c" >&2; exit 2; }; done

ROOT=$(mktemp -d)
trap 'rm -rf "$ROOT"' EXIT
export PROXYCTL_DATA="$ROOT/data"
export PROXYCTL_META="$PROXYCTL_DATA/meta.json"
export PROXYCTL_CERTS="$ROOT/certs"
export XRAY_CONFIG="$ROOT/xray/config.json"
export SINGBOX_CONFIG="$ROOT/singbox/config.json"
mkdir -p "$PROXYCTL_DATA" "$(dirname "$XRAY_CONFIG")" "$(dirname "$SINGBOX_CONFIG")" "$PROXYCTL_CERTS/test.example"

source "$PROJECT_DIR/lib/ui.sh"
source "$PROJECT_DIR/lib/core.sh"
source "$PROJECT_DIR/lib/metadata.sh"
source "$PROJECT_DIR/lib/common/network.sh"
source "$PROJECT_DIR/lib/common/port.sh"
source "$PROJECT_DIR/lib/xray/engine.sh"
source "$PROJECT_DIR/lib/singbox/engine.sh"
source "$PROJECT_DIR/lib/inbound.sh"
source "$PROJECT_DIR/lib/xray/inbound.sh"
source "$PROJECT_DIR/lib/singbox/inbound.sh"

cat >"$XRAY_CONFIG" <<'JSON'
{"log":{"loglevel":"warning"},"inbounds":[],"outbounds":[{"protocol":"freedom","tag":"direct"}],"routing":{"rules":[]}}
JSON
cat >"$SINGBOX_CONFIG" <<'JSON'
{"log":{"level":"warn"},"inbounds":[],"outbounds":[{"type":"direct","tag":"direct"}],"route":{"final":"direct"}}
JSON
metadata_init >/dev/null

engine_xray_installed(){ return 0; }
engine_singbox_installed(){ return 0; }
engine_xray_config_file(){ printf '%s\n' "$XRAY_CONFIG"; }
engine_singbox_config_file(){ printf '%s\n' "$SINGBOX_CONFIG"; }
engine_singbox_inbound_post_change(){ return 0; }
cert_exists(){ [[ "$1" == test.example ]]; }
cert_fullchain(){ printf '%s\n' "$PROXYCTL_CERTS/test.example/fullchain.pem"; }
cert_privkey(){ printf '%s\n' "$PROXYCTL_CERTS/test.example/privkey.pem"; }
apply_candidate(){
    local engine="$1" candidate="$2" dest
    dest=$(engine_call "$engine" config_file) || return 1
    jq empty "$candidate" >/dev/null 2>&1 || return 1
    cp "$candidate" "$dest"
}

PASS=0; FAIL=0
pass(){ echo "  PASS: $*"; ((++PASS)); }
fail(){ echo "  FAIL: $*" >&2; ((++FAIL)); }
ok(){ if "$@"; then pass "$*"; else fail "$*"; fi; }
bad(){ if "$@" >/dev/null 2>&1; then fail "$*"; else pass "$*"; fi; }
eqv(){ [[ "$1" == "$2" ]] && pass "$3" || fail "$3 — expected '$2', got '$1'"; }
contains(){ [[ "$1" == *"$2"* ]] && pass "$3" || fail "$3 — missing '$2'"; }

UUID1='11111111-1111-4111-8111-111111111111'
UUID2='22222222-2222-4222-8222-222222222222'
UUID3='33333333-3333-4333-8333-333333333333'

xspec=$(jq -cn --arg uuid "$UUID1" '{protocol:"VLESS",tag:"x-main",listen:"127.0.0.1",port:31001,client_host:"node.example",transport:"RAW",security:"reality",reality:{target:"www.microsoft.com:443",server_name:"www.microsoft.com",private_key:"private-key",public_key:"public-key",short_id:"a1b2c3d4"},user:{name:"alice",uuid:$uuid}}')
ok inbound_add_from_spec xray "$xspec"
eqv "$(jq -r '.inbounds[0].protocol' "$XRAY_CONFIG")" vless 'Xray spec becomes Xray VLESS config'
eqv "$(jq -r '.inbounds.xray["x-main"].clientHost' "$PROXYCTL_META")" node.example 'Xray client host stored as auxiliary metadata'
eqv "$(jq -r '.inbounds.xray["x-main"].realityPublicKey' "$PROXYCTL_META")" public-key 'Xray REALITY public key stored in metadata'
bad inbound_add_from_spec xray "$xspec"

xconflict=$(jq -cn --arg uuid "$UUID2" '{protocol:"VMess",tag:"x-conflict",listen:"127.0.0.1",port:31001,client_host:"node.example",transport:"RAW",security:"none",user:{name:"bob",uuid:$uuid}}')
bad inbound_add_from_spec xray "$xconflict"

ok inbound_rename xray x-main x-renamed
eqv "$(jq -r '.inbounds[0].tag' "$XRAY_CONFIG")" x-renamed 'Xray config rename applied'
eqv "$(jq -r '.inbounds.xray["x-renamed"].clientHost' "$PROXYCTL_META")" node.example 'Xray metadata follows rename'

ok inbound_client_add xray x-renamed bob "$UUID2"
eqv "$(jq '.inbounds[0].settings.clients|length' "$XRAY_CONFIG")" 2 'Xray user add changes real config'
bad inbound_client_add xray x-renamed bob "$UUID3"
ok inbound_client_rotate xray x-renamed bob "$UUID3"
eqv "$(jq -r '.inbounds[0].settings.clients[]|select(.email=="bob")|.id' "$XRAY_CONFIG")" "$UUID3" 'Xray user credential rotates'
bad inbound_client_rotate xray x-renamed missing "$UUID2"
ok inbound_client_delete xray x-renamed bob
eqv "$(jq '.inbounds[0].settings.clients|length' "$XRAY_CONFIG")" 1 'Xray user delete changes real config'
bad inbound_client_delete xray x-renamed missing
xlink=$(inbound_share xray x-renamed alice)
contains "$xlink" 'vless://' 'Xray share emits VLESS URI'
contains "$xlink" 'pbk=public-key' 'Xray REALITY share uses metadata public key'

# Xray SOCKS5 display name must map to the core protocol name `socks`.
xsocks=$(jq -cn '{protocol:"SOCKS5",tag:"x-socks",listen:"127.0.0.1",port:31002,client_host:"127.0.0.1",security:"none",user:{username:"",password:""}}')
ok inbound_add_from_spec xray "$xsocks"
eqv "$(jq -r '.inbounds[]|select(.tag=="x-socks")|.protocol' "$XRAY_CONFIG")" socks 'SOCKS5 capability maps to Xray socks protocol'
contains "$(inbound_share xray x-socks)" 'socks5://127.0.0.1:31002' 'Unauthenticated Xray SOCKS share is exported'

sspec=$(jq -cn --arg uuid "$UUID1" '{protocol:"VLESS",tag:"s-main",listen:"127.0.0.1",listen_port:32001,client_host:"sb.example",transport:"WebSocket",security:"tls",path:"/ws",tls:{cert_id:"test.example",server_name:"test.example"},user:{name:"alice",uuid:$uuid}}')
ok inbound_add_from_spec singbox "$sspec"
eqv "$(jq -r '.inbounds[0].type' "$SINGBOX_CONFIG")" vless 'sing-box spec becomes VLESS config'
eqv "$(jq -r '.inbounds.singbox["s-main"].clientHost' "$PROXYCTL_META")" sb.example 'sing-box metadata is isolated from Xray metadata'
eqv "$(jq -r '.inbounds.xray["x-renamed"].clientHost' "$PROXYCTL_META")" node.example 'sing-box metadata update does not overwrite Xray metadata'

ok inbound_client_add singbox s-main bob "$UUID2"
eqv "$(jq '.inbounds[0].users|length' "$SINGBOX_CONFIG")" 2 'sing-box user add changes real config'
ok inbound_client_rotate singbox s-main bob "$UUID3"
eqv "$(jq -r '.inbounds[0].users[]|select(.name=="bob")|.uuid' "$SINGBOX_CONFIG")" "$UUID3" 'sing-box user credential rotates'
ok inbound_client_delete singbox s-main bob
eqv "$(jq '.inbounds[0].users|length' "$SINGBOX_CONFIG")" 1 'sing-box user delete changes real config'
contains "$(inbound_share singbox s-main alice)" 'vless://' 'sing-box VLESS share is exported'

hy2=$(jq -cn '{protocol:"Hysteria2",tag:"s-hy2",listen:"127.0.0.1",listen_port:32002,client_host:"hy.example",security:"tls",tls:{cert_id:"test.example",server_name:"test.example"},user:{name:"hy",password:"hy-password"},hysteria2:{hop_range:"20000-20100",up_mbps:"",down_mbps:"",obfs_password:""}}')
ok inbound_add_from_spec singbox "$hy2"
eqv "$(jq -r '.inbounds.singbox["s-hy2"].hy2HopRange' "$PROXYCTL_META")" '20000-20100' 'Hysteria2 hop range is auxiliary metadata'
contains "$(inbound_share singbox s-hy2 hy)" ':20000-20100?' 'Hysteria2 share exports hop range'

ok inbound_delete singbox s-hy2
eqv "$(jq -r '.inbounds.singbox["s-hy2"] // "missing"' "$PROXYCTL_META")" missing 'sing-box delete cleans inbound metadata'
ok inbound_delete xray x-socks
ok inbound_delete xray x-renamed
eqv "$(jq '.inbounds|length' "$XRAY_CONFIG")" 0 'Xray inbounds can be fully removed'

printf '\nInbound tests: %d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
