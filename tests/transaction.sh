#!/usr/bin/env bash
# ------------------------------------------------------------------------------
# tests/transaction.sh — Phase 2.5 config transaction apply test suite
#
# All core/service interaction goes through a mocked engine_call that records
# every call and returns scripted results — this suite never touches a real
# Xray / sing-box / systemd / OpenRC. The only real system facility used is
# flock (Phase 2.4 locking) for the config-lock contention test.
#
# Test matrix (mock rc semantics):
#   TXN_WAS_ACTIVE_RC  — first  is_active  (was the service running before?)
#   TXN_HEALTH_RC      — second is_active  (post-restart health check)
#   TXN_RESTART1_RC    — first  restart    (new config)
#   TXN_RESTART2_RC    — second restart    (rollback, old config)
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

green() { echo -e "\033[0;32m$*\033[0m"; }
red()   { echo -e "\033[0;31m$*\033[0m"; }

pass() { green "  PASS: $*"; ((++PASSED)); }
fail() { red "  FAIL: $*"; ((++FAILED)); }

assert_ok()     { if "$@"; then pass "$*"; else fail "$*"; fi; }
assert_fail()   { if "$@"; then fail "$*"; else pass "$*"; fi; }
assert_eq()     { local got="$1" exp="$2"; shift 2 || true; [[ "${got}" == "${exp}" ]] && pass "$*" || fail "$* — expected '${exp}', got '${got}'"; }
assert_contains(){ local h="$1" n="$2"; shift 2 || true; [[ "${h}" == *"${n}"* ]] && pass "$*" || fail "$* — missing '${n}'"; }

assert_file_perm() {
    local f="$1" p="$2"
    local got
    got=$(stat -c '%a' "$f" 2>/dev/null || stat -f '%Lp' "$f" 2>/dev/null)
    [[ "${got}" == "${p}" ]] && pass "$3" || fail "$3 — expected ${p}, got ${got}"
}

file_hash() {
    local f="$1"
    if command -v sha1sum > /dev/null 2>&1; then
        sha1sum "$f" | awk '{print $1}'
    elif command -v shasum > /dev/null 2>&1; then
        shasum "$f" | awk '{print $1}'
    else
        cksum "$f" | awk '{print $1}'
    fi
}

# txn_remaining_tx_dirs — how many tx_* staging dirs still exist.
txn_remaining_tx_dirs() {
    find "${PROXYCTL_DATA}/transactions" -mindepth 1 -maxdepth 1 \
        -type d -name 'tx_*' 2>/dev/null | wc -l | tr -d ' '
}

# txn_expect_calls <expected-call...> — compares the recorded engine_call log.
txn_expect_calls() {
    local expected=("$@")
    local got=()
    mapfile -t got < "${TXN_CALLS_LOG}"
    if (( ${#expected[@]} != ${#got[@]} )); then
        return 1
    fi
    local i
    for i in "${!expected[@]}"; do
        [[ "${got[$i]}" == "${expected[$i]}" ]] || return 1
    done
    return 0
}

# txn_calls_have <needle> — true if any recorded call equals needle.
txn_calls_have() {
    local needle="$1"
    grep -qxF "${needle}" "${TXN_CALLS_LOG}"
}

# --- mocked engine_call -------------------------------------------------------
# Recorded in a shared FILE (not an array) because apply_candidate is often
# invoked inside $( ) command substitution, i.e. a subshell — a parent-shell
# array would never see the calls.
TXN_CONFIG_FILE=''
TXN_VALIDATE_RC=0
TXN_WAS_ACTIVE_RC=0
TXN_HEALTH_RC=0
TXN_RESTART1_RC=0
TXN_RESTART2_RC=0

txn_mock_reset() {
    : > "${TXN_CALLS_LOG}"
    TXN_CONFIG_FILE=''
    TXN_VALIDATE_RC=0
    TXN_WAS_ACTIVE_RC=0
    TXN_HEALTH_RC=0
    TXN_RESTART1_RC=0
    TXN_RESTART2_RC=0
    TXN_IS_ACTIVE_CALLS=0
    TXN_RESTART_CALLS=0
}

engine_call() {
    local engine="$1" method="$2"
    printf '%s\n' "${engine}:${method}" >> "${TXN_CALLS_LOG}"
    case "${method}" in
        config_file)
            printf '%s\n' "${TXN_CONFIG_FILE}"
            return 0
            ;;
        validate)
            return "${TXN_VALIDATE_RC}"
            ;;
        is_active)
            TXN_IS_ACTIVE_CALLS=$((TXN_IS_ACTIVE_CALLS + 1))
            if (( TXN_IS_ACTIVE_CALLS == 1 )); then
                return "${TXN_WAS_ACTIVE_RC}"
            fi
            return "${TXN_HEALTH_RC}"
            ;;
        restart)
            TXN_RESTART_CALLS=$((TXN_RESTART_CALLS + 1))
            if (( TXN_RESTART_CALLS == 1 )); then
                return "${TXN_RESTART1_RC}"
            fi
            return "${TXN_RESTART2_RC}"
            ;;
        *)
            return 1
            ;;
    esac
}

