#!/usr/bin/env bash
# ------------------------------------------------------------------------------
# tests/outbounds.sh — Phase 4 outbound lifecycle and managed-route safety
# ------------------------------------------------------------------------------
set -o errexit
set -o nounset
set -o pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
for c in jq openssl; do command -v "$c" >/dev/null 2>&1 || { echo "requires $c" >&2; exit 2; }; done

ROOT=$(mktemp -d)
trap 'rm -rf "$ROOT"' EXIT
export XRAY_CONFIG="$ROOT/xray.json"
export SINGBOX_CONFIG="$ROOT/singbox.json"

source "$PROJECT_DIR/lib/ui.sh"
source "$PROJECT_DIR/lib/core.sh"
source "$PROJECT_DIR/lib/common/network.sh"
source "$PROJECT_DIR/lib/common/port.sh"
source "$PROJECT_DIR/lib/xray/engine.sh"
source "$PROJECT_DIR/lib/singbox/engine.sh"
source "$PROJECT_DIR/lib/inbound.sh"
source "$PROJECT_DIR/lib/outbound.sh"
source "$PROJECT_DIR/lib/xray/outbound.sh"
source "$PROJECT_DIR/lib/singbox/outbound.sh"

cat >"$XRAY_CONFIG" <<'JSON'
{
  "inbounds":[{"tag":"xin","listen":"127.0.0.1","port":41001,"protocol":"socks","settings":{"auth":"noauth","udp":true}}],
  "outbounds":[{"protocol":"freedom","tag":"direct"},{"protocol":"blackhole","tag":"blocked"}],
  "routing":{"domainStrategy":"IPIfNonMatch","rules":[]}
}
JSON
cat >"$SINGBOX_CONFIG" <<'JSON'
{
  "inbounds":[{"type":"socks","tag":"sin","listen":"127.0.0.1","listen_port":42001,"users":[]}],
  "outbounds":[{"type":"direct","tag":"direct"}],
  "route":{"final":"direct","rules":[]}
}
JSON

engine_xray_installed(){ return 0; }
engine_singbox_installed(){ return 0; }
engine_xray_config_file(){ printf '%s\n' "$XRAY_CONFIG"; }
engine_singbox_config_file(){ printf '%s\n' "$SINGBOX_CONFIG"; }
_inbound_with_config_lock(){ "$@"; }
apply_candidate(){
    local engine="$1" candidate="$2" dest
    dest=$(engine_call "$engine" config_file) || return 1
    jq empty "$candidate" >/dev/null 2>&1 || return 1
    cp -- "$candidate" "$dest"
}

PASS=0; FAIL=0
pass(){ echo "  PASS: $*"; ((++PASS)); }
fail(){ echo "  FAIL: $*" >&2; ((++FAIL)); }
ok(){ if "$@"; then pass "$*"; else fail "$*"; fi; }
bad(){ if "$@" >/dev/null 2>&1; then fail "$*"; else pass "$*"; fi; }
eqv(){ [[ "$1" == "$2" ]] && pass "$3" || fail "$3 — expected '$2', got '$1'"; }
contains(){ [[ "$1" == *"$2"* ]] && pass "$3" || fail "$3 — missing '$2'"; }

printf '\nOutbound lifecycle tests\n\n'

xspec=$(jq -cn '{protocol:"SOCKS5",tag:"xproxy",server:"127.0.0.1",port:1080,username:"alice",password:"secret"}')
ok outbound_add_from_spec xray "$xspec"
eqv "$(jq -r '.outbounds[]|select(.tag=="xproxy")|.protocol' "$XRAY_CONFIG")" socks 'Xray SOCKS5 spec uses socks outbound'
eqv "$(jq -r '.outbounds[]|select(.tag=="xproxy")|.settings.user' "$XRAY_CONFIG")" alice 'Xray outbound authentication preserved'
bad outbound_add_from_spec xray "$xspec"

xlocal=$(jq -cn '{protocol:"LOCAL",tag:"xlocal",bind_ip:"192.0.2.10"}')
ok outbound_add_from_spec xray "$xlocal"
eqv "$(jq -r '.outbounds[]|select(.tag=="xlocal")|.sendThrough' "$XRAY_CONFIG")" 192.0.2.10 'Xray local-IP outbound uses sendThrough'

ok outbound_assign xray xin xproxy
eqv "$(jq -r '.routing.rules[]|select(.ruleTag=="proxyctl-outbound:xin")|.outboundTag' "$XRAY_CONFIG")" xproxy 'Xray inbound binding is tagged as ProxyCTL-managed'
ok outbound_assign xray xin direct
eqv "$(jq '[.routing.rules[]?|select(.ruleTag=="proxyctl-outbound:xin")]|length' "$XRAY_CONFIG")" 0 'Assigning Xray direct removes managed binding'
ok outbound_assign xray xin xproxy

