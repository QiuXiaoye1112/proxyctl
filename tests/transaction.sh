#!/usr/bin/env bash
# ------------------------------------------------------------------------------
# tests/transaction.sh — Phase 2.5 config transaction apply tests
#
# Core/service interaction is mocked through engine_call. Real flock is used
# only for the config-lock contention test. No real proxy core or init service
# is touched.
# ------------------------------------------------------------------------------
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
pass() { echo "  PASS: $*"; ((++PASSED)); }
fail() { echo "  FAIL: $*" >&2; ((++FAILED)); }
assert_eq() { local got="$1" exp="$2"; shift 2 || true; [[ "$got" == "$exp" ]] && pass "$*" || fail "$* — expected '${exp}', got '${got}'"; }
assert_contains() { local got="$1" needle="$2"; shift 2 || true; [[ "$got" == *"$needle"* ]] && pass "$*" || fail "$* — missing '${needle}'"; }
assert_ok() { if "$@"; then pass "$*"; else fail "$*"; fi; }
assert_fail() { if "$@"; then fail "$*"; else pass "$*"; fi; }

file_hash() {
    if command -v sha1sum >/dev/null 2>&1; then
        sha1sum "$1" | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then
        shasum "$1" | awk '{print $1}'
    else
        cksum "$1" | awk '{print $1}'
    fi
}
file_perm() { stat -c '%a' "$1"; }

txn_count() {
    find "${PROXYCTL_DATA}/transactions" -mindepth 1 -maxdepth 1 -type d -name 'tx_*' 2>/dev/null | wc -l | tr -d ' '
}
txn_first() {
    find "${PROXYCTL_DATA}/transactions" -mindepth 1 -maxdepth 1 -type d -name 'tx_*' 2>/dev/null | head -1
}
txn_cleanup_all() {
    rm -rf -- "${PROXYCTL_DATA}/transactions"
}

TXN_ROOT=$(mktemp -d)
trap 'rm -rf "${TXN_ROOT}"' EXIT
XRAY_DIR="${TXN_ROOT}/xray"
LOCK_DIR="${TXN_ROOT}/locks"
mkdir -m 700 -p "${XRAY_DIR}" "${LOCK_DIR}"
export PROXYCTL_DATA="${TXN_ROOT}/data"
export PROXYCTL_LOCK="${LOCK_DIR}/config.lock"
export PROXYCTL_CERT_LOCK="${LOCK_DIR}/cert.lock"
export PROXYCTL_FIREWALL_LOCK="${LOCK_DIR}/firewall.lock"

XRAY_CONFIG_FILE="${XRAY_DIR}/config.json"
CAND_FILE="${TXN_ROOT}/candidate.json"
TXN_CALLS_LOG="${TXN_ROOT}/calls.log"

TXN_CONFIG_FILE=''
TXN_VALIDATE_RC=0
TXN_WAS_ACTIVE_RC=0
TXN_NEW_HEALTH_RC=0
TXN_ROLLBACK_HEALTH_RC=0
TXN_RESTART1_RC=0
TXN_RESTART2_RC=0
TXN_IS_ACTIVE_CALLS=0
TXN_RESTART_CALLS=0
TXN_MUTATE_SOURCE_AFTER_VALIDATE=''
TXN_VALIDATE_OUTPUT=''

txn_mock_reset() {
    : > "${TXN_CALLS_LOG}"
    TXN_CONFIG_FILE="${XRAY_CONFIG_FILE}"
    TXN_VALIDATE_RC=0
    TXN_WAS_ACTIVE_RC=0
    TXN_NEW_HEALTH_RC=0
    TXN_ROLLBACK_HEALTH_RC=0
    TXN_RESTART1_RC=0
    TXN_RESTART2_RC=0
    TXN_IS_ACTIVE_CALLS=0
    TXN_RESTART_CALLS=0
    TXN_MUTATE_SOURCE_AFTER_VALIDATE=''
    TXN_VALIDATE_OUTPUT=''
}

