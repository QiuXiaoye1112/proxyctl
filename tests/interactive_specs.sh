#!/usr/bin/env bash
set -o errexit
set -o nounset
set -o pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

source "$PROJECT_DIR/lib/ui.sh"
source "$PROJECT_DIR/lib/xray/inbound.sh"
source "$PROJECT_DIR/lib/singbox/inbound.sh"
source "$PROJECT_DIR/lib/outbound.sh"

PASS=0
FAIL=0
pass(){ printf '  PASS: %s\n' "$*"; PASS=$((PASS+1)); }
fail(){ printf '  FAIL: %s\n' "$*" >&2; FAIL=$((FAIL+1)); }

# Deterministic UI-only fixtures. Builders are not exercised here; the purpose
# is to test the real collectors and their stdout/stderr contract.
inbound_random_hex(){ printf 'abcd'; }
inbound_random_password(){ printf 'password-123456'; }
inbound_generate_uuid(){ printf '11111111-1111-4111-8111-111111111111\n'; }
inbound_validate_tag(){ [[ -n "${1:-}" ]]; }
inbound_validate_path(){ [[ "${1:-}" == /* ]]; }
network_validate_ip(){ [[ -n "${1:-}" ]]; }
network_validate_host(){ [[ -n "${1:-}" ]]; }
network_validate_domain(){ [[ -n "${1:-}" ]]; }
network_public_ipv4(){ printf '203.0.113.10\n'; }
network_public_ipv6(){ return 1; }
port_validate(){ [[ "${1:-}" =~ ^[0-9]+$ ]]; }
outbound_validate_tag(){ [[ -n "${1:-}" ]]; }

run_xray_collector() {
    local root out err
    root=$(mktemp -d); out="$root/out"; err="$root/err"
    PROXYCTL_NO_TTY_GUARD=1 engine_xray_inbound_collect_spec >"$out" 2>"$err" <<< $'1\n\n\n443\n\n3\n1\n\n'
    jq -e '.protocol=="VLESS" and .security=="none" and .transport=="RAW"' "$out" >/dev/null || { rm -rf "$root"; return 1; }
    grep -Fq '选择入站协议' "$err" || { rm -rf "$root"; return 1; }
    grep -Fq '1) VLESS' "$err" || { rm -rf "$root"; return 1; }
    grep -Fq '2) VMess' "$err" || { rm -rf "$root"; return 1; }
    grep -Fq '3) Trojan' "$err" || { rm -rf "$root"; return 1; }
    grep -Fq '4) SOCKS5' "$err" || { rm -rf "$root"; return 1; }
    grep -Fq '5) HTTP' "$err" || { rm -rf "$root"; return 1; }
    grep -Fq '请选择 [1-5]:' "$err" || { rm -rf "$root"; return 1; }
    grep -Fq '选择安全方式' "$err" || { rm -rf "$root"; return 1; }
    grep -Fq '选择传输方式' "$err" || { rm -rf "$root"; return 1; }
    ! grep -Fq '选择入站协议' "$out" || { rm -rf "$root"; return 1; }
    rm -rf "$root"
}

run_singbox_collector() {
    local root out err
    root=$(mktemp -d); out="$root/out"; err="$root/err"
    PROXYCTL_NO_TTY_GUARD=1 engine_singbox_inbound_collect_spec >"$out" 2>"$err" <<< $'5\n\n\n1080\n\n\n'
    jq -e '.protocol=="SOCKS5" and .listen_port==1080' "$out" >/dev/null || { rm -rf "$root"; return 1; }
    grep -Fq '选择入站协议' "$err" || { rm -rf "$root"; return 1; }
    grep -Fq '1) AnyTLS' "$err" || { rm -rf "$root"; return 1; }
    grep -Fq '2) VLESS' "$err" || { rm -rf "$root"; return 1; }
    grep -Fq '3) Hysteria2' "$err" || { rm -rf "$root"; return 1; }
    grep -Fq '4) Trojan' "$err" || { rm -rf "$root"; return 1; }
    grep -Fq '5) SOCKS5' "$err" || { rm -rf "$root"; return 1; }
    grep -Fq '6) HTTP' "$err" || { rm -rf "$root"; return 1; }
    grep -Fq '请选择 [1-6]:' "$err" || { rm -rf "$root"; return 1; }
    ! grep -Fq '选择入站协议' "$out" || { rm -rf "$root"; return 1; }
    rm -rf "$root"
}

run_outbound_collector() {
    local root out err
    root=$(mktemp -d); out="$root/out"; err="$root/err"
    PROXYCTL_NO_TTY_GUARD=1 outbound_collect_spec >"$out" 2>"$err" <<< $'1\n\nproxy.example.com\n1080\n\n'
    jq -e '.protocol=="SOCKS5" and .server=="proxy.example.com" and .port==1080' "$out" >/dev/null || { rm -rf "$root"; return 1; }
    grep -Fq '选择出站协议' "$err" || { rm -rf "$root"; return 1; }
    grep -Fq '1) SOCKS5' "$err" || { rm -rf "$root"; return 1; }
    grep -Fq '2) HTTP' "$err" || { rm -rf "$root"; return 1; }
    grep -Fq '3) 本机指定出口 IP' "$err" || { rm -rf "$root"; return 1; }
    grep -Fq '请选择 [1-3]:' "$err" || { rm -rf "$root"; return 1; }
    grep -Fq '出站标签' "$err" || { rm -rf "$root"; return 1; }
    grep -Fq '代理服务器地址' "$err" || { rm -rf "$root"; return 1; }
    ! grep -Fq '选择出站协议' "$out" || { rm -rf "$root"; return 1; }
    rm -rf "$root"
}

printf '\nProxyCTL interactive collector tests\n\n'
run_xray_collector && pass 'Xray collector shows complete numbered choices and returns clean JSON' || fail 'Xray collector UI/data separation'
run_singbox_collector && pass 'sing-box collector shows complete numbered choices and returns clean JSON' || fail 'sing-box collector UI/data separation'
run_outbound_collector && pass 'outbound collector shows what 1-3 mean and returns clean JSON' || fail 'outbound collector UI/data separation'

printf '\nInteractive collector tests: %d passed, %d failed\n' "$PASS" "$FAIL"
((FAIL == 0))