# --- fixtures ----------------------------------------------------------------
TXN_ROOT=$(mktemp -d)
XRAY_DIR="${TXN_ROOT}/xray"
mkdir -p "${XRAY_DIR}"
export PROXYCTL_DATA="${TXN_ROOT}/data"
TXN_CALLS_LOG="${TXN_ROOT}/calls.log"
export PROXYCTL_META="${PROXYCTL_DATA}/meta.json"
export PROXYCTL_LOCK="${TXN_ROOT}/locks/config.lock"
export PROXYCTL_CERT_LOCK="${TXN_ROOT}/locks/cert.lock"
export PROXYCTL_FIREWALL_LOCK="${TXN_ROOT}/locks/firewall.lock"
mkdir -p "$(dirname "${PROXYCTL_LOCK}")"

XRAY_CONFIG_FILE="${XRAY_DIR}/config.json"
CAND_FILE="${TXN_ROOT}/candidate.json"
printf '{"version":"old"}\n' > "${XRAY_CONFIG_FILE}"
printf '{"version":"new"}\n' > "${CAND_FILE}"

txn_mock_reset
TXN_CONFIG_FILE="${XRAY_CONFIG_FILE}"

echo ''
echo '================================================================'
echo '  ProxyCTL Phase 2.5 Config Transaction Apply Tests'
echo '================================================================'
echo ''

# ============================================================================
# 1. validation success (active service): apply + commit
# ============================================================================
echo '--- 1. validation success ---'

txn_mock_reset
TXN_CONFIG_FILE="${XRAY_CONFIG_FILE}"
TXN_VALIDATE_RC=0
TXN_WAS_ACTIVE_RC=0
TXN_HEALTH_RC=0
TXN_RESTART1_RC=0

set +e
out=$(apply_candidate xray "${CAND_FILE}")
rc=$?
set -e
assert_eq "${rc}" '0' 'apply_candidate returns 0 on success'
assert_eq "${out}" '' 'apply_candidate stdout stays clean on success'
assert_contains "$(cat "${XRAY_CONFIG_FILE}")" '"version":"new"' 'formal config updated'

if txn_expect_calls 'xray:config_file' 'xray:validate' 'xray:is_active' 'xray:restart' 'xray:is_active'; then
    pass 'call order: config_file validate is_active restart is_active'
else
    fail "unexpected call order: ${TXN_CALLS[*]}"
fi
assert_eq "$(txn_remaining_tx_dirs)" '0' 'transaction staging cleaned after commit'

# ============================================================================
# 2. validation failure: formal config untouched, restart never called
# ============================================================================
echo '--- 2. validation failure ---'

printf '{"version":"old"}\n' > "${XRAY_CONFIG_FILE}"
txn_mock_reset
TXN_CONFIG_FILE="${XRAY_CONFIG_FILE}"
TXN_VALIDATE_RC=1

