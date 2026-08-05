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
    PROXYCTL_NO_TTY_GUARD=1 choose choice '主菜单' alpha beta <<<"2" >/dev/null
    [[ "$choice" == beta ]]
}
if test_choose_propagation; then pass 'choose writes selected value to caller variable'; else fail 'choose writes selected value to caller variable'; fi

# Other UI output helpers must also tolerate common caller variable names.
test_confirm_propagation() {
    local response
    PROXYCTL_NO_TTY_GUARD=1 confirm response '确认？' n <<<"y" >/dev/null
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
