#!/usr/bin/env bash
set -o nounset
set -o pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "$PROJECT_DIR"

PASSED=0
FAILED=0

run_case() {
    local name="$1"
    shift
    printf '\n================================================================\n'
    printf 'REGRESSION: %s\n' "$name"
    printf '================================================================\n'
    if "$@"; then
        printf 'REGRESSION PASS: %s\n' "$name"
        PASSED=$((PASSED + 1))
    else
        printf 'REGRESSION FAIL: %s\n' "$name" >&2
        FAILED=$((FAILED + 1))
    fi
}

run_shell_test() { bash "$1"; }
run_installer_test() {
    if (( EUID == 0 )); then
        bash tests/installer.sh
    elif command -v sudo >/dev/null 2>&1; then
        sudo bash tests/installer.sh
    else
        printf 'installer regression requires root or sudo\n' >&2
        return 1
    fi
}

run_case 'Bash declaration scope audit' python3 tests/bash_scope_audit.py
run_case 'Bash syntax' bash -c "find . -name '*.sh' -print0 | xargs -0 -n1 bash -n"
run_case 'Core smoke' run_shell_test tests/smoke.sh
run_case 'UI propagation' run_shell_test tests/ui.sh
run_case 'Real interactive spec collectors' run_shell_test tests/interactive_specs.sh
run_case 'Interactive menu E2E' run_shell_test tests/menu.sh
run_case 'Installer transaction / piped bootstrap' run_installer_test
run_case 'System abstraction' run_shell_test tests/system.sh
run_case 'Service abstraction' run_shell_test tests/service.sh
run_case 'Network utilities' run_shell_test tests/network.sh
run_case 'Port utilities' run_shell_test tests/port.sh
run_case 'Locking' run_shell_test tests/lock.sh
run_case 'Lock security' run_shell_test tests/lock_security.sh
run_case 'Config transactions' run_shell_test tests/transaction.sh
run_case 'Certificates' run_shell_test tests/certificate.sh
run_case 'Portable backup' run_shell_test tests/backup.sh
run_case 'Phase 2 integration' run_shell_test tests/integration.sh
run_case 'Core lifecycle adapters' run_shell_test tests/engine_lifecycle.sh
run_case 'Inbound lifecycle' run_shell_test tests/inbounds.sh
run_case 'Hardened sing-box users' run_shell_test tests/singbox_clients.sh
run_case 'Inbound edits and user rename' run_shell_test tests/inbound_edit.sh
run_case 'Outbound lifecycle and routing safety' run_shell_test tests/outbounds.sh
run_case 'Existing-config reconciliation' run_shell_test tests/reconcile.sh
run_case 'Restore runtime synchronization' run_shell_test tests/runtime.sh
run_case 'Self-uninstall safety' run_shell_test tests/uninstall.sh

printf '\n================================================================\n'
printf 'Full regression suites: %d passed, %d failed\n' "$PASSED" "$FAILED"
printf '================================================================\n'
(( FAILED == 0 ))