BEFORE_HASH=$(file_hash "${XRAY_CONFIG_FILE}")
if apply_candidate xray "${CAND_FILE}"; then
    fail 'apply_candidate should fail on validation error'
else
    pass 'apply_candidate fails on validation error'
fi
assert_eq "$(file_hash "${XRAY_CONFIG_FILE}")" "${BEFORE_HASH}" 'formal config unchanged on validation failure'
if txn_calls_have 'xray:restart'; then
    fail 'restart must not be called when validation fails'
else
    pass 'restart not called on validation failure'
fi
assert_eq "$(txn_remaining_tx_dirs)" '0' 'transaction staging cleaned after validation failure'

# ============================================================================
# 3. restart failure: rollback restores old config and restarts it
# ============================================================================
echo '--- 3. restart failure rollback ---'

printf '{"version":"old"}\n' > "${XRAY_CONFIG_FILE}"
txn_mock_reset
TXN_CONFIG_FILE="${XRAY_CONFIG_FILE}"
TXN_VALIDATE_RC=0
TXN_WAS_ACTIVE_RC=0
TXN_HEALTH_RC=0
TXN_RESTART1_RC=1
TXN_RESTART2_RC=0

if apply_candidate xray "${CAND_FILE}"; then
    fail 'apply_candidate should fail when restart fails'
else
    pass 'apply_candidate fails when restart fails'
fi
assert_contains "$(cat "${XRAY_CONFIG_FILE}")" '"version":"old"' 'old config restored after restart failure'
assert_eq "$(txn_remaining_tx_dirs)" '0' 'transaction staging cleaned after rollback'

# ============================================================================
# 4. health check failure: also rolls back
# ============================================================================
echo '--- 4. health check failure rollback ---'

printf '{"version":"old"}\n' > "${XRAY_CONFIG_FILE}"
txn_mock_reset
TXN_CONFIG_FILE="${XRAY_CONFIG_FILE}"
TXN_VALIDATE_RC=0
TXN_WAS_ACTIVE_RC=0
TXN_HEALTH_RC=1
TXN_RESTART1_RC=0
TXN_RESTART2_RC=0

if apply_candidate xray "${CAND_FILE}"; then
    fail 'apply_candidate should fail when health check fails'
else
    pass 'apply_candidate fails when health check fails'
fi
assert_contains "$(cat "${XRAY_CONFIG_FILE}")" '"version":"old"' 'old config restored after health check failure'
assert_eq "$(txn_remaining_tx_dirs)" '0' 'transaction staging cleaned after health rollback'

# ============================================================================
# 5. rollback restart failure: [CRITICAL] and non-zero
# ============================================================================
echo '--- 5. rollback restart failure is critical ---'

printf '{"version":"old"}\n' > "${XRAY_CONFIG_FILE}"
txn_mock_reset
TXN_CONFIG_FILE="${XRAY_CONFIG_FILE}"
TXN_VALIDATE_RC=0
TXN_WAS_ACTIVE_RC=0
TXN_HEALTH_RC=0
TXN_RESTART1_RC=1
TXN_RESTART2_RC=1

set +e
out=$(apply_candidate xray "${CAND_FILE}" 2>&1)
rc=$?
set -e
if (( rc == 0 )); then
    fail 'apply_candidate should return non-zero when rollback restart fails'
else
    pass 'apply_candidate returns non-zero when rollback restart fails'
fi
assert_contains "${out}" '[CRITICAL]' 'stderr contains [CRITICAL] on rollback restart failure'
assert_contains "$(cat "${XRAY_CONFIG_FILE}")" '"version":"old"' 'old config restored even when its restart fails'

# ============================================================================
# 6. no previous config: rollback removes the newly applied config
# ============================================================================
echo '--- 6. rollback with no previous config ---'

rm -f "${XRAY_CONFIG_FILE}"
txn_mock_reset
TXN_CONFIG_FILE="${XRAY_CONFIG_FILE}"
TXN_VALIDATE_RC=0
TXN_WAS_ACTIVE_RC=0
TXN_HEALTH_RC=0
TXN_RESTART1_RC=1
TXN_RESTART2_RC=0

