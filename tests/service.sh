#!/usr/bin/env bash
# ------------------------------------------------------------------------------
# tests/service.sh — Phase 2.2 service abstraction test suite
#
# Uses mock systemctl / rc-service / rc-update / journalctl injected via PATH.
# The init system is forced via PROXYCTL_TEST_INIT and the root check is
# decoupled via mock_root / mock_non_root, so tests are deterministic
# regardless of the host (CI or non-root included).
# ------------------------------------------------------------------------------
set -o errexit
set -o nounset
set -o pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

source "${PROJECT_DIR}/lib/ui.sh"
source "${PROJECT_DIR}/lib/common/system.sh"
source "${PROJECT_DIR}/lib/common/service.sh"

PASSED=0
FAILED=0

green() { echo -e "\033[0;32m$*\033[0m"; }
red()   { echo -e "\033[0;31m$*\033[0m"; }

pass() { green "  PASS: $*"; ((++PASSED)); }
fail() { red "  FAIL: $*"; ((++FAILED)); }

assert_eq() { local got="$1" exp="$2"; shift 2 || true; [[ "${got}" == "${exp}" ]] && pass "$*" || fail "$* — expected '${exp}', got '${got}'"; }

# --- root mocks ---------------------------------------------------------------
# Decouple the service write ops from the real EUID.
mock_root()     { system_is_root() { return 0; }; }
mock_non_root() { system_is_root() { return 1; }; }
mock_root

# --- mock init system binaries ------------------------------------------------
MOCK_DIR=$(mktemp -d)
export SERVICE_TEST_LOG="${MOCK_DIR}/calls.log"
export SERVICE_TEST_RCUP_OUT=''

cat > "${MOCK_DIR}/systemctl" <<'MOCKEOF'
#!/usr/bin/env bash
echo "systemctl $*" >> "${SERVICE_TEST_LOG}"

# service_exists uses `systemctl show --property=LoadState --value NAME.service`.
# Return loaded for known test services and not-found for everything else.
if [[ "${1:-}" == 'show' && "${2:-}" == '--property=LoadState' && "${3:-}" == '--value' ]]; then
    case "${4:-}" in
        xray.service|sing-box.service|foo.service)
            printf '%s\n' 'loaded'
            ;;
        *)
            printf '%s\n' 'not-found'
            ;;
    esac
fi
exit 0
MOCKEOF

cat > "${MOCK_DIR}/journalctl" <<'MOCKEOF'
#!/usr/bin/env bash
echo "journalctl $*" >> "${SERVICE_TEST_LOG}"
exit 0
MOCKEOF

cat > "${MOCK_DIR}/rc-service" <<'MOCKEOF'
#!/usr/bin/env bash
echo "rc-service $*" >> "${SERVICE_TEST_LOG}"
exit 0
MOCKEOF

cat > "${MOCK_DIR}/rc-update" <<'MOCKEOF'
#!/usr/bin/env bash
echo "rc-update $*" >> "${SERVICE_TEST_LOG}"
if [[ -n "${SERVICE_TEST_RCUP_OUT:-}" ]]; then
    printf '%s\n' "${SERVICE_TEST_RCUP_OUT}"
fi
exit 0
MOCKEOF

chmod +x "${MOCK_DIR}"/systemctl "${MOCK_DIR}"/journalctl "${MOCK_DIR}"/rc-service "${MOCK_DIR}"/rc-update
export PATH="${MOCK_DIR}:${PATH}"

reset_log() { : > "${SERVICE_TEST_LOG}"; }
last_call() { tail -1 "${SERVICE_TEST_LOG}"; }
calls_count() { wc -l < "${SERVICE_TEST_LOG}" | tr -d ' '; }

echo ''
echo '================================================================'
echo '  ProxyCTL Phase 2.2 Service Tests'
echo '================================================================'
echo ''

# ============================================================================
# 1. Service name validation (no command may ever be invoked)
# ============================================================================
echo '--- 1. Service name validation ---'

export PROXYCTL_TEST_INIT=systemd

# Valid names pass validation (write op proceeds to mocked systemctl).
for good in xray sing-box foo.service foo@bar nginx-1; do
    reset_log
    set +e
    service_start "$good" > /dev/null 2>&1
    good_rc=$?
    set -e
    if (( good_rc == 0 )); then
        pass "service_start accepts: ${good}"
    else
        fail "service_start should accept: ${good} (rc=${good_rc})"
    fi
