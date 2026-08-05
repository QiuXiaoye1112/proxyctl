#!/usr/bin/env bash
# ------------------------------------------------------------------------------
# tests/singbox_clients.sh — sing-box duplicate/missing user semantics
# ------------------------------------------------------------------------------
set -o errexit
set -o nounset
set -o pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
command -v jq >/dev/null 2>&1 || { echo 'requires jq' >&2; exit 2; }

ROOT=$(mktemp -d)
trap 'rm -rf "$ROOT"' EXIT
export SINGBOX_CONFIG="$ROOT/config.json"

source "$PROJECT_DIR/lib/ui.sh"
source "$PROJECT_DIR/lib/core.sh"
source "$PROJECT_DIR/lib/common/network.sh"
source "$PROJECT_DIR/lib/common/port.sh"
source "$PROJECT_DIR/lib/singbox/engine.sh"
source "$PROJECT_DIR/lib/inbound.sh"
source "$PROJECT_DIR/lib/singbox/inbound.sh"
source "$PROJECT_DIR/lib/singbox/clients.sh"

cat >"$SINGBOX_CONFIG" <<'JSON'
{
  "inbounds": [
    {
      "type":"vless","tag":"vless","listen":"127.0.0.1","listen_port":40001,
      "users":[{"name":"alice","uuid":"11111111-1111-4111-8111-111111111111","flow":""}],
      "tls":{"enabled":true,"server_name":"test.example","certificate_path":"/tmp/cert","key_path":"/tmp/key"}
    },
    {
      "type":"http","tag":"public-http","listen":"0.0.0.0","listen_port":40002,
      "users":[{"username":"admin","password":"secret"}]
    }
  ],
  "outbounds":[{"type":"direct","tag":"direct"}]
}
JSON

engine_singbox_installed(){ return 0; }
engine_singbox_config_file(){ printf '%s\n' "$SINGBOX_CONFIG"; }
apply_candidate(){ cp "$2" "$SINGBOX_CONFIG"; }

PASS=0; FAIL=0
pass(){ echo "  PASS: $*"; ((++PASS)); }
fail(){ echo "  FAIL: $*" >&2; ((++FAIL)); }
ok(){ if "$@"; then pass "$*"; else fail "$*"; fi; }
bad(){ if "$@" >/dev/null 2>&1; then fail "$*"; else pass "$*"; fi; }
eqv(){ [[ "$1" == "$2" ]] && pass "$3" || fail "$3 — expected '$2', got '$1'"; }

printf '\nsing-box hardened client tests\n\n'

bad engine_singbox_inbound_client_add vless alice 22222222-2222-4222-8222-222222222222
ok engine_singbox_inbound_client_add vless bob 22222222-2222-4222-8222-222222222222
eqv "$(jq '.inbounds[]|select(.tag=="vless")|.users|length' "$SINGBOX_CONFIG")" 2 'new sing-box user is appended exactly once'

bad engine_singbox_inbound_client_rotate vless missing 33333333-3333-4333-8333-333333333333
ok engine_singbox_inbound_client_rotate vless bob 33333333-3333-4333-8333-333333333333
eqv "$(jq -r '.inbounds[]|select(.tag=="vless")|.users[]|select(.name=="bob")|.uuid' "$SINGBOX_CONFIG")" '33333333-3333-4333-8333-333333333333' 'existing sing-box user rotates credential'

bad engine_singbox_inbound_client_delete vless missing
ok engine_singbox_inbound_client_delete vless bob
eqv "$(jq '.inbounds[]|select(.tag=="vless")|.users|length' "$SINGBOX_CONFIG")" 1 'existing sing-box user can be removed'

bad engine_singbox_inbound_client_delete public-http admin
eqv "$(jq '.inbounds[]|select(.tag=="public-http")|.users|length' "$SINGBOX_CONFIG")" 1 'last public HTTP credential is preserved'

printf '\nsing-box client tests: %d passed, %d failed\n' "$PASS" "$FAIL"
((FAIL == 0))
