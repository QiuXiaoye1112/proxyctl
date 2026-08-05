#!/usr/bin/env bash
# ------------------------------------------------------------------------------
# tests/integration.sh — Phase 2.8 cross-module integration tests
# ------------------------------------------------------------------------------
set -o errexit
set -o nounset
set -o pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
for c in jq openssl tar flock; do command -v "$c" >/dev/null 2>&1 || { echo "requires $c" >&2; exit 2; }; done

source "$PROJECT_DIR/lib/ui.sh"
source "$PROJECT_DIR/lib/core.sh"
source "$PROJECT_DIR/lib/metadata.sh"
source "$PROJECT_DIR/lib/transaction.sh"
source "$PROJECT_DIR/lib/common/system.sh"
source "$PROJECT_DIR/lib/common/network.sh"
source "$PROJECT_DIR/lib/common/lock.sh"
source "$PROJECT_DIR/lib/common/certificate.sh"
source "$PROJECT_DIR/lib/common/backup.sh"

PASS=0; FAIL=0
pass(){ echo "  PASS: $*"; ((++PASS)); }
fail(){ echo "  FAIL: $*" >&2; ((++FAIL)); }
eqv(){ [[ "$1" == "$2" ]] && pass "$3" || fail "$3 — expected '$2', got '$1'"; }
ok(){ if "$@"; then pass "$*"; else fail "$*"; fi; }

ROOT=$(mktemp -d)
trap 'rm -rf "$ROOT"' EXIT
export PROXYCTL_VERSION=0.2.7
export PROXYCTL_DATA="$ROOT/data"
export PROXYCTL_META="$PROXYCTL_DATA/meta.json"
export PROXYCTL_CERTS="$ROOT/certs"
export PROXYCTL_BACKUP="$ROOT/backups"
export PROXYCTL_LOCK_DIR="$ROOT/locks"
export PROXYCTL_LOCK="$PROXYCTL_LOCK_DIR/config.lock"
export PROXYCTL_CERT_LOCK="$PROXYCTL_LOCK_DIR/cert.lock"
export PROXYCTL_FIREWALL_LOCK="$PROXYCTL_LOCK_DIR/firewall.lock"
export PROXYCTL_CLOUDFLARE_INI="$ROOT/etc/cloudflare.ini"
export PROXYCTL_CERT_GROUP="$(id -gn)"
mkdir -m 700 -p "$PROXYCTL_DATA" "$PROXYCTL_LOCK_DIR" "$ROOT/config/xray" "$ROOT/config/singbox"
XRAY_CFG="$ROOT/config/xray/config.json"
SING_CFG="$ROOT/config/singbox/config.json"
CALLS="$ROOT/engine-calls"
: >"$CALLS"

_backup_require_root(){ return 0; }
_cert_require_root(){ return 0; }
_cert_setup_runtime_access(){ mkdir -p "$PROXYCTL_CERTS"; chmod 700 "$PROXYCTL_CERTS"; }
_cert_prepare_directory(){ local d; d=$(cert_dir "$1") || return 1; [[ ! -L "$d" ]] || return 1; mkdir -p "$d"; chmod 700 "$d"; }

engine_call(){
    local engine="$1" method="$2"; shift 2
    printf '%s:%s\n' "$engine" "$method" >>"$CALLS"
    case "$method" in
        installed) return 0 ;;
        config_file) [[ "$engine" == xray ]] && printf '%s\n' "$XRAY_CFG" || printf '%s\n' "$SING_CFG" ;;
        validate) jq empty "$1" >/dev/null 2>&1 ;;
        is_active) return 0 ;;
        restart)
            if [[ -f "$ROOT/fail-restart-once" ]]; then rm -f "$ROOT/fail-restart-once"; return 1; fi
            return 0 ;;
        *) return 1 ;;
    esac
}

make_pair(){
    local name="$1" d=''
    d="$ROOT/fixture-$name"
    mkdir -p "$d"
    openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj "/CN=${name}.example.com" \
      -addext "subjectAltName=DNS:${name}.example.com" -keyout "$d/key.pem" -out "$d/cert.pem" >/dev/null 2>&1
    printf '%s\t%s\n' "$d/cert.pem" "$d/key.pem"
}
IFS=$'\t' read -r CERT_A KEY_A < <(make_pair a)
IFS=$'\t' read -r CERT_B KEY_B < <(make_pair b)
IFS=$'\t' read -r CERT_C KEY_C < <(make_pair c)

write_config(){
    local file="$1" engine="$2" state="$3"
    cat >"$file" <<EOF
{"engine":"$engine","state":"$state","tls":{"certificateFile":"$PROXYCTL_CERTS/example.com/fullchain.pem","keyFile":"$PROXYCTL_CERTS/example.com/privkey.pem"}}
EOF
}

