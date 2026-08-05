#!/usr/bin/env bash
set -o errexit
set -o nounset
set -o pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
PASS=0; FAIL=0
pass(){ printf '  PASS: %s\n' "$*"; PASS=$((PASS+1)); }
fail(){ printf '  FAIL: %s\n' "$*" >&2; FAIL=$((FAIL+1)); }
expect_log(){ local _needle="$1" _name="$2"; if grep -Fqx -- "$_needle" "$LOG"; then pass "$_name"; else fail "$_name — missing log: $_needle"; fi; }

ROOT=$(mktemp -d)
trap 'rm -rf "$ROOT"' EXIT
export PROXYCTL_NO_TTY_GUARD=1
LOG="$ROOT/actions.log"
XCFG="$ROOT/xray.json"
SCFG="$ROOT/singbox.json"
mkdir -p "$ROOT/backups"

write_full_configs(){
  cat >"$XCFG" <<'JSON'
{"inbounds":[{"tag":"xray-a","listen":"0.0.0.0","port":443},{"tag":"xray-b","listen":"127.0.0.1","port":8443}],"outbounds":[]}
JSON
  cat >"$SCFG" <<'JSON'
{"inbounds":[{"tag":"sb-a","listen":"0.0.0.0","listen_port":443},{"tag":"sb-b","listen":"127.0.0.1","listen_port":8443}],"outbounds":[]}
JSON
}
write_single_configs(){
  printf '%s\n' '{"inbounds":[{"tag":"xray-a","listen":"0.0.0.0","port":443}],"outbounds":[]}' >"$XCFG"
  printf '%s\n' '{"inbounds":[{"tag":"sb-a","listen":"0.0.0.0","listen_port":443}],"outbounds":[]}' >"$SCFG"
}
write_empty_configs(){
  printf '%s\n' '{"inbounds":[],"outbounds":[]}' >"$XCFG"
  printf '%s\n' '{"inbounds":[],"outbounds":[]}' >"$SCFG"
}
write_full_configs

source "$PROJECT_DIR/lib/ui.sh"
source "$PROJECT_DIR/lib/menu.sh"

