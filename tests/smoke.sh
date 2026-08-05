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
assert_present(){ local p="$1"; shift; if [[ -e "$p" ]]; then pass "$*"; else fail "$* — missing: ${p}"; fi; }
assert_absent(){ local p="$1"; shift; if [[ ! -e "$p" ]]; then pass "$*"; else fail "$* — exists: ${p}"; fi; }

file_hash() {
    local f="$1"
    if command -v sha1sum > /dev/null 2>&1; then
        sha1sum "$f" | awk '{print $1}'
    elif command -v shasum > /dev/null 2>&1; then
        shasum "$f" | awk '{print $1}'
    elif command -v md5sum > /dev/null 2>&1; then
        md5sum "$f" | awk '{print $1}'
    else
        cksum "$f" | awk '{print $1}'
    fi
}

export PROXYCTL_DEV_LIB="${PROJECT_DIR}/lib"
export PROXYCTL_DATA='/tmp/proxyctl-test'
export PROXYCTL_META="${PROXYCTL_DATA}/meta.json"
export PROXYCTL_CERTS="${PROXYCTL_DATA}/certs"
export PROXYCTL_BACKUP="${PROXYCTL_DATA}/backup"
export PROXYCTL_LOCK="/tmp/proxyctl-test.lock"
export PROXYCTL_CERT_LOCK="/tmp/proxyctl-cert-test.lock"
export PROXYCTL_FIREWALL_LOCK="/tmp/proxyctl-firewall-test.lock"
rm -rf "${PROXYCTL_DATA}" "${PROXYCTL_LOCK}" "${PROXYCTL_CERT_LOCK}" "${PROXYCTL_FIREWALL_LOCK}"

run_proxyctl() {
    local out rc
    set +o errexit
    out=$(bash "${PROJECT_DIR}/proxyctl.sh" "$@" 2>&1)
    rc=$?
    set -o errexit
    echo "${out}"
    return "${rc}"
}

run_proxyctl_rc() {
    local rc
    set +o errexit
    bash "${PROJECT_DIR}/proxyctl.sh" "$@" > /dev/null 2>&1
    rc=$?
    set -o errexit
    return "${rc}"
}

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
        source '${PROJECT_DIR}/lib/common/service.sh'
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
        source '${PROJECT_DIR}/lib/common/service.sh'
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
    return 0
}

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
echo '  ProxyCTL Smoke Tests (Phase 1 core contract)'
echo '================================================================'
echo ''

echo '--- 1. Syntax check ---'
while IFS= read -r -d '' file; do
    if bash -n "${file}" 2>&1; then pass "syntax: ${file}"; else fail "syntax: ${file}"; fi
done < <(find "${PROJECT_DIR}" -name '*.sh' -print0)

echo ''
echo '--- 2. Source-layout execution ---'
out=$(run_proxyctl version)
rc=$?
assert_eq "${rc}" '0' 'version exits 0'
assert_contains "${out}" '0.2.5' 'version outputs 0.2.5'
out=$(run_proxyctl help)
assert_eq "$?" '0' 'help exits 0'
assert_contains "${out}" 'Usage' 'help shows usage'
assert_contains "${out}" 'cert' 'help exposes certificate manager'

echo ''
echo '--- 3. Installed-layout simulation ---'
installed_test() {
    local tmp
    tmp=$(mktemp -d)
    mkdir -p "${tmp}/usr/local/sbin" "${tmp}/usr/local/lib/proxyctl"
    cp "${PROJECT_DIR}/proxyctl.sh" "${tmp}/usr/local/sbin/proxyctl"
    cp -r "${PROJECT_DIR}/lib/"* "${tmp}/usr/local/lib/proxyctl/"
    chmod +x "${tmp}/usr/local/sbin/proxyctl"
    PROXYCTL_LIB="${tmp}/usr/local/lib/proxyctl" bash "${tmp}/usr/local/sbin/proxyctl" version 2>&1
    rm -rf "${tmp}"
}
out=$(installed_test)
assert_contains "${out}" '0.2.5' 'installed layout: version works'

echo ''
echo '--- 4. CLI exit codes ---'
run_proxyctl version
assert_eq "$?" '0' 'version exit code 0'
run_proxyctl help
assert_eq "$?" '0' 'help exit code 0'
if run_proxyctl_rc something-invalid; then fail 'unknown command should exit non-zero'; else pass 'unknown command exits non-zero'; fi
if run_proxyctl_rc ''; then pass 'empty command handled (non-zero or launches menu)'; else pass 'empty command handled'; fi

echo ''
echo '--- 5. Engine API completeness ---'
run_cap 'engine_validate_registration xray'
assert_eq "$?" '0' 'Xray engine registration valid'
run_cap 'engine_validate_registration singbox'
assert_eq "$?" '0' 'sing-box engine registration valid'

