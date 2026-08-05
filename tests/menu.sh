#!/usr/bin/env bash
set -o errexit
set -o nounset
set -o pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
readonly PROXYCTL_VERSION='0.3.0-test'

PASS=0
FAIL=0
pass(){ printf '  PASS: %s\n' "$*"; PASS=$((PASS+1)); }
fail(){ printf '  FAIL: %s\n' "$*" >&2; FAIL=$((FAIL+1)); }
expect_log(){ local needle="$1" name="$2"; grep -Fqx -- "$needle" "$LOG" && pass "$name" || fail "$name — missing log: $needle"; }

ROOT=$(mktemp -d)
trap 'rm -rf "$ROOT"' EXIT
export PROXYCTL_NO_TTY_GUARD=1
LOG="$ROOT/actions.log"
XCFG="$ROOT/xray.json"
SCFG="$ROOT/singbox.json"
mkdir -p "$ROOT/backups"

write_configs(){
  printf '%s\n' '{"inbounds":[{"tag":"xray-a","listen":"0.0.0.0","port":443,"protocol":"vless"}],"outbounds":[{"tag":"direct","protocol":"freedom"}]}' >"$XCFG"
  printf '%s\n' '{"inbounds":[{"tag":"sb-a","listen":"0.0.0.0","listen_port":8443,"type":"vless"}],"outbounds":[{"tag":"direct","type":"direct"}]}' >"$SCFG"
}
write_configs

source "$PROJECT_DIR/lib/ui.sh"
source "$PROJECT_DIR/lib/menu.sh"
ui_clear_screen(){ :; }
pause(){ :; }

X_ACTIVE=1
S_ACTIVE=1
X_ENABLED=1
S_ENABLED=1
engine_exists(){ [[ "$1" == xray || "$1" == singbox ]]; }
engine_list(){ printf 'singbox\nxray\n'; }
engine_call(){
  local e="$1" m="$2" arg
  shift 2 || true
  case "$m" in
    installed) return 0 ;;
    is_active) [[ "$e" == xray ]] && ((X_ACTIVE)) || { [[ "$e" == singbox ]] && ((S_ACTIVE)); } ;;
    version) [[ "$e" == xray ]] && printf 'Xray 26.7.11\n' || printf 'sing-box version 1.13.12\n' ;;
    config_file) [[ "$e" == xray ]] && printf '%s\n' "$XCFG" || printf '%s\n' "$SCFG" ;;
    service_name) [[ "$e" == xray ]] && printf 'xray\n' || printf 'sing-box\n' ;;
    install|update|uninstall|start|stop|restart|enable|disable|logs)
      printf '%s %s' "$e" "$m" >>"$LOG"
      for arg in "$@"; do [[ -n "$arg" ]] && printf ' %s' "$arg" >>"$LOG"; done
      printf '\n' >>"$LOG"
      ;;
  esac
}
service_is_enabled(){
  [[ "$1" == xray ]] && ((X_ENABLED)) || { [[ "$1" == sing-box ]] && ((S_ENABLED)); }
}

inbound_config_require(){ return 0; }
inbound_config_file(){ [[ "$1" == xray ]] && printf '%s\n' "$XCFG" || printf '%s\n' "$SCFG"; }
inbound_exists(){ return 0; }
inbound_clients(){ printf 'alice\tcredential\nbob\tcredential\n'; }
inbound_meta_get(){ return 1; }
inbound_show(){ printf 'inbound-show %s %s\n' "$1" "$2" >>"$LOG"; }
inbound_share(){ printf 'inbound-share %s %s\n' "$1" "$2" >>"$LOG"; }
inbound_modify_listen(){ printf 'inbound-modify %s %s %s %s %s\n' "$1" "$2" "$3" "$4" "${5:-}" >>"$LOG"; }
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
outbound_meta_list_managed(){ [[ "$1" == xray ]] && printf 'x-out-a\n' || printf 'sb-out-a\n'; }

cert_count(){ printf '1\n'; }
cert_list(){ printf 'example.com\n'; }
metadata_cert_list(){ printf 'example.com\n'; }
cert_acme_issue(){ printf 'cert-issue %s %s %s %s\n' "$1" "$2" "$3" "$4" >>"$LOG"; }
cert_generate_self(){ printf 'cert-self %s\n' "$1" >>"$LOG"; }
cert_import(){ printf 'cert-import %s %s %s\n' "$1" "$2" "$3" >>"$LOG"; }
cert_renew(){ printf 'cert-renew %s\n' "$1" >>"$LOG"; }
cert_delete(){ printf 'cert-delete %s\n' "$1" >>"$LOG"; }
cmd_cert(){ printf 'cmd-cert %s\n' "$1" >>"$LOG"; }

