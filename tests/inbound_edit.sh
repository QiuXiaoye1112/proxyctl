#!/usr/bin/env bash
# ------------------------------------------------------------------------------
# tests/inbound_edit.sh — safe listen edits + cross-engine user rename
# ------------------------------------------------------------------------------
set -o errexit
set -o nounset
set -o pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
command -v jq >/dev/null 2>&1 || { echo 'requires jq' >&2; exit 2; }

ROOT=$(mktemp -d)
trap 'rm -rf "$ROOT"' EXIT
export PROXYCTL_DATA="$ROOT/data"
export PROXYCTL_META="$PROXYCTL_DATA/meta.json"
export XRAY_CONFIG="$ROOT/xray.json"
export SINGBOX_CONFIG="$ROOT/singbox.json"

source "$PROJECT_DIR/lib/ui.sh"
source "$PROJECT_DIR/lib/core.sh"
source "$PROJECT_DIR/lib/metadata.sh"
source "$PROJECT_DIR/lib/common/network.sh"
source "$PROJECT_DIR/lib/common/port.sh"
source "$PROJECT_DIR/lib/xray/engine.sh"
source "$PROJECT_DIR/lib/singbox/engine.sh"
source "$PROJECT_DIR/lib/inbound.sh"
source "$PROJECT_DIR/lib/inbound_edit.sh"
source "$PROJECT_DIR/lib/xray/inbound.sh"
source "$PROJECT_DIR/lib/singbox/inbound.sh"
source "$PROJECT_DIR/lib/singbox/clients.sh"
source "$PROJECT_DIR/lib/client_rename.sh"

cat >"$XRAY_CONFIG" <<'JSON'
{"inbounds":[{"tag":"x","listen":"127.0.0.1","port":41001,"protocol":"vless","settings":{"clients":[{"email":"alice","id":"11111111-1111-4111-8111-111111111111"}],"decryption":"none"},"streamSettings":{"method":"raw","security":"none","rawSettings":{"header":{"type":"none"}}}}],"outbounds":[{"protocol":"freedom","tag":"direct"}]}
JSON
cat >"$SINGBOX_CONFIG" <<'JSON'
{"inbounds":[{"type":"vless","tag":"s","listen":"127.0.0.1","listen_port":42001,"users":[{"name":"alice","uuid":"11111111-1111-4111-8111-111111111111","flow":""}]}],"outbounds":[{"type":"direct","tag":"direct"}]}
JSON
metadata_init >/dev/null
inbound_meta_set xray x node.example '' '' >/dev/null
inbound_meta_set singbox s sb.example '' '' >/dev/null

engine_xray_installed(){ return 0; }
engine_singbox_installed(){ return 0; }
engine_xray_config_file(){ printf '%s\n' "$XRAY_CONFIG"; }
engine_singbox_config_file(){ printf '%s\n' "$SINGBOX_CONFIG"; }
POST_RC=0
engine_singbox_inbound_post_change(){ return "$POST_RC"; }
apply_candidate(){ cp "$2" "$(engine_call "$1" config_file)"; }

PASS=0; FAIL=0
pass(){ echo "  PASS: $*"; ((++PASS)); }
fail(){ echo "  FAIL: $*" >&2; ((++FAIL)); }
ok(){ if "$@"; then pass "$*"; else fail "$*"; fi; }
bad(){ if "$@" >/dev/null 2>&1; then fail "$*"; else pass "$*"; fi; }
eqv(){ [[ "$1" == "$2" ]] && pass "$3" || fail "$3 — expected '$2', got '$1'"; }

printf '\nInbound edit tests\n\n'

ok inbound_modify_listen xray x 0.0.0.0 41002 new.example
eqv "$(jq -r '.inbounds[0].listen' "$XRAY_CONFIG")" 0.0.0.0 'Xray listen address changes'
eqv "$(jq -r '.inbounds[0].port' "$XRAY_CONFIG")" 41002 'Xray listen port changes'
eqv "$(inbound_meta_get xray x clientHost)" new.example 'Xray client host metadata changes'

ok inbound_modify_listen singbox s ::1 42002 sb-new.example
eqv "$(jq -r '.inbounds[0].listen' "$SINGBOX_CONFIG")" ::1 'sing-box listen address changes'
eqv "$(jq -r '.inbounds[0].listen_port' "$SINGBOX_CONFIG")" 42002 'sing-box listen port changes'
eqv "$(inbound_meta_get singbox s clientHost)" sb-new.example 'sing-box client host metadata changes'

# Runtime synchronization failure must restore the old config.
POST_RC=1
before=$(jq -c . "$SINGBOX_CONFIG")
bad inbound_modify_listen singbox s 127.0.0.1 42003 should-not-stick.example
eqv "$(jq -c . "$SINGBOX_CONFIG")" "$before" 'failed runtime sync rolls config back'
eqv "$(inbound_meta_get singbox s clientHost)" sb-new.example 'failed runtime sync leaves metadata unchanged'
POST_RC=0

# User rename keeps credentials and rejects collisions/missing users.
ok inbound_client_rename xray x alice bob
eqv "$(jq -r '.inbounds[0].settings.clients[0].email' "$XRAY_CONFIG")" bob 'Xray user name changes'
eqv "$(jq -r '.inbounds[0].settings.clients[0].id' "$XRAY_CONFIG")" '11111111-1111-4111-8111-111111111111' 'Xray rename preserves UUID'
bad inbound_client_rename xray x missing nobody

ok inbound_client_rename singbox s alice bob
eqv "$(jq -r '.inbounds[0].users[0].name' "$SINGBOX_CONFIG")" bob 'sing-box user name changes'
eqv "$(jq -r '.inbounds[0].users[0].uuid' "$SINGBOX_CONFIG")" '11111111-1111-4111-8111-111111111111' 'sing-box rename preserves UUID'
bad inbound_client_rename singbox s missing nobody

printf '\nInbound edit tests: %d passed, %d failed\n' "$PASS" "$FAIL"
((FAIL == 0))