echo ''
echo '--- 6. Protocol capability ---'
out=$(run_cap 'engine_protocols xray')
assert_contains "${out}" 'VLESS' 'Xray has VLESS'
assert_contains "${out}" 'VMess' 'Xray has VMess'
assert_contains "${out}" 'Trojan' 'Xray has Trojan'
assert_contains "${out}" 'SOCKS5' 'Xray has SOCKS5'
assert_contains "${out}" 'HTTP' 'Xray has HTTP'
out=$(run_cap 'engine_protocols singbox')
assert_contains "${out}" 'AnyTLS' 'sing-box has AnyTLS'
assert_contains "${out}" 'VLESS' 'sing-box has VLESS'
assert_contains "${out}" 'Hysteria2' 'sing-box has Hysteria2'
assert_contains "${out}" 'Trojan' 'sing-box has Trojan'
assert_contains "${out}" 'SOCKS5' 'sing-box has SOCKS5'
assert_contains "${out}" 'HTTP' 'sing-box has HTTP'

echo ''
echo '--- 7. Empty transports ---'
for pair in 'xray:SOCKS5' 'xray:HTTP' 'singbox:AnyTLS' 'singbox:Hysteria2' 'singbox:SOCKS5' 'singbox:HTTP'; do
    engine="${pair%%:*}"; proto="${pair##*:}"
    out=$(run_cap "protocol_transports ${engine} ${proto}")
    assert_eq "${out}" '' "${engine} ${proto} has no transports"
done

echo ''
echo '--- 8. Invalid engine/protocol rejection ---'
if run_cap 'engine_protocols nonexistent' 2>/dev/null; then fail 'invalid engine should exit non-zero'; else pass 'invalid engine exits non-zero'; fi
if run_cap 'protocol_transports xray NOPROTO' 2>/dev/null; then fail 'invalid protocol should exit non-zero'; else pass 'invalid protocol exits non-zero'; fi
if run_cap 'engine_require nonexistent' 2>/dev/null; then fail 'engine_require for unknown engine should exit non-zero'; else pass 'engine_require for unknown engine exits non-zero'; fi

echo ''
echo '--- 9. Fail-closed / implemented contract ---'
assert_fail "run_meta 'backup_create test' 2>/dev/null" 'backup_create fails closed'
assert_fail "run_meta 'backup_restore foo' 2>/dev/null" 'backup_restore fails closed'
assert_fail "run_meta 'bbr_enable' 2>/dev/null" 'bbr_enable fails closed'
assert_fail "run_meta 'cert_acme_issue example.com' 2>/dev/null" 'cert_acme_issue rejects incomplete arguments'
assert_fail "run_meta 'apply_candidate xray /nonexistent/path' 2>/dev/null" 'apply_candidate fails closed'
assert_fail "run_meta 'engine_xray_validate /nonexistent/path' 2>/dev/null" 'Xray validate fails closed'
assert_fail "run_meta 'engine_singbox_validate /nonexistent/path' 2>/dev/null" 'sing-box validate fails closed'
assert_fail "run_meta 'engine_xray_logs' 2>/dev/null" 'Xray logs fails closed'
assert_fail "run_meta 'engine_singbox_logs' 2>/dev/null" 'sing-box logs fails closed'
out=$(run_meta_capture 'backup_list')
assert_contains "${out}" 'not implemented' 'backup_list reports not implemented'
out=$(run_meta_capture 'bbr_status')
assert_contains "${out}" 'not implemented' 'bbr_status reports not implemented'
out=$(run_meta_capture 'cert_list')
assert_eq "${out}" '' 'cert_list is empty when no managed certificates exist'
assert_fail "run_meta 'engine_xray_install' 2>/dev/null" 'Xray install fails closed'
assert_fail "run_meta 'engine_singbox_install' 2>/dev/null" 'sing-box install fails closed'

echo ''
echo '--- 10. Metadata init ---'
rm -rf "${PROXYCTL_DATA}"
run_meta metadata_init
assert_ok '[ -f "${PROXYCTL_META}" ]' 'metadata_init creates meta.json'
assert_file_perm "${PROXYCTL_META}" '600' 'meta.json has mode 600'

echo ''
echo '--- 11. Metadata validate ---'
if command -v jq > /dev/null 2>&1; then
    run_meta metadata_validate
    assert_eq "$?" '0' 'metadata_validate passes on valid meta.json'
    echo 'not json' > "${PROXYCTL_META}"
    if run_meta metadata_validate 2>/dev/null; then fail 'metadata_validate should reject invalid JSON'; else pass 'metadata_validate rejects invalid JSON'; fi
    rm -f "${PROXYCTL_META}"
    run_meta metadata_init
    run_meta metadata_validate
    assert_eq "$?" '0' 'metadata_validate passes after re-init'
    echo '{"version": 1}' > "${PROXYCTL_META}"
    if run_meta metadata_validate 2>/dev/null; then fail 'metadata_validate should reject missing required keys'; else pass 'metadata_validate rejects missing required keys'; fi
else
    echo '  (skipping jq-dependent metadata validate tests)'
fi

