#!/usr/bin/env bash
# ------------------------------------------------------------------------------
# tests/lock_security.sh — Phase 2.4 lock path hardening regression tests
# ------------------------------------------------------------------------------
set -o errexit
set -o nounset
set -o pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

source "${PROJECT_DIR}/lib/ui.sh"
source "${PROJECT_DIR}/lib/common/lock.sh"

if ! command -v flock >/dev/null 2>&1; then
    echo 'tests/lock_security.sh requires flock (util-linux).' >&2
    exit 2
fi

PASSED=0
FAILED=0
pass() { echo "  PASS: $*"; ((++PASSED)); }
fail() { echo "  FAIL: $*" >&2; ((++FAILED)); }

assert_ok() { if "$@"; then pass "$*"; else fail "$*"; fi; }
assert_fail() { if "$@"; then fail "$*"; else pass "$*"; fi; }
assert_eq() {
    local got="$1" expected="$2"; shift 2 || true
    [[ "${got}" == "${expected}" ]] && pass "$*" || fail "$* — expected '${expected}', got '${got}'"
}
file_perm() { stat -c '%a' "$1"; }

TMP=$(mktemp -d)
trap 'rm -rf "${TMP}"' EXIT

# ------------------------------------------------------------------------------
# 1. Bash 4.0 compatibility: no Bash 4.2-only declare -g in executable lines.
# ------------------------------------------------------------------------------
if grep -Eq '^[[:space:]]*declare[[:space:]]+-[^[:space:]]*g' "${PROJECT_DIR}/lib/common/lock.sh"; then
    fail 'lock.sh must not use declare -g'
else
    pass 'lock.sh avoids Bash 4.2-only declare -g'
fi

# ------------------------------------------------------------------------------
# 2. Default lock paths live under the dedicated /run/proxyctl directory.
# ------------------------------------------------------------------------------
unset PROXYCTL_LOCK_DIR PROXYCTL_LOCK PROXYCTL_CERT_LOCK PROXYCTL_FIREWALL_LOCK
assert_eq "$(lock_path config)" '/run/proxyctl/config.lock' 'default config lock path'
assert_eq "$(lock_path cert)" '/run/proxyctl/cert.lock' 'default cert lock path'
assert_eq "$(lock_path firewall)" '/run/proxyctl/firewall.lock' 'default firewall lock path'

# ------------------------------------------------------------------------------
# 3. Secure custom directory/file creation.
# ------------------------------------------------------------------------------
export PROXYCTL_LOCK_DIR="${TMP}/runtime"
unset PROXYCTL_LOCK PROXYCTL_CERT_LOCK PROXYCTL_FIREWALL_LOCK
assert_ok lock_acquire config 'acquire creates secure dedicated directory'
assert_eq "$(file_perm "${PROXYCTL_LOCK_DIR}")" '700' 'lock directory mode is 700'
assert_eq "$(file_perm "${PROXYCTL_LOCK_DIR}/config.lock")" '600' 'lock file mode is 600'
assert_ok lock_release config 'release secure custom lock'

# Existing regular lock files are not truncated by acquisition.
printf '%s\n' 'sentinel' > "${PROXYCTL_LOCK_DIR}/config.lock"
assert_ok lock_acquire config 'acquire existing regular lock file'
assert_ok lock_release config 'release existing regular lock file'
assert_eq "$(cat "${PROXYCTL_LOCK_DIR}/config.lock")" 'sentinel' 'acquire does not truncate lock file'

# ------------------------------------------------------------------------------
# 4. Duplicate acquire checks current ownership before flock availability.
# ------------------------------------------------------------------------------
assert_ok lock_acquire config 'initial acquire before duplicate-idempotency test'
_lock_require_flock() { return 1; }
assert_ok lock_acquire config 'duplicate acquire succeeds without re-checking flock'
unset -f _lock_require_flock
_lock_require_flock() {
    command -v flock >/dev/null 2>&1 || {
        echo 'flock is required for ProxyCTL locking.' >&2
        return 1
    }
    return 0
}
assert_ok lock_release config 'release after duplicate-idempotency test'

# ------------------------------------------------------------------------------
# 5. Pre-planted symlink lock file is rejected without touching target.
# ------------------------------------------------------------------------------
SAFE_DIR="${TMP}/symlink-file"
mkdir -m 700 "${SAFE_DIR}"
TARGET="${TMP}/sensitive-target"
printf '%s\n' 'do-not-touch' > "${TARGET}"
chmod 644 "${TARGET}"
ln -s "${TARGET}" "${SAFE_DIR}/config.lock"
export PROXYCTL_LOCK="${SAFE_DIR}/config.lock"
BEFORE_CONTENT=$(cat "${TARGET}")
BEFORE_PERM=$(file_perm "${TARGET}")
assert_fail lock_acquire config 'symlink lock file is rejected'
assert_eq "$(cat "${TARGET}")" "${BEFORE_CONTENT}" 'symlink target content unchanged'
assert_eq "$(file_perm "${TARGET}")" "${BEFORE_PERM}" 'symlink target permissions unchanged'
assert_fail lock_is_held config 'rejected symlink lock is not marked held'

# ------------------------------------------------------------------------------
# 6. Symlink parent directory is rejected.
# ------------------------------------------------------------------------------
REAL_PARENT="${TMP}/real-parent"
LINK_PARENT="${TMP}/link-parent"
mkdir -m 700 "${REAL_PARENT}"
ln -s "${REAL_PARENT}" "${LINK_PARENT}"
export PROXYCTL_LOCK="${LINK_PARENT}/config.lock"
assert_fail lock_acquire config 'symlink lock parent is rejected'
if [[ -e "${REAL_PARENT}/config.lock" ]]; then
    fail 'symlink parent rejection must not create a lock file in target directory'
else
    pass 'symlink parent rejection creates no target lock file'
fi

# ------------------------------------------------------------------------------
# 7. Non-regular existing lock path is rejected.
# ------------------------------------------------------------------------------
BAD_DIR="${TMP}/bad-type"
mkdir -m 700 "${BAD_DIR}"
mkdir "${BAD_DIR}/config.lock"
export PROXYCTL_LOCK="${BAD_DIR}/config.lock"
assert_fail lock_acquire config 'directory at lock-file path is rejected'

# ------------------------------------------------------------------------------
# 8. Group/world-writable lock directory is rejected.
# ------------------------------------------------------------------------------
OPEN_DIR="${TMP}/open-dir"
mkdir "${OPEN_DIR}"
chmod 777 "${OPEN_DIR}"
export PROXYCTL_LOCK="${OPEN_DIR}/config.lock"
assert_fail lock_acquire config 'world-writable lock directory is rejected'
if [[ -e "${OPEN_DIR}/config.lock" ]]; then
    fail 'insecure parent rejection must not create a lock file'
else
    pass 'insecure parent rejection creates no lock file'
fi

# ------------------------------------------------------------------------------
# Summary
# ------------------------------------------------------------------------------
echo ''
echo "Lock security tests: ${PASSED} passed, ${FAILED} failed"
(( FAILED == 0 ))
