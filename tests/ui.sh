#!/usr/bin/env bash
set -o errexit
set -o nounset
set -o pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
source "$PROJECT_DIR/lib/ui.sh"

PASS=0
FAIL=0
pass(){ echo "  PASS: $*"; ((++PASS)); }
fail(){ echo "  FAIL: $*" >&2; ((++FAIL)); }

printf '\nProxyCTL UI tests\n\n'

test_choose_propagation() {
    local choice
    PROXYCTL_NO_TTY_GUARD=1 choose choice '测试选择' alpha beta <<<"2" >/dev/null 2>/dev/null
    [[ "$choice" == beta ]]
}
test_choose_propagation && pass 'choose writes selected value to caller variable' || fail 'choose propagation'

test_choose_stream_separation() {
    local choice='' root out err
    root=$(mktemp -d); out="$root/stdout"; err="$root/stderr"
    PROXYCTL_NO_TTY_GUARD=1 choose choice 'Select outbound type:' SOCKS5 HTTP 'Local IP' <<<"1" >"$out" 2>"$err"
    [[ "$choice" == SOCKS5 ]] || { rm -rf "$root"; return 1; }
    [[ ! -s "$out" ]] || { rm -rf "$root"; return 1; }
    grep -Fq '选择出站协议' "$err" || { rm -rf "$root"; return 1; }
    grep -Fq '1) SOCKS5' "$err" || { rm -rf "$root"; return 1; }
    grep -Fq '2) HTTP' "$err" || { rm -rf "$root"; return 1; }
    grep -Fq '3) 本机指定出口 IP' "$err" || { rm -rf "$root"; return 1; }
    grep -Fq '请选择 [1-3]:' "$err" || { rm -rf "$root"; return 1; }
    rm -rf "$root"
}
test_choose_stream_separation && pass 'choose shows xrayctl-style menu on stderr and keeps stdout clean' || fail 'choose stream separation'

test_choose_prompt_visible() {
    local choice='' err
    err=$(mktemp)
    PROXYCTL_NO_TTY_GUARD=1 choose choice '选择核心' xray singbox <<<"2" >/dev/null 2>"$err"
    grep -Fq '请选择 [1-2]:' "$err" && [[ "$choice" == singbox ]]
    local rc=$?
    rm -f "$err"
    return "$rc"
}
test_choose_prompt_visible && pass 'choose renders selection prompt explicitly' || fail 'choose visible prompt'

test_confirm_propagation() {
    local response
    PROXYCTL_NO_TTY_GUARD=1 confirm response '确认？' n <<<"y" >/dev/null 2>/dev/null
    [[ "$response" == y ]]
}
test_confirm_propagation && pass 'confirm writes result to caller variable' || fail 'confirm propagation'

test_prompt_value_propagation() {
    local value
    prompt_value value '测试值' 'default-value' </dev/null >/dev/null 2>/dev/null
    [[ "$value" == default-value ]]
}
test_prompt_value_propagation && pass 'prompt_value keeps non-TTY default behavior' || fail 'prompt_value propagation'

test_prompt_optional_propagation() {
    local value
    prompt_optional value '可选值' 'optional-default' </dev/null >/dev/null 2>/dev/null
    [[ "$value" == optional-default ]]
}
test_prompt_optional_propagation && pass 'prompt_optional keeps non-TTY default behavior' || fail 'prompt_optional propagation'

printf '\nUI tests: %d passed, %d failed\n' "$PASS" "$FAIL"
((FAIL == 0))