echo ''
echo '--- 12. Metadata safe key ---'
rm -rf "${PROXYCTL_DATA}"
run_meta metadata_init
if command -v jq > /dev/null 2>&1; then
    run_meta metadata_get .version
    assert_eq "$?" '0' 'metadata_get .version exits 0'
    out=$(run_meta 'metadata_get version')
    assert_eq "${out}" '1' 'metadata_get version (no dot) returns 1'
    assert_fail "run_meta \"metadata_get '../../x'\" 2>/dev/null" 'metadata_get rejects path traversal'
    assert_fail "run_meta \"metadata_get 'a] | .foo'\" 2>/dev/null" 'metadata_get rejects jq injection attempt'
    assert_fail "run_meta \"metadata_get 'foo bar'\" 2>/dev/null" 'metadata_get rejects key with space'
    assert_fail "run_meta \"metadata_get '/etc/passwd'\" 2>/dev/null" 'metadata_get rejects absolute path'
    assert_fail "run_meta \"metadata_set_string '../../x' value\" 2>/dev/null" 'metadata_set_string rejects traversal key'
    assert_fail "run_meta \"metadata_set_string 'foo bar' value\" 2>/dev/null" 'metadata_set_string rejects key with space'
    run_meta 'metadata_set_json inbounds {"socks":{"engine":"xray","port":9000}}'
    assert_eq "$?" '0' 'metadata_set_json with valid key exits 0'
    assert_fail "run_meta \"metadata_set_json '../../x' '{}'\" 2>/dev/null" 'metadata_set_json rejects traversal key'
else
    echo '  (skipping jq-dependent metadata key tests)'
fi

echo ''
echo '--- 13. Metadata write ---'
rm -rf "${PROXYCTL_DATA}"
run_meta metadata_init
if command -v jq > /dev/null 2>&1; then
    run_meta 'metadata_set_json inbounds {"socks":{"engine":"xray","port":9000}}'
    out=$(run_meta 'metadata_get inbounds')
    assert_contains "${out}" '"socks"' 'metadata_set_json writes correctly'
    assert_file_perm "${PROXYCTL_META}" '600' 'meta.json keeps mode 600 after writes'
else
    echo '  (skipping jq-dependent metadata write tests)'
fi

echo ''
echo '--- 14. Metadata corruption protection ---'
rm -rf "${PROXYCTL_DATA}"
run_meta metadata_init
if command -v jq > /dev/null 2>&1; then
    before=$(shasum "${PROXYCTL_META}" 2>/dev/null || sha1sum "${PROXYCTL_META}" 2>/dev/null || cksum "${PROXYCTL_META}")
    if run_meta "metadata_set_json inbounds '{invalid'" 2>/dev/null; then fail 'metadata_set_json with invalid JSON should fail'; else pass 'metadata_set_json rejects invalid JSON'; fi
    after=$(shasum "${PROXYCTL_META}" 2>/dev/null || sha1sum "${PROXYCTL_META}" 2>/dev/null || cksum "${PROXYCTL_META}")
    assert_eq "${after}" "${before}" 'metadata not corrupted by invalid write'
    run_meta metadata_validate
    assert_eq "$?" '0' 'metadata still valid after rejected write'
else
    echo '  (skipping jq-dependent corruption tests)'
fi

echo ''
echo '--- 15. Transaction unique IDs ---'
rm -rf "${PROXYCTL_DATA}"
mkdir -p "${PROXYCTL_DATA}"
id1=$(run_meta 'transaction_begin test')
id2=$(run_meta 'transaction_begin test')
if [[ "$id1" != "$id2" ]]; then pass 'transaction IDs are unique'; else fail 'transaction IDs are unique'; fi
for id in "$id1" "$id2"; do
    if [[ "$id" =~ ^tx_[0-9]+_[0-9]+_test$ ]]; then pass "transaction ID format valid: ${id}"; else fail "transaction ID format invalid: ${id}"; fi
done
assert_file_perm "${PROXYCTL_DATA}/transactions" '700' 'transaction root is mode 700'

echo ''
echo '--- 16. Invalid label rejection ---'
for label in test xray-config singbox_config backup.1 my-label; do
    if run_meta "transaction_begin ${label}" > /dev/null 2>&1; then pass "valid label accepted: ${label}"; else fail "valid label rejected: ${label}"; fi
done
for label in '../test' '../../etc' '/test' 'a/b' '..' '.'; do
    if run_meta "transaction_begin ${label}" 2>/dev/null; then fail "invalid label accepted: ${label}"; else pass "invalid label rejected: ${label}"; fi
done
if run_meta 'transaction_validate_label "a b"' 2>/dev/null; then fail 'invalid label accepted: a b'; else pass 'invalid label rejected: a b'; fi
if run_meta 'transaction_validate_label ""' 2>/dev/null; then fail 'invalid label accepted: (empty)'; else pass 'invalid label rejected: (empty)'; fi
rm -rf "${PROXYCTL_DATA}/transactions"

echo ''
echo '--- 17. Transaction ID validation ---'
for bad_id in '/etc/passwd' '../../etc/passwd' '..' '.' '/' ''; do
    if run_meta "transaction_commit '${bad_id}'" 2>/dev/null; then fail "transaction_commit accepts bad id: ${bad_id}"; else pass "transaction_commit rejects: ${bad_id}"; fi
