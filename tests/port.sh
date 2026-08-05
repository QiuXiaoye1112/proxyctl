#!/usr/bin/env bash
# ------------------------------------------------------------------------------
# tests/port.sh — Phase 2.3 port inspection test suite
#
# ss is mocked via PATH; fixtures are controlled through PORT_TEST_* env vars.
# The random-port generator is overridden for deterministic tests.
# ------------------------------------------------------------------------------
set -o errexit
set -o nounset
set -o pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

source "${PROJECT_DIR}/lib/ui.sh"
source "${PROJECT_DIR}/lib/common/port.sh"

PASSED=0
FAILED=0

green() { echo -e "\033[0;32m$*\033[0m"; }
red()   { echo -e "\033[0;31m$*\033[0m"; }

pass() { green "  PASS: $*"; ((++PASSED)); }
fail() { red "  FAIL: $*"; ((++FAILED)); }

assert_eq()   { local got="$1" exp="$2"; shift 2 || true; [[ "${got}" == "${exp}" ]] && pass "$*" || fail "$* — expected '${exp}', got '${got}'"; }
assert_ok()   { local cmd="$1"; shift; if eval "${cmd}"; then pass "$*"; else fail "$*"; fi; }
assert_fail() { local cmd="$1"; shift; if ! eval "${cmd}" 2>/dev/null; then pass "$*"; else fail "$*"; fi; }

# --- mock ss -------------------------------------------------------------------
MOCK_DIR=$(mktemp -d)
export PORT_TEST_LOG="${MOCK_DIR}/port.log"
export PORT_TEST_SS_FAIL=''
export PORT_TEST_TCP_OUT=''
export PORT_TEST_UDP_OUT=''

cat > "${MOCK_DIR}/ss" <<'SSEOF'
#!/usr/bin/env bash
echo "ss $*" >> "${PORT_TEST_LOG}"
if [[ "${PORT_TEST_SS_FAIL:-}" == '1' ]]; then
    exit 1
fi
case " $* " in
    *" -ltnp "*) printf '%s' "${PORT_TEST_TCP_OUT:-}"; exit 0 ;;
    *" -ltn "*)  printf '%s' "${PORT_TEST_TCP_OUT:-}"; exit 0 ;;
    *" -lunp "*) printf '%s' "${PORT_TEST_UDP_OUT:-}"; exit 0 ;;
    *" -lun "*)  printf '%s' "${PORT_TEST_UDP_OUT:-}"; exit 0 ;;
esac
exit 0
SSEOF

chmod +x "${MOCK_DIR}/ss"
export PATH="${MOCK_DIR}:${PATH}"

# --- default TCP/UDP fixtures ---------------------------------------------------
export PORT_TEST_TCP_OUT='LISTEN 0 4096 0.0.0.0:22 0.0.0.0:*
LISTEN 0 4096 [::]:443 [::]:*
LISTEN 0 128 127.0.0.1:8080 0.0.0.0:*
LISTEN 0 128 0.0.0.0:1443 0.0.0.0:*
LISTEN 0 128 0.0.0.0:4430 0.0.0.0:*'

export PORT_TEST_UDP_OUT='UNCONN 0 0 0.0.0.0:53 0.0.0.0:*
UNCONN 0 0 [::]:443 [::]:*'

echo ''
echo '================================================================'
echo '  ProxyCTL Phase 2.3 Port Tests'
echo '================================================================'
echo ''

# ============================================================================
# 1. port_validate matrix
# ============================================================================
echo '--- 1. port_validate ---'

for p in 1 80 443 65535; do
    assert_ok "port_validate '$p'" "port_validate accepts: ${p}"
done

for bad in 0 65536 -1 abc 1.5 +80 ''; do
    assert_fail "port_validate '$bad'" "port_validate rejects: '${bad}'"
done

# ============================================================================
# 2. TCP listening detection (exact port match)
# ============================================================================
echo ''
echo '--- 2. TCP listening ---'

assert_ok "port_is_listening 22 tcp"   '22/tcp is listening'
assert_ok "port_is_listening 443 tcp"  '443/tcp is listening'
assert_ok "port_is_listening 8080 tcp" '8080/tcp is listening'
assert_fail "port_is_listening 80 tcp" '80/tcp is free'

# 443 must not match 1443 or 4430
assert_ok "port_is_listening 1443 tcp" '1443/tcp is listening (exact match)'
assert_ok "port_is_listening 4430 tcp" '4430/tcp is listening (exact match)'

# port_is_free is the inverse
assert_ok "port_is_free 80 tcp"    '80/tcp is free'
assert_fail "port_is_free 443 tcp" '443/tcp is not free'

# IPv6-formatted address [::]:443 is parsed correctly
assert_ok "port_is_listening 443 tcp" '443/tcp detected via [::]:443 entry'

# ============================================================================
# 3. TCP/UDP separation
# ============================================================================
echo ''
echo '--- 3. TCP/UDP separation ---'

assert_ok "port_is_listening 53 udp" '53/udp is listening'
assert_fail "port_is_listening 53 tcp" '53/tcp is free (separate from udp)'
assert_fail "port_is_free 53 udp" '53/udp is not free'
assert_ok "port_is_free 53 tcp" '53/tcp is free'

# ============================================================================
# 4. Inspection failure must fail closed
# ============================================================================
echo ''
echo '--- 4. Inspection failure ---'

export PORT_TEST_SS_FAIL=1
set +e
port_is_listening 443 tcp 2>/dev/null
lis_rc=$?
port_is_free 443 tcp 2>/dev/null
free_rc=$?
set -e
if (( lis_rc != 0 && lis_rc != 1 )); then
    pass 'port_is_listening propagates inspection failure (not 0/1)'