backup_list(){ :; }
backup_root(){ printf '%s\n' "$ROOT/backups"; }
backup_create(){ printf 'backup-create %s\n' "${1:-}" >>"$LOG"; }
proxyctl_backup_restore(){ printf 'backup-restore %s\n' "$1" >>"$LOG"; }
bbr_status(){ printf 'bbr-status\n' >>"$LOG"; }
proxyctl_reconcile(){ printf 'reconcile %s\n' "${1:-both}" >>"$LOG"; }
proxyctl_uninstall(){ printf 'uninstall %s\n' "$*" >>"$LOG"; }

prompt_value(){
  local out="$1" prompt="$2" default="${3:-}" value=''
  case "$prompt" in
    '域名或公网 IP'|'域名或 IP') value='example.com' ;;
    'ACME 邮箱') value='admin@example.com' ;;
    '证书标识') value='imported-cert' ;;
    '完整证书链路径') value='/tmp/fullchain.pem' ;;
    '私钥路径') value='/tmp/privkey.pem' ;;
    '新的用户名') value='renamed-user' ;;
    '新的入站名称') value='renamed-inbound' ;;
    *) value="${default:-test-value}" ;;
  esac
  printf -v "$out" '%s' "$value"
}
prompt_optional(){ local out="$1" _prompt="$2" default="${3:-}"; printf -v "$out" '%s' "$default"; }

printf '\nProxyCTL xrayctl-style menu tests\n\n'

# Main page must look like a status page, not a generic nested choose dialog.
main_out="$ROOT/main.out"; main_err="$ROOT/main.err"
menu_main <<< $'0\n' >"$main_out" 2>"$main_err"
grep -Fq 'ProxyCTL 统一代理管理器' "$main_out" && pass 'main page title' || fail 'main page title'
grep -Fq 'Xray: 运行中' "$main_out" && grep -Fq 'sing-box: 运行中' "$main_out" && pass 'main page core summary' || fail 'main page core summary'
grep -Fq '当前入站' "$main_out" && grep -Fq 'xray-a' "$main_out" && grep -Fq 'sb-a' "$main_out" && pass 'main page current inbound overview' || fail 'main page current inbound overview'
grep -Fq '1) 入站管理' "$main_out" && grep -Fq '7) 卸载' "$main_out" && grep -Fq '0) 退出' "$main_out" && pass 'main page fixed numbered menu' || fail 'main page fixed numbered menu'
grep -Fq '请选择:' "$main_err" && pass 'main page explicit prompt' || fail 'main page explicit prompt'

# Engine selector must preserve Xray first, sing-box second.
test_engine_xray(){ local e=''; menu_select_engine e 0 <<< $'1\n' >/dev/null 2>/dev/null; [[ "$e" == xray ]]; }
test_engine_singbox(){ local e=''; menu_select_engine e 0 <<< $'2\n' >/dev/null 2>/dev/null; [[ "$e" == singbox ]]; }
test_engine_xray && pass 'core selector 1 = Xray' || fail 'core selector Xray'
test_engine_singbox && pass 'core selector 2 = sing-box' || fail 'core selector sing-box'

# Inbound page follows xrayctl: list first, then add/manage/share/delete/0.
in_out="$ROOT/inbound.out"; menu_inbound <<< $'0\n' >"$in_out" 2>/dev/null
grep -Fq '1) 新增入站' "$in_out" && grep -Fq '2) 管理已有入站' "$in_out" && grep -Fq '3) 全部分享信息' "$in_out" && grep -Fq '4) 删除入站' "$in_out" && grep -Fq '0) 返回' "$in_out" && pass 'inbound page mirrors xrayctl structure' || fail 'inbound page structure'

: >"$LOG"; menu_inbound <<< $'1\n1\n0\n' >/dev/null 2>/dev/null; expect_log 'inbound-add xray' 'inbound add Xray dispatch'
: >"$LOG"; menu_inbound <<< $'1\n2\n0\n' >/dev/null 2>/dev/null; expect_log 'inbound-add singbox' 'inbound add sing-box dispatch'
: >"$LOG"; menu_inbound <<< $'2\n1\n1\n0\n0\n' >/dev/null 2>/dev/null; expect_log 'inbound-share xray xray-a' 'manage inbound share dispatch'
: >"$LOG"; menu_inbound <<< $'4\n2\ny\n0\n' >/dev/null 2>/dev/null; expect_log 'inbound-delete singbox sb-a' 'inbound delete dispatch'