if apply_candidate xray "${CAND_FILE}"; then
    fail 'apply_candidate should fail on restart failure'
else
    pass 'apply_candidate fails on restart failure'
fi
if [[ -e "${XRAY_CONFIG_FILE}" ]]; then
    fail 'new config must be removed when there was no previous config'
else
    pass 'new config removed after rollback with no previous config'
fi
assert_eq "$(txn_remaining_tx_dirs)" '0' 'transaction staging cleaned'

# ============================================================================
# 7. inactive service: config replaced, restart never called
# ============================================================================
echo '--- 7. inactive service is not started ---'

printf '{"version":"old"}\n' > "${XRAY_CONFIG_FILE}"
txn_mock_reset
TXN_CONFIG_FILE="${XRAY_CONFIG_FILE}"
TXN_VALIDATE_RC=0
TXN_WAS_ACTIVE_RC=1
TXN_HEALTH_RC=0
TXN_RESTART1_RC=0

set +e
out=$(apply_candidate xray "${CAND_FILE}")
rc=$?
set -e
assert_eq "${rc}" '0' 'apply_candidate succeeds for inactive service'
assert_eq "${out}" '' 'apply_candidate stdout stays clean'
assert_contains "$(cat "${XRAY_CONFIG_FILE}")" '"version":"new"' 'config applied for inactive service'
if txn_calls_have 'xray:restart'; then
    fail 'restart must not be called for an inactive service'
else
    pass 'restart not called for inactive service'
fi
assert_eq "$(txn_remaining_tx_dirs)" '0' 'transaction staging cleaned after inactive apply'

# ============================================================================
# 8. atomic replacement: temp copy failure never touches formal config
# ============================================================================
echo '--- 8. atomic replacement ---'

printf '{"version":"old"}\n' > "${XRAY_CONFIG_FILE}"
txn_mock_reset
TXN_CONFIG_FILE="${XRAY_CONFIG_FILE}"
TXN_VALIDATE_RC=0
TXN_WAS_ACTIVE_RC=0
TXN_HEALTH_RC=0
TXN_RESTART1_RC=0

BEFORE_HASH=$(file_hash "${XRAY_CONFIG_FILE}")
export PROXYCTL_TEST_FAIL_ATOMIC_COPY=1
if apply_candidate xray "${CAND_FILE}"; then
    fail 'apply_candidate should fail when the temp copy fails'
else
    pass 'apply_candidate fails when the temp copy fails'
fi
unset PROXYCTL_TEST_FAIL_ATOMIC_COPY
assert_eq "$(file_hash "${XRAY_CONFIG_FILE}")" "${BEFORE_HASH}" 'formal config unchanged when temp copy fails'
if find "${XRAY_DIR}" -name '.proxyctl-config.*' | grep -q .; then
    fail 'temp file left behind after failed copy'
else
    pass 'no temp file left behind after failed copy'
fi
if txn_calls_have 'xray:restart'; then
    fail 'restart must not be called when the replace never happened'
else
    pass 'restart not called when replace failed'
fi
assert_eq "$(txn_remaining_tx_dirs)" '0' 'transaction staging cleaned after failed copy'

# ============================================================================
# 9. permissions: old mode preserved on apply and on rollback
# ============================================================================
echo '--- 9. permissions preserved ---'

printf '{"version":"old"}\n' > "${XRAY_CONFIG_FILE}"
chmod 640 "${XRAY_CONFIG_FILE}"
txn_mock_reset
TXN_CONFIG_FILE="${XRAY_CONFIG_FILE}"
TXN_VALIDATE_RC=0
TXN_WAS_ACTIVE_RC=0
TXN_HEALTH_RC=0
TXN_RESTART1_RC=0

if apply_candidate xray "${CAND_FILE}"; then
    pass 'apply_candidate succeeds for permission test'
else
    fail 'apply_candidate should succeed'
fi
assert_file_perm "${XRAY_CONFIG_FILE}" '640' 'new config keeps previous mode 640'

