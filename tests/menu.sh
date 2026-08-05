#!/usr/bin/env bash
# ------------------------------------------------------------------------------
# tests/menu.sh — interactive menu state/selection regression tests
#
# These tests intentionally run with nounset enabled. They exercise the same
# output-variable names used by the real menus (choice, engine, tag) so Bash
# dynamic-scope shadowing becomes an immediate test failure.
# ------------------------------------------------------------------------------
set -o errexit
set -o nounset
set -o pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

PASS=0
FAIL=0
pass(){ printf '  PASS: %s\n' "$*"; PASS=$((PASS + 1)); }
fail(){ printf '  FAIL: %s\n' "$*" >&2; FAIL=$((FAIL + 1)); }
check(){ if "$@"; then pass "$TEST_NAME"; else fail "$TEST_NAME"; fi; }

ROOT=$(mktemp -d)
trap 'rm -rf "$ROOT"' EXIT
export PROXYCTL_NO_TTY_GUARD=1
LOG="$ROOT/actions.log"
XCFG="$ROOT/xray.json"
SCFG="$ROOT/singbox.json"

cat >"$XCFG" <<'JSON'
{"inbounds":[{"tag":"xray-a"},{"tag":"xray-b"}],"outbounds":[]}
JSON
cat >"$SCFG" <<'JSON'
{"inbounds":[{"tag":"sb-a"},{"tag":"sb-b"}],"outbounds":[]}
JSON

source "$PROJECT_DIR/lib/ui.sh"
source "$PROJECT_DIR/lib/menu.sh"

# --- dependency stubs -------------------------------------------------------
engine_exists(){ [[ "$1" == xray || "$1" == singbox ]]; }
engine_list(){ printf 'singbox\nxray\n'; }
engine_call(){
    local _e="$1" _m="$2"
    shift 2 || true
    case "$_m" in
        installed|is_active) return 0 ;;
        version) printf 'test-version\n'; return 0 ;;
        install|update|uninstall|start|stop|restart|enable|disable|logs)
            printf '%s %s' "$_e" "$_m" >>"$LOG"
            (($# == 0)) || printf ' %s' "$*" >>"$LOG"
            printf '\n' >>"$LOG"
            return 0
            ;;
        *) return 0 ;;
    esac
}
inbound_config_require(){ return 0; }
inbound_config_file(){ [[ "$1" == xray ]] && printf '%s\n' "$XCFG" || printf '%s\n' "$SCFG"; }
inbound_exists(){ return 0; }
inbound_clients(){ printf 'alice\tcredential\nbob\tcredential\n'; }
inbound_meta_get(){ return 1; }
inbound_show(){ return 0; }
inbound_share(){ return 0; }
inbound_modify_listen(){ return 0; }
inbound_rename(){ return 0; }
inbound_delete(){ return 0; }
inbound_client_add(){ return 0; }
inbound_client_rename(){ return 0; }
inbound_client_rotate(){ return 0; }
inbound_client_delete(){ return 0; }
inbound_random_hex(){ printf 'abcd'; }
inbound_add_interactive(){ printf 'inbound-add %s\n' "$1" >>"$LOG"; }
outbound_add_interactive(){ printf 'outbound-add %s\n' "$1" >>"$LOG"; }
outbound_assign_interactive(){ printf 'outbound-assign %s %s\n' "$1" "$2" >>"$LOG"; }
outbound_delete(){ printf 'outbound-delete %s %s\n' "$1" "$2" >>"$LOG"; }
outbound_exists(){ return 0; }
outbound_meta_list_managed(){
    case "${TEST_OUTBOUND_MODE:-some}:$1" in
        none:*) return 0 ;;
        *:xray) printf 'x-out-a\nx-out-b\n' ;;
        *:singbox) printf 'sb-out-a\nsb-out-b\n' ;;
    esac
}
cmd_inbound(){ return 0; }
cmd_outbound(){ return 0; }
cmd_status(){ return 0; }
cert_list(){ return 0; }
metadata_cert_list(){ return 0; }
cert_acme_issue(){ return 0; }
cert_generate_self(){ return 0; }
cert_import(){ return 0; }
cert_renew(){ return 0; }
cert_delete(){ return 0; }
cmd_cert(){ return 0; }
backup_list(){ return 0; }
backup_root(){ printf '%s\n' "$ROOT/backups"; }
backup_create(){ return 0; }
proxyctl_backup_restore(){ return 0; }
bbr_status(){ return 0; }
proxyctl_reconcile(){ return 0; }

printf '\nProxyCTL menu tests\n\n'

# 1. UI primitive must propagate to a caller variable named exactly "choice".
test_choose_choice(){
    local choice=''
    choose choice '测试' A B <<<"2" >/dev/null
    [[ "$choice" == B ]]
}
TEST_NAME='choose propagates a caller variable named choice'; check test_choose_choice

