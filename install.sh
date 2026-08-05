#!/usr/bin/env bash
# ------------------------------------------------------------------------------
# install.sh — Install proxyctl to system paths
#
# Installs ONLY the proxyctl manager. Does NOT install Xray or sing-box.
#
# The installer runs as a single transaction:
#   1. stage new lib + binary (nothing touched yet)
#   2. verify staged content
#   3. swap in new lib + binary (old moved aside as *.old)
#   4. symlink, directories, metadata init, final verify
#   5. COMMIT — only then are *.old backups removed
#
# Any failure triggers install_rollback (via the EXIT trap), restoring the
# previous installation. Old lib/binary/symlink are preserved until commit.
#
# Test-only overrides (not user documentation):
#   PROXYCTL_INSTALL_ROOT  — install under an alternate root (default /)
#   PROXYCTL_TEST_FAIL_AT  — inject a failure at a named point
# ------------------------------------------------------------------------------
set -o errexit
set -o nounset
set -o pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly INSTALL_ROOT="${PROXYCTL_INSTALL_ROOT:-/}"

root_path() {
    local path="$1"
    if [[ "$INSTALL_ROOT" == '/' ]]; then printf '%s' "$path"; else printf '%s%s' "$INSTALL_ROOT" "$path"; fi
}

readonly BIN_PATH="$(root_path '/usr/local/sbin/proxyctl')"
readonly SYMLINK_PATH="$(root_path '/usr/local/bin/proxyctl')"
readonly LIB_PATH="$(root_path '/usr/local/lib/proxyctl')"
readonly DATA_PATH="$(root_path '/var/lib/proxyctl')"
readonly CERTS_PATH="$(root_path '/etc/proxyctl/certs')"
readonly BACKUP_PATH="$(root_path '/var/backups/proxyctl')"
readonly BIN_NEW="${BIN_PATH}.new"
readonly BIN_OLD="${BIN_PATH}.old"
readonly LIB_NEW="${LIB_PATH}.new"
readonly LIB_OLD="${LIB_PATH}.old"

_STAGED_BIN=0
_STAGED_LIB=0
_HAD_OLD_BIN=0
_HAD_OLD_LIB=0
_HAD_OLD_SYMLINK=0
_OLD_SYMLINK_TARGET=''
_SYMLINK_CHANGED=0
_CREATED_DATA_DIR=0
_CREATED_CERTS_DIR=0
_CREATED_BACKUP_DIR=0
_INSTALL_COMMITTED=0

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    echo 'This installer must be run as root.'
    echo "Usage: sudo bash ${0}"
    exit 1
fi
if [[ "${BASH_VERSINFO[0]:-0}" -lt 4 ]]; then
    echo "proxyctl installer: Bash 4.0+ is required (found ${BASH_VERSION:-unknown})" >&2
    exit 1
fi

_verify_lib_contents() {
    local dir="$1" f missing=0
    local required_files=(
        core.sh
        ui.sh
        capability.sh
        metadata.sh
        transaction.sh
        menu.sh
        inbound.sh
        inbound_edit.sh
        client_rename.sh
        outbound.sh
        runtime.sh
        reconcile.sh
        uninstall.sh
        xray/engine.sh
        xray/inbound.sh
        xray/outbound.sh
        singbox/engine.sh
        singbox/inbound.sh
        singbox/clients.sh
        singbox/outbound.sh
        singbox/hy2_hop.sh
        common/system.sh
        common/service.sh
        common/network.sh
        common/port.sh
        common/lock.sh
        common/certificate.sh
        common/backup.sh
        common/bbr.sh
    )
    for f in "${required_files[@]}"; do
        if [[ ! -f "${dir}/${f}" ]]; then
            echo "  MISSING: ${f}" >&2; missing=$((missing + 1))
        elif [[ ! -s "${dir}/${f}" ]]; then
            echo "  EMPTY: ${f}" >&2; missing=$((missing + 1))
        fi
    done
    return "$missing"
}

_verify_lib_syntax() {
    local dir="$1" errors=0
    while IFS= read -r -d '' sh_file; do
        if ! bash -n "$sh_file" 2>&1; then errors=$((errors + 1)); fi
    done < <(find "$dir" -name '*.sh' -print0)
    return "$errors"
}