engine_call() {
    local engine="$1" method="$2"
    printf '%s\n' "${engine}:${method}" >> "${TXN_CALLS_LOG}"
    case "$method" in
        config_file)
            printf '%s\n' "${TXN_CONFIG_FILE}"
            ;;
        validate)
            [[ -z "$TXN_VALIDATE_OUTPUT" ]] || printf '%s\n' "$TXN_VALIDATE_OUTPUT"
            if [[ -n "$TXN_MUTATE_SOURCE_AFTER_VALIDATE" ]]; then
                printf '%s\n' '{"version":"mutated-after-validation"}' > "$TXN_MUTATE_SOURCE_AFTER_VALIDATE"
            fi
            return "$TXN_VALIDATE_RC"
            ;;
        is_active)
            TXN_IS_ACTIVE_CALLS=$((TXN_IS_ACTIVE_CALLS + 1))
            if (( TXN_IS_ACTIVE_CALLS == 1 )); then
                return "$TXN_WAS_ACTIVE_RC"
            elif (( TXN_RESTART_CALLS >= 2 )); then
                return "$TXN_ROLLBACK_HEALTH_RC"
            else
                return "$TXN_NEW_HEALTH_RC"
            fi
            ;;
        restart)
            TXN_RESTART_CALLS=$((TXN_RESTART_CALLS + 1))
            if (( TXN_RESTART_CALLS == 1 )); then
                return "$TXN_RESTART1_RC"
            fi
            return "$TXN_RESTART2_RC"
            ;;
        *) return 1 ;;
    esac
}

reset_files() {
    txn_cleanup_all
    printf '%s\n' '{"version":"old"}' > "${XRAY_CONFIG_FILE}"
    chmod 600 "${XRAY_CONFIG_FILE}"
    printf '%s\n' '{"version":"new"}' > "${CAND_FILE}"
    txn_mock_reset
}

calls_contain() { grep -qxF "$1" "${TXN_CALLS_LOG}"; }

printf '\nProxyCTL Phase 2.5 Transaction Tests\n\n'

# 1. Normal active apply.
reset_files
TXN_VALIDATE_OUTPUT='core-validation-diagnostic'
set +e
out=$(apply_candidate xray "${CAND_FILE}" 2>/dev/null)
rc=$?
set -e
assert_eq "$rc" '0' 'active apply succeeds'
assert_eq "$out" '' 'core validation output does not pollute stdout'
assert_contains "$(cat "${XRAY_CONFIG_FILE}")" '"version":"new"' 'new config installed'
assert_eq "$(txn_count)" '0' 'successful transaction cleaned'

# 2. Validation failure leaves formal config untouched.
reset_files
TXN_VALIDATE_RC=1
before=$(file_hash "${XRAY_CONFIG_FILE}")
assert_fail apply_candidate xray "${CAND_FILE}" 'validation failure rejects apply'
assert_eq "$(file_hash "${XRAY_CONFIG_FILE}")" "$before" 'validation failure leaves config untouched'
if calls_contain 'xray:restart'; then fail 'restart called after validation failure'; else pass 'restart not called after validation failure'; fi
assert_eq "$(txn_count)" '0' 'validation-failure transaction cleaned'

# 3. Exact validated snapshot must be the exact applied snapshot.
reset_files
TXN_MUTATE_SOURCE_AFTER_VALIDATE="${CAND_FILE}"
assert_ok apply_candidate xray "${CAND_FILE}" 'apply succeeds while original candidate is mutated after validation'
assert_contains "$(cat "${XRAY_CONFIG_FILE}")" '"version":"new"' 'formal config uses validated snapshot, not mutated source'
assert_contains "$(cat "${CAND_FILE}")" 'mutated-after-validation' 'test actually mutated original candidate'

# 4. Restart failure rolls back old config and old service successfully.
reset_files
TXN_RESTART1_RC=1
TXN_RESTART2_RC=0
TXN_ROLLBACK_HEALTH_RC=0
assert_fail apply_candidate xray "${CAND_FILE}" 'restart failure returns nonzero'
assert_contains "$(cat "${XRAY_CONFIG_FILE}")" '"version":"old"' 'restart failure restores old config'
assert_eq "$(txn_count)" '0' 'successful rollback cleans transaction'

# 5. New-config health failure may still have a healthy rollback.
reset_files
TXN_NEW_HEALTH_RC=1
TXN_RESTART2_RC=0
TXN_ROLLBACK_HEALTH_RC=0
assert_fail apply_candidate xray "${CAND_FILE}" 'new config health failure returns nonzero'
assert_contains "$(cat "${XRAY_CONFIG_FILE}")" '"version":"old"' 'health failure restores old config'
assert_eq "$(txn_count)" '0' 'healthy rollback after health failure cleans transaction'

