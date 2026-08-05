#!/usr/bin/env bash
# ------------------------------------------------------------------------------
# tests/backup.sh — Phase 2.7 portable backup / restore tests
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
bad(){ if "$@"; then fail "$*"; else pass "$*"; fi; }

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

_backup_require_root(){ return 0; }
_cert_require_root(){ return 0; }
_cert_setup_runtime_access(){ mkdir -p "$PROXYCTL_CERTS"; chmod 700 "$PROXYCTL_CERTS"; }
_cert_prepare_directory(){ local d; d=$(cert_dir "$1") || return 1; [[ ! -L "$d" ]] || return 1; mkdir -p "$d"; chmod 700 "$d"; }

engine_call(){
    local engine="$1" method="$2"; shift 2
    case "$method" in
        installed) return 0 ;;
        config_file) [[ "$engine" == xray ]] && printf '%s\n' "$XRAY_CFG" || printf '%s\n' "$SING_CFG" ;;
        validate) jq empty "$1" >/dev/null 2>&1 ;;
        is_active) return 1 ;;
        restart) return 0 ;;
        *) return 1 ;;
    esac
}

make_pair(){
    local name="$1" d
    d="$ROOT/fixture-$name"
    mkdir -p "$d"
    openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj "/CN=${name}.example.com" \
      -addext "subjectAltName=DNS:${name}.example.com" -keyout "$d/key.pem" -out "$d/cert.pem" >/dev/null 2>&1
    printf '%s\t%s\n' "$d/cert.pem" "$d/key.pem"
}
IFS=$'\t' read -r CERT_A KEY_A < <(make_pair original)
IFS=$'\t' read -r CERT_B KEY_B < <(make_pair changed)

printf '{"engine":"xray","state":"original"}\n' >"$XRAY_CFG"
printf '{"engine":"singbox","state":"original"}\n' >"$SING_CFG"
metadata_init >/dev/null
metadata_cert_set example.com example.com example.com imported imported false
changed=0
_cert_replace_pair example.com "$CERT_A" "$KEY_A" changed
mkdir -p "$(dirname "$PROXYCTL_CLOUDFLARE_INI")"
printf 'dns_cloudflare_email = old@example.com\ndns_cloudflare_api_key = old-key\n' >"$PROXYCTL_CLOUDFLARE_INI"
chmod 600 "$PROXYCTL_CLOUDFLARE_INI"
ORIG_SERIAL=$(openssl x509 -in "$(cert_fullchain example.com)" -noout -serial)
ORIG_META=$(jq -c . "$PROXYCTL_META")

printf '\nProxyCTL Phase 2.7 Backup Tests\n\n'

ok _backup_validate_label nightly
bad _backup_validate_label '../bad'
bad _backup_validate_label 'a..b'
ok _backup_validate_id 'proxyctl-20260805-120000-123-nightly.tar.gz'
bad _backup_validate_id '../../etc/passwd'
ok _backup_member_ok 'certs/example.com/fullchain.pem'
bad _backup_member_ok '../escape'
bad _backup_member_ok 'certs/example.com/nested/file'

ID=$(backup_create nightly)
ok _backup_validate_id "$ID"
ARCHIVE="$PROXYCTL_BACKUP/$ID"
[[ -f "$ARCHIVE" ]] && pass 'backup archive created' || fail 'backup archive created'
MODE=$(stat -c '%a' "$ARCHIVE" 2>/dev/null || stat -f '%Lp' "$ARCHIVE")
eqv "$MODE" 600 'backup archive is mode 600'
ok _backup_archive_ok "$ARCHIVE"
LIST=$(backup_list)
[[ "$LIST" == *"$ID"* ]] && pass 'backup_list shows archive' || fail 'backup_list shows archive'
TARLIST=$(tar -tzf "$ARCHIVE")
[[ "$TARLIST" == *'engines/xray/config.json'* ]] && pass 'archive contains Xray config' || fail 'archive contains Xray config'
[[ "$TARLIST" == *'engines/singbox/config.json'* ]] && pass 'archive contains sing-box config' || fail 'archive contains sing-box config'
[[ "$TARLIST" == *'certs/example.com/privkey.pem'* ]] && pass 'archive contains managed private key' || fail 'archive contains managed private key'
[[ "$TARLIST" == *'secrets/cloudflare.ini'* ]] && pass 'archive contains Cloudflare credentials' || fail 'archive contains Cloudflare credentials'

printf '{"engine":"xray","state":"changed"}\n' >"$XRAY_CFG"
printf '{"engine":"singbox","state":"changed"}\n' >"$SING_CFG"
metadata_set_json inbounds '{"changed":{"engine":"xray"}}'
_cert_replace_pair example.com "$CERT_B" "$KEY_B" changed
printf 'dns_cloudflare_email = new@example.com\ndns_cloudflare_api_key = new-key\n' >"$PROXYCTL_CLOUDFLARE_INI"

ok backup_restore "$ID"
eqv "$(jq -r .state "$XRAY_CFG")" original 'restore recovers Xray config'
eqv "$(jq -r .state "$SING_CFG")" original 'restore recovers sing-box config'
eqv "$(openssl x509 -in "$(cert_fullchain example.com)" -noout -serial)" "$ORIG_SERIAL" 'restore recovers certificate pair'
eqv "$(jq -c . "$PROXYCTL_META")" "$ORIG_META" 'restore recovers metadata'
[[ "$(cat "$PROXYCTL_CLOUDFLARE_INI")" == *'old-key'* ]] && pass 'restore recovers Cloudflare credentials' || fail 'restore recovers Cloudflare credentials'

# Config-lock contention must fail before archive mutation.
READY="$ROOT/ready"; RELEASE="$ROOT/release"
bash -c "source '$PROJECT_DIR/lib/ui.sh'; source '$PROJECT_DIR/lib/common/lock.sh'; lock_acquire config || exit 10; touch '$READY'; while [[ ! -f '$RELEASE' ]]; do sleep 0.05; done; lock_release config" &
HOLDER=$!
i=0; while [[ ! -f "$READY" && $i -lt 100 ]]; do sleep 0.05; i=$((i+1)); done
set +e
OUT=$(backup_create blocked 2>&1); RC=$?
set -e
[[ $RC -ne 0 ]] && pass 'backup creation fails under config-lock contention' || fail 'backup creation fails under config-lock contention'
[[ "$OUT" == *'Another ProxyCTL config operation is already running.'* ]] && pass 'backup lock contention reports busy state' || fail 'backup lock contention reports busy state'
touch "$RELEASE"; wait "$HOLDER"

printf '\nBackup tests: %d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