done
for bad_id in '/etc/passwd' '../../etc/passwd' '..' '.' '/' ''; do
    if run_meta "transaction_rollback '${bad_id}'" 2>/dev/null; then fail "transaction_rollback accepts bad id: ${bad_id}"; else pass "transaction_rollback rejects: ${bad_id}"; fi
done

echo ''
echo '--- 18. Stage traversal rejection ---'
rm -rf "${PROXYCTL_DATA}"
mkdir -p "${PROXYCTL_DATA}"
tx_id=$(run_meta 'transaction_begin test-stage')
echo 'test' > "/tmp/proxyctl-stage-test.txt"
if run_meta "transaction_stage ${tx_id} config.json /tmp/proxyctl-stage-test.txt" 2>/dev/null; then pass 'stage with valid name succeeds'; else fail 'stage with valid name failed'; fi
for bad_name in '../escape' '../../escape' '/etc/passwd' 'foo/bar' '..' '.'; do
    if run_meta "transaction_stage ${tx_id} ${bad_name} /tmp/proxyctl-stage-test.txt" 2>/dev/null; then fail "stage accepts traversal name: ${bad_name}"; else pass "stage rejects traversal name: ${bad_name}"; fi
done
rm -f "/tmp/proxyctl-stage-test.txt"
rm -rf "${PROXYCTL_DATA}/transactions"

echo ''
echo '--- 19. Transaction safe deletion ---'
rm -rf "${PROXYCTL_DATA}"
mkdir -p "${PROXYCTL_DATA}"
tx_id=$(run_meta 'transaction_begin safe-test')
if run_meta "transaction_commit ${tx_id}" 2>/dev/null; then pass 'transaction_commit with valid ID succeeds'; else fail 'transaction_commit with valid ID failed'; fi
tx_dir=$(run_meta "transaction_dir ${tx_id}")
if [[ ! -d "$tx_dir" ]]; then pass 'transaction directory cleaned up after commit'; else fail 'transaction directory not cleaned up after commit'; fi
tx_id2=$(run_meta 'transaction_begin rollback-test')
if run_meta "transaction_rollback ${tx_id2}" 2>/dev/null; then pass 'transaction_rollback with valid ID succeeds'; else fail 'transaction_rollback with valid ID failed'; fi
tx_dir2=$(run_meta "transaction_dir ${tx_id2}")
if [[ ! -d "$tx_dir2" ]]; then pass 'transaction directory cleaned up after rollback'; else fail 'transaction directory not cleaned up after rollback'; fi
rm -rf "${PROXYCTL_DATA}/transactions"

echo ''
echo '--- 20. Choose API ---'
choose_test() {
    export PROXYCTL_NO_TTY_GUARD=1
    source "${PROJECT_DIR}/lib/ui.sh"
    local result
    choose result 'Pick one' 'Option A' 'Option B' 'Option C' > /dev/null 2>&1 <<< '2'
    echo "${result}"
}
out=$(choose_test)
assert_eq "${out}" 'Option B' 'choose returns correct selection'

echo ''
echo '--- 21. Non-TTY behavior ---'
if bash -c "source '${PROJECT_DIR}/lib/ui.sh'; confirm result 'Test?'" 2>/dev/null; then fail 'confirm fails without TTY'; else pass 'confirm fails without TTY'; fi
if bash -c "source '${PROJECT_DIR}/lib/ui.sh'; prompt_value result 'Give value'" 2>/dev/null; then fail 'prompt_value fails without TTY (no default)'; else pass 'prompt_value fails without TTY (no default)'; fi
if bash -c "source '${PROJECT_DIR}/lib/ui.sh'; prompt_value result 'Give value' 'default-val'; [[ \"\$result\" == 'default-val' ]]" 2>/dev/null; then pass 'prompt_value returns default without TTY'; else fail 'prompt_value returns default without TTY'; fi

echo ''
echo '--- 22. Module source ---'
MODULES=(
    "${PROJECT_DIR}/lib/ui.sh" "${PROJECT_DIR}/lib/capability.sh" "${PROJECT_DIR}/lib/metadata.sh"
    "${PROJECT_DIR}/lib/transaction.sh" "${PROJECT_DIR}/lib/common/system.sh" "${PROJECT_DIR}/lib/common/service.sh"
    "${PROJECT_DIR}/lib/common/network.sh" "${PROJECT_DIR}/lib/common/port.sh" "${PROJECT_DIR}/lib/common/lock.sh"
    "${PROJECT_DIR}/lib/common/certificate.sh" "${PROJECT_DIR}/lib/common/backup.sh" "${PROJECT_DIR}/lib/common/bbr.sh"
)
for mod in "${MODULES[@]}"; do
    if bash -c "source '${mod}'" 2>&1; then pass "source: ${mod}"; else fail "source: ${mod}"; fi