done

# Traversal / dot / space names must be rejected with NO command invocation.
for bad in '.' '..' '../xray' '/etc/passwd' 'a b' '.foo'; do
    reset_log
    set +e
    service_start "$bad" > /dev/null 2>&1
    bad_rc=$?
    set -e
    if (( bad_rc != 0 )); then
        pass "service_start rejects: ${bad}"
    else
        fail "service_start should reject: ${bad}"
    fi
    assert_eq "$(calls_count)" '0' "no command invoked for: ${bad}"
done

# ============================================================================
# 2. Non-root write operations are refused
# ============================================================================
echo ''
echo '--- 2. Non-root rejection ---'

mock_non_root

for op in start stop restart enable disable; do
    reset_log
    set +e
    "service_${op}" xray > /dev/null 2>&1
    op_rc=$?
    set -e
    if (( op_rc != 0 )); then
        pass "non-root: service_${op} refused"
    else
        fail "non-root: service_${op} should be refused"
    fi
    assert_eq "$(calls_count)" '0' "non-root: no command for service_${op}"
done

mock_root

# ============================================================================
# 3. systemd mapping (forced, root mocked)
# ============================================================================
echo ''
echo '--- 3. systemd mapping ---'

export PROXYCTL_TEST_INIT=systemd

reset_log
service_start xray
assert_eq "$(last_call)" 'systemctl start xray' 'systemd: service_start → systemctl start xray'

reset_log
service_stop xray
assert_eq "$(last_call)" 'systemctl stop xray' 'systemd: service_stop → systemctl stop xray'

reset_log
service_restart xray
assert_eq "$(last_call)" 'systemctl restart xray' 'systemd: service_restart → systemctl restart xray'

reset_log
service_enable xray
assert_eq "$(last_call)" 'systemctl enable xray' 'systemd: service_enable → systemctl enable xray'

reset_log
service_disable xray
assert_eq "$(last_call)" 'systemctl disable xray' 'systemd: service_disable → systemctl disable xray'

reset_log
service_is_active xray
assert_eq "$(last_call)" 'systemctl is-active --quiet xray' 'systemd: is_active → systemctl is-active --quiet xray'

reset_log
service_is_enabled xray
assert_eq "$(last_call)" 'systemctl is-enabled --quiet xray' 'systemd: is_enabled → systemctl is-enabled --quiet xray'

# Existing service: mock returns LoadState=loaded.
reset_log
set +e
service_exists xray
exists_rc=$?
set -e
if (( exists_rc == 0 )); then
    pass 'systemd: service_exists true for loaded service'
else
    fail 'systemd: service_exists should be true for loaded service'
fi
assert_eq "$(last_call)" 'systemctl show --property=LoadState --value xray.service' 'systemd: exists queries LoadState'

# Missing service: systemctl still exits 0, but LoadState=not-found must return false.
reset_log
set +e
service_exists definitely-missing
missing_rc=$?
set -e
if (( missing_rc != 0 )); then
    pass 'systemd: service_exists false for LoadState=not-found'
else
    fail 'systemd: service_exists should reject LoadState=not-found'
fi
assert_eq "$(last_call)" 'systemctl show --property=LoadState --value definitely-missing.service' 'systemd: missing exists query uses LoadState'

reset_log
service_logs xray 25
assert_eq "$(last_call)" 'journalctl -u xray -n 25 --no-pager' 'systemd: logs → journalctl -u xray -n 25 --no-pager'

reset_log
service_start sing-box
assert_eq "$(last_call)" 'systemctl start sing-box' 'systemd: sing-box name passed through'

# ============================================================================
# 4. OpenRC mapping (forced, root mocked)
# ============================================================================
echo ''
echo '--- 4. OpenRC mapping ---'

export PROXYCTL_TEST_INIT=openrc

reset_log
service_start xray
assert_eq "$(last_call)" 'rc-service xray start' 'openrc: service_start → rc-service xray start'

reset_log
service_stop xray
assert_eq "$(last_call)" 'rc-service xray stop' 'openrc: service_stop → rc-service xray stop'

reset_log
service_restart xray
assert_eq "$(last_call)" 'rc-service xray restart' 'openrc: service_restart → rc-service xray restart'

reset_log
service_enable xray
assert_eq "$(last_call)" 'rc-update add xray default' 'openrc: service_enable → rc-update add xray default'