engine_exists(){ [[ "$1" == xray || "$1" == singbox ]]; }
engine_list(){ printf 'singbox\nxray\n'; }
engine_call(){
  local _e="$1" _m="$2" _arg
  shift 2 || true
  case "$_m" in
    installed|is_active) return 0 ;;
    version) printf 'test-version\n' ;;
    install|update|uninstall|start|stop|restart|enable|disable|logs)
      printf '%s %s' "$_e" "$_m" >>"$LOG"
      for _arg in "$@"; do [[ -n "$_arg" ]] && printf ' %s' "$_arg" >>"$LOG"; done
      printf '\n' >>"$LOG"
      ;;
  esac
}
inbound_config_require(){ return 0; }
inbound_config_file(){ [[ "$1" == xray ]] && printf '%s\n' "$XCFG" || printf '%s\n' "$SCFG"; }
inbound_exists(){ return 0; }
inbound_clients(){ printf 'alice\tcredential\nbob\tcredential\n'; }
inbound_meta_get(){ return 1; }
inbound_show(){ printf 'inbound-show %s %s\n' "$1" "$2" >>"$LOG"; }
inbound_share(){ printf 'inbound-share %s %s\n' "$1" "$2" >>"$LOG"; }
inbound_modify_listen(){
  printf 'inbound-modify %s %s %s %s' "$1" "$2" "$3" "$4" >>"$LOG"
  [[ -z "${5:-}" ]] || printf ' %s' "$5" >>"$LOG"
  printf '\n' >>"$LOG"
}
inbound_rename(){ printf 'inbound-rename %s %s %s\n' "$1" "$2" "$3" >>"$LOG"; }
inbound_delete(){ printf 'inbound-delete %s %s\n' "$1" "$2" >>"$LOG"; }
inbound_client_add(){ printf 'client-add %s %s %s\n' "$1" "$2" "$3" >>"$LOG"; }
inbound_client_rename(){ printf 'client-rename %s %s %s %s\n' "$1" "$2" "$3" "$4" >>"$LOG"; }
inbound_client_rotate(){ printf 'client-rotate %s %s %s\n' "$1" "$2" "$3" >>"$LOG"; }
inbound_client_delete(){ printf 'client-delete %s %s %s\n' "$1" "$2" "$3" >>"$LOG"; }
inbound_random_hex(){ printf 'abcd'; }
inbound_add_interactive(){ printf 'inbound-add %s\n' "$1" >>"$LOG"; }
outbound_add_interactive(){ printf 'outbound-add %s\n' "$1" >>"$LOG"; }
outbound_assign_interactive(){ printf 'outbound-assign %s %s\n' "$1" "$2" >>"$LOG"; }
outbound_delete(){ printf 'outbound-delete %s %s\n' "$1" "$2" >>"$LOG"; }
outbound_exists(){ return 0; }
outbound_meta_list_managed(){
  case "${TEST_OUTBOUND_MODE:-some}:$1" in
    none:*) return 0 ;;
    one:xray) printf 'x-out-a\n' ;;
    one:singbox) printf 'sb-out-a\n' ;;
    *:xray) printf 'x-out-a\nx-out-b\n' ;;
    *:singbox) printf 'sb-out-a\nsb-out-b\n' ;;
  esac
}
cmd_inbound(){ printf 'cmd-inbound %s\n' "${1:-list}" >>"$LOG"; }
cmd_outbound(){ printf 'cmd-outbound %s\n' "${1:-list}" >>"$LOG"; }
cmd_status(){ printf 'cmd-status\n' >>"$LOG"; }
cert_list(){ return 0; }
metadata_cert_list(){ [[ "${TEST_CERT_MODE:-none}" == one ]] && printf 'example.com\n' || true; }
cert_acme_issue(){ printf 'cert-issue %s %s %s %s\n' "$1" "$2" "$3" "$4" >>"$LOG"; }
cert_generate_self(){ printf 'cert-self %s\n' "$1" >>"$LOG"; }
cert_import(){ printf 'cert-import %s %s %s\n' "$1" "$2" "$3" >>"$LOG"; }
cert_renew(){ printf 'cert-renew %s\n' "$1" >>"$LOG"; }
cert_delete(){ printf 'cert-delete %s\n' "$1" >>"$LOG"; }
cmd_cert(){ printf 'cmd-cert %s\n' "$1" >>"$LOG"; }
backup_list(){ return 0; }
backup_root(){ printf '%s\n' "$ROOT/backups"; }
backup_create(){ printf 'backup-create %s\n' "${1:-}" >>"$LOG"; }
proxyctl_backup_restore(){ printf 'backup-restore %s\n' "$1" >>"$LOG"; }
bbr_status(){ printf 'bbr-status\n' >>"$LOG"; }
proxyctl_reconcile(){ printf 'reconcile %s\n' "${1:-both}" >>"$LOG"; }

prompt_value(){
  local __out="$1" _p="$2" _d="${3:-}" _v=''
  case "$_p" in
    '域名或公网 IP'|'域名或 IP') _v='example.com' ;;
    'ACME 邮箱') _v='admin@example.com' ;;
    '证书标识') _v='imported-cert' ;;
    '完整证书链路径') _v='/tmp/fullchain.pem' ;;
    '私钥路径') _v='/tmp/privkey.pem' ;;
    '新的用户名') _v='renamed-user' ;;
    '新的入站名称') _v='renamed-inbound' ;;
    *) _v="${_d:-test-value}" ;;
  esac
  printf -v "$__out" '%s' "$_v"
}
prompt_optional(){
  local __out="$1" _p="$2" _d="${3:-}" _v=''
  _v="$_d"
  [[ "$_p" != '备份标签（可留空）' ]] || _v='menu-test'
  printf -v "$__out" '%s' "$_v"
}

printf '\nProxyCTL menu tests\n\n'

test_choose_choice(){ local choice=''; choose choice '测试' A B <<<"2" >/dev/null; [[ "$choice" == B ]]; }
test_engine_xray(){ local engine=''; menu_select_engine engine 0 <<<"1" >/dev/null; [[ "$engine" == xray ]]; }
test_engine_singbox(){ local engine=''; menu_select_engine engine 0 <<<"2" >/dev/null; [[ "$engine" == singbox ]]; }
test_inbound_selector(){ local engine='' tag=''; menu_select_inbound engine tag <<< $'1\n2\n' >/dev/null; [[ "$engine" == xray && "$tag" == xray-b ]]; }
test_outbound_selector(){ local engine='' tag=''; TEST_OUTBOUND_MODE=some menu_select_outbound engine tag <<< $'2\n2\n' >/dev/null; [[ "$engine" == singbox && "$tag" == sb-out-b ]]; }