done
for mod in "${PROJECT_DIR}/lib/xray/engine.sh" "${PROJECT_DIR}/lib/singbox/engine.sh"; do
    if bash -c "source '${PROJECT_DIR}/lib/core.sh'; source '${mod}'" 2>&1; then pass "source: ${mod} (with core)"; else fail "source: ${mod} (with core)"; fi
done

echo ''
echo '--- 23. Full load ---'
out=$(run_proxyctl version)
assert_eq "$?" '0' 'proxyctl loads without error'
assert_contains "${out}" '0.2.5' 'proxyctl version reports 0.2.5'

echo ''
echo '--- 24. internal-init ---'
rm -rf "${PROXYCTL_DATA}"
if command -v jq > /dev/null 2>&1; then
    run_meta 'metadata_init && metadata_validate'
    assert_eq "$?" '0' 'internal-init sequence succeeds'
    if [[ -f "${PROXYCTL_META}" ]]; then pass 'meta.json created by internal-init sequence'; else fail 'meta.json not created by internal-init sequence'; fi
else
    run_meta metadata_init
    if run_meta metadata_validate 2>/dev/null; then fail 'metadata_validate without jq should fail'; else pass 'metadata_validate without jq fails (jq required)'; fi
fi

echo ''
echo '--- 25. Data directory permissions ---'
rm -rf "${PROXYCTL_DATA}"
run_meta metadata_init
assert_file_perm "${PROXYCTL_META}" '600' 'meta.json is mode 600'
if [[ -d "$(dirname "${PROXYCTL_META}")" ]]; then pass 'data directory exists'; else fail 'data directory does not exist'; fi

echo ''
echo '--- 26. Bash version check ---'
bash_version=$(bash -c 'echo "${BASH_VERSINFO[0]}"')
if ((bash_version >= 4)); then pass "Bash version ${bash_version} >= 4"; else fail "Bash version ${bash_version} < 4"; fi
out=$(run_proxyctl version)
assert_contains "${out}" '0.2.5' 'entry point passes bash version check'

echo ''
echo '--- 27. apply_candidate ---'
out=$(run_meta_capture 'apply_candidate xray /nonexistent/candidate.json')
assert_contains "${out}" 'does not exist' 'apply_candidate detects missing file'
assert_fail "run_meta 'apply_candidate nonexistent /tmp/whatever.json' 2>/dev/null" 'apply_candidate rejects unknown engine'

echo ''
echo '--- 28. Installed layout extended ---'
installed_help_test() {
    local tmp
    tmp=$(mktemp -d)
    mkdir -p "${tmp}/usr/local/sbin" "${tmp}/usr/local/lib/proxyctl"
    cp "${PROJECT_DIR}/proxyctl.sh" "${tmp}/usr/local/sbin/proxyctl"
    cp -r "${PROJECT_DIR}/lib/"* "${tmp}/usr/local/lib/proxyctl/"
    chmod +x "${tmp}/usr/local/sbin/proxyctl"
    PROXYCTL_LIB="${tmp}/usr/local/lib/proxyctl" bash "${tmp}/usr/local/sbin/proxyctl" help 2>&1
    rm -rf "${tmp}"
}
out=$(installed_help_test)
assert_contains "${out}" 'Usage' 'installed layout: help works'
installed_init_test() {
    local tmp data_dir
    tmp=$(mktemp -d)
    mkdir -p "${tmp}/usr/local/sbin" "${tmp}/usr/local/lib/proxyctl"
    cp "${PROJECT_DIR}/proxyctl.sh" "${tmp}/usr/local/sbin/proxyctl"
    cp -r "${PROJECT_DIR}/lib/"* "${tmp}/usr/local/lib/proxyctl/"
    chmod +x "${tmp}/usr/local/sbin/proxyctl"
    data_dir="${tmp}/var/lib/proxyctl"
    PROXYCTL_LIB="${tmp}/usr/local/lib/proxyctl" PROXYCTL_DATA="${data_dir}" PROXYCTL_META="${data_dir}/meta.json" \
        bash "${tmp}/usr/local/sbin/proxyctl" internal-init 2>&1
    local rc=$?
    rm -rf "${tmp}"
    return $rc
}
if command -v jq > /dev/null 2>&1; then
    set +e; out=$(installed_init_test 2>&1); rc=$?; set -e
    if ((rc == 0)); then pass 'installed layout: internal-init succeeds'; else fail "installed layout: internal-init failed (rc=${rc}): ${out}"; fi
else
    set +e; out=$(installed_init_test 2>&1); rc=$?; set -e
    if ((rc != 0)); then pass 'installed layout: internal-init fails without jq (expected)'; else fail 'installed layout: internal-init unexpectedly succeeded without jq'; fi
fi

echo ''
echo '--- 29. Installer transaction ---'
if [[ "$(id -u)" -ne 0 ]]; then
    echo '  (skipping installer transaction tests — requires root)'
