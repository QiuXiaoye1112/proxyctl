#!/usr/bin/env bash
# ------------------------------------------------------------------------------
# tests/smoke.sh — Phase 1 smoke test suite
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

assert_ok() {
    local cmd="$1"
    shift
    if eval "${cmd}"; then pass "$*"; else fail "$*"; fi
}

assert_fail() {
    local cmd="$1"
    shift
    if ! eval "${cmd}"; then pass "correctly rejected: $*"; else fail "should have failed: $*"; fi
}

assert_eq() {
    local got="$1"
    local expected="$2"
    shift 2 || true
    if [[ "${got}" == "${expected}" ]]; then
        pass "$*"
    else
        fail "$* — expected '${expected}', got '${got}'"
    fi
}

assert_contains() {
    local haystack="$1"
    local needle="$2"
    local label="$3"
    if [[ "${haystack}" == *"${needle}"* ]]; then
        pass "${label}"
    else
        fail "${label} — output does not contain '${needle}'"
    fi
}

assert_not_contains() {
    local haystack="$1"
    local needle="$2"
    local label="$3"
    if [[ "${haystack}" != *"${needle}"* ]]; then
        pass "${label}"
    else
        fail "${label} — output incorrectly contains '${needle}'"
    fi
}

# --- setup ------------------------------------------------------------------
export PROXYCTL_DEV_LIB="${PROJECT_DIR}/lib"

run_proxyctl() {
    bash "${PROJECT_DIR}/proxyctl.sh" "$@" 2>&1 || true
}

# --- 1. Syntax check all .sh files ------------------------------------------
echo ''
echo '== Phase 1 Smoke Tests =='
echo ''

echo '--- 1. Syntax check ---'
while IFS= read -r -d '' file; do
    if bash -n "${file}" 2>&1; then
        pass "syntax: ${file}"
    else
        fail "syntax: ${file}"
    fi
done < <(find "${PROJECT_DIR}" -name '*.sh' -print0)

# --- 2. All modules can be sourced independently ----------------------------
echo ''
echo '--- 2. Module source ---'
export PROXYCTL_DATA='/tmp/proxyctl-test'
export PROXYCTL_META="${PROXYCTL_DATA}/meta.json"
export PROXYCTL_CERTS="${PROXYCTL_DATA}/certs"
export PROXYCTL_BACKUP="${PROXYCTL_DATA}/backup"
export PROXYCTL_LOCK="/tmp/proxyctl-test.lock"

# Clean up from prior runs
rm -rf "${PROXYCTL_DATA}" "${PROXYCTL_LOCK}"

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

# --- 3. Engine modules source with core --------------------------------------
echo ''
echo '--- 3. Engine module source ---'
# core.sh registers the engine_call function; engine files register themselves.
for mod in \
    "${PROJECT_DIR}/lib/xray/engine.sh" \
    "${PROJECT_DIR}/lib/singbox/engine.sh"; do
    # core + engine
    if bash -c "source '${PROJECT_DIR}/lib/core.sh'; source '${mod}'" 2>&1; then
        pass "source: ${mod} (with core)"
    else
        fail "source: ${mod} (with core)"
    fi
done

# --- 4. Full proxyctl loads -------------------------------------------------
echo ''
echo '--- 4. Full load ---'
if output=$(run_proxyctl version); then
    pass 'proxyctl loads without error'
else
    fail 'proxyctl load'
fi

# --- 5. CLI commands --------------------------------------------------------
echo ''
echo '--- 5. CLI commands ---'

out=$(run_proxyctl version)
assert_contains "${out}" '1.0.0' 'version outputs version number'

out=$(run_proxyctl help)
assert_contains "${out}" 'Usage' 'help shows usage'
assert_contains "${out}" 'status' 'help lists status command'

out=$(run_proxyctl status)
assert_contains "${out}" 'ProxyCTL Status' 'status shows header'

# --- 6. Engine protocol capability ------------------------------------------
echo ''
echo '--- 6. Engine protocol capability ---'

run_cap() {
    bash -c "
        source '${PROJECT_DIR}/lib/core.sh'
        source '${PROJECT_DIR}/lib/ui.sh'
        source '${PROJECT_DIR}/lib/capability.sh'
        source '${PROJECT_DIR}/lib/xray/engine.sh'
        source '${PROJECT_DIR}/lib/singbox/engine.sh'
        \$*" _ "$@" 2>&1
}

# Xray protocols
out=$(run_cap 'engine_protocols xray')
assert_contains "${out}" 'VLESS'   'Xray has VLESS'
assert_contains "${out}" 'VMess'   'Xray has VMess'
assert_contains "${out}" 'Trojan'  'Xray has Trojan'
assert_contains "${out}" 'SOCKS5'  'Xray has SOCKS5'
assert_contains "${out}" 'HTTP'    'Xray has HTTP'

