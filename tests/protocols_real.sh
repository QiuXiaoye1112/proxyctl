#!/usr/bin/env bash
# ------------------------------------------------------------------------------
# tests/protocols_real.sh — validate protocol and outbound builders with cores
# ------------------------------------------------------------------------------
set -o errexit
set -o nounset
set -o pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

for c in jq openssl xray sing-box; do
    command -v "$c" >/dev/null 2>&1 || { echo "requires ${c}" >&2; exit 2; }
done

source "$PROJECT_DIR/lib/ui.sh"
source "$PROJECT_DIR/lib/core.sh"
source "$PROJECT_DIR/lib/common/network.sh"
source "$PROJECT_DIR/lib/common/port.sh"
source "$PROJECT_DIR/lib/xray/engine.sh"
source "$PROJECT_DIR/lib/singbox/engine.sh"
source "$PROJECT_DIR/lib/inbound.sh"
source "$PROJECT_DIR/lib/xray/inbound.sh"
source "$PROJECT_DIR/lib/singbox/inbound.sh"
source "$PROJECT_DIR/lib/outbound.sh"
source "$PROJECT_DIR/lib/xray/outbound.sh"
source "$PROJECT_DIR/lib/singbox/outbound.sh"

ROOT=$(mktemp -d)
trap 'rm -rf "$ROOT"' EXIT
CERT="$ROOT/fullchain.pem"
KEY="$ROOT/privkey.pem"
openssl req -x509 -newkey rsa:2048 -nodes -days 2 \
    -subj '/CN=test.example' -addext 'subjectAltName=DNS:test.example' \
    -keyout "$KEY" -out "$CERT" >/dev/null 2>&1

cert_exists() { [[ "$1" == test.example ]]; }
cert_fullchain() { printf '%s\n' "$CERT"; }
cert_privkey() { printf '%s\n' "$KEY"; }

PASS=0
FAIL=0
pass() { echo "  PASS: $*"; ((++PASS)); }
fail() { echo "  FAIL: $*" >&2; ((++FAIL)); }

validate_xray() {
    local name="$1" spec="$2" inbound config="$ROOT/xray-${1}.json" output
    if ! inbound=$(engine_xray_inbound_build_from_spec "$spec" 2>"$ROOT/error"); then
        fail "Xray builder: ${name} — $(cat "$ROOT/error")"
        return 0
    fi
    jq -n --argjson inbound "$inbound" '{log:{loglevel:"warning"},inbounds:[$inbound],outbounds:[{protocol:"freedom",tag:"direct"}]}' >"$config"
    if output=$(xray run -test -config "$config" 2>&1); then
        pass "Xray core accepts ${name}"
    else
        fail "Xray core rejects ${name}: ${output}"
    fi
}

validate_singbox() {
    local name="$1" spec="$2" inbound config="$ROOT/singbox-${1}.json" output
    if ! inbound=$(engine_singbox_inbound_build_from_spec "$spec" 2>"$ROOT/error"); then
        fail "sing-box builder: ${name} — $(cat "$ROOT/error")"
        return 0
    fi
    jq -n --argjson inbound "$inbound" '{log:{level:"warn",timestamp:true},inbounds:[$inbound],outbounds:[{type:"direct",tag:"direct"}],route:{final:"direct"}}' >"$config"
    if output=$(sing-box check -c "$config" 2>&1); then
        pass "sing-box core accepts ${name}"
    else
        fail "sing-box core rejects ${name}: ${output}"
    fi
}

validate_xray_outbound() {
    local name="$1" spec="$2" outbound config="$ROOT/xray-out-${name}.json" output
    if ! outbound=$(engine_xray_outbound_build_from_spec "$spec" 2>"$ROOT/error"); then
        fail "Xray outbound builder: ${name} — $(cat "$ROOT/error")"
        return 0
    fi
    jq -n --argjson outbound "$outbound" '{log:{loglevel:"warning"},inbounds:[],outbounds:[{protocol:"freedom",tag:"direct"},$outbound],routing:{rules:[]}}' >"$config"
    if output=$(xray run -test -config "$config" 2>&1); then
        pass "Xray core accepts outbound ${name}"
    else
        fail "Xray core rejects outbound ${name}: ${output}"
    fi
}

validate_singbox_outbound() {
    local name="$1" spec="$2" outbound config="$ROOT/singbox-out-${name}.json" output
    if ! outbound=$(engine_singbox_outbound_build_from_spec "$spec" 2>"$ROOT/error"); then
        fail "sing-box outbound builder: ${name} — $(cat "$ROOT/error")"
        return 0
    fi
    jq -n --argjson outbound "$outbound" '{log:{level:"warn",timestamp:true},inbounds:[],outbounds:[{type:"direct",tag:"direct"},$outbound],route:{final:"direct",rules:[]}}' >"$config"
    if output=$(sing-box check -c "$config" 2>&1); then
        pass "sing-box core accepts outbound ${name}"
    else
        fail "sing-box core rejects outbound ${name}: ${output}"
    fi
}

UUID='11111111-1111-4111-8111-111111111111'
IFS=$'\t' read -r XRAY_PRIVATE XRAY_PUBLIC < <(_xray_generate_reality)
IFS=$'\t' read -r SB_PRIVATE SB_PUBLIC < <(_singbox_generate_reality)