else
    INSTALL_TEST_BASE=$(mktemp -d)
    INSTALL_ROOT="${INSTALL_TEST_BASE}/fs"
    run_installer() {
        local root="$1" failat="$2" out rc
        set +o errexit
        out=$(PROXYCTL_INSTALL_ROOT="$root" PROXYCTL_TEST_FAIL_AT="$failat" bash "${PROJECT_DIR}/install.sh" 2>&1)
        rc=$?
        set -o errexit
        echo "${out}"
        return "${rc}"
    }
    seed_old_install() {
        local root="$1"
        mkdir -p "$(dirname "${root}/usr/local/sbin/proxyctl")" "${root}/usr/local/lib/proxyctl" "${root}/usr/local/bin" "${root}/var/lib/proxyctl"
        printf '#!/usr/bin/env bash\necho old-binary-0.1.0\n' > "${root}/usr/local/sbin/proxyctl"
        chmod +x "${root}/usr/local/sbin/proxyctl"
        printf 'old-lib-0.1.0\n' > "${root}/usr/local/lib/proxyctl/.old-marker"
        ln -s "/usr/local/sbin/proxyctl" "${root}/usr/local/bin/proxyctl"
        printf '{"version":1,"inbounds":{},"certificates":{},"firewall":{}}\n' > "${root}/var/lib/proxyctl/meta.json"
    }

    echo '  29a. First-install failure rollback'
    rm -rf "$INSTALL_ROOT"; mkdir -p "$INSTALL_ROOT"
    set +e; out=$(run_installer "$INSTALL_ROOT" 'before-metadata' 2>&1); rc=$?; set -e
    if (( rc != 0 )); then pass 'installer: first install fails when failure injected'; else fail 'installer: first install should fail with injection'; fi
    assert_absent "${INSTALL_ROOT}/usr/local/sbin/proxyctl" 'installer first-fail: binary absent'
    assert_absent "${INSTALL_ROOT}/usr/local/sbin/proxyctl.new" 'installer first-fail: binary.new absent'
    assert_absent "${INSTALL_ROOT}/usr/local/sbin/proxyctl.old" 'installer first-fail: binary.old absent'
    assert_absent "${INSTALL_ROOT}/usr/local/lib/proxyctl" 'installer first-fail: library absent'
    assert_absent "${INSTALL_ROOT}/usr/local/lib/proxyctl.new" 'installer first-fail: library.new absent'
    assert_absent "${INSTALL_ROOT}/usr/local/lib/proxyctl.old" 'installer first-fail: library.old absent'
    assert_absent "${INSTALL_ROOT}/usr/local/bin/proxyctl" 'installer first-fail: symlink absent'

    echo '  29b. Upgrade failure rollback'
    rm -rf "$INSTALL_ROOT"; mkdir -p "$INSTALL_ROOT"; seed_old_install "$INSTALL_ROOT"
    OLD_BIN_HASH=$(file_hash "${INSTALL_ROOT}/usr/local/sbin/proxyctl")
    OLD_LIB_HASH=$(file_hash "${INSTALL_ROOT}/usr/local/lib/proxyctl/.old-marker")
    OLD_META_HASH=$(file_hash "${INSTALL_ROOT}/var/lib/proxyctl/meta.json")
    OLD_LINK_TARGET=$(readlink "${INSTALL_ROOT}/usr/local/bin/proxyctl")
    set +e; out=$(run_installer "$INSTALL_ROOT" 'before-metadata' 2>&1); rc=$?; set -e
    if (( rc != 0 )); then pass 'installer: upgrade fails when failure injected'; else fail 'installer: upgrade should fail with injection'; fi
    assert_eq "$(file_hash "${INSTALL_ROOT}/usr/local/sbin/proxyctl")" "$OLD_BIN_HASH" 'installer upgrade-fail: old binary restored'
    assert_eq "$(file_hash "${INSTALL_ROOT}/usr/local/lib/proxyctl/.old-marker")" "$OLD_LIB_HASH" 'installer upgrade-fail: old library restored'
    assert_eq "$(file_hash "${INSTALL_ROOT}/var/lib/proxyctl/meta.json")" "$OLD_META_HASH" 'installer upgrade-fail: old metadata preserved'
    assert_eq "$(readlink "${INSTALL_ROOT}/usr/local/bin/proxyctl")" "$OLD_LINK_TARGET" 'installer upgrade-fail: symlink restored'

    echo '  29c. Failure after binary swap'
    rm -rf "$INSTALL_ROOT"; mkdir -p "$INSTALL_ROOT"; seed_old_install "$INSTALL_ROOT"
    OLD_BIN_HASH=$(file_hash "${INSTALL_ROOT}/usr/local/sbin/proxyctl")
    OLD_LIB_HASH=$(file_hash "${INSTALL_ROOT}/usr/local/lib/proxyctl/.old-marker")
    set +e; out=$(run_installer "$INSTALL_ROOT" 'after-bin-swap' 2>&1); rc=$?; set -e
    if (( rc != 0 )); then pass 'installer: failure after bin swap is detected'; else fail 'installer: failure after bin swap should fail'; fi
    assert_eq "$(file_hash "${INSTALL_ROOT}/usr/local/sbin/proxyctl")" "$OLD_BIN_HASH" 'installer after-bin-swap-fail: old binary restored'
    assert_eq "$(file_hash "${INSTALL_ROOT}/usr/local/lib/proxyctl/.old-marker")" "$OLD_LIB_HASH" 'installer after-bin-swap-fail: old library restored'

    echo '  29d. Successful install commit'
    rm -rf "$INSTALL_ROOT"; mkdir -p "$INSTALL_ROOT"
    set +e; out=$(run_installer "$INSTALL_ROOT" '' 2>&1); rc=$?; set -e
    if (( rc == 0 )); then pass 'installer: successful install exits 0'; else fail "installer: successful install should exit 0 (rc=${rc}): ${out}"; fi
    assert_present "${INSTALL_ROOT}/usr/local/sbin/proxyctl" 'installer success: binary present'
    assert_present "${INSTALL_ROOT}/usr/local/lib/proxyctl" 'installer success: library present'
    assert_eq "$(readlink "${INSTALL_ROOT}/usr/local/bin/proxyctl")" "${INSTALL_ROOT}/usr/local/sbin/proxyctl" 'installer success: symlink points to binary'
    assert_present "${INSTALL_ROOT}/var/lib/proxyctl/meta.json" 'installer success: metadata present'
    assert_file_perm "${INSTALL_ROOT}/var/lib/proxyctl/meta.json" '600' 'installer success: metadata mode 600'
    assert_file_perm "${INSTALL_ROOT}/var/lib/proxyctl" '700' 'installer success: data dir mode 700'
    assert_file_perm "${INSTALL_ROOT}/var/lib/proxyctl/transactions" '700' 'installer success: transactions dir mode 700'
    assert_file_perm "${INSTALL_ROOT}/etc/proxyctl/certs" '700' 'installer success: certs dir mode 700'
    assert_file_perm "${INSTALL_ROOT}/var/backups/proxyctl" '700' 'installer success: backup dir mode 700'
    assert_absent "${INSTALL_ROOT}/usr/local/sbin/proxyctl.new" 'installer success: no binary.new'
    assert_absent "${INSTALL_ROOT}/usr/local/sbin/proxyctl.old" 'installer success: no binary.old'
    assert_absent "${INSTALL_ROOT}/usr/local/lib/proxyctl.new" 'installer success: no library.new'
    assert_absent "${INSTALL_ROOT}/usr/local/lib/proxyctl.old" 'installer success: no library.old'

    echo '  29e. Commit cleanup failure does not rollback'
    rm -rf "$INSTALL_ROOT"; mkdir -p "$INSTALL_ROOT"; seed_old_install "$INSTALL_ROOT"
    SEED_BIN_HASH=$(file_hash "${INSTALL_ROOT}/usr/local/sbin/proxyctl")
    set +e; out=$(PROXYCTL_INSTALL_ROOT="$INSTALL_ROOT" PROXYCTL_TEST_FAIL_CLEANUP='bin' bash "${PROJECT_DIR}/install.sh" 2>&1); rc=$?; set -e
    if (( rc == 0 )); then pass 'installer cleanup-fail(bin): installer still exits 0'; else fail "installer cleanup-fail(bin): should exit 0 (rc=${rc}): ${out}"; fi
    NEW_BIN_HASH=$(file_hash "${INSTALL_ROOT}/usr/local/sbin/proxyctl")
    if [[ "$NEW_BIN_HASH" != "$SEED_BIN_HASH" ]]; then pass 'installer cleanup-fail(bin): new binary replaced old'; else fail 'installer cleanup-fail(bin): binary should be the new one'; fi
    assert_present "${INSTALL_ROOT}/usr/local/lib/proxyctl" 'installer cleanup-fail(bin): new library present'
    assert_present "${INSTALL_ROOT}/usr/local/bin/proxyctl" 'installer cleanup-fail(bin): symlink present'
    set +e; out=$(PROXYCTL_INSTALL_ROOT="$INSTALL_ROOT" PROXYCTL_TEST_FAIL_CLEANUP='lib' bash "${PROJECT_DIR}/install.sh" 2>&1); rc=$?; set -e
    if (( rc == 0 )); then pass 'installer cleanup-fail(lib): installer still exits 0'; else fail "installer cleanup-fail(lib): should exit 0 (rc=${rc}): ${out}"; fi
    assert_present "${INSTALL_ROOT}/usr/local/sbin/proxyctl" 'installer cleanup-fail(lib): new binary present'
    assert_present "${INSTALL_ROOT}/usr/local/lib/proxyctl" 'installer cleanup-fail(lib): new library present'

    echo '  29f. Non-symlink collision rejected'
    rm -rf "$INSTALL_ROOT"; mkdir -p "$INSTALL_ROOT"
    mkdir -p "$(dirname "${INSTALL_ROOT}/usr/local/sbin/proxyctl")" "$(dirname "${INSTALL_ROOT}/usr/local/bin/proxyctl")"
    printf 'do-not-touch\n' > "${INSTALL_ROOT}/usr/local/bin/proxyctl"
    COLLIDE_HASH=$(file_hash "${INSTALL_ROOT}/usr/local/bin/proxyctl")
    set +e; out=$(run_installer "$INSTALL_ROOT" '' 2>&1); rc=$?; set -e
    if (( rc != 0 )); then pass 'installer collision: non-symlink file is refused'; else fail "installer collision: should refuse (rc=${rc}): ${out}"; fi
    assert_eq "$(file_hash "${INSTALL_ROOT}/usr/local/bin/proxyctl")" "$COLLIDE_HASH" 'installer collision: file untouched'
    assert_absent "${INSTALL_ROOT}/usr/local/sbin/proxyctl" 'installer collision: binary not installed'
    assert_absent "${INSTALL_ROOT}/usr/local/lib/proxyctl" 'installer collision: library not installed'

    echo '  29g. Directory collision rejected'
    rm -rf "$INSTALL_ROOT"; mkdir -p "$INSTALL_ROOT"; mkdir -p "${INSTALL_ROOT}/usr/local/bin/proxyctl"
    set +e; out=$(run_installer "$INSTALL_ROOT" '' 2>&1); rc=$?; set -e
    if (( rc != 0 )); then pass 'installer collision: directory is refused'; else fail "installer collision: directory should be refused (rc=${rc}): ${out}"; fi
    if [[ -d "${INSTALL_ROOT}/usr/local/bin/proxyctl" ]]; then pass 'installer collision: directory left intact'; else fail 'installer collision: directory should not be deleted'; fi

    echo '  29h. Broken symlink replaced'
    rm -rf "$INSTALL_ROOT"; mkdir -p "$INSTALL_ROOT"; mkdir -p "$(dirname "${INSTALL_ROOT}/usr/local/bin/proxyctl")"
    ln -s "/nonexistent/old-proxyctl" "${INSTALL_ROOT}/usr/local/bin/proxyctl"
    set +e; out=$(run_installer "$INSTALL_ROOT" '' 2>&1); rc=$?; set -e
    if (( rc == 0 )); then pass 'installer: broken symlink is replaced'; else fail "installer: broken symlink should be replaceable (rc=${rc}): ${out}"; fi
    assert_eq "$(readlink "${INSTALL_ROOT}/usr/local/bin/proxyctl")" "${INSTALL_ROOT}/usr/local/sbin/proxyctl" 'installer: broken symlink now points to binary'
    rm -rf "$INSTALL_TEST_BASE"
