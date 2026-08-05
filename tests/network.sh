#!/usr/bin/env bash
# ------------------------------------------------------------------------------
# tests/network.sh — Phase 2.3 network test suite
#
# All external tools (ip, curl, getent, nc) are mocked via PATH so the suite
# never touches the real network, routes, or socket state.
# ------------------------------------------------------------------------------
set -o errexit
set -o nounset
set -o pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

source "${PROJECT_DIR}/lib/ui.sh"
source "${PROJECT_DIR}/lib/common/network.sh"

PASSED=0
FAILED=0

green() { echo -e "\033[0;32m$*\033[0m"; }
red()   { echo -e "\033[0;31m$*\033[0m"; }

pass() { green "  PASS: $*"; ((++PASSED)); }
fail() { red "  FAIL: $*"; ((++FAILED)); }

assert_eq()    { local got="$1" exp="$2"; shift 2 || true; [[ "${got}" == "${exp}" ]] && pass "$*" || fail "$* — expected '${exp}', got '${got}'"; }
assert_ok()    { local cmd="$1"; shift; if eval "${cmd}"; then pass "$*"; else fail "$*"; fi; }
assert_fail()  { local cmd="$1"; shift; if ! eval "${cmd}" 2>/dev/null; then pass "$*"; else fail "$*"; fi; }

# --- mock tools ----------------------------------------------------------------
MOCK_DIR=$(mktemp -d)
export NET_TEST_LOG="${MOCK_DIR}/net.log"
export NET_TEST_CURL_OUT=''
export NET_TEST_IP_FAIL=''
export NET_TEST_NO_V6_ROUTE=''
export NET_TEST_NC_FAIL=''

cat > "${MOCK_DIR}/ip" <<'IPEOF'
#!/usr/bin/env bash
echo "ip $*" >> "${NET_TEST_LOG}"
if [[ "${NET_TEST_IP_FAIL:-}" == '1' ]]; then
    exit 1
fi
case "${1:-}" in
    -4)
        echo '1.1.1.1 via 10.0.0.1 dev eth0 src 10.0.0.2 uid 0'
        exit 0
        ;;
    -6)
        if [[ "${NET_TEST_NO_V6_ROUTE:-}" == '1' ]]; then
            exit 1
        fi
        echo '2606:4700:4700::1111 via fe80::1 dev eth0 src 2001:db8::2 metric 1024'
        exit 0
        ;;
    *)
        exit 1
        ;;
esac
IPEOF

cat > "${MOCK_DIR}/curl" <<'CURLEOF'
#!/usr/bin/env bash
echo "curl $*" >> "${NET_TEST_LOG}"
url=''
for a in "$@"; do url="$a"; done
case "$url" in
    *cloudflare.com*) exit 1 ;;
    *ipify.org*)      printf '%s\n' 'invalid-ip-output'; exit 0 ;;
    *icanhazip.com*)  printf '%s\n' "${NET_TEST_CURL_OUT}"; exit 0 ;;
    *)                exit 1 ;;
esac
CURLEOF

cat > "${MOCK_DIR}/getent" <<'GETENTEOF'
#!/usr/bin/env bash
echo "getent $*" >> "${NET_TEST_LOG}"
case "${1:-}" in
    ahostsv4)
        printf '104.16.1.1        STREAM example.com\n104.16.1.1        DGRAM\n104.16.2.1        STREAM\n'
        exit 0
        ;;
    ahostsv6)
        printf '2001:db8::1        STREAM example.com\n'
        exit 0
        ;;
    ahosts)
        printf '104.16.1.1        STREAM example.com\n104.16.1.1        DGRAM\n104.16.2.1        STREAM\n2001:db8::1        STREAM\n'
        exit 0
        ;;
    *)
        exit 1
        ;;
esac
GETENTEOF

cat > "${MOCK_DIR}/nc" <<'NCEOF'
#!/usr/bin/env bash
echo "nc $*" >> "${NET_TEST_LOG}"
if [[ "${NET_TEST_NC_FAIL:-}" == '1' ]]; then
    exit 1
fi
exit 0
NCEOF

chmod +x "${MOCK_DIR}"/ip "${MOCK_DIR}"/curl "${MOCK_DIR}"/getent "${MOCK_DIR}"/nc
export PATH="${MOCK_DIR}:${PATH}"

echo ''
echo '================================================================'
echo '  ProxyCTL Phase 2.3 Network Tests'
echo '================================================================'
echo ''

