#!/usr/bin/env bash
set -o errexit
set -o nounset
set -o pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
source "${PROJECT_DIR}/lib/ui.sh"
source "${PROJECT_DIR}/lib/core.sh"
source "${PROJECT_DIR}/lib/transaction.sh"
source "${PROJECT_DIR}/lib/common/lock.sh"
source "${PROJECT_DIR}/lib/xray/engine.sh"
source "${PROJECT_DIR}/lib/singbox/engine.sh"

PASSED=0
FAILED=0
pass(){ echo "  PASS: $*"; ((++PASSED)); }
fail(){ echo "  FAIL: $*" >&2; ((++FAILED)); }
eqv(){ [[ "$1" == "$2" ]] && pass "$3" || fail "$3 — expected '$2', got '$1'"; }
has(){ [[ "$1" == *"$2"* ]] && pass "$3" || fail "$3 — missing '$2'"; }
ok(){ if "$@"; then pass "$*"; else fail "$*"; fi; }
bad(){ if "$@"; then fail "$*"; else pass "$*"; fi; }

ROOT=$(mktemp -d)
trap 'rm -rf "${ROOT}"' EXIT
mkdir -m 700 -p "${ROOT}/xray" "${ROOT}/locks"
export PROXYCTL_DATA="${ROOT}/data"
export PROXYCTL_LOCK="${ROOT}/locks/config.lock"
export PROXYCTL_CERT_LOCK="${ROOT}/locks/cert.lock"
export PROXYCTL_FIREWALL_LOCK="${ROOT}/locks/firewall.lock"
CONFIG="${ROOT}/xray/config.json"
CAND="${ROOT}/candidate.json"
LOG="${ROOT}/calls.log"

TXN_CONFIG_FILE="$CONFIG"
TXN_VALIDATE_RC=0
TXN_WAS_ACTIVE_RC=0
TXN_NEW_HEALTH_RC=0
TXN_ROLLBACK_HEALTH_RC=0
TXN_RESTART1_RC=0
TXN_RESTART2_RC=0
TXN_IS_ACTIVE_CALLS=0
TXN_RESTART_CALLS=0
TXN_MUTATE=''
TXN_VALIDATE_OUTPUT=''

reset_mock(){
  : > "$LOG"
  TXN_CONFIG_FILE="$CONFIG"
  TXN_VALIDATE_RC=0
  TXN_WAS_ACTIVE_RC=0
  TXN_NEW_HEALTH_RC=0
  TXN_ROLLBACK_HEALTH_RC=0
  TXN_RESTART1_RC=0
  TXN_RESTART2_RC=0
  TXN_IS_ACTIVE_CALLS=0
  TXN_RESTART_CALLS=0
  TXN_MUTATE=''
  TXN_VALIDATE_OUTPUT=''
}
reset_case(){
  rm -rf "${PROXYCTL_DATA}/transactions"
  rm -f "$CONFIG" "${ROOT}/candidate-link.json"
  printf '%s\n' '{"version":"old"}' > "$CONFIG"
  chmod 600 "$CONFIG"
  printf '%s\n' '{"version":"new"}' > "$CAND"
  reset_mock
}
tx_count(){
  [[ -d "${PROXYCTL_DATA}/transactions" ]] || { echo 0; return; }
  find "${PROXYCTL_DATA}/transactions" -mindepth 1 -maxdepth 1 -type d -name 'tx_*' | wc -l | tr -d ' '
}
tx_first(){ find "${PROXYCTL_DATA}/transactions" -mindepth 1 -maxdepth 1 -type d -name 'tx_*' | head -1; }
called(){ grep -qxF "$1" "$LOG"; }

engine_call(){
  local engine="$1" method="$2"
  printf '%s\n' "${engine}:${method}" >> "$LOG"
  case "$method" in
    config_file) printf '%s\n' "$TXN_CONFIG_FILE" ;;
    validate)
      [[ -z "$TXN_VALIDATE_OUTPUT" ]] || printf '%s\n' "$TXN_VALIDATE_OUTPUT"
      [[ -z "$TXN_MUTATE" ]] || printf '%s\n' '{"version":"mutated-after-validation"}' > "$TXN_MUTATE"
      return "$TXN_VALIDATE_RC" ;;
    restart)
      TXN_RESTART_CALLS=$((TXN_RESTART_CALLS+1))
      (( TXN_RESTART_CALLS == 1 )) && return "$TXN_RESTART1_RC"
      return "$TXN_RESTART2_RC" ;;
    is_active)
      TXN_IS_ACTIVE_CALLS=$((TXN_IS_ACTIVE_CALLS+1))
      (( TXN_IS_ACTIVE_CALLS == 1 )) && return "$TXN_WAS_ACTIVE_RC"
      (( TXN_RESTART_CALLS >= 2 )) && return "$TXN_ROLLBACK_HEALTH_RC"
      return "$TXN_NEW_HEALTH_RC" ;;
    *) return 1 ;;
  esac
}

