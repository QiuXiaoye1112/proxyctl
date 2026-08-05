#!/usr/bin/env bash
# ------------------------------------------------------------------------------
# tests/lock.sh — Phase 2.4 process locking test suite
#
# Uses the REAL flock(1) (util-linux) against temp lock files — the kernel
# contention behaviour is never mocked. Cross-process coordination uses
# READY/RELEASE marker files so timing is deterministic (no sleep guessing).
#
# Requires: bash 4.0+, flock (util-linux). Skips nothing — if flock is
# missing the suite refuses to run rather than fake results.
# ------------------------------------------------------------------------------
set -o errexit
set -o nounset
set -o pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

source "${PROJECT_DIR}/lib/ui.sh"
source "${PROJECT_DIR}/lib/common/lock.sh"

# Real flock is mandatory for this suite.
if ! command -v flock > /dev/null 2>&1; then
    echo 'tests/lock.sh requires flock (util-linux).' >&2
    exit 2
fi

PASSED=0
FAILED=0

green() { echo -e "\033[0;32m$*\033[0m"; }
red()   { echo -e "\033[0;31m$*\033[0m"; }

pass() { green "  PASS: $*"; ((++PASSED)); }
fail() { red "  FAIL: $*"; ((++FAILED)); }

assert_ok()     { if "$@"; then pass "$*"; else fail "$*"; fi; }
assert_fail()   { if "$@"; then fail "$*"; else pass "$*"; fi; }
assert_eq()     { local got="$1" exp="$2"; shift 2 || true; [[ "${got}" == "${exp}" ]] && pass "$*" || fail "$* — expected '${exp}', got '${got}'"; }
assert_contains(){ local h="$1" n="$2"; shift 2 || true; [[ "${h}" == *"${n}"* ]] && pass "$*" || fail "$* — output missing '${n}'"; }

# assert_rc <expected> <cmd...> — runs cmd, compares its real exit code.
assert_rc() {
    local expected="$1"
    shift
    local rc
    set +e
    "$@"
    rc=$?
    set -e
    if (( rc == expected )); then
        pass "$* → exit ${expected}"
    else
        fail "$* → expected ${expected}, got ${rc}"
    fi
}

# --- lock paths (temp, override) ----------------------------------------------
LOCK_TMP=$(mktemp -d)
LOCK_DIR="${LOCK_TMP}/locks"
export PROXYCTL_LOCK="${LOCK_DIR}/config.lock"
export PROXYCTL_CERT_LOCK="${LOCK_DIR}/cert.lock"
export PROXYCTL_FIREWALL_LOCK="${LOCK_DIR}/firewall.lock"

# lock_child_prelude — lines every background/child bash -c sources so it sees
# exactly the same library this suite does.
lock_child_prelude() {
    printf '%s\n' \
        "source '${PROJECT_DIR}/lib/ui.sh'" \
        "source '${PROJECT_DIR}/lib/common/lock.sh'"
}
readonly LOCK_PRELUDE="$(lock_child_prelude)"

echo ''
echo '================================================================'
echo '  ProxyCTL Phase 2.4 Process Locking Tests'
echo '================================================================'
echo ''

# ============================================================================
# 1. acquire / release
# ============================================================================
echo '--- 1. acquire / release ---'

assert_ok lock_acquire config 'acquire config succeeds'
assert_ok lock_is_held config 'config held after acquire'
assert_ok lock_release config 'release config succeeds'
assert_fail lock_is_held config 'config not held after release'

# The lock file is not a lock: it must survive release.
if [[ -f "${PROXYCTL_LOCK}" ]]; then
    pass 'lock file remains after release (never deleted)'
else
    fail 'lock file must not be deleted on release'
fi

# ============================================================================
# 2. duplicate acquire is idempotent
# ============================================================================
echo '--- 2. duplicate acquire ---'

assert_ok lock_acquire config 'first acquire succeeds'
assert_ok lock_acquire config 'second acquire is idempotent'
assert_ok lock_is_held config 'still held after duplicate acquire'
assert_ok lock_release config 'single release frees after duplicate acquire'
assert_fail lock_is_held config 'released after duplicate acquire + one release'
assert_ok lock_acquire config 're-acquire after release works'
assert_ok lock_release config 're-acquired lock released'

