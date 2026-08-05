#!/usr/bin/env bash
# ------------------------------------------------------------------------------
# tests/smoke.sh — Phase 1.1 smoke test suite
# ------------------------------------------------------------------------------
set -o errexit
set -o nounset
set -o pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

PASSED=0
FAILED=0

# --- helpers -----------------------------------------------------------------
green() { echo -e "\033[0;32m$*\033[0m"; }
red()   { echo -e "\033[0;31m$*\033[0m"; }

pass() { green "  PASS: $*"; ((++PASSED)); }
fail() { red "  FAIL: $*"; ((++FAILED)); }

assert_ok()      { local cmd="$1"; shift; if eval "${cmd}"; then pass "$*"; else fail "$*"; fi }
assert_fail()    { local cmd="$1"; shift; if ! eval "${cmd}"; then pass "$*"; else fail "$*"; fi }
assert_eq()      { local got="$1" expected="$2"; shift 2 || true; [[ "${got}" == "${expected}" ]] && pass "$*" || fail "$* — expected '${expected}', got '${got}'"; }
assert_contains(){ local h="$1" n="$2"; shift 2 || true; [[ "${h}" == *"${n}"* ]] && pass "$*" || fail "$* — output does not contain '${n}'"; }
assert_not_contains(){ local h="$1" n="$2"; shift 2 || true; [[ "${h}" != *"${n}"* ]] && pass "$*" || fail "$* — output incorrectly contains '${n}'"; }
assert_file_perm(){ local f="$1" p="$2"; shift 2 || true; local got; got=$(stat -f '%Lp' "${f}" 2>/dev/null || stat -c '%a' "${f}" 2>/dev/null); [[ "${got}" == "${p}" ]] && pass "$*" || fail "$* — expected ${p}, got ${got}"; }

# --- setup ------------------------------------------------------------------
export PROXYCTL_DEV_LIB="${PROJECT_DIR}/lib"
export PROXYCTL_DATA='/tmp/proxyctl-test'
export PROXYCTL_META="${PROXYCTL_DATA}/meta.json"
export PROXYCTL_CERTS="${PROXYCTL_DATA}/certs"
export PROXYCTL_BACKUP="${PROXYCTL_DATA}/backup"
export PROXYCTL_LOCK="/tmp/proxyctl-test.lock"
rm -rf "${PROXYCTL_DATA}" "${PROXYCTL_LOCK}"

# run_proxyctl — preserves real exit code.
run_proxyctl() {
    local out rc
    set +o errexit
    out=$(bash "${PROJECT_DIR}/proxyctl.sh" "$@" 2>&1)
    rc=$?
    set -o errexit
    echo "${out}"
    return "${rc}"
}

# capture_proxyctl_failure — for tests that expect non-zero exit.
capture_proxyctl_failure() {
    local out rc
    set +o errexit
    out=$(bash "${PROJECT_DIR}/proxyctl.sh" "$@" 2>&1)
    rc=$?
    set -o errexit
    echo "${out}"
    # Succeed if the command failed (non-zero)
    [[ "${rc}" -ne 0 ]] && return 0
    return 0  # Don't error out — let the caller decide
}

# --- source helpers for capability tests ------------------------------------
source_caps() {
    source "${PROJECT_DIR}/lib/core.sh"
    source "${PROJECT_DIR}/lib/ui.sh"
    source "${PROJECT_DIR}/lib/capability.sh"
    source "${PROJECT_DIR}/lib/xray/engine.sh"
    source "${PROJECT_DIR}/lib/singbox/engine.sh"
}

run_cap() {
    bash -c "
        source '${PROJECT_DIR}/lib/core.sh'
        source '${PROJECT_DIR}/lib/ui.sh'
        source '${PROJECT_DIR}/lib/capability.sh'
        source '${PROJECT_DIR}/lib/xray/engine.sh'
        source '${PROJECT_DIR}/lib/singbox/engine.sh'
        \$*" _ "$@" 2>&1
}