printf '\nProxyCTL Phase 2.5 Transaction Tests\n'

reset_case
TXN_VALIDATE_OUTPUT='diagnostic'
set +e; out=$(apply_candidate xray "$CAND" 2>/dev/null); rc=$?; set -e
eqv "$rc" 0 'active apply succeeds'
eqv "$out" '' 'validation diagnostics stay off stdout'
has "$(cat "$CONFIG")" '"version":"new"' 'new config applied'
eqv "$(tx_count)" 0 'success cleans transaction'

reset_case
TXN_VALIDATE_RC=1
before=$(cat "$CONFIG")
bad apply_candidate xray "$CAND" 'validation failure rejected'
eqv "$(cat "$CONFIG")" "$before" 'validation failure leaves config untouched'
if called 'xray:restart'; then fail 'restart called after validation failure'; else pass 'restart skipped after validation failure'; fi

reset_case
TXN_MUTATE="$CAND"
ok apply_candidate xray "$CAND" 'snapshot apply succeeds after source mutation'
has "$(cat "$CONFIG")" '"version":"new"' 'validated snapshot is what gets applied'
has "$(cat "$CAND")" 'mutated-after-validation' 'source mutation really occurred'

reset_case
TXN_RESTART1_RC=1
bad apply_candidate xray "$CAND" 'restart failure triggers rollback'
has "$(cat "$CONFIG")" '"version":"old"' 'restart rollback restores old config'
eqv "$(tx_count)" 0 'successful rollback cleans transaction'

reset_case
TXN_NEW_HEALTH_RC=1
TXN_ROLLBACK_HEALTH_RC=0
bad apply_candidate xray "$CAND" 'new health failure triggers rollback'
has "$(cat "$CONFIG")" '"version":"old"' 'healthy rollback restores old config'
eqv "$(tx_count)" 0 'healthy rollback cleans transaction'

reset_case
TXN_RESTART1_RC=1
TXN_RESTART2_RC=1
set +e; out=$(apply_candidate xray "$CAND" 2>&1); rc=$?; set -e
[[ $rc -ne 0 ]] && pass 'rollback service failure is nonzero' || fail 'rollback service failure must be nonzero'
has "$out" '[CRITICAL]' 'rollback service failure is critical'
has "$out" 'Transaction preserved at:' 'failed rollback reports preserved transaction'
preserved=$(tx_first)
[[ -f "$preserved/old-config" ]] && pass 'old-config preserved after service rollback failure' || fail 'old-config backup missing'
rm -rf "${PROXYCTL_DATA}/transactions"

reset_case
TXN_RESTART1_RC=1
export PROXYCTL_TEST_FAIL_ROLLBACK_RESTORE=1
set +e; out=$(apply_candidate xray "$CAND" 2>&1); rc=$?; set -e
unset PROXYCTL_TEST_FAIL_ROLLBACK_RESTORE
[[ $rc -ne 0 ]] && pass 'rollback restore failure is nonzero' || fail 'rollback restore failure must be nonzero'
has "$out" '[CRITICAL]' 'rollback restore failure is critical'
has "$out" 'Transaction preserved at:' 'restore failure preserves transaction'
preserved=$(tx_first)
[[ -f "$preserved/old-config" ]] && pass 'old-config survives failed restore' || fail 'old-config lost after failed restore'
has "$(cat "$preserved/old-config")" '"version":"old"' 'preserved backup contains old config'
has "$(cat "$CONFIG")" '"version":"new"' 'failed restore leaves applied config for manual recovery'
rm -rf "${PROXYCTL_DATA}/transactions"

reset_case
rm -f "$CONFIG"
TXN_RESTART1_RC=1
bad apply_candidate xray "$CAND" 'no-old-config restart failure rolls back'
[[ ! -e "$CONFIG" ]] && pass 'new config removed when no old config existed' || fail 'new config remained after rollback'

reset_case
TXN_WAS_ACTIVE_RC=1
ok apply_candidate xray "$CAND" 'inactive service apply succeeds'
if called 'xray:restart'; then fail 'inactive service restarted'; else pass 'inactive service left stopped'; fi