test_choose_choice && pass 'choose propagates choice' || fail 'choose propagates choice'
test_engine_xray && pass 'core selector option 1 returns xray' || fail 'core selector option 1 returns xray'
test_engine_singbox && pass 'core selector option 2 returns singbox' || fail 'core selector option 2 returns singbox'
test_inbound_selector && pass 'inbound selector propagates engine/tag' || fail 'inbound selector propagates engine/tag'
test_outbound_selector && pass 'outbound selector propagates engine/tag' || fail 'outbound selector propagates engine/tag'

: >"$LOG"; menu_core <<< $'1\n11\n' >/dev/null; expect_log 'cmd-status' 'core status dispatch'
: >"$LOG"; menu_core <<< $'2\n1\n11\n' >/dev/null; expect_log 'xray install' 'core install Xray'
: >"$LOG"; menu_core <<< $'2\n2\n11\n' >/dev/null; expect_log 'singbox install' 'core install sing-box'
: >"$LOG"; menu_core <<< $'3\n1\n11\n' >/dev/null; expect_log 'xray update' 'core update'
: >"$LOG"; out=$(menu_core <<< $'4\n2\ny\n11\n'); expect_log 'singbox uninstall' 'core uninstall'; [[ "$out" == *'操作完成。'* ]] && pass 'uninstall feedback' || fail 'uninstall feedback'
: >"$LOG"; out=$(menu_core <<< $'5\n1\n11\n'); expect_log 'xray start' 'core start'; [[ "$out" == *'操作完成。'* ]] && pass 'start feedback' || fail 'start feedback'
: >"$LOG"; out=$(menu_core <<< $'6\n2\n11\n'); expect_log 'singbox stop' 'core stop'; [[ "$out" == *'操作完成。'* ]] && pass 'stop feedback' || fail 'stop feedback'
: >"$LOG"; menu_core <<< $'7\n1\n11\n' >/dev/null; expect_log 'xray restart' 'core restart'
: >"$LOG"; menu_core <<< $'8\n2\n11\n' >/dev/null; expect_log 'singbox enable' 'core enable'
: >"$LOG"; menu_core <<< $'9\n1\n11\n' >/dev/null; expect_log 'xray disable' 'core disable'
: >"$LOG"; menu_core <<< $'10\n2\n11\n' >/dev/null; expect_log 'singbox logs 100' 'core logs'

TEST_OUTBOUND_MODE=none menu_outbound <<< $'4\n1\n5\n' >/dev/null; pass 'empty managed outbound path safe'
write_empty_configs
menu_outbound <<< $'3\n1\n5\n' >/dev/null; pass 'empty inbound outbound-assign path safe'
menu_inbound <<< $'3\n1\n4\n' >/dev/null; pass 'empty inbound manage path safe'

write_single_configs
: >"$LOG"; menu_inbound <<< $'1\n4\n' >/dev/null; expect_log 'cmd-inbound list' 'inbound list'
: >"$LOG"; menu_inbound <<< $'2\n1\n4\n' >/dev/null; expect_log 'inbound-add xray' 'inbound add Xray'
: >"$LOG"; menu_inbound <<< $'2\n2\n4\n' >/dev/null; expect_log 'inbound-add singbox' 'inbound add sing-box'
: >"$LOG"; menu_inbound <<< $'3\n1\n1\n9\n4\n' >/dev/null; expect_log 'inbound-show xray xray-a' 'inbound show'
: >"$LOG"; menu_inbound <<< $'3\n2\n2\n9\n4\n' >/dev/null; expect_log 'inbound-share singbox sb-a' 'inbound share'
: >"$LOG"; menu_inbound <<< $'3\n1\n4\n9\n4\n' >/dev/null; expect_log 'outbound-assign xray xray-a' 'inbound set outbound'
: >"$LOG"; menu_inbound <<< $'3\n1\n5\n9\n4\n' >/dev/null; expect_log 'inbound-modify xray xray-a 0.0.0.0 443' 'inbound modify'
: >"$LOG"; menu_inbound <<< $'3\n2\n6\n9\n4\n' >/dev/null; expect_log 'inbound-rename singbox sb-a renamed-inbound' 'inbound rename'
: >"$LOG"; menu_inbound <<< $'3\n1\n7\ny\n4\n' >/dev/null; expect_log 'inbound-delete xray xray-a' 'inbound delete'