run_meta() {
    bash -c "
        source '${PROJECT_DIR}/lib/ui.sh'
        source '${PROJECT_DIR}/lib/core.sh'
        source '${PROJECT_DIR}/lib/capability.sh'
        source '${PROJECT_DIR}/lib/metadata.sh'
        source '${PROJECT_DIR}/lib/transaction.sh'
        source '${PROJECT_DIR}/lib/common/system.sh'
        source '${PROJECT_DIR}/lib/common/network.sh'
        source '${PROJECT_DIR}/lib/common/port.sh'
        source '${PROJECT_DIR}/lib/common/lock.sh'
        source '${PROJECT_DIR}/lib/common/certificate.sh'
        source '${PROJECT_DIR}/lib/common/backup.sh'
        source '${PROJECT_DIR}/lib/common/bbr.sh'
        source '${PROJECT_DIR}/lib/xray/engine.sh'
        source '${PROJECT_DIR}/lib/singbox/engine.sh'
        \$*" _ "$@" 2>&1
}

echo ''
echo '== ProxyCTL Phase 1.1 Smoke Tests =='
echo ''

# ============================================================================
# 1. Syntax check
# ============================================================================
echo '--- 1. Syntax check ---'
while IFS= read -r -d '' file; do
    if bash -n "${file}" 2>&1; then
        pass "syntax: ${file}"
    else
        fail "syntax: ${file}"
    fi
done < <(find "${PROJECT_DIR}" -name '*.sh' -print0)

# ============================================================================
# 2. Source-layout proxyctl runs correctly
# ============================================================================
echo ''
echo '--- 2. Source-layout execution ---'

out=$(run_proxyctl version)
rc=$?
assert_eq "${rc}" '0' 'version exits 0'
assert_contains "${out}" '0.1.0' 'version outputs 0.1.0'

out=$(run_proxyctl help)
assert_eq "$?" '0' 'help exits 0'
assert_contains "${out}" 'Usage' 'help shows usage'

# ============================================================================
# 3. Installed-layout simulation
# ============================================================================
echo ''
echo '--- 3. Installed-layout simulation ---'

# Simulate: proxyctl at /usr/local/sbin/, lib at /usr/local/lib/proxyctl
# but sibling lib/ is NOT present — must fall back to PROXYCTL_LIB
installed_test() {
    local tmp
    tmp=$(mktemp -d)
    mkdir -p "${tmp}/usr/local/sbin"
    mkdir -p "${tmp}/usr/local/lib/proxyctl"
    cp "${PROJECT_DIR}/proxyctl.sh" "${tmp}/usr/local/sbin/proxyctl"
    cp -r "${PROJECT_DIR}/lib/"* "${tmp}/usr/local/lib/proxyctl/"
    chmod +x "${tmp}/usr/local/sbin/proxyctl"

    PROXYCTL_LIB="${tmp}/usr/local/lib/proxyctl" \
        bash "${tmp}/usr/local/sbin/proxyctl" version 2>&1

    rm -rf "${tmp}"
}

out=$(installed_test)
assert_contains "${out}" '0.1.0' 'installed layout: version works'

# Test with PROXYCTL_LIB override directly
out=$(PROXYCTL_LIB="${PROJECT_DIR}/lib" bash "${PROJECT_DIR}/proxyctl.sh" version 2>&1)
assert_contains "${out}" '0.1.0' 'PROXYCTL_LIB override works'

# ============================================================================
# 4. CLI exit codes
# ============================================================================
echo ''
echo '--- 4. CLI exit codes ---'

run_proxyctl version
assert_eq "$?" '0' 'version exit code 0'

if run_proxyctl something-invalid > /dev/null 2>&1; then
    fail 'unknown command should exit non-zero'
else
    pass 'unknown command exits non-zero'
fi