else
    fail "port_is_listening should propagate failure (rc=${lis_rc})"
fi
if (( free_rc != 0 )); then
    pass 'port_is_free does not report free when inspection fails'
else
    fail 'port_is_free must not report free on inspection failure'
fi

set +e
fail_out=$(port_is_free 443 tcp 2>&1 >/dev/null)
set -e
if [[ "${fail_out}" == *'Unable to inspect'* ]]; then
    pass 'inspection failure reports explicit error'
else
    fail "inspection failure should report explicit error: '${fail_out}'"
fi

unset PORT_TEST_SS_FAIL

# ============================================================================
# 5. port_process
# ============================================================================
echo ''
echo '--- 5. port_process ---'

export PORT_TEST_TCP_OUT='LISTEN 0 4096 0.0.0.0:443 0.0.0.0:* users:(("nginx",pid=1234,fd=6))'
assert_eq "$(port_process 443 tcp)" '1234 nginx' 'port_process returns PID NAME'

export PORT_TEST_TCP_OUT='LISTEN 0 4096 0.0.0.0:443 0.0.0.0:*'
assert_eq "$(port_process 443 tcp)" 'unknown' 'port_process returns unknown when info unreadable'

# Not listening → return 1
export PORT_TEST_TCP_OUT='LISTEN 0 4096 0.0.0.0:22 0.0.0.0:*'
set +e
port_process 443 tcp >/dev/null 2>&1
proc_rc=$?
set -e
if (( proc_rc != 0 )); then
    pass 'port_process returns non-zero when port not listening'
else
    fail 'port_process should fail when port not listening'
fi

# Multiple processes are all extracted
export PORT_TEST_TCP_OUT='LISTEN 0 4096 0.0.0.0:443 0.0.0.0:* users:(("xray",pid=111,fd=3),("xray",pid=222,fd=4))'
assert_eq "$(port_process 443 tcp | wc -l | tr -d ' ')" '2' 'port_process extracts all processes'

# ============================================================================
# 6. port_require_free
# ============================================================================
echo ''
echo '--- 6. port_require_free ---'

export PORT_TEST_TCP_OUT='LISTEN 0 4096 0.0.0.0:443 0.0.0.0:* users:(("nginx",pid=1234,fd=6))'
set +e
req_out=$(port_require_free 443 tcp 2>&1 >/dev/null)
req_rc=$?
set -e
if (( req_rc != 0 )); then
    pass 'port_require_free fails when occupied'
else
    fail 'port_require_free should fail when occupied'
fi
if [[ "${req_out}" == *'nginx'* && "${req_out}" == *'1234'* ]]; then
    pass 'port_require_free reports owning process'
else
    fail "port_require_free should report owner: '${req_out}'"
fi

export PORT_TEST_TCP_OUT='LISTEN 0 4096 0.0.0.0:22 0.0.0.0:*'
assert_ok "port_require_free 80 tcp" 'port_require_free succeeds when free'

# ============================================================================
# 7. port_random (deterministic generator override)
# ============================================================================
echo ''
echo '--- 7. port_random ---'

# Override the random generator with a fixed sequence. port_random calls it
# via command substitution (a subshell), so the counter must persist in a file.
_PORT_RANDOM_FILE="${MOCK_DIR}/random-seq"
printf '0\n' > "${_PORT_RANDOM_FILE}"
_port_random_number() {
    local vals=(10000 10001 10002 10003 10004 10005)
    local idx
    idx=$(cat "${_PORT_RANDOM_FILE}")
    printf '%s\n' "${vals[$idx]}"
    printf '%d\n' "$(( idx + 1 ))" > "${_PORT_RANDOM_FILE}"
}

# 10000 and 10001 occupied, 10002 free
export PORT_TEST_TCP_OUT='LISTEN 0 4096 0.0.0.0:10000 0.0.0.0:*
LISTEN 0 4096 0.0.0.0:10001 0.0.0.0:*'

assert_eq "$(port_random 10000 20000 tcp)" '10002' 'port_random returns first free port (10002)'

# All occupied → failure after attempts
printf '0\n' > "${_PORT_RANDOM_FILE}"
export PORT_TEST_TCP_OUT='LISTEN 0 4096 0.0.0.0:10000 0.0.0.0:*
LISTEN 0 4096 0.0.0.0:10001 0.0.0.0:*
LISTEN 0 4096 0.0.0.0:10002 0.0.0.0:*
LISTEN 0 4096 0.0.0.0:10003 0.0.0.0:*
LISTEN 0 4096 0.0.0.0:10004 0.0.0.0:*
LISTEN 0 4096 0.0.0.0:10005 0.0.0.0:*'
set +e
port_random 10000 20000 tcp >/dev/null 2>&1
rand_rc=$?
set -e
if (( rand_rc != 0 )); then
    pass 'port_random fails when range exhausted'
else
    fail 'port_random should fail when all candidates occupied'
fi

# Argument validation
assert_fail "port_random 20000 10000 tcp" 'port_random rejects start > end'
assert_fail "port_random 0 1000 tcp" 'port_random rejects invalid start'

# ============================================================================
# 8. Cleanup
# ============================================================================
echo ''
echo '--- 8. Cleanup ---'

rm -rf "${MOCK_DIR}"

# ============================================================================
# Summary
# ============================================================================
echo ''
echo '================================================================'
echo "  Port tests: ${PASSED} passed, ${FAILED} failed"
echo '================================================================'

if (( FAILED > 0 )); then
    exit 1
fi