# 2. Core selector must propagate engine and preserve fixed Xray/sing-box order.
test_engine_xray(){
    local engine=''
    menu_select_engine engine 0 <<<"1" >/dev/null
    [[ "$engine" == xray ]]
}
TEST_NAME='core selector option 1 returns xray'; check test_engine_xray

test_engine_singbox(){
    local engine=''
    menu_select_engine engine 0 <<<"2" >/dev/null
    [[ "$engine" == singbox ]]
}
TEST_NAME='core selector option 2 returns singbox'; check test_engine_singbox

# 3. Nested selector must propagate both engine and tag to its caller.
test_inbound_selector(){
    local engine='' tag=''
    menu_select_inbound engine tag <<< $'1\n2\n' >/dev/null
    [[ "$engine" == xray && "$tag" == xray-b ]]
}
TEST_NAME='inbound selector propagates engine and tag'; check test_inbound_selector

test_outbound_selector(){
    local engine='' tag=''
    TEST_OUTBOUND_MODE=some menu_select_outbound engine tag <<< $'2\n2\n' >/dev/null
    [[ "$engine" == singbox && "$tag" == sb-out-b ]]
}
TEST_NAME='outbound selector propagates engine and tag'; check test_outbound_selector

# 4. Core install menu must dispatch the selected core, never a stale core.
: >"$LOG"
menu_core <<< $'2\n1\n11\n' >/dev/null
if grep -qx 'xray install' "$LOG"; then pass 'core install dispatches Xray'; else fail 'core install dispatches Xray'; fi

: >"$LOG"
menu_core <<< $'2\n2\n11\n' >/dev/null
if grep -qx 'singbox install' "$LOG"; then pass 'core install dispatches sing-box'; else fail 'core install dispatches sing-box'; fi

# 5. Start/stop operations provide visible completion feedback.
: >"$LOG"
out=$(menu_core <<< $'5\n1\n11\n')
if grep -qx 'xray start' "$LOG" && [[ "$out" == *'操作完成。'* ]]; then pass 'core start dispatch and feedback'; else fail 'core start dispatch and feedback'; fi

: >"$LOG"
out=$(menu_core <<< $'6\n2\n11\n')
if grep -qx 'singbox stop' "$LOG" && [[ "$out" == *'操作完成。'* ]]; then pass 'core stop dispatch and feedback'; else fail 'core stop dispatch and feedback'; fi

# 6. Uninstall path must return to the menu instead of appearing hung.
: >"$LOG"
out=$(menu_core <<< $'4\n2\ny\n11\n')
if grep -qx 'singbox uninstall' "$LOG" && [[ "$out" == *'操作完成。'* ]]; then pass 'core uninstall completes and returns'; else fail 'core uninstall completes and returns'; fi

# 7. The exact empty-state paths reported from the VPS must not crash.
TEST_OUTBOUND_MODE=none menu_outbound <<< $'4\n1\n5\n' >/dev/null
pass 'delete outbound with no managed outbound returns safely'

# Empty inbound list for both engines.
cat >"$XCFG" <<'JSON'
{"inbounds":[],"outbounds":[]}
JSON
cat >"$SCFG" <<'JSON'
{"inbounds":[],"outbounds":[]}
JSON
menu_outbound <<< $'3\n1\n5\n' >/dev/null
pass 'assign outbound with no inbound returns safely'
menu_inbound <<< $'3\n1\n4\n' >/dev/null
pass 'manage inbound with no inbound returns safely'

# 8. Add inbound must dispatch the selected engine correctly.
cat >"$XCFG" <<'JSON'
{"inbounds":[],"outbounds":[]}
JSON
cat >"$SCFG" <<'JSON'
{"inbounds":[],"outbounds":[]}
JSON
: >"$LOG"
menu_inbound <<< $'2\n1\n4\n' >/dev/null
if grep -qx 'inbound-add xray' "$LOG"; then pass 'add inbound dispatches Xray'; else fail 'add inbound dispatches Xray'; fi
: >"$LOG"
menu_inbound <<< $'2\n2\n4\n' >/dev/null
if grep -qx 'inbound-add singbox' "$LOG"; then pass 'add inbound dispatches sing-box'; else fail 'add inbound dispatches sing-box'; fi

# 9. Every top-level submenu can be entered/exited under nounset.
menu_inbound <<<"4" >/dev/null
menu_outbound <<<"5" >/dev/null
menu_core <<<"11" >/dev/null
menu_certificates <<<"7" >/dev/null
menu_backup <<<"3" >/dev/null
menu_system <<<"3" >/dev/null
pass 'all top-level submenus enter/exit under nounset'

printf '\nMenu tests: %d passed, %d failed\n' "$PASS" "$FAIL"
((FAIL == 0))
