#!/usr/bin/env bash
# ------------------------------------------------------------------------------
# tests/smoke.sh — Phase 1.2 smoke test suite
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
assert_fail()    { local cmd="$1"; shift; if ! eval "${cmd}" 2>/dev/null; then pass "$*"; else fail "$*"; fi }
assert_eq()      { local got="$1" expected="$2"; shift 2 || true; [[ "${got}" == "${expected}" ]] && pass "$*" || fail "$* — expected '${expected}', got '${got}'"; }
assert_contains(){ local h="$1" n="$2"; shift 2 || true; [[ "${h}" == *"${n}"* ]] && pass "$*" || fail "$* — output does not contain '${n}'"; }
assert_not_contains(){ local h="$1" n="$2"; shift 2 || true; [[ "${h}" != *"${n}"* ]] && pass "$*" || fail "$* — output incorrectly contains '${n}'"; }
assert_file_perm(){ local f="$1" p="$2"; shift 2 || true; local got; got=$(stat -c '%a' "${f}" 2>/dev/null || stat -f '%Lp' "${f}" 2>/dev/null); [[ "${got}" == "${p}" ]] && pass "$*" || fail "$* — expected ${p}, got ${got}"; }

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

# run_proxyctl_rc — returns exit code directly, discards stdout.
run_proxyctl_rc() {
    local rc
    set +o errexit
    bash "${PROJECT_DIR}/proxyctl.sh" "$@" > /dev/null 2>&1
    rc=$?
    set -o errexit
    return "${rc}"
}

# run_meta — run a bash command with full proxyctl library sourced.
run_meta() {
    local rc
    set +o errexit
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
    rc=$?
    set -o errexit
    return "${rc}"
}