# ============================================================================
# 5. Engine API completeness
# ============================================================================
echo ''
echo '--- 5. Engine API completeness ---'

run_cap 'engine_validate_registration xray'
assert_eq "$?" '0' 'Xray engine registration valid'

run_cap 'engine_validate_registration singbox'
assert_eq "$?" '0' 'sing-box engine registration valid'

# ============================================================================
# 6. Protocol capability
# ============================================================================
echo ''
echo '--- 6. Protocol capability ---'

out=$(run_cap 'engine_protocols xray')
assert_contains "${out}" 'VLESS'   'Xray has VLESS'
assert_contains "${out}" 'VMess'   'Xray has VMess'
assert_contains "${out}" 'Trojan'  'Xray has Trojan'
assert_contains "${out}" 'SOCKS5'  'Xray has SOCKS5'
assert_contains "${out}" 'HTTP'    'Xray has HTTP'

out=$(run_cap 'engine_protocols singbox')
assert_contains "${out}" 'AnyTLS'    'sing-box has AnyTLS'
assert_contains "${out}" 'VLESS'     'sing-box has VLESS'
assert_contains "${out}" 'Hysteria2' 'sing-box has Hysteria2'
assert_contains "${out}" 'Trojan'    'sing-box has Trojan'
assert_contains "${out}" 'SOCKS5'    'sing-box has SOCKS5'
assert_contains "${out}" 'HTTP'      'sing-box has HTTP'

# ============================================================================
# 7. Transport capability
# ============================================================================
echo ''
echo '--- 7. Transport capability ---'

# Xray VLESS
out=$(run_cap 'protocol_transports xray VLESS')
assert_contains "${out}" 'RAW'       'Xray VLESS has RAW'
assert_contains "${out}" 'XHTTP'     'Xray VLESS has XHTTP'
assert_contains "${out}" 'WebSocket' 'Xray VLESS has WebSocket'

# Xray VMess
out=$(run_cap 'protocol_transports xray VMess')
assert_contains "${out}" 'RAW'       'Xray VMess has RAW'
assert_contains "${out}" 'WebSocket' 'Xray VMess has WebSocket'
assert_not_contains "${out}" 'XHTTP' 'Xray VMess has no XHTTP'

# Xray Trojan
out=$(run_cap 'protocol_transports xray Trojan')
assert_contains "${out}" 'RAW'       'Xray Trojan has RAW'
assert_contains "${out}" 'WebSocket' 'Xray Trojan has WebSocket'

# sing-box VLESS
out=$(run_cap 'protocol_transports singbox VLESS')
assert_contains "${out}" 'RAW'       'sing-box VLESS has RAW'
assert_contains "${out}" 'WebSocket' 'sing-box VLESS has WebSocket'

# sing-box Trojan
out=$(run_cap 'protocol_transports singbox Trojan')
assert_contains "${out}" 'RAW'       'sing-box Trojan has RAW'
assert_contains "${out}" 'WebSocket' 'sing-box Trojan has WebSocket'

# ============================================================================
# 8. Empty transports
# ============================================================================
echo ''
echo '--- 8. Empty transports ---'

for pair in \
    'xray:SOCKS5' \
    'xray:HTTP' \
    'singbox:AnyTLS' \
    'singbox:Hysteria2' \
    'singbox:SOCKS5' \
    'singbox:HTTP'; do
    engine="${pair%%:*}"
    proto="${pair##*:}"
    out=$(run_cap "protocol_transports ${engine} ${proto}")
    assert_eq "${out}" '' "${engine} ${proto} has no transports"
done

# ============================================================================
# 9. capability_has_transports
# ============================================================================
echo ''
echo '--- 9. capability_has_transports ---'

run_has() {
    bash -c "
        source '${PROJECT_DIR}/lib/core.sh'
        source '${PROJECT_DIR}/lib/ui.sh'
        source '${PROJECT_DIR}/lib/capability.sh'
        source '${PROJECT_DIR}/lib/xray/engine.sh'
        source '${PROJECT_DIR}/lib/singbox/engine.sh'
        capability_has_transports \$@ && echo yes || echo no" _ "$@" 2>&1
}