capture_existing_state() {
    [[ -f "$BIN_PATH" ]] && _HAD_OLD_BIN=1
    [[ -d "$LIB_PATH" ]] && _HAD_OLD_LIB=1
    if [[ -L "$SYMLINK_PATH" ]]; then _HAD_OLD_SYMLINK=1; _OLD_SYMLINK_TARGET="$(readlink "$SYMLINK_PATH" 2>/dev/null || true)"; fi
    [[ -d "$DATA_PATH" ]] || _CREATED_DATA_DIR=1
    [[ -d "$CERTS_PATH" ]] || _CREATED_CERTS_DIR=1
    [[ -d "$BACKUP_PATH" ]] || _CREATED_BACKUP_DIR=1
}

stage_library() {
    rm -rf "$LIB_NEW"; mkdir -p "$LIB_NEW"
    cp -r "${SCRIPT_DIR}/lib/"* "$LIB_NEW/"
    find "$LIB_NEW" -name '*.sh' -exec chmod 644 {} \;
    find "$LIB_NEW" -type d -exec chmod 755 {} \;
}

stage_binary() {
    mkdir -p "$(dirname "$BIN_NEW")"
    install -m 755 "${SCRIPT_DIR}/proxyctl.sh" "$BIN_NEW" || die_install 'Failed to stage binary.'
}

verify_staging() {
    _verify_lib_contents "$LIB_NEW" || die_install 'Staged library verification failed (missing or empty files).'
    _verify_lib_syntax "$LIB_NEW" || die_install 'Staged library has syntax errors.'
    bash -n "$BIN_NEW" || die_install 'Staged binary has syntax errors.'
    PROXYCTL_DEV_LIB="$LIB_NEW" bash "$BIN_NEW" version >/dev/null 2>&1 || die_install 'Staged binary failed version self-check against staged library.'
}

swap_library() {
    if [[ -d "$LIB_PATH" ]]; then rm -rf "$LIB_OLD"; mv "$LIB_PATH" "$LIB_OLD"; _STAGED_LIB=1; fi
    mv "$LIB_NEW" "$LIB_PATH"
}

swap_binary() {
    if [[ -f "$BIN_PATH" ]]; then rm -f "$BIN_OLD"; mv "$BIN_PATH" "$BIN_OLD"; _STAGED_BIN=1; fi
    mv "$BIN_NEW" "$BIN_PATH"
}

create_symlink() {
    mkdir -p "$(dirname "$SYMLINK_PATH")"
    ln -sfn "$BIN_PATH" "$SYMLINK_PATH" || die_install 'Failed to create symlink.'
    _SYMLINK_CHANGED=1
}

ensure_directories() {
    mkdir -p "$DATA_PATH"; chmod 700 "$DATA_PATH"
    mkdir -p "$CERTS_PATH"; chmod 700 "$CERTS_PATH"
    mkdir -p "$BACKUP_PATH"; chmod 700 "$BACKUP_PATH"
    mkdir -p "$DATA_PATH/transactions"; chmod 700 "$DATA_PATH/transactions"
}

dependency_check() {
    if ! command -v jq >/dev/null 2>&1; then
        echo '' >&2
        echo 'jq is required for proxyctl metadata operations.' >&2
        echo 'Install jq and re-run the installer.' >&2
        echo '' >&2
        echo '  Debian/Ubuntu:  apt-get install jq' >&2
        echo '  RHEL/CentOS:     yum install jq' >&2
        echo '  Fedora:          dnf install jq' >&2
        echo '  Arch:            pacman -S jq' >&2
        echo '  Alpine:          apk add jq' >&2
        die_install 'jq not found — metadata init requires jq.'
    fi
}

run_metadata_init() {
    PROXYCTL_DEV_LIB="$LIB_PATH" PROXYCTL_DATA="$DATA_PATH" PROXYCTL_META="$DATA_PATH/meta.json" "$BIN_PATH" internal-init 2>&1 || die_install 'Metadata initialisation failed.'
}

final_verify() {
    PROXYCTL_LIB="$LIB_PATH" "$BIN_PATH" version >/dev/null 2>&1 || die_install 'Installed binary version check failed.'
    PROXYCTL_LIB="$LIB_PATH" "$BIN_PATH" help >/dev/null 2>&1 || die_install 'Installed binary help check failed.'
}

warn_install() { echo "[WARN] $*" >&2; }
validate_symlink_path() {
    if [[ -e "$SYMLINK_PATH" || -L "$SYMLINK_PATH" ]]; then
        [[ -L "$SYMLINK_PATH" ]] || die_install "Refusing to overwrite non-symlink path: $SYMLINK_PATH"
    fi
}