reset_case
before=$(cat "$CONFIG")
export PROXYCTL_TEST_FAIL_ATOMIC_COPY=1
bad apply_candidate xray "$CAND" 'atomic copy failure rejected'
unset PROXYCTL_TEST_FAIL_ATOMIC_COPY
eqv "$(cat "$CONFIG")" "$before" 'atomic copy failure leaves old config untouched'

reset_case
chmod 640 "$CONFIG"
ok apply_candidate xray "$CAND" 'mode-preservation apply succeeds'
eqv "$(stat -c '%a' "$CONFIG")" 640 'old mode preserved'

reset_case
ln -s "$CAND" "${ROOT}/candidate-link.json"
bad apply_candidate xray "${ROOT}/candidate-link.json" 'symlink candidate rejected'
bad apply_candidate nonexistent "$CAND" 'unknown engine rejected'
rm -f "$CONFIG"
ln -s "$CAND" "$CONFIG"
bad apply_candidate xray "$CAND" 'symlink formal config rejected'

# reset_case explicitly removes the prior symlink before contention coverage.
reset_case
export TXN_READY="${ROOT}/ready"
export TXN_RELEASE="${ROOT}/release"
rm -f "$TXN_READY" "$TXN_RELEASE"
bash -c "source '${PROJECT_DIR}/lib/ui.sh'; source '${PROJECT_DIR}/lib/common/lock.sh'; lock_acquire config || exit 10; touch \"\${TXN_READY}\"; while [[ ! -f \"\${TXN_RELEASE}\" ]]; do sleep 0.05; done; lock_release config" &
holder=$!
i=0
while [[ ! -f "$TXN_READY" && $i -lt 200 ]]; do sleep 0.05; i=$((i+1)); done
[[ -f "$TXN_READY" ]] && pass 'contention holder acquired lock' || fail 'contention holder failed'
set +e; out=$(apply_candidate xray "$CAND" 2>&1); rc=$?; set -e
[[ $rc -ne 0 ]] && pass 'apply fails under config lock contention' || fail 'contended apply must fail'
has "$out" 'Another ProxyCTL config operation is already running.' 'contention busy message'
has "$(cat "$CONFIG")" '"version":"old"' 'contention leaves config untouched'
touch "$TXN_RELEASE"
wait "$holder"

reset_case
MOCK_BIN="${ROOT}/mock-bin"
EMPTY_BIN="${ROOT}/empty-bin"
mkdir "$MOCK_BIN" "$EMPTY_BIN"
ENGINE_LOG="${ROOT}/engine.log"
export TXN_ENGINE_LOG="$ENGINE_LOG"
cat > "$MOCK_BIN/xray" <<'EOF'
#!/usr/bin/env bash
printf 'xray %s\n' "$*" >> "$TXN_ENGINE_LOG"
exit "${TXN_XRAY_RC:-0}"
EOF
cat > "$MOCK_BIN/sing-box" <<'EOF'
#!/usr/bin/env bash
printf 'sing-box %s\n' "$*" >> "$TXN_ENGINE_LOG"
exit "${TXN_SINGBOX_RC:-0}"
EOF
chmod +x "$MOCK_BIN/xray" "$MOCK_BIN/sing-box"
( PATH="$MOCK_BIN:$PATH"; engine_xray_validate "$CAND" ) && pass 'xray validator mock succeeds' || fail 'xray validator failed'
( PATH="$MOCK_BIN:$PATH"; engine_singbox_validate "$CAND" ) && pass 'sing-box validator mock succeeds' || fail 'sing-box validator failed'
grep -qxF "xray run -test -config $CAND" "$ENGINE_LOG" && pass 'xray CLI exact' || fail 'xray CLI wrong'
grep -qxF "sing-box check -c $CAND" "$ENGINE_LOG" && pass 'sing-box CLI exact' || fail 'sing-box CLI wrong'
if ( export TXN_XRAY_RC=1; PATH="$MOCK_BIN:$PATH"; engine_xray_validate "$CAND" >/dev/null 2>&1 ); then fail 'xray core failure accepted'; else pass 'xray core failure rejected'; fi
if ( PATH="$EMPTY_BIN"; engine_xray_validate "$CAND" >/dev/null 2>&1 ); then fail 'missing xray accepted'; else pass 'missing xray fails closed'; fi
if ( PATH="$EMPTY_BIN"; engine_singbox_validate "$CAND" >/dev/null 2>&1 ); then fail 'missing sing-box accepted'; else pass 'missing sing-box fails closed'; fi

printf '\nTransaction tests: %d passed, %d failed\n' "$PASSED" "$FAILED"
(( FAILED == 0 ))