# 6. Rollback service failure preserves transaction and old-config backup.
reset_files
TXN_RESTART1_RC=1
TXN_RESTART2_RC=1
set +e
out=$(apply_candidate xray "${CAND_FILE}" 2>&1)
rc=$?
set -e
[[ "$rc" -ne 0 ]] && pass 'rollback service failure returns nonzero' || fail 'rollback service failure must return nonzero'
assert_contains "$out" '[CRITICAL]' 'rollback service failure is critical'
assert_contains "$out" 'Transaction preserved at:' 'rollback service failure reports preserved transaction'
preserved=$(txn_first)
[[ -n "$preserved" && -f "${preserved}/old-config" ]] && pass 'old-config backup preserved after rollback service failure' || fail 'old-config backup must be preserved'
assert_contains "$(cat "${XRAY_CONFIG_FILE}")" '"version":"old"' 'old config was restored before service rollback failed'
txn_cleanup_all

# 7. Rollback config-restore failure is critical and preserves recovery data.
reset_files
TXN_RESTART1_RC=1
export PROXYCTL_TEST_FAIL_ROLLBACK_RESTORE=1
set +e
out=$(apply_candidate xray "${CAND_FILE}" 2>&1)
rc=$?
set -e
unset PROXYCTL_TEST_FAIL_ROLLBACK_RESTORE
[[ "$rc" -ne 0 ]] && pass 'rollback restore failure returns nonzero' || fail 'rollback restore failure must return nonzero'
assert_contains "$out" '[CRITICAL]' 'rollback restore failure is critical'
assert_contains "$out" 'Transaction preserved at:' 'rollback restore failure reports preserved transaction'
preserved=$(txn_first)
[[ -n "$preserved" && -f "${preserved}/old-config" ]] && pass 'old-config survives failed restore' || fail 'failed restore must preserve old-config'
assert_contains "$(cat "${preserved}/old-config")" '"version":"old"' 'preserved old-config contains recovery content'
assert_contains "$(cat "${XRAY_CONFIG_FILE}")" '"version":"new"' 'failed restore leaves applied file visible for manual recovery'
txn_cleanup_all

# 8. No previous config: rollback removes newly installed file.
reset_files
rm -f -- "${XRAY_CONFIG_FILE}"
TXN_RESTART1_RC=1
TXN_RESTART2_RC=0
TXN_ROLLBACK_HEALTH_RC=0
assert_fail apply_candidate xray "${CAND_FILE}" 'restart failure with no prior config returns nonzero'
[[ ! -e "${XRAY_CONFIG_FILE}" ]] && pass 'rollback removes new config when no old config existed' || fail 'new config should be removed'
assert_eq "$(txn_count)" '0' 'no-old-config rollback cleaned'

# 9. Inactive service is never started/restarted.
reset_files
TXN_WAS_ACTIVE_RC=1
assert_ok apply_candidate xray "${CAND_FILE}" 'inactive service apply succeeds'
if calls_contain 'xray:restart'; then fail 'inactive service was restarted'; else pass 'inactive service remains stopped'; fi

# 10. Failed atomic copy cannot partially replace formal config.
reset_files
before=$(file_hash "${XRAY_CONFIG_FILE}")
export PROXYCTL_TEST_FAIL_ATOMIC_COPY=1
assert_fail apply_candidate xray "${CAND_FILE}" 'injected atomic-copy failure returns nonzero'
unset PROXYCTL_TEST_FAIL_ATOMIC_COPY
assert_eq "$(file_hash "${XRAY_CONFIG_FILE}")" "$before" 'failed temp copy leaves formal config unchanged'
if find "${XRAY_DIR}" -name '.proxyctl-config.*' | grep -q .; then fail 'atomic temp file leaked'; else pass 'atomic temp file cleaned'; fi

# 11. Existing mode is preserved.
reset_files
chmod 640 "${XRAY_CONFIG_FILE}"
assert_ok apply_candidate xray "${CAND_FILE}" 'mode-preservation apply succeeds'
assert_eq "$(file_perm "${XRAY_CONFIG_FILE}")" '640' 'existing mode 640 preserved'