# rollback path must also restore the mode
chmod 640 "${XRAY_CONFIG_FILE}"
txn_mock_reset
TXN_CONFIG_FILE="${XRAY_CONFIG_FILE}"
TXN_VALIDATE_RC=0
TXN_WAS_ACTIVE_RC=0
TXN_HEALTH_RC=0
TXN_RESTART1_RC=1
TXN_RESTART2_RC=0
if apply_candidate xray "${CAND_FILE}"; then
    fail 'apply_candidate should fail on restart failure'
else
    pass 'apply_candidate fails on restart failure'
fi
assert_file_perm "${XRAY_CONFIG_FILE}" '640' 'rollback restores previous mode 640'

# ============================================================================
# 10. symlink candidate is rejected
# ============================================================================
echo '--- 10. symlink candidate rejected ---'

printf '{"version":"old"}\n' > "${XRAY_CONFIG_FILE}"
ln -sf "${CAND_FILE}" "${TXN_ROOT}/candidate-link.json"
BEFORE_HASH=$(file_hash "${XRAY_CONFIG_FILE}")

if apply_candidate xray "${TXN_ROOT}/candidate-link.json"; then
    fail 'apply_candidate should reject a symlink candidate'
else
    pass 'apply_candidate rejects a symlink candidate'
fi
assert_eq "$(file_hash "${XRAY_CONFIG_FILE}")" "${BEFORE_HASH}" 'formal config untouched for symlink candidate'

# ============================================================================
# 11. bad engine name
# ============================================================================
echo '--- 11. unknown engine rejected ---'

printf '{"version":"old"}\n' > "${XRAY_CONFIG_FILE}"
BEFORE_HASH=$(file_hash "${XRAY_CONFIG_FILE}")
txn_mock_reset

if apply_candidate nonexistent "${CAND_FILE}"; then
    fail 'apply_candidate should reject an unknown engine'
else
    pass 'apply_candidate rejects an unknown engine'
fi
if [[ -s "${TXN_CALLS_LOG}" ]]; then
    fail 'engine_call never invoked for unknown engine'
else
    pass 'engine_call never invoked for unknown engine'
fi
assert_eq "$(file_hash "${XRAY_CONFIG_FILE}")" "${BEFORE_HASH}" 'formal config untouched for unknown engine'

# ============================================================================
# 12. config lock contention (real flock): apply fails immediately
# ============================================================================
echo '--- 12. config lock contention ---'

printf '{"version":"old"}\n' > "${XRAY_CONFIG_FILE}"
txn_mock_reset
TXN_CONFIG_FILE="${XRAY_CONFIG_FILE}"
TXN_VALIDATE_RC=0
TXN_WAS_ACTIVE_RC=0
TXN_HEALTH_RC=0
TXN_RESTART1_RC=0

export TXN_READY="${TXN_ROOT}/ready.12"
export TXN_RELEASE="${TXN_ROOT}/release.12"
rm -f "${TXN_READY}" "${TXN_RELEASE}"