metadata_init >/dev/null
metadata_cert_set example.com example.com example.com imported imported false
changed=0
_cert_replace_pair example.com "$CERT_A" "$KEY_A" changed
write_config "$XRAY_CFG" xray baseline
write_config "$SING_CFG" singbox baseline
metadata_set_json inbounds '{"baseline":{"engine":"xray"}}'
BASE_META=$(jq -c . "$PROXYCTL_META")
BASE_SERIAL=$(openssl x509 -in "$(cert_fullchain example.com)" -noout -serial)

printf '\nProxyCTL Phase 2.8 Integration Tests\n\n'
BASE_BACKUP=$(backup_create baseline)
write_config "$ROOT/xray-new.json" xray changed
write_config "$ROOT/sing-new.json" singbox changed
ok apply_candidate xray "$ROOT/xray-new.json"
ok apply_candidate singbox "$ROOT/sing-new.json"
_cert_replace_pair example.com "$CERT_B" "$KEY_B" changed
ok _cert_restart_consumers_if_changed example.com "$changed"
metadata_set_json inbounds '{"changed":{"engine":"singbox"}}'

CALL_TEXT=$(cat "$CALLS")
[[ "$CALL_TEXT" == *'xray:restart'* ]] && pass 'transaction/certificate lifecycle restarts Xray' || fail 'transaction/certificate lifecycle restarts Xray'
[[ "$CALL_TEXT" == *'singbox:restart'* ]] && pass 'transaction/certificate lifecycle restarts sing-box' || fail 'transaction/certificate lifecycle restarts sing-box'

ok backup_restore "$BASE_BACKUP"
eqv "$(jq -r .state "$XRAY_CFG")" baseline 'backup restore returns Xray to baseline'
eqv "$(jq -r .state "$SING_CFG")" baseline 'backup restore returns sing-box to baseline'
eqv "$(openssl x509 -in "$(cert_fullchain example.com)" -noout -serial)" "$BASE_SERIAL" 'backup restore returns shared certificate to baseline'
eqv "$(jq -c . "$PROXYCTL_META")" "$BASE_META" 'backup restore returns metadata to baseline'

write_config "$ROOT/xray-pre.json" xray pre-restore
write_config "$ROOT/sing-pre.json" singbox pre-restore
ok apply_candidate xray "$ROOT/xray-pre.json"
ok apply_candidate singbox "$ROOT/sing-pre.json"
_cert_replace_pair example.com "$CERT_C" "$KEY_C" changed
metadata_set_json inbounds '{"pre_restore":{"engine":"xray"}}'
PRE_META=$(jq -c . "$PROXYCTL_META")
PRE_SERIAL=$(openssl x509 -in "$(cert_fullchain example.com)" -noout -serial)

touch "$ROOT/fail-restart-once"
set +e
backup_restore "$BASE_BACKUP" >/dev/null 2>&1
RC=$?
set -e
[[ $RC -ne 0 ]] && pass 'restore surfaces an engine restart failure' || fail 'restore surfaces an engine restart failure'
eqv "$(jq -r .state "$XRAY_CFG")" pre-restore 'failed restore preserves pre-restore Xray config'
eqv "$(jq -r .state "$SING_CFG")" pre-restore 'failed restore preserves pre-restore sing-box config'
eqv "$(openssl x509 -in "$(cert_fullchain example.com)" -noout -serial)" "$PRE_SERIAL" 'failed restore preserves pre-restore certificate'
eqv "$(jq -c . "$PROXYCTL_META")" "$PRE_META" 'failed restore preserves pre-restore metadata'

READY="$ROOT/cert-ready"; RELEASE="$ROOT/cert-release"
bash -c "source '$PROJECT_DIR/lib/ui.sh'; source '$PROJECT_DIR/lib/common/lock.sh'; lock_acquire cert || exit 10; touch '$READY'; while [[ ! -f '$RELEASE' ]]; do sleep 0.05; done; lock_release cert" &
HOLDER=$!
i=0; while [[ ! -f "$READY" && $i -lt 100 ]]; do sleep 0.05; i=$((i+1)); done
BEFORE_COUNT=$(find "$PROXYCTL_BACKUP" -maxdepth 1 -type f -name 'proxyctl-*.tar.gz' | wc -l | tr -d ' ')
set +e
backup_create cert-busy >/dev/null 2>&1
RC=$?
set -e
AFTER_COUNT=$(find "$PROXYCTL_BACKUP" -maxdepth 1 -type f -name 'proxyctl-*.tar.gz' | wc -l | tr -d ' ')
[[ $RC -ne 0 ]] && pass 'backup fails cleanly when cert lock is busy' || fail 'backup fails cleanly when cert lock is busy'
eqv "$AFTER_COUNT" "$BEFORE_COUNT" 'busy cert lock leaves no partial archive'
touch "$RELEASE"; wait "$HOLDER"

printf '\nIntegration tests: %d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