reset_log
service_disable xray
assert_eq "$(last_call)" 'rc-update del xray default' 'openrc: service_disable → rc-update del xray default'

reset_log
service_is_active xray
assert_eq "$(last_call)" 'rc-service xray status' 'openrc: is_active → rc-service xray status'

# is_enabled: exact first-field match, enabled when listed
reset_log
export SERVICE_TEST_RCUP_OUT=' xray | default'
set +e
service_is_enabled xray
enabled_rc=$?
set -e
if (( enabled_rc == 0 )); then
    pass 'openrc: is_enabled true when service in rc-update'
else
    fail 'openrc: is_enabled should be true when listed'
fi

# is_enabled: exact match must NOT match a similar-but-different name
reset_log
export SERVICE_TEST_RCUP_OUT=' xray-test2 | default'
set +e
service_is_enabled xray-test
near_rc=$?
set -e
if (( near_rc != 0 )); then
    pass 'openrc: is_enabled exact match rejects xray-test2 for xray-test'
else
    fail 'openrc: is_enabled should not match a partial name'
fi

# is_enabled: absent → not enabled
reset_log
export SERVICE_TEST_RCUP_OUT=''
set +e
service_is_enabled nginx
disabled_rc=$?
set -e
if (( disabled_rc != 0 )); then
    pass 'openrc: is_enabled false when service absent'
else
    fail 'openrc: is_enabled should be false when absent'
fi

# exists: /etc/init.d/<name> executable (deterministically absent here)
reset_log
set +e
service_exists zzz-proxyctl-test-zzz
exists_rc=$?
set -e
if (( exists_rc != 0 )); then
    pass 'openrc: exists false when init script absent'
else
    fail 'openrc: exists should be false for absent init script'
fi

# logs: no log file → explicit failure (no fake success)
reset_log
set +e
log_out=$(service_logs zzz-proxyctl-test-zzz 2>&1)
log_rc=$?
set -e
if (( log_rc != 0 )) && [[ "${log_out}" == *'No log file found'* ]]; then
    pass 'openrc: logs fails explicitly when no log file'
else
    fail "openrc: logs should fail explicitly (rc=${log_rc}, out='${log_out}')"
fi

# ============================================================================
# 5. service_logs line-count validation
# ============================================================================
echo ''
echo '--- 5. service_logs line validation ---'

export PROXYCTL_TEST_INIT=systemd

for bad in 0 -1 abc 1.5 10001; do
    reset_log
    set +e
    service_logs xray "$bad" > /dev/null 2>&1
    bad_rc=$?
    set -e
    if (( bad_rc != 0 )); then
        pass "service_logs rejects lines='${bad}'"
    else
        fail "service_logs should reject lines='${bad}'"
    fi
    assert_eq "$(calls_count)" '0' "no journalctl for lines='${bad}'"
done

# Explicit empty argument must also be rejected (not defaulted)
reset_log
set +e
service_logs xray '' > /dev/null 2>&1
empty_rc=$?
set -e
if (( empty_rc != 0 )); then
    pass "service_logs rejects empty lines"
else
    fail 'service_logs should reject empty lines'
fi
assert_eq "$(calls_count)" '0' 'no journalctl for empty lines'

# Boundary values are accepted
for ok in 1 50 10000; do
    reset_log
    set +e
    service_logs xray "$ok" > /dev/null 2>&1
    ok_rc=$?
    set -e
    if (( ok_rc == 0 )); then
        pass "service_logs accepts lines=${ok}"
    else
        fail "service_logs should accept lines=${ok}"
    fi
    assert_eq "$(last_call)" "journalctl -u xray -n ${ok} --no-pager" "journalctl uses -n ${ok}"
done

# Default (no arg) is 50
reset_log
service_logs xray
assert_eq "$(last_call)" 'journalctl -u xray -n 50 --no-pager' 'service_logs defaults to 50 lines'

# ============================================================================
# 6. Cleanup
# ============================================================================
echo ''
echo '--- 6. Cleanup ---'

rm -rf "${MOCK_DIR}"

# ============================================================================
# Summary
# ============================================================================
echo ''
echo '================================================================'
echo "  Service tests: ${PASSED} passed, ${FAILED} failed"
echo '================================================================'

if (( FAILED > 0 )); then
    exit 1
fi
