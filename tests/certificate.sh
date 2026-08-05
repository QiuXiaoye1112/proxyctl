#!/usr/bin/env bash
# ------------------------------------------------------------------------------
# tests/certificate.sh — Phase 2.6 shared certificate manager tests
#
# No Let's Encrypt/network/system service is touched. OpenSSL creates local
# fixtures; Certbot, engine control, port inspection and root requirements are
# mocked where needed. Real flock is used for certificate-lock contention.
# ------------------------------------------------------------------------------
set -o errexit
set -o nounset
set -o pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

for cmd in jq openssl flock; do
    command -v "$cmd" >/dev/null 2>&1 || { echo "tests/certificate.sh requires ${cmd}" >&2; exit 2; }
done

source "${PROJECT_DIR}/lib/ui.sh"
source "${PROJECT_DIR}/lib/core.sh"
source "${PROJECT_DIR}/lib/metadata.sh"
source "${PROJECT_DIR}/lib/common/system.sh"
source "${PROJECT_DIR}/lib/common/network.sh"
source "${PROJECT_DIR}/lib/common/port.sh"
source "${PROJECT_DIR}/lib/common/lock.sh"
source "${PROJECT_DIR}/lib/common/certificate.sh"

PASSED=0
FAILED=0
pass() { echo "  PASS: $*"; ((++PASSED)); }
fail() { echo "  FAIL: $*" >&2; ((++FAILED)); }
ok() { if "$@"; then pass "$*"; else fail "$*"; fi; }
bad() { if "$@"; then fail "$*"; else pass "$*"; fi; }
eqv() { [[ "$1" == "$2" ]] && pass "$3" || fail "$3 — expected '$2', got '$1'"; }
has() { [[ "$1" == *"$2"* ]] && pass "$3" || fail "$3 — missing '$2'"; }

ROOT=$(mktemp -d)
trap 'rm -rf "${ROOT}"' EXIT
export PROXYCTL_DATA="${ROOT}/data"
export PROXYCTL_META="${PROXYCTL_DATA}/meta.json"
export PROXYCTL_CERTS="${ROOT}/certs"
export PROXYCTL_LOCK_DIR="${ROOT}/locks"
export PROXYCTL_LOCK="${PROXYCTL_LOCK_DIR}/config.lock"
export PROXYCTL_CERT_LOCK="${PROXYCTL_LOCK_DIR}/cert.lock"
export PROXYCTL_FIREWALL_LOCK="${PROXYCTL_LOCK_DIR}/firewall.lock"
export PROXYCTL_CERTBOT_VENV="${ROOT}/certbot-venv"
export PROXYCTL_CERTBOT_CONFIG="${ROOT}/letsencrypt/config"
export PROXYCTL_CERTBOT_WORK="${ROOT}/letsencrypt/work"
export PROXYCTL_CERTBOT_LOGS="${ROOT}/letsencrypt/logs"
export PROXYCTL_CLOUDFLARE_INI="${ROOT}/etc/cloudflare.ini"
export PROXYCTL_CERT_GROUP="$(id -gn)"
export PROXYCTL_BIN="${ROOT}/proxyctl"
mkdir -m 700 -p "$PROXYCTL_LOCK_DIR" "$PROXYCTL_DATA"
metadata_init >/dev/null

# Unit tests run unprivileged. Bypass only the system ownership plumbing; the
# pair replacement and all path checks remain real.
_cert_require_root() { return 0; }
_cert_setup_runtime_access() {
    [[ ! -L "$PROXYCTL_CERTS" ]] || return 1
    mkdir -p "$PROXYCTL_CERTS"
    chmod 700 "$PROXYCTL_CERTS"
}
_cert_prepare_directory() {
    local id="$1" dir
    cert_validate_identifier "$id" || return 1
    _cert_setup_runtime_access || return 1
    dir=$(cert_dir "$id")
    [[ ! -L "$dir" ]] || return 1
    mkdir -p "$dir"
    chmod 700 "$dir"
}