cleanup_old_artifacts() {
    if [[ "${PROXYCTL_TEST_FAIL_CLEANUP:-}" == bin ]]; then warn_install 'Injected old binary cleanup failure (test)'; elif ! rm -f "$BIN_OLD"; then warn_install "Unable to remove old binary backup: $BIN_OLD"; fi
    if [[ "${PROXYCTL_TEST_FAIL_CLEANUP:-}" == lib ]]; then warn_install 'Injected old library cleanup failure (test)'; elif ! rm -rf "$LIB_OLD"; then warn_install "Unable to remove old library backup: $LIB_OLD"; fi
}

install_commit() { _INSTALL_COMMITTED=1; cleanup_old_artifacts; }

install_rollback() {
    echo 'Rolling back installation...' >&2
    if (( _STAGED_BIN )); then rm -f "$BIN_PATH"; mv "$BIN_OLD" "$BIN_PATH" 2>/dev/null || true
    elif (( _HAD_OLD_BIN == 0 )); then rm -f "$BIN_PATH" 2>/dev/null || true; fi
    if (( _STAGED_LIB )); then rm -rf "$LIB_PATH"; mv "$LIB_OLD" "$LIB_PATH" 2>/dev/null || true
    elif (( _HAD_OLD_LIB == 0 )); then rm -rf "$LIB_PATH" 2>/dev/null || true; fi
    if (( _SYMLINK_CHANGED )); then
        if (( _HAD_OLD_SYMLINK )) && [[ -n "$_OLD_SYMLINK_TARGET" ]]; then ln -sfn "$_OLD_SYMLINK_TARGET" "$SYMLINK_PATH" 2>/dev/null || true; else rm -f "$SYMLINK_PATH" 2>/dev/null || true; fi
    fi
    rm -rf "$BIN_NEW" "$LIB_NEW" 2>/dev/null || true
    if (( _CREATED_DATA_DIR )); then rmdir "$DATA_PATH/transactions" 2>/dev/null || true; rmdir "$DATA_PATH" 2>/dev/null || true; fi
    (( _CREATED_CERTS_DIR == 0 )) || rmdir "$CERTS_PATH" 2>/dev/null || true
    (( _CREATED_BACKUP_DIR == 0 )) || rmdir "$BACKUP_PATH" 2>/dev/null || true
}

_cleanup_on_exit() { local rc=$?; if (( rc != 0 && _INSTALL_COMMITTED == 0 )); then install_rollback || true; fi; }
die_install() { local msg="$1" code="${2:-1}"; echo '' >&2; echo "[FATAL] ${msg}" >&2; echo '' >&2; exit "$code"; }
_test_failpoint() { [[ "${PROXYCTL_TEST_FAIL_AT:-}" != "$1" ]] || die_install "Injected test failure at: $1"; }

echo ''
echo '  ProxyCTL Installer'
echo '  =================='
echo ''
capture_existing_state
validate_symlink_path
trap _cleanup_on_exit EXIT

echo 'Installing proxyctl library...'; stage_library; echo "  -> staged: ${LIB_NEW}"
echo 'Installing proxyctl binary...'; stage_binary; echo "  -> staged: ${BIN_NEW}"
echo 'Verifying staged installation...'; verify_staging; echo '  -> staging verification passed'
echo 'Swapping library...'; swap_library; _test_failpoint after-lib-swap; echo "  -> ${LIB_PATH}/"
echo 'Swapping binary...'; swap_binary; _test_failpoint after-bin-swap; echo "  -> ${BIN_PATH}"
echo 'Creating symlink...'; create_symlink; _test_failpoint after-symlink; echo "  -> ${SYMLINK_PATH} -> ${BIN_PATH}"
echo ''; echo 'Creating data directories...'; ensure_directories
echo "  -> ${DATA_PATH}/ (mode 700)"; echo "  -> ${CERTS_PATH}/ (mode 700)"; echo "  -> ${BACKUP_PATH}/ (mode 700)"; echo "  -> ${DATA_PATH}/transactions/ (mode 700)"
echo ''; echo 'Checking dependencies...'; dependency_check
echo 'Initialising metadata...'; _test_failpoint before-metadata; run_metadata_init; _test_failpoint after-metadata; echo '  -> metadata initialised successfully'
echo ''; echo 'Verifying installation...'; _test_failpoint before-final-check; final_verify; echo '  -> version: OK'; echo '  -> help:    OK'
install_commit
echo ''; echo 'ProxyCTL installed successfully.'; echo ''; echo 'Run "proxyctl" to start the interactive menu.'; echo 'Run "proxyctl help" for usage information.'