# ============================================================================
# 3. cross-process contention (non-blocking)
# ============================================================================
echo '--- 3. cross-process contention ---'

export LOCK_TEST_READY="${LOCK_DIR}/ready.3"
export LOCK_TEST_RELEASE="${LOCK_DIR}/release.3"
rm -f "${LOCK_TEST_READY}" "${LOCK_TEST_RELEASE}"

HOLDER_A=$(cat <<'EOF'
lock_acquire config || exit 10
touch "${LOCK_TEST_READY}"
while [[ ! -f "${LOCK_TEST_RELEASE}" ]]; do sleep 0.05; done
lock_release config
exit 0
EOF
)

bash -c "${LOCK_PRELUDE}"$'\n'"${HOLDER_A}" 'holder-a' &
HOLDER_A_PID=$!

# Wait for A to hold the lock (bounded, marker-driven — deterministic).
i=0
while [[ ! -f "${LOCK_TEST_READY}" ]]; do
    sleep 0.05
    i=$((i + 1))
    if (( i > 200 )); then
        break
    fi
done
if [[ -f "${LOCK_TEST_READY}" ]]; then
    pass 'holder A acquired config and signalled READY'
else
    fail 'holder A never signalled READY'
fi

# B must fail IMMEDIATELY (flock -n) while A holds.
assert_fail \
    bash -c "${LOCK_PRELUDE}"$'\n'"lock_acquire config" 'contender-b' \
    'contender B rejected immediately while A holds config'

# Release A deterministically.
touch "${LOCK_TEST_RELEASE}"
set +e
wait "${HOLDER_A_PID}"
HOLDER_A_RC=$?
set -e
if (( HOLDER_A_RC == 0 )); then
    pass 'holder A released and exited cleanly'
else
    fail "holder A exited rc=${HOLDER_A_RC}"
fi

# ============================================================================
# 4. reacquire after the previous holder released
# ============================================================================
echo '--- 4. reacquire after release ---'

assert_ok \
    bash -c "${LOCK_PRELUDE}"$'\n'"lock_acquire config && lock_release config" 'contender-b2' \
    'config reacquirable after previous holder released'

# ============================================================================
# 5. different locks are independent
# ============================================================================
echo '--- 5. different locks ---'

assert_ok lock_acquire config 'parent holds config'
assert_ok lock_acquire cert 'same process holds cert while config held'
assert_ok lock_is_held config 'config still held'
assert_ok lock_is_held cert 'cert still held'
assert_ok \
    bash -c "${LOCK_PRELUDE}"$'\n'"lock_acquire firewall && lock_release firewall" 'fw-child' \
    'cross-process: firewall lock unaffected by config+cert holders'
assert_ok lock_release cert 'release cert'
assert_ok lock_release config 'release config'

# ============================================================================
# 6. with_lock success
# ============================================================================
echo '--- 6. with_lock success ---'

check_held() { lock_is_held config; }
assert_ok with_lock config check_held 'with_lock holds config during command'
assert_fail lock_is_held config 'with_lock released config after command'

# ============================================================================
# 7. with_lock preserves the command exit code
# ============================================================================
echo '--- 7. with_lock exit code ---'

failing_fn() { return 37; }
assert_rc 37 with_lock config failing_fn 'with_lock preserves exit 37'
assert_fail lock_is_held config 'lock released after failing with_lock command'

# ============================================================================
# 8. with_lock must not release a lock the caller already held
# ============================================================================
echo '--- 8. nested with_lock ownership ---'

assert_ok lock_acquire config 'acquire config before nesting'
inner_holds() { lock_is_held config; }
assert_ok with_lock config inner_holds 'nested with_lock on already-held lock succeeds'
assert_ok lock_is_held config 'outer lock still held after nested with_lock'
assert_ok lock_release config 'outer lock released manually'
assert_fail lock_is_held config 'outer lock fully released'

# ============================================================================
# 9. process exit auto-releases (no stale-lock cleanup needed)
# ============================================================================
echo '--- 9. auto-release on exit ---'