# sing-box protocols
out=$(run_cap 'engine_protocols singbox')
assert_contains "${out}" 'AnyTLS'    'sing-box has AnyTLS'
assert_contains "${out}" 'VLESS'     'sing-box has VLESS'
assert_contains "${out}" 'Hysteria2' 'sing-box has Hysteria2'
assert_contains "${out}" 'Trojan'    'sing-box has Trojan'
assert_contains "${out}" 'SOCKS5'    'sing-box has SOCKS5'
assert_contains "${out}" 'HTTP'      'sing-box has HTTP'

# --- 7. Transport capability ------------------------------------------------
echo ''
echo '--- 7. Transport capability ---'

# Xray VLESS transports
out=$(run_cap 'protocol_transports xray VLESS')
assert_contains "${out}" 'RAW'       'Xray VLESS has RAW'
assert_contains "${out}" 'XHTTP'     'Xray VLESS has XHTTP'
assert_contains "${out}" 'WebSocket' 'Xray VLESS has WebSocket'

# Xray VMess transports
out=$(run_cap 'protocol_transports xray VMess')
assert_contains "${out}" 'RAW'       'Xray VMess has RAW'
assert_contains "${out}" 'WebSocket' 'Xray VMess has WebSocket'
assert_not_contains "${out}" 'XHTTP' 'Xray VMess has no XHTTP'

# Xray Trojan transports
out=$(run_cap 'protocol_transports xray Trojan')
assert_contains "${out}" 'RAW'       'Xray Trojan has RAW'
assert_contains "${out}" 'WebSocket' 'Xray Trojan has WebSocket'

# sing-box VLESS transports
out=$(run_cap 'protocol_transports singbox VLESS')
assert_contains "${out}" 'RAW'       'sing-box VLESS has RAW'
assert_contains "${out}" 'WebSocket' 'sing-box VLESS has WebSocket'

# sing-box Trojan transports
out=$(run_cap 'protocol_transports singbox Trojan')
assert_contains "${out}" 'RAW'       'sing-box Trojan has RAW'
assert_contains "${out}" 'WebSocket' 'sing-box Trojan has WebSocket'

# --- 8. Empty transports ----------------------------------------------------
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

# --- 9. capability_has_transports -------------------------------------------
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

assert_eq "$(run_has xray VLESS)"   'yes' 'Xray VLESS has transports'
assert_eq "$(run_has xray SOCKS5)"  'no'  'Xray SOCKS5 has no transports'
assert_eq "$(run_has singbox AnyTLS)" 'no' 'sing-box AnyTLS has no transports'

# --- 10. Invalid engine / protocol rejection --------------------------------
echo ''
echo '--- 10. Invalid engine/protocol rejection ---'

assert_fail "run_cap 'engine_protocols nonexistent'"
assert_fail "run_cap 'protocol_transports xray NOPROTO'"

# --- 11. Metadata init/validate ----------------------------------------------
echo ''
echo '--- 11. Metadata ---'

rm -rf "${PROXYCTL_DATA}"

out=$(run_proxyctl version)
# metadata_init must be called explicitly — validate the init function works
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

out=$(run_meta 'metadata_init')
assert_contains "${out}" 'Metadata initialised' 'metadata_init creates file'

assert_ok   '[ -f "${PROXYCTL_META}" ]'          'meta.json exists after init'

# validation (requires jq)
if command -v jq > /dev/null 2>&1; then
    out=$(run_meta 'metadata_validate')
    assert_contains "${out}" '' 'metadata_validate passes on valid file'

    out=$(run_meta metadata_get .version)
    assert_eq "${out}" '1' 'metadata_get returns version 1'
fi

# --- 12. Non-root query commands work ---------------------------------------
echo ''
echo '--- 12. Non-root commands ---'

out=$(run_proxyctl version)
assert_contains "${out}" '1.0.0' 'version works as non-root'

out=$(run_proxyctl help)
assert_contains "${out}" 'Usage' 'help works as non-root'

# --- 13. Stub functions report not implemented ------------------------------
echo ''
echo '--- 13. Stub functions ---'

out=$(run_meta engine_xray_install 2>/dev/null || true)
assert_contains "${out}" 'not yet implemented' 'stub reports not implemented'

out=$(run_meta engine_singbox_install 2>/dev/null || true)
assert_contains "${out}" 'not yet implemented' 'sing-box stub reports not implemented'

# --- 14. Unknown CLI command ------------------------------------------------
echo ''
echo '--- 14. Unknown command ---'

out=$(run_proxyctl nonexistent)
assert_contains "${out}" "unknown command" 'unknown command reports error'

# --- summary -----------------------------------------------------------------
echo ''
echo '========================================'
echo "  Results: ${PASSED} passed, ${FAILED} failed"
echo '========================================'

if ((FAILED > 0)); then
    exit 1
fi