make_pair() {
    local name="$1" dir="${ROOT}/fixtures/${name}"
    mkdir -p "$dir"
    openssl req -x509 -newkey rsa:2048 -nodes -days 2 \
        -subj "/CN=${name}.example.com" -addext "subjectAltName=DNS:${name}.example.com" \
        -keyout "${dir}/key.pem" -out "${dir}/cert.pem" >/dev/null 2>&1
    printf '%s\t%s\n' "${dir}/cert.pem" "${dir}/key.pem"
}

IFS=$'\t' read -r CERT_A KEY_A < <(make_pair a)
IFS=$'\t' read -r CERT_B KEY_B < <(make_pair b)

printf '\nProxyCTL Phase 2.6 Certificate Tests\n\n'

# 1. Identifier/subject/path contracts.
ok cert_validate_identifier 'example.com'
bad cert_validate_identifier '../escape'
bad cert_validate_identifier 'a..b'
ok cert_validate_subject 'example.com'
ok cert_validate_subject '192.0.2.10'
eqv "$(cert_identifier_for_subject 'Example.COM')" 'example.com' 'domain identifier is normalized'
has "$(cert_identifier_for_subject '192.0.2.10')" 'ip4-' 'IPv4 identifier is hashed'
eqv "$(cert_fullchain 'example.com')" "${PROXYCTL_CERTS}/example.com/fullchain.pem" 'fullchain path mapping'
eqv "$(cert_privkey 'example.com')" "${PROXYCTL_CERTS}/example.com/privkey.pem" 'privkey path mapping'

# 2. Real OpenSSL pair validation.
ok cert_validate_pair_files "$CERT_A" "$KEY_A"
bad cert_validate_pair_files "$CERT_A" "$KEY_B"

# 3. Staged replacement + change detection.
changed=''
ok _cert_replace_pair example.com "$CERT_A" "$KEY_A" changed
eqv "$changed" 1 'first pair install reports changed'
ok cert_validate_pair_files "$(cert_fullchain example.com)" "$(cert_privkey example.com)"
changed=''
ok _cert_replace_pair example.com "$CERT_A" "$KEY_A" changed
eqv "$changed" 0 'identical pair reports unchanged'

# 4. Invalid replacement cannot destroy a good managed pair.
before_cert=$(openssl x509 -in "$(cert_fullchain example.com)" -noout -serial)
bad _cert_replace_pair example.com "$CERT_B" "$KEY_A" changed
after_cert=$(openssl x509 -in "$(cert_fullchain example.com)" -noout -serial)
eqv "$after_cert" "$before_cert" 'mismatched replacement leaves old cert intact'

# 5. Pre-planted symlink managed target is rejected and target untouched.
mkdir -p "${PROXYCTL_CERTS}/symlink-test"
SENSITIVE="${ROOT}/sensitive"
printf 'do-not-touch\n' >"$SENSITIVE"
ln -s "$SENSITIVE" "${PROXYCTL_CERTS}/symlink-test/fullchain.pem"
bad _cert_replace_pair symlink-test "$CERT_A" "$KEY_A" changed
eqv "$(cat "$SENSITIVE")" 'do-not-touch' 'symlink target remains untouched'

# 6. Certificate metadata keeps identifier distinct from Certbot certName and
# preserves false instead of treating it as a missing jq value.
ok metadata_cert_set 'example.com' 'example.com' 'example.com-0002' letsencrypt http-standalone true
eqv "$(metadata_cert_get_field example.com certName)" 'example.com-0002' 'metadata preserves distinct certName'
eqv "$(metadata_cert_get_field example.com autoRenew)" 'true' 'metadata stores autoRenew=true'
ok metadata_cert_set 'manual.example.com' 'manual.example.com' 'manual.example.com' letsencrypt dns-manual false
eqv "$(metadata_cert_get_field manual.example.com autoRenew)" 'false' 'metadata preserves autoRenew=false'
has "$(metadata_cert_list)" 'example.com' 'certificate appears in metadata list'

