#!/usr/bin/env bash
# ------------------------------------------------------------------------------
# tests/engine_lifecycle.sh — Phase 3 core lifecycle adapter coverage
# ------------------------------------------------------------------------------
set -o errexit
set -o nounset
set -o pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
ROOT=$(mktemp -d)
trap 'rm -rf "$ROOT"' EXIT
mkdir -p "$ROOT/bin" "$ROOT/systemd" "$ROOT/openrc" "$ROOT/xray" "$ROOT/singbox"
export PATH="$ROOT/bin:$PATH"
export XRAY_CONFIG="$ROOT/xray/config.json"
export SINGBOX_CONFIG="$ROOT/singbox/config.json"
export PROXYCTL_SYSTEMD_UNIT_DIR="$ROOT/systemd"
export PROXYCTL_OPENRC_INIT_DIR="$ROOT/openrc"
export PROXYCTL_XRAY_LOG_DIR="$ROOT/xray-log"
export PROXYCTL_SINGBOX_DATA="$ROOT/singbox-data"
export PROXYCTL_CERTS="$ROOT/certs"
export PROXYCTL_CERT_GROUP="$(id -gn)"

source "$PROJECT_DIR/lib/ui.sh"
source "$PROJECT_DIR/lib/core.sh"
source "$PROJECT_DIR/lib/common/system.sh"
source "$PROJECT_DIR/lib/common/service.sh"
source "$PROJECT_DIR/lib/xray/engine.sh"
source "$PROJECT_DIR/lib/singbox/engine.sh"

PASS=0; FAIL=0
pass(){ echo "  PASS: $*"; ((++PASS)); }
fail(){ echo "  FAIL: $*" >&2; ((++FAIL)); }
ok(){ if "$@"; then pass "$*"; else fail "$*"; fi; }
bad(){ if "$@" >/dev/null 2>&1; then fail "$*"; else pass "$*"; fi; }
eqv(){ [[ "$1" == "$2" ]] && pass "$3" || fail "$3 — expected '$2', got '$1'"; }
contains(){ [[ "$1" == *"$2"* ]] && pass "$3" || fail "$3 — missing '$2'"; }

cat >"$ROOT/bin/xray" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  version) echo 'Xray 26.7.11 test' ;;
  run) exit 0 ;;
  *) exit 0 ;;
esac
SH
chmod +x "$ROOT/bin/xray"
cat >"$ROOT/bin/sing-box" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  version) echo 'sing-box version 1.13.12' ;;
  check) exit 0 ;;
  *) exit 0 ;;
esac
SH
chmod +x "$ROOT/bin/sing-box"

system_is_root(){ return 0; }
systemctl(){ return 0; }
rc-update(){ return 0; }
service_start(){ return 0; }
service_stop(){ return 0; }
service_restart(){ return 0; }
service_enable(){ return 0; }
service_disable(){ return 0; }
service_is_active(){ return 1; }
_cert_setup_runtime_access(){ mkdir -p "$PROXYCTL_CERTS"; return 0; }
cert_runtime_group(){ printf '%s\n' "$PROXYCTL_CERT_GROUP"; }
chown(){ return 0; }

printf '\nCore lifecycle adapter tests\n\n'

ok _engine_xray_write_default_config
eqv "$(jq -r '.inbounds|length' "$XRAY_CONFIG")" 0 'Xray fresh config starts without inbounds'
eqv "$(jq -r '.outbounds[0].protocol' "$XRAY_CONFIG")" freedom 'Xray fresh config contains direct outbound'
ok _engine_xray_prepare_config_access
mode=$(stat -c '%a' "$XRAY_CONFIG" 2>/dev/null || stat -f '%Lp' "$XRAY_CONFIG")
eqv "$mode" 640 'Xray config is group-readable but not world-readable'

ok _engine_singbox_write_default_config
eqv "$(jq -r '.inbounds|length' "$SINGBOX_CONFIG")" 0 'sing-box fresh config starts without inbounds'
eqv "$(jq -r '.outbounds[0].type' "$SINGBOX_CONFIG")" direct 'sing-box fresh config contains direct outbound'