xray_spec() {
    jq -cn \
      --arg protocol "$1" --arg tag "$2" --argjson port "$3" --arg transport "$4" --arg security "$5" \
      --arg path "${6:-}" --arg uuid "$UUID" --arg xpriv "$XRAY_PRIVATE" --arg xpub "$XRAY_PUBLIC" '
      {protocol:$protocol,tag:$tag,listen:"127.0.0.1",port:$port,client_host:"test.example",transport:$transport,security:$security,path:$path,
       tls:{cert_id:"test.example",server_name:"test.example"},
       reality:{target:"www.microsoft.com:443",server_name:"www.microsoft.com",private_key:$xpriv,public_key:$xpub,short_id:"a1b2c3d4"},
       user:{name:"user1",username:"user1",password:"test-password",uuid:$uuid}}'
}

singbox_spec() {
    jq -cn \
      --arg protocol "$1" --arg tag "$2" --argjson port "$3" --arg transport "$4" --arg security "$5" \
      --arg path "${6:-}" --arg uuid "$UUID" --arg spriv "$SB_PRIVATE" --arg spub "$SB_PUBLIC" '
      {protocol:$protocol,tag:$tag,listen:"127.0.0.1",listen_port:$port,client_host:"test.example",transport:$transport,security:$security,path:$path,
       tls:{cert_id:"test.example",server_name:"test.example"},
       reality:{target:"www.microsoft.com",target_port:"443",server_name:"www.microsoft.com",private_key:$spriv,public_key:$spub,short_id:"a1b2c3d4"},
       user:{name:"user1",username:"user1",password:"test-password",uuid:$uuid},
       hysteria2:{hop_range:"",up_mbps:"100",down_mbps:"100",obfs_password:"test-obfs"}}'
}

printf '\nReal Xray protocol validation\n'
validate_xray 'vless-raw-reality' "$(xray_spec VLESS x-vless-raw 21001 RAW reality)"
validate_xray 'vless-xhttp-tls' "$(xray_spec VLESS x-vless-xhttp 21002 XHTTP tls /xhttp)"
validate_xray 'vless-ws-tls' "$(xray_spec VLESS x-vless-ws 21003 WebSocket tls /ws)"
validate_xray 'vmess-raw' "$(xray_spec VMess x-vmess-raw 21004 RAW none)"
validate_xray 'vmess-ws-tls' "$(xray_spec VMess x-vmess-ws 21005 WebSocket tls /vmess)"
validate_xray 'trojan-raw-reality' "$(xray_spec Trojan x-trojan-raw 21006 RAW reality)"
validate_xray 'trojan-ws-tls' "$(xray_spec Trojan x-trojan-ws 21007 WebSocket tls /trojan)"
validate_xray 'socks5' "$(xray_spec SOCKS5 x-socks 21008 '' none)"
validate_xray 'http' "$(xray_spec HTTP x-http 21009 '' none)"

printf '\nReal sing-box protocol validation\n'
validate_singbox 'anytls-reality' "$(singbox_spec AnyTLS s-anytls 22001 '' reality)"
validate_singbox 'vless-raw-reality' "$(singbox_spec VLESS s-vless-raw 22002 RAW reality)"
validate_singbox 'vless-ws-tls' "$(singbox_spec VLESS s-vless-ws 22003 WebSocket tls /vless)"
validate_singbox 'hysteria2-tls' "$(singbox_spec Hysteria2 s-hy2 22004 '' tls)"
validate_singbox 'trojan-raw-reality' "$(singbox_spec Trojan s-trojan-raw 22005 RAW reality)"
validate_singbox 'trojan-ws-tls' "$(singbox_spec Trojan s-trojan-ws 22006 WebSocket tls /trojan)"
validate_singbox 'socks5' "$(singbox_spec SOCKS5 s-socks 22007 '' '')"
validate_singbox 'http' "$(singbox_spec HTTP s-http 22008 '' '')"

printf '\nReal Xray outbound validation\n'
validate_xray_outbound socks5 "$(jq -cn '{protocol:"SOCKS5",tag:"proxy",server:"127.0.0.1",port:1080,username:"user",password:"pass"}')"
validate_xray_outbound http "$(jq -cn '{protocol:"HTTP",tag:"proxy",server:"127.0.0.1",port:3128,username:"",password:""}')"
validate_xray_outbound local "$(jq -cn '{protocol:"LOCAL",tag:"local-test",bind_ip:"127.0.0.1"}')"

printf '\nReal sing-box outbound validation\n'
validate_singbox_outbound socks5 "$(jq -cn '{protocol:"SOCKS5",tag:"proxy",server:"127.0.0.1",port:1080,username:"user",password:"pass"}')"
validate_singbox_outbound http "$(jq -cn '{protocol:"HTTP",tag:"proxy",server:"127.0.0.1",port:3128,username:"",password:""}')"
validate_singbox_outbound local "$(jq -cn '{protocol:"LOCAL",tag:"local-test",bind_ip:"127.0.0.1"}')"

printf '\nReal-core tests: %d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