bash -c "
    source '${PROJECT_DIR}/lib/ui.sh'
    source '${PROJECT_DIR}/lib/common/lock.sh'
    lock_acquire config || exit 10
    touch \"\${TXN_READY}\"
    while [[ ! -f \"\${TXN_RELEASE}\" ]]; do sleep 0.05; done
    lock_release config
    exit 0
" 'config-holder' &
HOLDER_PID=$!

i=0
while [[ ! -f "${TXN_READY}" ]]; do
    sleep 0.05
    i=$((i + 1))
    if (( i > 200 )); then
        break
    fi
done
if [[ -f "${TXN_READY}" ]]; then
    pass 'holder acquired the config lock'
else
    fail 'holder never acquired the config lock'
fi

set +e
out=$(apply_candidate xray "${CAND_FILE}" 2>&1)
rc=$?
set -e
if (( rc == 0 )); then
    fail 'apply_candidate should fail immediately under config lock contention'
else
    pass 'apply_candidate fails immediately under config lock contention'
fi
assert_contains "${out}" 'Another ProxyCTL config operation is already running.' 'busy message on lock contention'
assert_contains "$(cat "${XRAY_CONFIG_FILE}")" '"version":"old"' 'formal config untouched under lock contention'

touch "${TXN_RELEASE}"
set +e
wait "${HOLDER_PID}"
HOLDER_RC=$?
set -e
assert_eq "${HOLDER_RC}" '0' 'config lock holder released cleanly'

# ============================================================================
# 13. engine validation adapters invoke the real core CLI
# ============================================================================
echo '--- 13. engine validation adapter CLI ---'

MOCK_BIN=$(mktemp -d)
EMPTY_BIN=$(mktemp -d)
ENGINE_LOG="${TXN_ROOT}/engine-calls.log"
rm -f "${ENGINE_LOG}"
export TXN_ENGINE_LOG="${ENGINE_LOG}"

cat > "${MOCK_BIN}/xray" <<'XEOF'
#!/usr/bin/env bash
printf 'xray %s\n' "$*" >> "${TXN_ENGINE_LOG}"
exit "${TXN_XRAY_RC:-0}"
XEOF
cat > "${MOCK_BIN}/sing-box" <<'SEOF'
#!/usr/bin/env bash
printf 'sing-box %s\n' "$*" >> "${TXN_ENGINE_LOG}"
exit "${TXN_SINGBOX_RC:-0}"
SEOF
chmod +x "${MOCK_BIN}/xray" "${MOCK_BIN}/sing-box"

if ( PATH="${MOCK_BIN}:${PATH}"; engine_xray_validate "${CAND_FILE}" ); then
    pass 'engine_xray_validate succeeds'
else
    fail 'engine_xray_validate should succeed'
fi
if grep -q "^xray run -test -config ${CAND_FILE}$" "${ENGINE_LOG}"; then
    pass 'xray CLI args: run -test -config FILE'
else
    fail "xray CLI args wrong: $(cat "${ENGINE_LOG}")"
fi

if ( PATH="${MOCK_BIN}:${PATH}"; engine_singbox_validate "${CAND_FILE}" ); then
    pass 'engine_singbox_validate succeeds'
else
    fail 'engine_singbox_validate should succeed'
fi
if grep -q "^sing-box check -c ${CAND_FILE}$" "${ENGINE_LOG}"; then
    pass 'sing-box CLI args: check -c FILE'
else
    fail "sing-box CLI args wrong: $(cat "${ENGINE_LOG}")"
fi

# core returning non-zero must fail validation (no JSON fallback)
rm -f "${ENGINE_LOG}"
if ( export TXN_XRAY_RC=1; PATH="${MOCK_BIN}:${PATH}"; engine_xray_validate "${CAND_FILE}" 2>/dev/null ); then
    fail 'engine_xray_validate must fail when core validation fails'
else
    pass 'engine_xray_validate fails when core validation fails'
fi

# core missing -> fail closed
if ( PATH="${EMPTY_BIN}"; engine_xray_validate "${CAND_FILE}" 2>/dev/null ); then
    fail 'engine_xray_validate must fail when xray is missing'
else
    pass 'engine_xray_validate fails when xray is missing'
fi
if ( PATH="${EMPTY_BIN}"; engine_singbox_validate "${CAND_FILE}" 2>/dev/null ); then
    fail 'engine_singbox_validate must fail when sing-box is missing'
else
    pass 'engine_singbox_validate fails when sing-box is missing'
fi

# ============================================================================
# Cleanup
# ============================================================================
echo ''
echo '--- Cleanup ---'

rm -rf "${TXN_ROOT}" "${MOCK_BIN}" "${EMPTY_BIN}"
unset TXN_READY TXN_RELEASE TXN_ENGINE_LOG PROXYCTL_TEST_FAIL_ATOMIC_COPY

# ============================================================================
# Summary
# ============================================================================
echo ''
echo '================================================================'
echo "  Transaction tests: ${PASSED} passed, ${FAILED} failed"
echo '================================================================'

if (( FAILED > 0 )); then
    exit 1
fi