# 7. Cloudflare credentials are atomic/private and do not leak umask changes.
before_umask=$(umask)
ok cert_save_cloudflare_credentials 'user@example.com' 'secret-key'
eqv "$(stat -c '%a' "$PROXYCTL_CLOUDFLARE_INI")" '600' 'Cloudflare credential mode is 600'
eqv "$(umask)" "$before_umask" 'credential write preserves caller umask'
ok cert_cloudflare_credentials_available

# 8. Port 80 owner mapping uses shared port_process output.
port_process() { return 1; }
eqv "$(cert_detect_port80_owner)" free 'free port 80 detected'
port_process() { printf '101 xray\n'; }
eqv "$(cert_detect_port80_owner)" xray 'Xray port owner detected'
port_process() { printf '102 sing-box\n'; }
eqv "$(cert_detect_port80_owner)" singbox 'sing-box port owner detected'
port_process() { printf '103 nginx\n'; }
eqv "$(cert_detect_port80_owner)" nginx 'nginx port owner detected'
port_process() { printf '104 apache2\n'; }
eqv "$(cert_detect_port80_owner)" apache 'Apache port owner detected'
port_process() { printf '105 caddy\n'; }
eqv "$(cert_detect_port80_owner)" other 'unknown server maps to other'

# 9. HTTP validation temporarily stops/restores either managed engine only.
CALLS="${ROOT}/engine-calls"
: >"$CALLS"
engine_call() {
    local engine="$1" method="$2"
    printf '%s:%s\n' "$engine" "$method" >>"$CALLS"
    case "$method" in
        is_active|stop|start|restart) return 0 ;;
        service_name) printf '%s\n' "$engine" ;;
        *) return 1 ;;
    esac
}
certbot_cmd() { printf 'certbot:%s\n' "$*" >>"$CALLS"; return 0; }
cert_detect_port80_owner() { printf '%s\n' xray; }
ok _cert_issue_domain_http example.com user@example.com 0
has "$(cat "$CALLS")" 'xray:stop' 'HTTP validation stops Xray when it owns port 80'
has "$(cat "$CALLS")" 'xray:start' 'HTTP validation restores Xray'
: >"$CALLS"
cert_detect_port80_owner() { printf '%s\n' singbox; }
ok _cert_issue_domain_http example.com user@example.com 0
has "$(cat "$CALLS")" 'singbox:stop' 'HTTP validation stops sing-box when it owns port 80'
has "$(cat "$CALLS")" 'singbox:start' 'HTTP validation restores sing-box'

# 10. Certbot command is always isolated from system /etc/letsencrypt.
mkdir -p "${PROXYCTL_CERTBOT_VENV}/bin"
CERTBOT_LOG="${ROOT}/certbot-argv"
cat >"${PROXYCTL_CERTBOT_VENV}/bin/certbot" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >"${CERTBOT_TEST_LOG}"
EOF
chmod +x "${PROXYCTL_CERTBOT_VENV}/bin/certbot"
export CERTBOT_TEST_LOG="$CERTBOT_LOG"
unset -f certbot_cmd
source "${PROJECT_DIR}/lib/common/certificate.sh"
certbot_cmd certificates
argv=$(cat "$CERTBOT_LOG")
has "$argv" "--config-dir ${PROXYCTL_CERTBOT_CONFIG}" 'Certbot uses ProxyCTL config dir'
has "$argv" "--work-dir ${PROXYCTL_CERTBOT_WORK}" 'Certbot uses ProxyCTL work dir'
has "$argv" "--logs-dir ${PROXYCTL_CERTBOT_LOGS}" 'Certbot uses ProxyCTL logs dir'

# Restore test overrides after re-source.
_cert_require_root() { return 0; }
_cert_setup_runtime_access() { mkdir -p "$PROXYCTL_CERTS"; chmod 700 "$PROXYCTL_CERTS"; }
_cert_prepare_directory() { local dir; dir=$(cert_dir "$1") || return 1; [[ ! -L "$dir" ]] || return 1; mkdir -p "$dir"; chmod 700 "$dir"; }