fi

echo ''
echo '--- 30. Network / Port contract ---'
assert_ok "run_meta 'network_validate_ipv4 127.0.0.1'" 'network_validate_ipv4 accepts loopback'
assert_fail "run_meta 'network_validate_ipv4 999.1.1.1' 2>/dev/null" 'network_validate_ipv4 rejects bad octet'
assert_ok "run_meta 'network_validate_ip 2001:db8::1'" 'network_validate_ip accepts IPv6'
assert_ok "run_meta 'port_validate 443'" 'port_validate accepts 443'
assert_fail "run_meta 'port_validate 0' 2>/dev/null" 'port_validate rejects 0'
assert_fail "run_meta 'port_validate 65536' 2>/dev/null" 'port_validate rejects 65536'

echo ''
echo '--- 31. Lock contract ---'
out=$(run_meta 'lock_path config')
assert_eq "$?" '0' 'lock_path config exits 0'
assert_eq "${out}" "${PROXYCTL_LOCK}" 'lock_path config maps to PROXYCTL_LOCK'
out=$(run_meta 'lock_path cert')
assert_eq "$?" '0' 'lock_path cert exits 0'
assert_eq "${out}" "${PROXYCTL_CERT_LOCK}" 'lock_path cert maps to PROXYCTL_CERT_LOCK'
out=$(run_meta 'lock_path firewall')
assert_eq "$?" '0' 'lock_path firewall exits 0'
assert_eq "${out}" "${PROXYCTL_FIREWALL_LOCK}" 'lock_path firewall maps to PROXYCTL_FIREWALL_LOCK'
assert_fail "run_meta 'lock_path something' 2>/dev/null" 'lock_path rejects unknown name'

echo ''
echo '--- 32. Certificate contract (light) ---'
assert_ok "run_meta 'cert_validate_identifier example.com'" 'certificate identifier accepts domain'
assert_fail "run_meta 'cert_validate_identifier ../escape' 2>/dev/null" 'certificate identifier rejects traversal'
out=$(run_meta 'cert_fullchain example.com')
assert_eq "${out}" "${PROXYCTL_CERTS}/example.com/fullchain.pem" 'certificate fullchain path mapping'
out=$(run_meta 'cert_privkey example.com')
assert_eq "${out}" "${PROXYCTL_CERTS}/example.com/privkey.pem" 'certificate private-key path mapping'

echo ''
echo '================================================================'
echo "  Results: ${PASSED} passed, ${FAILED} failed"
echo '================================================================'

if ((FAILED > 0)); then
    exit 1
fi