# Renaming and deleting an inbound must not leave managed Xray route references.
jq '(.inbounds[]|select(.tag=="xin")|.tag)="xin2"' "$XRAY_CONFIG" >"$ROOT/tmp" && mv "$ROOT/tmp" "$XRAY_CONFIG"
ok engine_xray_inbound_post_change rename xin2 xin
eqv "$(jq -r '.routing.rules[]|select(.ruleTag=="proxyctl-outbound:xin2")|.inboundTag[0]' "$XRAY_CONFIG")" xin2 'Xray managed route follows inbound rename'
jq '.inbounds=[]' "$XRAY_CONFIG" >"$ROOT/tmp" && mv "$ROOT/tmp" "$XRAY_CONFIG"
ok engine_xray_inbound_post_change delete xin2
eqv "$(jq '[.routing.rules[]?|select(.ruleTag=="proxyctl-outbound:xin2")]|length' "$XRAY_CONFIG")" 0 'Xray managed route removed with inbound'

# Custom rules are not ours: deletion must fail without touching config.
jq '.routing.rules += [{type:"field",domain:["example.com"],outboundTag:"xproxy"}]' "$XRAY_CONFIG" >"$ROOT/tmp" && mv "$ROOT/tmp" "$XRAY_CONFIG"
before=$(jq -c . "$XRAY_CONFIG")
bad outbound_delete xray xproxy
eqv "$(jq -c . "$XRAY_CONFIG")" "$before" 'Xray custom routing reference prevents outbound deletion'
jq '.routing.rules=[]' "$XRAY_CONFIG" >"$ROOT/tmp" && mv "$ROOT/tmp" "$XRAY_CONFIG"
ok outbound_delete xray xproxy

sspec=$(jq -cn '{protocol:"HTTP",tag:"sproxy",server:"127.0.0.1",port:3128,username:"",password:""}')
ok outbound_add_from_spec singbox "$sspec"
eqv "$(jq -r '.outbounds[]|select(.tag=="sproxy")|.type' "$SINGBOX_CONFIG")" http 'sing-box HTTP spec uses http outbound'
slocal=$(jq -cn '{protocol:"LOCAL",tag:"slocal",bind_ip:"2001:db8::10"}')
ok outbound_add_from_spec singbox "$slocal"
eqv "$(jq -r '.outbounds[]|select(.tag=="slocal")|.inet6_bind_address' "$SINGBOX_CONFIG")" '2001:db8::10' 'sing-box IPv6 local outbound uses inet6_bind_address'

ok outbound_assign singbox sin sproxy
eqv "$(jq -r '.route.rules[]|select(.action=="route" and .inbound==["sin"] and .outbound=="sproxy")|.outbound' "$SINGBOX_CONFIG")" sproxy 'sing-box inbound binding uses minimal managed route'
ok outbound_assign singbox sin direct
eqv "$(jq '[.route.rules[]?|select(.action=="route" and .inbound==["sin"])]|length' "$SINGBOX_CONFIG")" 0 'Assigning sing-box direct removes managed binding'
ok outbound_assign singbox sin sproxy

jq '(.inbounds[]|select(.tag=="sin")|.tag)="sin2"' "$SINGBOX_CONFIG" >"$ROOT/tmp" && mv "$ROOT/tmp" "$SINGBOX_CONFIG"
ok singbox_outbound_inbound_post_change rename sin2 sin
eqv "$(jq -r '.route.rules[]|select(.action=="route" and .inbound==["sin2"])|.outbound' "$SINGBOX_CONFIG")" sproxy 'sing-box managed route follows inbound rename'
jq '.inbounds=[]' "$SINGBOX_CONFIG" >"$ROOT/tmp" && mv "$ROOT/tmp" "$SINGBOX_CONFIG"
ok singbox_outbound_inbound_post_change delete sin2
eqv "$(jq '[.route.rules[]?|select(.action=="route" and .inbound==["sin2"])]|length' "$SINGBOX_CONFIG")" 0 'sing-box managed route removed with inbound'

jq '.route.rules += [{domain_suffix:["example.com"],action:"route",outbound:"sproxy"}]' "$SINGBOX_CONFIG" >"$ROOT/tmp" && mv "$ROOT/tmp" "$SINGBOX_CONFIG"
before=$(jq -c . "$SINGBOX_CONFIG")
bad outbound_delete singbox sproxy
eqv "$(jq -c . "$SINGBOX_CONFIG")" "$before" 'sing-box custom route reference prevents outbound deletion'
jq '.route.rules=[]' "$SINGBOX_CONFIG" >"$ROOT/tmp" && mv "$ROOT/tmp" "$SINGBOX_CONFIG"
ok outbound_delete singbox sproxy

bad outbound_add_from_spec singbox "$(jq -cn '{protocol:"HTTP",tag:"direct",server:"127.0.0.1",port:3128}')"
bad outbound_delete xray direct

contains "$(outbound_list xray)" xlocal 'Xray outbound listing includes local outbound'
contains "$(outbound_list singbox)" slocal 'sing-box outbound listing includes local outbound'

printf '\nOutbound tests: %d passed, %d failed\n' "$PASS" "$FAIL"
((FAIL == 0))