# ============================================================================
# 1. IPv4 validation matrix
# ============================================================================
echo '--- 1. IPv4 validation ---'

for ip in 0.0.0.0 1.1.1.1 127.0.0.1 192.168.1.1 255.255.255.255 \
          01.02.03.04 08.08.08.08 009.010.099.255 000.000.000.000; do
    assert_ok "network_validate_ipv4 '$ip'" "IPv4 accepts: ${ip}"
done

for bad in 256.0.0.1 1.2.3 1.2.3.4.5 1..3.4 abc 1.2.3.4. 0000.0.0.0 ''; do
    assert_fail "network_validate_ipv4 '$bad'" "IPv4 rejects: '${bad}'"
done

# ============================================================================
# 2. IPv6 validation matrix
# ============================================================================
echo ''
echo '--- 2. IPv6 validation ---'

for ip in '::1' '::' '2001:db8::1' 'fe80::1' 'ffff:ffff:ffff:ffff:ffff:ffff:ffff:ffff' '::ffff:192.168.1.1' '2001:db8:0:0:0:0:2:1'; do
    assert_ok "_network_validate_ipv6_shell '$ip'" "IPv6 shell accepts: ${ip}"
done

for bad in '2001:::1' 'gggg::1' '12345::1' ':1:2:3:4:5:6:7:8' '1:2:3:4:5:6:7:8:' '1.2.3.4'; do
    assert_fail "_network_validate_ipv6_shell '$bad'" "IPv6 shell rejects: '${bad}'"
done

for ip in '::1' '2001:db8::1' 'fe80::1' '::'; do
    assert_ok "network_validate_ipv6 '$ip'" "network_validate_ipv6 accepts: ${ip}"
done

assert_fail "network_validate_ipv6 '1.2.3.4'" 'network_validate_ipv6 rejects IPv4'
assert_fail "network_validate_ipv4 '::1'" 'network_validate_ipv4 rejects IPv6'

# ============================================================================
# 3. network_validate_ip
# ============================================================================
echo ''
echo '--- 3. network_validate_ip ---'

assert_ok "network_validate_ip '127.0.0.1'" 'network_validate_ip accepts IPv4'
assert_ok "network_validate_ip '::1'" 'network_validate_ip accepts IPv6'
assert_fail "network_validate_ip 'not-an-ip'" 'network_validate_ip rejects garbage'

# ============================================================================
# 4. Domain validation
# ============================================================================
echo ''
echo '--- 4. Domain validation ---'

for d in example.com a.example.com foo-bar.example.org xn--test.example example.com.; do
    assert_ok "network_validate_domain '$d'" "domain accepts: ${d}"
done

for bad in -example.com example-.com example..com foo_bar.com .; do
    assert_fail "network_validate_domain '$bad'" "domain rejects: '${bad}'"
done

assert_fail "network_validate_domain 'localhost'" 'domain rejects single label (needs a dot)'

# ============================================================================
# 5. Host validation
# ============================================================================
echo ''
echo '--- 5. Host validation ---'

assert_ok "network_validate_host '127.0.0.1'" 'host accepts IPv4'
assert_ok "network_validate_host '::1'" 'host accepts IPv6'
assert_ok "network_validate_host 'example.com'" 'host accepts domain'
assert_ok "network_validate_host 'localhost'" 'host accepts localhost'
assert_ok "network_validate_host 'server'" 'host accepts single-label hostname'
assert_fail "network_validate_host 'bad host'" 'host rejects spaces'
assert_fail "network_validate_host ''" 'host rejects empty'

# ============================================================================
# 6. Default interface
# ============================================================================
echo ''
echo '--- 6. Default interface ---'

assert_eq "$(network_default_interface_v4)" 'eth0' 'default interface v4 = eth0'
assert_eq "$(network_default_interface_v6)" 'eth0' 'default interface v6 = eth0'

export NET_TEST_NO_V6_ROUTE=1
assert_fail "network_default_interface_v6" 'default interface v6 fails without route'
unset NET_TEST_NO_V6_ROUTE

# ============================================================================
# 7. Primary IP
# ============================================================================
echo ''
echo '--- 7. Primary IP ---'

assert_eq "$(network_primary_ipv4)" '10.0.0.2' 'primary IPv4 = 10.0.0.2'
assert_eq "$(network_primary_ipv6)" '2001:db8::2' 'primary IPv6 = 2001:db8::2'

assert_ok "network_has_ipv4" 'has_ipv4 true'
assert_ok "network_has_ipv6" 'has_ipv6 true'