# 11. A shared cert referenced by both configs restarts both active engines.
XRAY_CFG="${ROOT}/xray.json"
SING_CFG="${ROOT}/sing.json"
printf '{"cert":"%s"}\n' "$(cert_fullchain example.com)" >"$XRAY_CFG"
printf '{"key":"%s"}\n' "$(cert_privkey example.com)" >"$SING_CFG"
: >"$CALLS"
engine_call() {
    local engine="$1" method="$2"
    printf '%s:%s\n' "$engine" "$method" >>"$CALLS"
    case "$method" in
        config_file) [[ "$engine" == xray ]] && printf '%s\n' "$XRAY_CFG" || printf '%s\n' "$SING_CFG" ;;
        is_active|restart) return 0 ;;
        *) return 1 ;;
    esac
}
ok _cert_restart_consumers_if_changed example.com 1
has "$(cat "$CALLS")" 'xray:restart' 'shared certificate change restarts Xray consumer'
has "$(cat "$CALLS")" 'singbox:restart' 'shared certificate change restarts sing-box consumer'

# 12. Certificate deletion refuses a certificate still referenced by an engine.
ok metadata_cert_set example.com example.com example.com imported imported false
bad _cert_delete_locked example.com
ok metadata_cert_exists example.com

# 13. ACME HTTP metadata and issuance consume one owner observation. A mocked
# owner sequence would expose the old double-detection bug; the issue helper
# must receive the exact owner selected by _cert_acme_issue_locked.
OWNER_LOG="${ROOT}/owner-log"
META_LOG="${ROOT}/meta-log"
cert_exists() { return 1; }
cert_ensure_certbot_environment() { return 0; }
cert_detect_port80_owner() { printf '%s\n' nginx; }
_cert_issue_domain_http() { printf '%s\n' "${4:-missing}" >"$OWNER_LOG"; return 0; }
_cert_sync_lineage() { [[ -z "${3:-}" ]] || printf -v "$3" '%s' 0; return 0; }
cert_setup_renewal_timer() { return 0; }
_cert_restart_consumers_if_changed() { return 0; }
metadata_cert_set() { printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$@" >"$META_LOG"; return 0; }
ok _cert_acme_issue_locked example.com user@example.com http 0
eqv "$(cat "$OWNER_LOG")" nginx 'HTTP issue helper receives the original owner snapshot'
has "$(cat "$META_LOG")" $'letsencrypt\thttp-nginx\ttrue' 'metadata matches the actual nginx issuance branch'

# Restore real metadata helpers before the final lock test.
source "${PROJECT_DIR}/lib/metadata.sh"
_cert_require_root() { return 0; }

# 14. Real cert-lock contention blocks mutating certificate operations.
export CERT_READY="${ROOT}/cert-ready"
export CERT_RELEASE="${ROOT}/cert-release"
rm -f "$CERT_READY" "$CERT_RELEASE"
bash -c "source '${PROJECT_DIR}/lib/ui.sh'; source '${PROJECT_DIR}/lib/common/lock.sh'; lock_acquire cert || exit 10; touch \"\${CERT_READY}\"; while [[ ! -f \"\${CERT_RELEASE}\" ]]; do sleep 0.05; done; lock_release cert" &
holder=$!
i=0
while [[ ! -f "$CERT_READY" && $i -lt 200 ]]; do sleep 0.05; i=$((i+1)); done
[[ -f "$CERT_READY" ]] && pass 'certificate lock holder acquired lock' || fail 'certificate lock holder failed'
set +e
out=$(cert_save_cloudflare_credentials user@example.com other-key 2>&1)
rc=$?
set -e
[[ $rc -ne 0 ]] && pass 'mutating cert operation fails under cert-lock contention' || fail 'cert operation must fail under contention'
has "$out" 'Another ProxyCTL certificate operation is already running.' 'cert-lock contention reports busy message'
touch "$CERT_RELEASE"
wait "$holder"

printf '\nCertificate tests: %d passed, %d failed\n' "$PASSED" "$FAILED"
(( FAILED == 0 ))