set +e
bash -c "${LOCK_PRELUDE}"$'\n'"lock_acquire config" 'auto-release'
AUTO_RC=$?
set -e
if (( AUTO_RC == 0 )); then
    pass 'holder child exited cleanly'
else
    fail "holder child exited rc=${AUTO_RC}"
fi
assert_ok lock_acquire config 'lock auto-released after holder process exited'
assert_ok lock_release config 'released re-acquired lock'

# ============================================================================
# 10. SIGTERM auto-releases
# ============================================================================
echo '--- 10. auto-release on SIGTERM ---'

export LOCK_TEST_READY="${LOCK_DIR}/ready.10"
rm -f "${LOCK_TEST_READY}"

bash -c "${LOCK_PRELUDE}"$'\n'"lock_acquire config || exit 11; touch \"\${LOCK_TEST_READY}\"; exec sleep 60" 'sigterm-holder' &
SIG_PID=$!

i=0
while [[ ! -f "${LOCK_TEST_READY}" ]]; do
    sleep 0.05
    i=$((i + 1))
    if (( i > 200 )); then
        break
    fi
done
if [[ -f "${LOCK_TEST_READY}" ]]; then
    pass 'SIGTERM holder acquired config and signalled READY'
else
    fail 'SIGTERM holder never signalled READY'
fi

kill -TERM "${SIG_PID}" 2>/dev/null || true
set +e
wait "${SIG_PID}"
SIG_RC=$?
set -e

assert_ok lock_acquire config 'lock reacquirable after holder was SIGTERMed'
assert_ok lock_release config 'released re-acquired lock'

# ============================================================================
# 11. unknown lock names are rejected (no path built from input)
# ============================================================================
echo '--- 11. unknown lock names ---'

assert_fail lock_acquire '../x' 'lock_acquire rejects traversal name'
assert_fail lock_acquire '/abs/path' 'lock_acquire rejects absolute name'
assert_fail lock_release 'x' 'lock_release rejects unknown name'
assert_fail lock_path '/' 'lock_path rejects "/"'
assert_fail lock_path '' 'lock_path rejects empty name'
assert_fail lock_fd '../../etc/passwd' 'lock_fd rejects traversal name'
assert_fail with_lock config 'with_lock requires a command'

# Unknown names must produce the documented stderr message.
out=$(lock_path something 2>&1) || true
assert_contains "${out}" 'Unknown lock name: something' 'lock_path reports unknown name'

# And no arbitrary file may be created by a rejected name.
if [[ -e "${LOCK_TMP}/x" || -e "${LOCK_TMP}/locks/x" ]]; then
    fail 'rejected lock name created a file'
else
    pass 'rejected lock name created no file'
fi

# ============================================================================
# 12. fail closed when flock is unavailable
# ============================================================================
echo '--- 12. flock unavailable fails closed ---'

# (a) Override _lock_require_flock inside an isolated child — never mocks
#     command -v for the whole suite. lock_acquire must fail closed.
assert_fail \
    bash -c "${LOCK_PRELUDE}"$'\n'"_lock_require_flock() { return 1; }; lock_acquire config" 'no-flock' \
    'lock_acquire fails closed when flock is unavailable'

# (b) The real _lock_require_flock must emit the documented message when flock
#     is genuinely absent — probed with a PATH that contains no flock.
NO_FLOCK_MSG=$(bash -c "
    PATH=/nonexistent
    source '${PROJECT_DIR}/lib/ui.sh'
    source '${PROJECT_DIR}/lib/common/lock.sh'
    _lock_require_flock 2>&1
") || true
assert_contains "${NO_FLOCK_MSG}" 'flock is required for ProxyCTL locking.' 'real _lock_require_flock reports missing flock'

# ============================================================================
# Cleanup
# ============================================================================
echo ''
echo '--- Cleanup ---'

rm -rf "${LOCK_TMP}"
unset LOCK_TEST_READY LOCK_TEST_RELEASE

# ============================================================================
# Summary
# ============================================================================
echo ''
echo '================================================================'
echo "  Lock tests: ${PASSED} passed, ${FAILED} failed"
echo '================================================================'

if (( FAILED > 0 )); then
    exit 1
fi