export NET_TEST_IP_FAIL=1
assert_fail "network_primary_ipv4" 'primary IPv4 fails when ip fails'
assert_fail "network_has_ipv4" 'has_ipv4 false when ip fails'
unset NET_TEST_IP_FAIL

# ============================================================================
# 8. Public IPv4 provider fallback
# ============================================================================
echo ''
echo '--- 8. Public IPv4 fallback ---'

export NET_TEST_CURL_OUT='1.2.3.4'
assert_eq "$(network_public_ipv4)" '1.2.3.4' 'public IPv4 = 1.2.3.4 (fallback to icanhazip)'

export NET_TEST_CURL_OUT='<html>error 500</html>'
assert_fail "network_public_ipv4" 'public IPv4 fails when all providers invalid'

# ============================================================================
# 9. Public IPv6 provider fallback
# ============================================================================
echo ''
echo '--- 9. Public IPv6 fallback ---'

export NET_TEST_CURL_OUT='2001:db8::1'
assert_eq "$(network_public_ipv6)" '2001:db8::1' 'public IPv6 = 2001:db8::1'

export NET_TEST_CURL_OUT='invalid'
assert_fail "network_public_ipv6" 'public IPv6 fails when provider output invalid'

unset NET_TEST_CURL_OUT

# ============================================================================
# 10. DNS resolve
# ============================================================================
echo ''
echo '--- 10. DNS resolve ---'

# Consume the resolver output completely before inspecting individual lines.
# Piping the producer into `head -1` intentionally closes stdout early and
# makes Bash's builtin printf report EPIPE even though resolution succeeded.
RESOLVE_V4=$(network_resolve_domain example.com 4)
RESOLVE_V4_FIRST=${RESOLVE_V4%%$'\n'*}
RESOLVE_V4_LAST=${RESOLVE_V4##*$'\n'}
assert_eq "$RESOLVE_V4_FIRST" '104.16.1.1' 'resolve v4 first IP'
assert_eq "$(printf '%s\n' "$RESOLVE_V4" | wc -l | tr -d ' ')" '2' 'resolve v4 dedups (2 unique)'
assert_eq "$RESOLVE_V4_LAST" '104.16.2.1' 'resolve v4 second IP'
assert_eq "$(network_resolve_domain example.com 6)" '2001:db8::1' 'resolve v6 IP'
assert_eq "$(network_resolve_domain example.com any | wc -l | tr -d ' ')" '3' 'resolve any = 3 unique (2 v4 + 1 v6)'

: > "${NET_TEST_LOG}"
assert_fail "network_resolve_domain 'exa_mple.com'" 'resolve rejects invalid domain'
if [[ ! -s "${NET_TEST_LOG}" ]]; then
    pass 'invalid domain does not call getent'
else
    fail "invalid domain should not call getent: $(cat "${NET_TEST_LOG}")"
fi

# ============================================================================
# 11. TCP connect
# ============================================================================
echo ''
echo '--- 11. TCP connect ---'

export NET_TEST_NC_FAIL=''
assert_ok "network_tcp_connect example.com 443" 'tcp_connect success via nc'
assert_eq "$(tail -1 "${NET_TEST_LOG}")" 'nc -z -w 3 example.com 443' 'nc receives -z -w 3 host port'

: > "${NET_TEST_LOG}"
assert_fail "network_tcp_connect example.com 99999" 'tcp_connect rejects invalid port'
assert_fail "network_tcp_connect example.com 443 99" 'tcp_connect rejects timeout > 30'
assert_fail "network_tcp_connect 'bad host' 443" 'tcp_connect rejects invalid host'
assert_fail "network_tcp_connect example.com 443 0" 'tcp_connect rejects timeout 0'
if [[ ! -s "${NET_TEST_LOG}" ]]; then
    pass 'invalid tcp_connect args do not call nc'
else
    fail "invalid tcp_connect args should not call nc: $(cat "${NET_TEST_LOG}")"
fi

export NET_TEST_NC_FAIL=1
assert_fail "network_tcp_connect example.com 443" 'tcp_connect failure propagates (nc exit 1)'
unset NET_TEST_NC_FAIL

# ============================================================================
# 12. Cleanup
# ============================================================================
echo ''
echo '--- 12. Cleanup ---'

rm -rf "${MOCK_DIR}"

echo ''
echo '================================================================'
echo "  Network tests: ${PASSED} passed, ${FAILED} failed"
echo '================================================================'

if (( FAILED > 0 )); then
    exit 1
fi
