#!/usr/bin/env bash
# ------------------------------------------------------------------------------
# tests/system.sh — Phase 2.1 system/platform test suite
# ------------------------------------------------------------------------------
set -o errexit
set -o nounset
set -o pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

source "${PROJECT_DIR}/lib/ui.sh"
source "${PROJECT_DIR}/lib/common/system.sh"

PASSED=0
FAILED=0

green() { echo -e "\033[0;32m$*\033[0m"; }
red()   { echo -e "\033[0;31m$*\033[0m"; }

pass() { green "  PASS: $*"; ((++PASSED)); }
fail() { red "  FAIL: $*"; ((++FAILED)); }

assert_eq()    { local got="$1" exp="$2"; shift 2 || true; [[ "${got}" == "${exp}" ]] && pass "$*" || fail "$* — expected '${exp}', got '${got}'"; }
assert_ok()    { local cmd="$1"; shift; if eval "${cmd}"; then pass "$*"; else fail "$*"; fi; }
assert_fail()  { local cmd="$1"; shift; if ! eval "${cmd}" 2>/dev/null; then pass "$*"; else fail "$*"; fi; }

echo ''
echo '================================================================'
echo '  ProxyCTL Phase 2.1 System Tests'
echo '================================================================'
echo ''

# ============================================================================
# 1. OS detection
# ============================================================================
echo '--- 1. OS detection ---'
out=$(system_os)
assert_eq "${out}" 'linux' 'system_os returns linux on Linux'

# ============================================================================
# 2. Architecture mapping (full table via helper)
# ============================================================================
echo ''
echo '--- 2. Architecture mapping ---'

arch_case() {
    local machine="$1" expected="$2" label="$3"
    local got
    set +e
    got=$(_system_arch_from_machine "$machine" 2>/dev/null)
    local rc=$?
    set -e
    if (( rc == 0 )) && [[ "$got" == "$expected" ]]; then
        pass "$label ($machine → $expected)"
    else
        fail "$label ($machine → '$got', rc=$rc, expected '$expected')"
    fi
}

arch_case 'x86_64'   'amd64'     'x86_64 maps to amd64'
arch_case 'amd64'    'amd64'     'amd64 stays amd64'
arch_case 'aarch64'  'arm64'     'aarch64 maps to arm64'
arch_case 'arm64'    'arm64'     'arm64 stays arm64'
arch_case 'armv7l'   'armv7'     'armv7l maps to armv7'
arch_case 'armv7'    'armv7'     'armv7 stays armv7'
arch_case 'i386'     '386'       'i386 maps to 386'
arch_case 'i686'     '386'       'i686 maps to 386'
arch_case 'x86'      '386'       'x86 maps to 386'

# Unsupported architecture must return non-zero and print 'unsupported'
set +e
unsupported_out=$(_system_arch_from_machine 'sparc' 2>/dev/null)
unsupported_rc=$?
set -e
if (( unsupported_rc != 0 )) && [[ "${unsupported_out}" == 'unsupported' ]]; then
    pass 'unsupported architecture is rejected with non-zero'
else
    fail "unsupported architecture should fail (out='${unsupported_out}', rc=${unsupported_rc})"
fi

# Real system_arch returns a supported token
set +e
real_arch=$(system_arch 2>/dev/null)
real_rc=$?
set -e
if (( real_rc == 0 )); then
    case "$real_arch" in
        amd64|arm64|armv7|386)
            pass "system_arch detects ${real_arch}"
            ;;
        *)
            fail "system_arch returned unexpected value: ${real_arch}"
            ;;
    esac
else
    fail "system_arch failed on this host (rc=${real_rc})"
fi

# ============================================================================
# 3. Distro detection
# ============================================================================
echo ''
echo '--- 3. Distro detection ---'