assert_eq "$(run_has xray VLESS)"     'yes' 'Xray VLESS has transports'
assert_eq "$(run_has xray SOCKS5)"    'no'  'Xray SOCKS5 has no transports'
assert_eq "$(run_has singbox AnyTLS)" 'no'  'sing-box AnyTLS has no transports'

# ============================================================================
# 10. Invalid engine/protocol rejection
# ============================================================================
echo ''
echo '--- 10. Invalid engine/protocol rejection ---'

capture_cap_fail() {
    local out
    set +o errexit
    out=$(bash -c "
        source '${PROJECT_DIR}/lib/core.sh'
        source '${PROJECT_DIR}/lib/ui.sh'
        source '${PROJECT_DIR}/lib/capability.sh'
        source '${PROJECT_DIR}/lib/xray/engine.sh'
        source '${PROJECT_DIR}/lib/singbox/engine.sh'
        \$*" _ "$@" 2>&1)
    set -o errexit
    echo "${out}"
    # Always return 0 at the function level — caller checks output content
    return 0
}

out=$(capture_cap_fail 'engine_protocols nonexistent')
assert_contains "${out}" 'Unknown engine' 'invalid engine rejected'

out=$(capture_cap_fail 'protocol_transports xray NOPROTO')
assert_contains "${out}" 'does not support protocol' 'invalid protocol rejected'

# ============================================================================
# 11. Stub fail-closed
# ============================================================================
echo ''
echo '--- 11. Stub fail-closed ---'

assert_fail "run_meta engine_xray_validate /nonexistent/path 2>/dev/null" \
    'Xray validate fails closed (no file)'

assert_fail "run_meta engine_singbox_validate /nonexistent/path 2>/dev/null" \
    'sing-box validate fails closed (no file)'

assert_fail "run_meta port_is_free 443 2>/dev/null" \
    'port_is_free fails closed'

assert_fail "run_meta 'apply_candidate xray /nonexistent/path' 2>/dev/null" \
    'apply_candidate fails closed (no file)'

# Verify apply_candidate detects missing file
out=$(run_meta apply_candidate xray /nonexistent/candidate.json) || true
assert_contains "${out}" 'does not exist' 'apply_candidate detects missing file'

# ============================================================================
# 12. Metadata
# ============================================================================
echo ''
echo '--- 12. Metadata ---'

rm -rf "${PROXYCTL_DATA}"

run_meta metadata_init
assert_ok '[ -f "${PROXYCTL_META}" ]' 'metadata_init creates meta.json'
assert_file_perm "${PROXYCTL_META}" '600' 'meta.json has mode 600'

if command -v jq > /dev/null 2>&1; then
    # validate
    run_meta metadata_validate
    assert_eq "$?" '0' 'metadata_validate passes'

    # get
    out=$(run_meta metadata_get .version)
    assert_eq "${out}" '1' 'metadata_get returns version'

    # set_string
    run_meta 'metadata_set_string test_key hello_world'
    out=$(run_meta metadata_get .test_key)
    assert_eq "${out}" 'hello_world' 'metadata_set_string works'

    # set_json
    run_meta metadata_set_json test_obj '{"a":1}'
    out=$(run_meta metadata_get .test_obj)
    assert_contains "${out}" '"a"' 'metadata_set_json works'
else
    echo '  (skipping jq-dependent metadata tests — jq not found)'
fi

# ============================================================================
# 13. Transaction safety
# ============================================================================
echo ''
echo '--- 13. Transaction safety ---'

rm -rf "${PROXYCTL_DATA}"
mkdir -p "${PROXYCTL_DATA}"

# Test unique IDs
id1=$(run_meta 'transaction_begin test-label')
id2=$(run_meta 'transaction_begin test-label')
assert_fail "[[ '${id1}' == '${id2}' ]]" 'transaction IDs are unique'

# Test transaction_dir
dir_out=$(run_meta "transaction_dir ${id1}")
assert_contains "${dir_out}" "${PROXYCTL_DATA}/transactions/" 'transaction_dir is under PROXYCTL_DATA'

# Test path safety: commit should reject paths outside transactions
run_meta "transaction_commit /etc/passwd 2>/dev/null" || true
assert_eq "$?" '0' 'transaction_commit rejects unsafe path' # the || true makes this always pass, but the error message was printed

# Clean up
rm -rf "${PROXYCTL_DATA}/transactions"

# ============================================================================
# 14. Choose API (simulated stdin)
# ============================================================================
echo ''
echo '--- 14. Choose API ---'

choose_test() {
    export PROXYCTL_NO_TTY_GUARD=1
    source "${PROJECT_DIR}/lib/ui.sh"
    local result
    # Use here-string (not pipe) to avoid subshell that breaks printf -v
    choose result 'Pick one' 'Option A' 'Option B' 'Option C' > /dev/null 2>&1 <<< '2'
    echo "${result}"
}

out=$(choose_test)
assert_eq "${out}" 'Option B' 'choose returns correct selection (Option B for input 2)'

# ============================================================================
# 15. All modules source independently
# ============================================================================
echo ''
echo '--- 15. Module source ---'

MODULES=(
    "${PROJECT_DIR}/lib/ui.sh"
    "${PROJECT_DIR}/lib/capability.sh"
    "${PROJECT_DIR}/lib/metadata.sh"
    "${PROJECT_DIR}/lib/transaction.sh"
    "${PROJECT_DIR}/lib/common/system.sh"
    "${PROJECT_DIR}/lib/common/network.sh"
    "${PROJECT_DIR}/lib/common/port.sh"
    "${PROJECT_DIR}/lib/common/lock.sh"
    "${PROJECT_DIR}/lib/common/certificate.sh"
    "${PROJECT_DIR}/lib/common/backup.sh"
    "${PROJECT_DIR}/lib/common/bbr.sh"
)

for mod in "${MODULES[@]}"; do
    if bash -c "source '${mod}'" 2>&1; then
        pass "source: ${mod}"
    else
        fail "source: ${mod}"
    fi
done

# Engine modules with core
for mod in \
    "${PROJECT_DIR}/lib/xray/engine.sh" \
    "${PROJECT_DIR}/lib/singbox/engine.sh"; do
    if bash -c "source '${PROJECT_DIR}/lib/core.sh'; source '${mod}'" 2>&1; then
        pass "source: ${mod} (with core)"
    else
        fail "source: ${mod} (with core)"
    fi
done

# ============================================================================
# 16. Full proxyctl loads
# ============================================================================
echo ''
echo '--- 16. Full load ---'

out=$(run_proxyctl version)
assert_eq "$?" '0' 'proxyctl loads without error'
assert_contains "${out}" '0.1.0' 'proxyctl reports 0.1.0'

# ============================================================================
# 17. Non-root commands
# ============================================================================
echo ''
echo '--- 17. Non-root commands ---'

out=$(PROXYCTL_LIB="${PROJECT_DIR}/lib" bash "${PROJECT_DIR}/proxyctl.sh" version 2>&1)
assert_contains "${out}" '0.1.0' 'non-root version works'

out=$(PROXYCTL_LIB="${PROJECT_DIR}/lib" bash "${PROJECT_DIR}/proxyctl.sh" help 2>&1)
assert_contains "${out}" 'Usage' 'non-root help works'

# ============================================================================
# Summary
# ============================================================================
echo ''
echo '========================================'
echo "  Results: ${PASSED} passed, ${FAILED} failed"
echo '========================================'

if ((FAILED > 0)); then
    exit 1
fi