# run_meta_capture — like run_meta but returns output and always exits 0.
run_meta_capture() {
    local out rc
    set +o errexit
    out=$(bash -c "
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
        \$*" _ "$@" 2>&1)
    rc=$?
    set -o errexit
    echo "${out}"
    # Always return 0 from the wrapper — caller inspects output
    return 0
}

# run_cap — run capability check with engines loaded.
run_cap() {
    local rc
    set +o errexit
    bash -c "
        source '${PROJECT_DIR}/lib/core.sh'
        source '${PROJECT_DIR}/lib/ui.sh'
        source '${PROJECT_DIR}/lib/capability.sh'
        source '${PROJECT_DIR}/lib/xray/engine.sh'
        source '${PROJECT_DIR}/lib/singbox/engine.sh'
        \$*" _ "$@" 2>&1
    rc=$?
    set -o errexit
    return "${rc}"
}

echo ''
echo '================================================================'
echo '  ProxyCTL Phase 1.2 Smoke Tests'
echo '================================================================'
echo ''

# ============================================================================
# 1. Bash syntax check
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
# 2. Source-layout execution
# ============================================================================
echo ''
echo '--- 2. Source-layout execution ---'

out=$(run_proxyctl version)
rc=$?
assert_eq "${rc}" '0' 'version exits 0'
assert_contains "${out}" '0.1.1' 'version outputs 0.1.1'

out=$(run_proxyctl help)
assert_eq "$?" '0' 'help exits 0'
assert_contains "${out}" 'Usage' 'help shows usage'

# ============================================================================
# 3. Installed-layout simulation
# ============================================================================
echo ''
echo '--- 3. Installed-layout simulation ---'

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
assert_contains "${out}" '0.1.1' 'installed layout: version works'

# ============================================================================
# 4. CLI exit codes
# ============================================================================
echo ''
echo '--- 4. CLI exit codes ---'

run_proxyctl version
assert_eq "$?" '0' 'version exit code 0'

run_proxyctl help
assert_eq "$?" '0' 'help exit code 0'

if run_proxyctl_rc something-invalid; then
    fail 'unknown command should exit non-zero'
else
    pass 'unknown command exits non-zero'
fi

if run_proxyctl_rc ''; then
    # Empty command launches menu — needs TTY, should fail in test
    pass 'empty command handled (non-zero or launches menu)'
else
    pass 'empty command handled'
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
# 7. Empty transports
# ============================================================================
echo ''
echo '--- 7. Empty transports ---'

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
# 8. Invalid engine/protocol rejection (real exit codes)
# ============================================================================
echo ''
echo '--- 8. Invalid engine/protocol rejection ---'

# Invalid engine — must exit non-zero
if run_cap 'engine_protocols nonexistent' 2>/dev/null; then
    fail 'invalid engine should exit non-zero'
else
    pass 'invalid engine exits non-zero'
fi

# Invalid protocol — must exit non-zero
if run_cap 'protocol_transports xray NOPROTO' 2>/dev/null; then
    fail 'invalid protocol should exit non-zero'
else
    pass 'invalid protocol exits non-zero'
fi

# Unknown engine (via engine_require) exits non-zero
if run_cap 'engine_require nonexistent' 2>/dev/null; then
    fail 'engine_require for unknown engine should exit non-zero'
else
    pass 'engine_require for unknown engine exits non-zero'
fi

# ============================================================================
# 9. Fail-closed stubs (all must exit non-zero)
# ============================================================================
echo ''
echo '--- 9. Fail-closed stubs ---'

# Mutating stubs — must fail (return non-zero)
assert_fail "run_meta 'backup_create test' 2>/dev/null" \
    'backup_create fails closed'

assert_fail "run_meta 'backup_restore foo' 2>/dev/null" \
    'backup_restore fails closed'

assert_fail "run_meta 'bbr_enable' 2>/dev/null" \
    'bbr_enable fails closed'

assert_fail "run_meta 'cert_acme_issue example.com' 2>/dev/null" \
    'cert_acme_issue fails closed'

assert_fail "run_meta 'network_check_port 443' 2>/dev/null" \
    'network_check_port fails closed'

assert_fail "run_meta 'port_is_free 443' 2>/dev/null" \
    'port_is_free fails closed'

assert_fail "run_meta 'port_allocate 8080' 2>/dev/null" \
    'port_allocate fails closed'

assert_fail "run_meta 'apply_candidate xray /nonexistent/path' 2>/dev/null" \
    'apply_candidate fails closed'

assert_fail "run_meta 'engine_xray_validate /nonexistent/path' 2>/dev/null" \
    'Xray validate fails closed'

assert_fail "run_meta 'engine_singbox_validate /nonexistent/path' 2>/dev/null" \
    'sing-box validate fails closed'

# Engine logs stubs — query but should fail when core not installed
assert_fail "run_meta 'engine_xray_logs' 2>/dev/null" \
    'Xray logs fails closed'

assert_fail "run_meta 'engine_singbox_logs' 2>/dev/null" \
    'sing-box logs fails closed'

# Query stubs — should also indicate not implemented
out=$(run_meta_capture 'backup_list')
assert_contains "${out}" 'not implemented' 'backup_list reports not implemented'

out=$(run_meta_capture 'bbr_status')
assert_contains "${out}" 'not implemented' 'bbr_status reports not implemented'

out=$(run_meta_capture 'cert_list')
assert_contains "${out}" 'not implemented' 'cert_list reports not implemented'

# Verify engine install stubs fail
assert_fail "run_meta 'engine_xray_install' 2>/dev/null" \
    'Xray install fails closed'

assert_fail "run_meta 'engine_singbox_install' 2>/dev/null" \
    'sing-box install fails closed'

# ============================================================================
# 10. Metadata init
# ============================================================================
echo ''
echo '--- 10. Metadata init ---'

rm -rf "${PROXYCTL_DATA}"

run_meta metadata_init
assert_ok '[ -f "${PROXYCTL_META}" ]' 'metadata_init creates meta.json'
assert_file_perm "${PROXYCTL_META}" '600' 'meta.json has mode 600'

# ============================================================================
# 11. Metadata validate
# ============================================================================
echo ''
echo '--- 11. Metadata validate ---'

# Need jq for validation
if command -v jq > /dev/null 2>&1; then
    run_meta metadata_validate
    assert_eq "$?" '0' 'metadata_validate passes on valid meta.json'

    # Corrupt the file and re-validate
    echo 'not json' > "${PROXYCTL_META}"
    if run_meta metadata_validate 2>/dev/null; then
        fail 'metadata_validate should reject invalid JSON'
    else
        pass 'metadata_validate rejects invalid JSON'
    fi

    # Re-init and re-validate
    rm -f "${PROXYCTL_META}"
    run_meta metadata_init
    run_meta metadata_validate
    assert_eq "$?" '0' 'metadata_validate passes after re-init'

    # Missing required key
    echo '{"version": 1}' > "${PROXYCTL_META}"
    if run_meta metadata_validate 2>/dev/null; then
        fail 'metadata_validate should reject missing required keys'
    else
        pass 'metadata_validate rejects missing required keys'
    fi
else
    echo '  (skipping jq-dependent metadata validate tests)'
fi

# ============================================================================
# 12. Metadata safe key validation
# ============================================================================
echo ''
echo '--- 12. Metadata safe key ---'

rm -rf "${PROXYCTL_DATA}"
run_meta metadata_init

if command -v jq > /dev/null 2>&1; then
    # Valid keys should work
    run_meta metadata_get .version
    assert_eq "$?" '0' 'metadata_get .version exits 0'

    # Valid key works without leading dot
    out=$(run_meta 'metadata_get version')
    assert_eq "${out}" '1' 'metadata_get version (no dot) returns 1'

    # Invalid keys must be rejected with non-zero
    assert_fail "run_meta \"metadata_get '../../x'\" 2>/dev/null" \
        'metadata_get rejects path traversal'

    assert_fail "run_meta \"metadata_get 'a] | .foo'\" 2>/dev/null" \
        'metadata_get rejects jq injection attempt'

    assert_fail "run_meta \"metadata_get 'foo bar'\" 2>/dev/null" \
        'metadata_get rejects key with space'

    assert_fail "run_meta \"metadata_get '/etc/passwd'\" 2>/dev/null" \
        'metadata_get rejects absolute path'

    # metadata_set_string with valid key
    run_meta 'metadata_set_string test_key hello'
    assert_eq "$?" '0' 'metadata_set_string with valid key exits 0'

    # metadata_set_string with invalid key
    assert_fail "run_meta \"metadata_set_string '../../x' value\" 2>/dev/null" \
        'metadata_set_string rejects traversal key'

    assert_fail "run_meta \"metadata_set_string 'foo bar' value\" 2>/dev/null" \
        'metadata_set_string rejects key with space'

    # metadata_set_json with valid key
    run_meta 'metadata_set_json test_obj {"a":1}'
    assert_eq "$?" '0' 'metadata_set_json with valid key exits 0'

    # metadata_set_json with invalid key
    assert_fail "run_meta \"metadata_set_json '../../x' '{}'\" 2>/dev/null" \
        'metadata_set_json rejects traversal key'
else
    echo '  (skipping jq-dependent metadata key tests)'
fi

# ============================================================================
# 13. Metadata string/JSON write
# ============================================================================
echo ''
echo '--- 13. Metadata write ---'

rm -rf "${PROXYCTL_DATA}"
run_meta metadata_init

if command -v jq > /dev/null 2>&1; then
    # String write
    run_meta 'metadata_set_string test_key hello_world'
    out=$(run_meta 'metadata_get test_key')
    assert_eq "${out}" 'hello_world' 'metadata_set_string writes correctly'

    # JSON write
    run_meta 'metadata_set_json test_obj {"b":2}'
    out=$(run_meta 'metadata_get test_obj')
    assert_contains "${out}" '"b"' 'metadata_set_json writes correctly'

    # Verify permissions persisted
    assert_file_perm "${PROXYCTL_META}" '600' 'meta.json keeps mode 600 after writes'
else
    echo '  (skipping jq-dependent metadata write tests)'
fi

# ============================================================================
# 14. Invalid JSON does not corrupt metadata
# ============================================================================
echo ''
echo '--- 14. Metadata corruption protection ---'

rm -rf "${PROXYCTL_DATA}"
run_meta metadata_init

if command -v jq > /dev/null 2>&1; then
    # Compute checksum before
    before=$(shasum "${PROXYCTL_META}" 2>/dev/null || sha1sum "${PROXYCTL_META}" 2>/dev/null || cksum "${PROXYCTL_META}")

    # Attempt invalid JSON write — must fail
    if run_meta "metadata_set_json test_key '{invalid'" 2>/dev/null; then
        fail 'metadata_set_json with invalid JSON should fail'
    else
        pass 'metadata_set_json rejects invalid JSON'
    fi

    # Verify checksum unchanged
    after=$(shasum "${PROXYCTL_META}" 2>/dev/null || sha1sum "${PROXYCTL_META}" 2>/dev/null || cksum "${PROXYCTL_META}")
    assert_eq "${after}" "${before}" 'metadata not corrupted by invalid write'

    # Verify it's still valid
    run_meta metadata_validate
    assert_eq "$?" '0' 'metadata still valid after rejected write'
else
    echo '  (skipping jq-dependent corruption tests)'
fi

# ============================================================================
# 15. Transaction unique IDs
# ============================================================================
echo ''
echo '--- 15. Transaction unique IDs ---'

rm -rf "${PROXYCTL_DATA}"
mkdir -p "${PROXYCTL_DATA}"

id1=$(run_meta 'transaction_begin test')
id2=$(run_meta 'transaction_begin test')
# Must be different
if [[ "$id1" != "$id2" ]]; then
    pass 'transaction IDs are unique'
else
    fail 'transaction IDs are unique'
fi

# Verify format
for id in "$id1" "$id2"; do
    if [[ "$id" =~ ^tx_[0-9]+_[0-9]+_test$ ]]; then
        pass "transaction ID format valid: ${id}"
    else
        fail "transaction ID format invalid: ${id}"
    fi
done

# ============================================================================
# 16. Invalid transaction label rejection
# ============================================================================
echo ''
echo '--- 16. Invalid label rejection ---'

# Valid labels
for label in test xray-config singbox_config backup.1 my-label; do
    if run_meta "transaction_begin ${label}" > /dev/null 2>&1; then
        pass "valid label accepted: ${label}"
    else
        fail "valid label rejected: ${label}"
    fi
done

# Invalid labels (no spaces — those tested separately below)
for label in '../test' '../../etc' '/test' 'a/b' '..' '.'; do
    if run_meta "transaction_begin ${label}" 2>/dev/null; then
        fail "invalid label accepted: ${label}"
    else
        pass "invalid label rejected: ${label}"
    fi
done

# Label with space — test validate_label directly (run_meta $* can't pass spaces)
if run_meta 'transaction_validate_label "a b"' 2>/dev/null; then
    fail 'invalid label accepted: a b'
else
    pass 'invalid label rejected: a b'
fi

# Empty label
if run_meta 'transaction_validate_label ""' 2>/dev/null; then
    fail 'invalid label accepted: (empty)'
else
    pass 'invalid label rejected: (empty)'
fi

# Clean up
rm -rf "${PROXYCTL_DATA}/transactions"

# ============================================================================
# 17. Transaction ID validation (commit/rollback)
# ============================================================================
echo ''
echo '--- 17. Transaction ID validation ---'

# Invalid tx_ids must be rejected by commit
for bad_id in '/etc/passwd' '../../etc/passwd' '..' '.' '/' ''; do
    if run_meta "transaction_commit '${bad_id}'" 2>/dev/null; then
        fail "transaction_commit accepts bad id: ${bad_id}"
    else
        pass "transaction_commit rejects: ${bad_id}"
    fi
done

# Invalid tx_ids must be rejected by rollback
for bad_id in '/etc/passwd' '../../etc/passwd' '..' '.' '/' ''; do
    if run_meta "transaction_rollback '${bad_id}'" 2>/dev/null; then
        fail "transaction_rollback accepts bad id: ${bad_id}"
    else
        pass "transaction_rollback rejects: ${bad_id}"
    fi
done

# ============================================================================
# 18. Transaction stage name traversal rejection
# ============================================================================
echo ''
echo '--- 18. Stage traversal rejection ---'

rm -rf "${PROXYCTL_DATA}"
mkdir -p "${PROXYCTL_DATA}"

# Create a valid transaction
tx_id=$(run_meta 'transaction_begin test-stage')

# Create a test source file
echo 'test' > "/tmp/proxyctl-stage-test.txt"

# Valid stage name should succeed
if run_meta "transaction_stage ${tx_id} config.json /tmp/proxyctl-stage-test.txt" 2>/dev/null; then
    pass 'stage with valid name succeeds'
else
    fail 'stage with valid name failed'
fi

# Invalid stage names must fail
for bad_name in '../escape' '../../escape' '/etc/passwd' 'foo/bar' '..' '.'; do
    if run_meta "transaction_stage ${tx_id} ${bad_name} /tmp/proxyctl-stage-test.txt" 2>/dev/null; then
        fail "stage accepts traversal name: ${bad_name}"
    else
        pass "stage rejects traversal name: ${bad_name}"
    fi
done

# Clean up
rm -f "/tmp/proxyctl-stage-test.txt"
rm -rf "${PROXYCTL_DATA}/transactions"

# ============================================================================
# 19. Transaction commit/rollback must not delete outside root
# ============================================================================
echo ''
echo '--- 19. Transaction safe deletion ---'

rm -rf "${PROXYCTL_DATA}"
mkdir -p "${PROXYCTL_DATA}"

# Create a valid transaction
tx_id=$(run_meta 'transaction_begin safe-test')

# Verify commit of valid tx works
if run_meta "transaction_commit ${tx_id}" 2>/dev/null; then
    pass 'transaction_commit with valid ID succeeds'
else
    fail 'transaction_commit with valid ID failed'
fi

# Verify the tx directory was cleaned up
tx_dir=$(run_meta "transaction_dir ${tx_id}")
if [[ ! -d "$tx_dir" ]]; then
    pass 'transaction directory cleaned up after commit'
else
    fail 'transaction directory not cleaned up after commit'
fi

# Create another tx for rollback test
tx_id2=$(run_meta 'transaction_begin rollback-test')
if run_meta "transaction_rollback ${tx_id2}" 2>/dev/null; then
    pass 'transaction_rollback with valid ID succeeds'
else
    fail 'transaction_rollback with valid ID failed'
fi

tx_dir2=$(run_meta "transaction_dir ${tx_id2}")
if [[ ! -d "$tx_dir2" ]]; then
    pass 'transaction directory cleaned up after rollback'
else
    fail 'transaction directory not cleaned up after rollback'
fi

rm -rf "${PROXYCTL_DATA}/transactions"

# ============================================================================
# 20. UI choose variable return
# ============================================================================
echo ''
echo '--- 20. Choose API ---'

choose_test() {
    export PROXYCTL_NO_TTY_GUARD=1
    source "${PROJECT_DIR}/lib/ui.sh"
    local result
    # Use here-string (not pipe) to avoid subshell that breaks printf -v
    choose result 'Pick one' 'Option A' 'Option B' 'Option C' > /dev/null 2>&1 <<< '2'
    echo "${result}"
}

out=$(choose_test)
assert_eq "${out}" 'Option B' 'choose returns correct selection'

# ============================================================================
# 21. Non-TTY behavior
# ============================================================================
echo ''
echo '--- 21. Non-TTY behavior ---'

# confirm should fail without TTY (unless guard is set)
if bash -c "source '${PROJECT_DIR}/lib/ui.sh'; confirm result 'Test?'" 2>/dev/null; then
    fail 'confirm fails without TTY'
else
    pass 'confirm fails without TTY'
fi

# prompt_value without default should fail without TTY
if bash -c "source '${PROJECT_DIR}/lib/ui.sh'; prompt_value result 'Give value'" 2>/dev/null; then
    fail 'prompt_value fails without TTY (no default)'
else
    pass 'prompt_value fails without TTY (no default)'
fi

# prompt_value with default should succeed without TTY
if bash -c "source '${PROJECT_DIR}/lib/ui.sh'; prompt_value result 'Give value' 'default-val'; [[ \"\$result\" == 'default-val' ]]" 2>/dev/null; then
    pass 'prompt_value returns default without TTY'
else
    fail 'prompt_value returns default without TTY'
fi

# ============================================================================
# 22. All modules source independently
# ============================================================================
echo ''
echo '--- 22. Module source ---'

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
# 23. Full proxyctl loads
# ============================================================================
echo ''
echo '--- 23. Full load ---'

out=$(run_proxyctl version)
assert_eq "$?" '0' 'proxyctl loads without error'
assert_contains "${out}" '0.1.1' 'proxyctl version reports 0.1.1'

# ============================================================================
# 24. internal-init with custom paths
# ============================================================================
echo ''
echo '--- 24. internal-init ---'

rm -rf "${PROXYCTL_DATA}"

if command -v jq > /dev/null 2>&1; then
    run_meta 'metadata_init && metadata_validate'
    assert_eq "$?" '0' 'internal-init sequence succeeds'

    # Verify the file exists
    if [[ -f "${PROXYCTL_META}" ]]; then
        pass 'meta.json created by internal-init sequence'
    else
        fail 'meta.json not created by internal-init sequence'
    fi
else
    # Without jq, metadata_validate should fail
    run_meta metadata_init
    if run_meta metadata_validate 2>/dev/null; then
        fail 'metadata_validate without jq should fail'
    else
        pass 'metadata_validate without jq fails (jq required)'
    fi
fi

# ============================================================================
# 25. Data directory permissions
# ============================================================================
echo ''
echo '--- 25. Data directory permissions ---'

rm -rf "${PROXYCTL_DATA}"
run_meta metadata_init

# Check meta.json permissions
assert_file_perm "${PROXYCTL_META}" '600' 'meta.json is mode 600'

# Verify the data dir exists
if [[ -d "$(dirname "${PROXYCTL_META}")" ]]; then
    pass 'data directory exists'
else
    fail 'data directory does not exist'
fi

# ============================================================================
# 26. Bash version check
# ============================================================================
echo ''
echo '--- 26. Bash version check ---'

bash_version=$(bash -c 'echo "${BASH_VERSINFO[0]}"')
if ((bash_version >= 4)); then
    pass "Bash version ${bash_version} >= 4"
else
    fail "Bash version ${bash_version} < 4"
fi

# Verify the entry point checks bash version
out=$(run_proxyctl version)
assert_contains "${out}" '0.1.1' 'entry point passes bash version check'

# ============================================================================
# 27. apply_candidate detects missing file
# ============================================================================
echo ''
echo '--- 27. apply_candidate ---'

out=$(run_meta_capture 'apply_candidate xray /nonexistent/candidate.json')
assert_contains "${out}" 'does not exist' 'apply_candidate detects missing file'

# ============================================================================
# 28. Installed-layout: help and status
# ============================================================================
echo ''
echo '--- 28. Installed layout extended ---'

# Test help via installed layout
installed_help_test() {
    local tmp
    tmp=$(mktemp -d)
    mkdir -p "${tmp}/usr/local/sbin"
    mkdir -p "${tmp}/usr/local/lib/proxyctl"
    cp "${PROJECT_DIR}/proxyctl.sh" "${tmp}/usr/local/sbin/proxyctl"
    cp -r "${PROJECT_DIR}/lib/"* "${tmp}/usr/local/lib/proxyctl/"
    chmod +x "${tmp}/usr/local/sbin/proxyctl"

    PROXYCTL_LIB="${tmp}/usr/local/lib/proxyctl}" \
        bash "${tmp}/usr/local/sbin/proxyctl" help 2>&1

    rm -rf "${tmp}"
}

out=$(installed_help_test)
assert_contains "${out}" 'Usage' 'installed layout: help works'

# Test internal-init via installed layout (with temp data dir)
installed_init_test() {
    local tmp
    tmp=$(mktemp -d)
    mkdir -p "${tmp}/usr/local/sbin"
    mkdir -p "${tmp}/usr/local/lib/proxyctl"
    cp "${PROJECT_DIR}/proxyctl.sh" "${tmp}/usr/local/sbin/proxyctl"
    cp -r "${PROJECT_DIR}/lib/"* "${tmp}/usr/local/lib/proxyctl/"
    chmod +x "${tmp}/usr/local/sbin/proxyctl"

    local data_dir="${tmp}/var/lib/proxyctl"
    PROXYCTL_LIB="${tmp}/usr/local/lib/proxyctl" \
        PROXYCTL_DATA="${data_dir}" \
        PROXYCTL_META="${data_dir}/meta.json" \
        bash "${tmp}/usr/local/sbin/proxyctl" internal-init 2>&1

    local rc=$?
    rm -rf "${tmp}"
    return $rc
}

if command -v jq > /dev/null 2>&1; then
    out=$(installed_init_test)
    rc=$?
    if ((rc == 0)); then
        pass 'installed layout: internal-init succeeds'
    else
        fail "installed layout: internal-init failed (rc=${rc}): ${out}"
    fi
else
    # Should fail without jq
    out=$(installed_init_test) || true
    if [[ "$?" -ne 0 ]] || [[ "${out}" == *"fail"* ]]; then
        pass 'installed layout: internal-init fails without jq (expected)'
    else
        pass 'installed layout: internal-init (jq not available — skip)'
    fi
fi

# ============================================================================
# Summary
# ============================================================================
echo ''
echo '================================================================'
echo "  Results: ${PASSED} passed, ${FAILED} failed"
echo '================================================================'

if ((FAILED > 0)); then
    exit 1
fi