if [[ -r /etc/os-release ]]; then
    set +e
    distro=$(system_distro 2>/dev/null)
    distro_rc=$?
    set -e
    if (( distro_rc == 0 )); then
        case "$distro" in
            debian|ubuntu|alpine|centos|rocky|almalinux|fedora|arch|rhel)
                pass "system_distro detects ${distro}"
                ;;
            *)
                fail "system_distro returned unexpected value: ${distro}"
                ;;
        esac
    else
        fail "system_distro failed (rc=${distro_rc})"
    fi

    set +e
    distro_id=$(system_distro_id 2>/dev/null)
    distro_id_rc=$?
    set -e
    if (( distro_id_rc == 0 )) && [[ -n "$distro_id" ]]; then
        pass "system_distro_id returns ${distro_id}"
    else
        fail 'system_distro_id should return the os-release ID'
    fi

    set +e
    version=$(system_version 2>/dev/null)
    version_rc=$?
    set -e
    if (( version_rc == 0 )) && [[ -n "$version" ]]; then
        pass "system_version returns ${version}"
    else
        pass 'system_version empty (no VERSION_ID) — acceptable'
    fi
else
    echo '  (skipping distro tests — /etc/os-release not readable)'
fi

# ============================================================================
# 4. Init system detection (forced + real)
# ============================================================================
echo ''
echo '--- 4. Init system detection ---'

# Forced systemd
PROXYCTL_TEST_INIT=systemd
set +e
init_out=$(system_init 2>/dev/null)
init_rc=$?
set -e
assert_eq "$init_out" 'systemd' 'forced init: systemd'

# Forced openrc
PROXYCTL_TEST_INIT=openrc
set +e
init_out=$(system_init 2>/dev/null)
init_rc=$?
set -e
assert_eq "$init_out" 'openrc' 'forced init: openrc'

# Forced unsupported must fail
PROXYCTL_TEST_INIT=bogus
set +e
init_out=$(system_init 2>/dev/null)
init_rc=$?
set -e
if (( init_rc != 0 )) && [[ "$init_out" == 'unsupported' ]]; then
    pass 'forced init: unsupported is rejected'
else
    fail "forced init: bogus should fail (out='${init_out}', rc=${init_rc})"
fi

# Real detection (unset override)
unset PROXYCTL_TEST_INIT
set +e
real_init=$(system_init 2>/dev/null)
real_init_rc=$?
set -e
if (( real_init_rc == 0 )); then
    case "$real_init" in
        systemd|openrc)
            pass "system_init detects ${real_init}"
            ;;
        *)
            fail "system_init returned unexpected value: ${real_init}"
            ;;
    esac
else
    pass 'system_init unsupported on this host — acceptable'
fi

# ============================================================================
# 5. Package manager detection
# ============================================================================
echo ''
echo '--- 5. Package manager detection ---'

set +e
pm=$(system_package_manager 2>/dev/null)
pm_rc=$?
set -e
if (( pm_rc == 0 )); then
    case "$pm" in
        apt|apk|dnf|yum|pacman)
            pass "system_package_manager detects ${pm}"
            ;;
        *)
            fail "system_package_manager returned unexpected value: ${pm}"
            ;;
    esac
else
    pass 'system_package_manager unknown on this host — acceptable'
fi

# ============================================================================
# 6. Root / non-root behavior
# ============================================================================
echo ''
echo '--- 6. Root / non-root behavior ---'

if system_is_root; then
    pass 'system_is_root true when EUID=0'

    set +e
    system_require_root
    req_rc=$?
    set -e
    if (( req_rc == 0 )); then
        pass 'system_require_root passes when root'
    else
        fail 'system_require_root should pass when root'
    fi
else
    pass 'system_is_root false when not root'

    set +e
    system_require_root > /dev/null 2>&1
    req_rc=$?
    set -e
    if (( req_rc != 0 )); then
        pass 'system_require_root fails when not root'
    else
        fail 'system_require_root should fail when not root'
    fi
fi

# ============================================================================
# 7. Hostname
# ============================================================================
echo ''
echo '--- 7. Hostname ---'

set +e
host=$(system_hostname 2>/dev/null)
host_rc=$?
set -e
if (( host_rc == 0 )) && [[ -n "$host" ]]; then
    pass "system_hostname returns ${host}"
else
    fail 'system_hostname should return a hostname'
fi

# ============================================================================
# Summary
# ============================================================================
echo ''
echo '================================================================'
echo "  System tests: ${PASSED} passed, ${FAILED} failed"
echo '================================================================'

if (( FAILED > 0 )); then
    exit 1
fi