for pair in 'amd64:Xray-linux-64.zip' 'arm64:Xray-linux-arm64-v8a.zip' 'armv7:Xray-linux-arm32-v7a.zip' '386:Xray-linux-32.zip'; do
    arch=${pair%%:*}; expected=${pair#*:}
    system_arch(){ printf '%s\n' "$arch"; }
    eqv "$(_engine_xray_openrc_asset)" "$expected" "Xray OpenRC asset mapping: ${arch}"
done

ok _engine_singbox_version_ge 1.12.0 1.12.0
ok _engine_singbox_version_ge 1.13.12 1.12.0
bad _engine_singbox_version_ge 1.11.9 1.12.0

system_init(){ printf '%s\n' systemd; }
ok _engine_singbox_write_service
contains "$(cat "$PROXYCTL_SYSTEMD_UNIT_DIR/sing-box.service")" 'managed by ProxyCTL' 'sing-box systemd unit has ownership marker'
contains "$(cat "$PROXYCTL_SYSTEMD_UNIT_DIR/sing-box.service")" "$SINGBOX_CONFIG" 'sing-box systemd unit uses configured path'

system_init(){ printf '%s\n' openrc; }
ok _engine_singbox_write_service
contains "$(cat "$PROXYCTL_OPENRC_INIT_DIR/sing-box")" 'openrc-run' 'sing-box OpenRC service generated'
contains "$(cat "$PROXYCTL_OPENRC_INIT_DIR/sing-box")" "$SINGBOX_CONFIG" 'sing-box OpenRC service uses configured path'
ok _engine_xray_write_openrc_service
contains "$(cat "$PROXYCTL_OPENRC_INIT_DIR/xray")" 'managed by ProxyCTL' 'Xray OpenRC service has ownership marker'
contains "$(cat "$PROXYCTL_OPENRC_INIT_DIR/xray")" "$XRAY_CONFIG" 'Xray OpenRC service uses configured path'
contains "$(cat "$PROXYCTL_OPENRC_INIT_DIR/xray")" "$PROXYCTL_XRAY_LOG_DIR" 'Xray OpenRC service uses configured log directory'

# Root checks fail before any network/package mutation.
system_is_root(){ return 1; }
bad engine_xray_install
bad engine_singbox_install
system_is_root(){ return 0; }

# Verify official installer argument contracts without network access.
XRAY_ARGS="$ROOT/xray-installer.args"
_engine_xray_download_installer(){
    cat >"$1" <<SH
#!/usr/bin/env bash
printf '%s\\n' "\$*" > "$XRAY_ARGS"
SH
}
system_init(){ printf '%s\n' systemd; }
rm -f "$XRAY_CONFIG"
ok engine_xray_install 26.7.11
contains "$(cat "$XRAY_ARGS")" 'install --version 26.7.11' 'Xray exact-version installer arguments'
[[ -f "$XRAY_CONFIG" ]] && pass 'Xray install initializes missing config' || fail 'Xray install initializes missing config'

SB_ARGS="$ROOT/singbox-installer.args"
system_package_manager(){ printf '%s\n' apt; }
curl(){
    local dest='' prev='' arg
    for arg in "$@"; do
        if [[ "$prev" == -o ]]; then dest="$arg"; break; fi
        prev="$arg"
    done
    [[ -n "$dest" ]] || return 1
    cat >"$dest" <<SH
#!/usr/bin/env bash
printf '%s\\n' "\$*" > "$SB_ARGS"
SH
}
rm -f "$SINGBOX_CONFIG"
ok engine_singbox_install 1.13.12
contains "$(cat "$SB_ARGS")" '--version 1.13.12' 'sing-box exact-version installer arguments'
[[ -f "$SINGBOX_CONFIG" ]] && pass 'sing-box install initializes missing config' || fail 'sing-box install initializes missing config'

# Removing the core must leave manager-owned config untouched.
package_remove(){ printf '%s\n' "$*" >"$ROOT/package-remove"; return 0; }
system_init(){ printf '%s\n' systemd; }
printf 'keep-xray\n' >"$XRAY_CONFIG.keep"
printf 'keep-singbox\n' >"$SINGBOX_CONFIG.keep"
ok engine_singbox_uninstall
[[ -f "$SINGBOX_CONFIG" ]] && pass 'sing-box uninstall preserves config' || fail 'sing-box uninstall preserves config'
contains "$(cat "$ROOT/package-remove")" 'sing-box' 'sing-box uninstall delegates package removal'

printf '\nEngine lifecycle tests: %d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