: >"$LOG"; menu_clients xray xray-a <<< $'1\n5\n' >/dev/null; expect_log 'client-add xray xray-a user-abcd' 'user add'
: >"$LOG"; menu_clients xray xray-a <<< $'2\n1\n5\n' >/dev/null; expect_log 'client-rename xray xray-a alice renamed-user' 'user rename'
: >"$LOG"; menu_clients singbox sb-a <<< $'3\n2\ny\n5\n' >/dev/null; expect_log 'client-rotate singbox sb-a bob' 'user rotate'
: >"$LOG"; menu_clients singbox sb-a <<< $'4\n1\ny\n5\n' >/dev/null; expect_log 'client-delete singbox sb-a alice' 'user delete'

: >"$LOG"; menu_outbound <<< $'1\n5\n' >/dev/null; expect_log 'cmd-outbound list' 'outbound list'
: >"$LOG"; menu_outbound <<< $'2\n1\n5\n' >/dev/null; expect_log 'outbound-add xray' 'outbound add Xray'
: >"$LOG"; menu_outbound <<< $'2\n2\n5\n' >/dev/null; expect_log 'outbound-add singbox' 'outbound add sing-box'
: >"$LOG"; menu_outbound <<< $'3\n1\n5\n' >/dev/null; expect_log 'outbound-assign xray xray-a' 'outbound assign'
: >"$LOG"; TEST_OUTBOUND_MODE=one menu_outbound <<< $'4\n2\ny\n5\n' >/dev/null; expect_log 'outbound-delete singbox sb-out-a' 'outbound delete'

: >"$LOG"; menu_certificates <<< $'1\n1\n7\n' >/dev/null; expect_log 'cert-issue example.com admin@example.com http 0' 'certificate issue'
: >"$LOG"; menu_certificates <<< $'2\n7\n' >/dev/null; expect_log 'cert-self example.com' 'certificate self-signed'
: >"$LOG"; menu_certificates <<< $'3\n7\n' >/dev/null; expect_log 'cert-import imported-cert /tmp/fullchain.pem /tmp/privkey.pem' 'certificate import'
: >"$LOG"; TEST_CERT_MODE=one menu_certificates <<< $'4\n7\n' >/dev/null; expect_log 'cert-renew example.com' 'certificate renew'
: >"$LOG"; TEST_CERT_MODE=one menu_certificates <<< $'5\ny\n7\n' >/dev/null; expect_log 'cert-delete example.com' 'certificate delete'
: >"$LOG"; menu_certificates <<< $'6\n7\n' >/dev/null; expect_log 'cmd-cert cloudflare' 'Cloudflare dispatch'

: >"$LOG"; menu_backup <<< $'1\n3\n' >/dev/null; expect_log 'backup-create menu-test' 'backup create'
BACKUP_ID='proxyctl-20260805-120000-123-menu.tar.gz'; : >"$ROOT/backups/$BACKUP_ID"
: >"$LOG"; menu_backup <<< $'2\ny\n3\n' >/dev/null; expect_log "backup-restore $BACKUP_ID" 'backup restore'
: >"$LOG"; menu_system <<< $'1\n3\n' >/dev/null; expect_log 'bbr-status' 'BBR status'
: >"$LOG"; menu_system <<< $'2\n1\n3\n' >/dev/null; expect_log 'reconcile xray' 'reconcile Xray'
: >"$LOG"; menu_system <<< $'2\n3\n3\n' >/dev/null; expect_log 'reconcile both' 'reconcile both'

menu_main <<< $'1\n4\n7\n' >/dev/null
menu_inbound <<<"4" >/dev/null; menu_outbound <<<"5" >/dev/null; menu_core <<<"11" >/dev/null
menu_certificates <<<"7" >/dev/null; menu_backup <<<"3" >/dev/null; menu_system <<<"3" >/dev/null
pass 'main and all submenus enter/exit under nounset'

printf '\nMenu tests: %d passed, %d failed\n' "$PASS" "$FAIL"
((FAIL==0))