# 12. Unsafe inputs are rejected.
reset_files
ln -s "${CAND_FILE}" "${TXN_ROOT}/candidate-link.json"
assert_fail apply_candidate xray "${TXN_ROOT}/candidate-link.json" 'symlink candidate rejected'
assert_fail apply_candidate nonexistent "${CAND_FILE}" 'unknown engine rejected'
rm -f "${XRAY_CONFIG_FILE}"
ln -s "${CAND_FILE}" "${XRAY_CONFIG_FILE}"
assert_fail apply_candidate xray "${CAND_FILE}" 'symlink formal config rejected'

# 13. Config lock contention fails immediately and leaves config untouched.
reset_files
export TXN_READY="${TXN_ROOT}/ready"
export TXN_RELEASE="${TXN_ROOT}/release"
rm -f "$TXN_READY" "$TXN_RELEASE"
bash -c "
    source '${PROJECT_DIR}/lib/ui.sh'
    source '${PROJECT_DIR}/lib/common/lock.sh'
    lock_acquire config || exit 10
    touch \"\${TXN_READY}\"
    while [[ ! -f \"\${TXN_RELEASE}\" ]]; do sleep 0.05; done
    lock_release config
" &
holder=$!
i=0
while [[ ! -f "$TXN_READY" && $i -lt 200 ]]; do sleep 0.05; i=$((i + 1)); done
[[ -f "$TXN_READY" ]] && pass 'contention holder acquired config lock' || fail 'contention holder did not acquire lock'
set +e
out=$(apply_candidate xray "${CAND_FILE}" 2>&1)
rc=$?
set -e
[[ "$rc" -ne 0 ]] && pass 'apply fails under config lock contention' || fail 'apply must fail under config lock contention'
assert_contains "$out" 'Another ProxyCTL config operation is already running.' 'contention emits busy message'
assert_contains "$(cat "${XRAY_CONFIG_FILE}")" '"version":"old"' 'contention leaves config untouched'
touch "$TXN_RELEASE"
wait "$holder"

# 14. Real engine adapters use exact core validation CLIs and fail closed.
reset_files
MOCK_BIN="${TXN_ROOT}/mock-bin"
EMPTY_BIN="${TXN_ROOT}/empty-bin"
mkdir "$MOCK_BIN" "$EMPTY_BIN"
ENGINE_LOG="${TXN_ROOT}/engine.log"
export TXN_ENGINE_LOG="$ENGINE_LOG"
cat > "${MOCK_BIN}/xray" <<'EOF'
#!/usr/bin/env bash
printf 'xray %s\n' "$*" >> "$TXN_ENGINE_LOG"
exit "${TXN_XRAY_RC:-0}"
EOF
cat > "${MOCK_BIN}/sing-box" <<'EOF'
#!/usr/bin/env bash
printf 'sing-box %s\n' "$*" >> "$TXN_ENGINE_LOG"
exit "${TXN_SINGBOX_RC:-0}"
EOF
chmod +x "${MOCK_BIN}/xray" "${MOCK_BIN}/sing-box"

( PATH="${MOCK_BIN}:${PATH}"; engine_xray_validate "${CAND_FILE}" ) && pass 'xray validator succeeds with mock core' || fail 'xray validator should succeed'
( PATH="${MOCK_BIN}:${PATH}"; engine_singbox_validate "${CAND_FILE}" ) && pass 'sing-box validator succeeds with mock core' || fail 'sing-box validator should succeed'
grep -qxF "xray run -test -config ${CAND_FILE}" "$ENGINE_LOG" && pass 'xray validation CLI exact' || fail 'xray validation CLI wrong'
grep -qxF "sing-box check -c ${CAND_FILE}" "$ENGINE_LOG" && pass 'sing-box validation CLI exact' || fail 'sing-box validation CLI wrong'

if ( export TXN_XRAY_RC=1; PATH="${MOCK_BIN}:${PATH}"; engine_xray_validate "${CAND_FILE}" >/dev/null 2>&1 ); then fail 'xray core failure accepted'; else pass 'xray core failure rejected'; fi
if ( PATH="${EMPTY_BIN}"; engine_xray_validate "${CAND_FILE}" >/dev/null 2>&1 ); then fail 'missing xray accepted'; else pass 'missing xray fails closed'; fi
if ( PATH="${EMPTY_BIN}"; engine_singbox_validate "${CAND_FILE}" >/dev/null 2>&1 ); then fail 'missing sing-box accepted'; else pass 'missing sing-box fails closed'; fi

printf '\nTransaction tests: %d passed, %d failed\n' "$PASSED" "$FAILED"
(( FAILED == 0 ))
