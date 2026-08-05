#!/usr/bin/env bash
# ------------------------------------------------------------------------------
# tests/ui.sh — terminal UI output-variable regression tests
# ------------------------------------------------------------------------------
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

# Regression: choose() used to declare a local variable named `choice`, so
# `printf -v choice` wrote into the callee instead of the caller under Bash's
# dynamic scoping. menu_main then crashed under set -u with "choice: unbound".
test_choose_propagation() {
    local choice
    PROXYCTL_NO_TTY_GUARD=1 choose choice '主菜单' alpha beta <<<"2" >/dev/null 2>/dev/null
    [[ "$choice" == beta ]]
}
if test_choose_propagation; then pass 'choose writes selected value to caller variable'; else fail 'choose writes selected value to caller variable'; fi

# collect_spec helpers run inside command substitutions and process
# substitutions. Human-facing menu text must therefore stay off stdout or it
# corrupts the JSON / tab-separated data channel.
test_choose_stream_separation() {
    local choice='' root out err
    root=$(mktemp -d)
    out="$root/stdout"
    err="$root/stderr"
    PROXYCTL_NO_TTY_GUARD=1 choose choice 'Select outbound type:' SOCKS5 HTTP 'Local IP' <<<"1" >"$out" 2>"$err"
    [[ "$choice" == SOCKS5 ]] || { rm -rf "$root"; return 1; }
    [[ ! -s "$out" ]] || { rm -rf "$root"; return 1; }
    grep -Fq '选择要添加的出站类型：' "$err" || { rm -rf "$root"; return 1; }
    grep -Fq '1) SOCKS5' "$err" || { rm -rf "$root"; return 1; }
    grep -Fq '2) HTTP' "$err" || { rm -rf "$root"; return 1; }
    grep -Fq '3) 本机指定出口 IP' "$err" || { rm -rf "$root"; return 1; }
    grep -Fq '请选择 [1-3]：' "$err" || { rm -rf "$root"; return 1; }
    rm -rf "$root"
}
if test_choose_stream_separation; then pass 'choose keeps menu text on stderr and stdout clean'; else fail 'choose keeps menu text on stderr and stdout clean'; fi

# read -p only guarantees prompt rendering for terminal input. ProxyCTL now
# renders the prompt itself so returning from installers/uninstallers cannot
# leave a menu visibly waiting for input with no "请选择" prompt.
test_choose_prompt_visible_without_tty_read_p() {
    local choice='' err
    err=$(mktemp)
    PROXYCTL_NO_TTY_GUARD=1 choose choice '核心管理' A B <<<"2" >/dev/null 2>"$err"
    grep -Fq '请选择 [1-2]：' "$err" && [[ "$choice" == B ]]
    local rc=$?
    rm -f "$err"
    return "$rc"
}
if test_choose_prompt_visible_without_tty_read_p; then pass 'choose renders selection prompt explicitly'; else fail 'choose renders selection prompt explicitly'; fi

# Other UI output helpers must also tolerate common caller variable names.
test_confirm_propagation() {
    local response
    PROXYCTL_NO_TTY_GUARD=1 confirm response '确认？' n <<<"y" >/dev/null 2>/dev/null
    [[ "$response" == y ]]
}
if test_confirm_propagation; then pass 'confirm writes result to caller variable'; else fail 'confirm writes result to caller variable'; fi

test_prompt_value_propagation() {
    local value
    prompt_value value '测试值' 'default-value' </dev/null >/dev/null
    [[ "$value" == default-value ]]
}
if test_prompt_value_propagation; then pass 'prompt_value writes default to caller variable'; else fail 'prompt_value writes default to caller variable'; fi

test_prompt_optional_propagation() {
    local value
    prompt_optional value '可选值' 'optional-default' </dev/null >/dev/null
    [[ "$value" == optional-default ]]
}
if test_prompt_optional_propagation; then pass 'prompt_optional writes default to caller variable'; else fail 'prompt_optional writes default to caller variable'; fi

printf '\nUI tests: %d passed, %d failed\n' "$PASS" "$FAIL"
((FAIL == 0))