# Outbound page wording/flow follows xrayctl and says 添加, not generic CRUD 新建.
out_out="$ROOT/outbound.out"; menu_outbound <<< $'0\n' >"$out_out" 2>/dev/null
grep -Fq '1) 选择入站设置出站' "$out_out" && grep -Fq '2) 添加出站 (SOCKS5/HTTP/本机 IP)' "$out_out" && grep -Fq '3) 删除出站' "$out_out" && grep -Fq '0) 返回' "$out_out" && pass 'outbound page uses add/assign/delete wording' || fail 'outbound page wording'
: >"$LOG"; menu_outbound <<< $'1\n1\n0\n' >/dev/null 2>/dev/null; expect_log 'outbound-assign xray xray-a' 'outbound assignment dispatch'
: >"$LOG"; menu_outbound <<< $'2\n1\n0\n' >/dev/null 2>/dev/null; expect_log 'outbound-add xray' 'outbound add dispatch'
: >"$LOG"; menu_outbound <<< $'3\n2\ny\n0\n' >/dev/null 2>/dev/null; expect_log 'outbound-delete singbox sb-out-a' 'outbound delete dispatch'

# Service management follows xrayctl's compact 1..6 menu.
core_out="$ROOT/core.out"; menu_core <<< $'0\n' >"$core_out" 2>/dev/null
grep -Fq '1) 启动/停止' "$core_out" && grep -Fq '5) 安装/更新/修复核心' "$core_out" && grep -Fq '6) 卸载核心' "$core_out" && grep -Fq '0) 返回' "$core_out" && pass 'service page mirrors xrayctl compact layout' || fail 'service page layout'

: >"$LOG"; X_ACTIVE=1 menu_core <<< $'1\n1\n0\n' >/dev/null 2>/dev/null; expect_log 'xray stop' 'running Xray toggles to stop'
: >"$LOG"; X_ACTIVE=0 menu_core <<< $'1\n1\n0\n' >/dev/null 2>/dev/null; expect_log 'xray start' 'stopped Xray toggles to start'; X_ACTIVE=1
: >"$LOG"; menu_core <<< $'2\n2\n0\n' >/dev/null 2>/dev/null; expect_log 'singbox restart' 'service restart dispatch'
: >"$LOG"; X_ENABLED=1 menu_core <<< $'3\n1\n0\n' >/dev/null 2>/dev/null; expect_log 'xray disable' 'autostart toggle disable'; X_ENABLED=1
: >"$LOG"; menu_core <<< $'4\n2\n0\n' >/dev/null 2>/dev/null; expect_log 'singbox logs 100' 'service logs dispatch'
: >"$LOG"; menu_core <<< $'5\n1\n1\n0\n' >/dev/null 2>/dev/null; expect_log 'xray install' 'install/repair dispatch'

# Exact regression for the user's report: after uninstall finishes, the menu must
# redraw and print another visible 请选择: prompt instead of appearing frozen.
: >"$LOG"; core_err="$ROOT/core-uninstall.err"
menu_core <<< $'6\n2\ny\n0\n' >/dev/null 2>"$core_err"
expect_log 'singbox uninstall' 'core uninstall dispatch'
prompt_count=$(grep -Fo '请选择:' "$core_err" | wc -l | tr -d ' ')
((prompt_count >= 2)) && pass 'uninstall returns to service page with visible prompt' || fail 'uninstall return prompt'

# Certificate, backup and system pages retain 0-return xrayctl navigation.
cert_out="$ROOT/cert.out"; menu_certificates <<< $'0\n' >"$cert_out" 2>/dev/null
grep -Fq "1) Let's Encrypt 自动签发" "$cert_out" && grep -Fq '0) 返回' "$cert_out" && pass 'certificate page fixed navigation' || fail 'certificate navigation'
backup_out="$ROOT/backup.out"; menu_backup <<< $'0\n' >"$backup_out" 2>/dev/null
grep -Fq '1) 创建备份' "$backup_out" && grep -Fq '2) 恢复备份' "$backup_out" && grep -Fq '0) 返回' "$backup_out" && pass 'backup page fixed navigation' || fail 'backup navigation'
sys_out="$ROOT/system.out"; menu_system <<< $'0\n' >"$sys_out" 2>/dev/null
grep -Fq '1) 查看 BBR 状态' "$sys_out" && grep -Fq '0) 返回' "$sys_out" && pass 'system page fixed navigation' || fail 'system navigation'

printf '\nMenu tests: %d passed, %d failed\n' "$PASS" "$FAIL"
((FAIL == 0))
