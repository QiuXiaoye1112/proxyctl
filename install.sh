#!/usr/bin/env bash
# ------------------------------------------------------------------------------
# install.sh — Install proxyctl to system paths
#
# Installs ONLY the proxyctl manager. Does NOT install Xray or sing-box.
# Safe update: stages new files, validates, then atomically swaps.
# Failures trigger rollback to previous state.
# ------------------------------------------------------------------------------
set -o errexit
set -o nounset
set -o pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- paths ------------------------------------------------------------------
readonly BIN_PATH='/usr/local/sbin/proxyctl'
readonly SYMLINK_PATH='/usr/local/bin/proxyctl'
readonly LIB_PATH='/usr/local/lib/proxyctl'
readonly DATA_PATH='/var/lib/proxyctl'
readonly CERTS_PATH='/etc/proxyctl/certs'
readonly BACKUP_PATH='/var/backups/proxyctl'

readonly BIN_NEW="${BIN_PATH}.new"
readonly BIN_OLD="${BIN_PATH}.old"
readonly LIB_NEW="${LIB_PATH}.new"
readonly LIB_OLD="${LIB_PATH}.old"

# Track what was staged for rollback on failure.
_STAGED_BIN=''
_STAGED_LIB=''
_OLD_BACKED_UP=''

# --- banner -----------------------------------------------------------------
echo ''
echo '  ProxyCTL Installer'
echo '  =================='
echo ''

# --- preflight --------------------------------------------------------------
if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    echo 'This installer must be run as root.'
    echo "Usage: sudo bash ${0}"
    exit 1
fi

# Bash version check (installer itself also requires Bash 4+)
if [[ "${BASH_VERSINFO[0]:-0}" -lt 4 ]]; then
    echo "proxyctl installer: Bash 4.0+ is required (found ${BASH_VERSION:-unknown})" >&2
    exit 1
fi

# --- die_install ------------------------------------------------------------
die_install() {
    local msg="$1"
    local code="${2:-1}"
    echo '' >&2
    echo "[FATAL] ${msg}" >&2
    echo '' >&2

    # Rollback: restore old binary if we moved it
    if [[ -n "${_STAGED_BIN}" && -f "${BIN_OLD}" ]]; then
        echo 'Rolling back binary...'
        rm -f "${BIN_PATH}"
        mv "${BIN_OLD}" "${BIN_PATH}" 2>/dev/null || true
    fi

    # Rollback: restore old lib if we moved it
    if [[ -n "${_STAGED_LIB}" && -d "${LIB_OLD}" ]]; then
        echo 'Rolling back library...'
        rm -rf "${LIB_PATH}" 2>/dev/null || true
        mv "${LIB_OLD}" "${LIB_PATH}" 2>/dev/null || true
    fi

    # Clean up staged files
    rm -rf "${BIN_NEW}" "${LIB_NEW}" 2>/dev/null || true

    echo 'Installation aborted.' >&2
    exit "${code}"
}

# --- helpers ----------------------------------------------------------------
_verify_lib_contents() {
    local dir="$1"
    local missing=0

    local required_files=(
        core.sh
        ui.sh
        capability.sh
        metadata.sh
        transaction.sh
        menu.sh
        xray/engine.sh
        singbox/engine.sh
        common/system.sh
        common/network.sh
        common/port.sh
        common/lock.sh
        common/certificate.sh
        common/backup.sh
        common/bbr.sh
    )

    for f in "${required_files[@]}"; do
        if [[ ! -f "${dir}/${f}" ]]; then
            echo "  MISSING: ${f}" >&2
            missing=$((missing + 1))
        elif [[ ! -s "${dir}/${f}" ]]; then
            echo "  EMPTY: ${f}" >&2
            missing=$((missing + 1))
        fi
    done

    return "${missing}"
}

_verify_lib_syntax() {
    local dir="$1"
    local errors=0

    while IFS= read -r -d '' sh_file; do
        if ! bash -n "${sh_file}" 2>&1; then
            errors=$((errors + 1))
        fi
    done < <(find "${dir}" -name '*.sh' -print0)

    return "${errors}"
}

# --- install library (staged with rollback) ----------------------------------
echo 'Installing proxyctl library...'

# Step 1: prepare lib.new
rm -rf "${LIB_NEW}"
mkdir -p "${LIB_NEW}"

# Copy source lib to staging
cp -r "${SCRIPT_DIR}/lib/"* "${LIB_NEW}/"
find "${LIB_NEW}" -name '*.sh' -exec chmod 644 {} \;
find "${LIB_NEW}" -type d -exec chmod 755 {} \;

echo "  -> staged: ${LIB_NEW}"

# Step 2: verify lib.new contents
echo 'Verifying staged library...'
if ! _verify_lib_contents "${LIB_NEW}"; then
    rm -rf "${LIB_NEW}"
    die_install 'Staged library verification failed (missing or empty files).'
fi

# Step 3: validate bash syntax
if ! _verify_lib_syntax "${LIB_NEW}"; then
    rm -rf "${LIB_NEW}"
    die_install 'Staged library has syntax errors.'
fi

echo '  -> library verification passed'

# Step 4: if existing lib exists, move to lib.old
if [[ -d "${LIB_PATH}" ]]; then
    rm -rf "${LIB_OLD}"
    mv "${LIB_PATH}" "${LIB_OLD}"
    _STAGED_LIB=1
fi

# Step 5: lib.new → lib
mv "${LIB_NEW}" "${LIB_PATH}"
echo "  -> ${LIB_PATH}/"

# Step 6: verify new lib
if ! _verify_lib_contents "${LIB_PATH}"; then
    # Swap back
    rm -rf "${LIB_PATH}"
    if [[ -d "${LIB_OLD}" ]]; then
        mv "${LIB_OLD}" "${LIB_PATH}"
    fi
    die_install 'Installed library verification failed — rolled back.'
fi

# Step 7: success — clean up old
if [[ -d "${LIB_OLD}" ]]; then
    rm -rf "${LIB_OLD}"
    echo '  -> old library cleaned up'
fi

_staged_bin=''
_OLD_BACKED_UP=''

# --- install binary (staged with rollback) -----------------------------------
echo 'Installing proxyctl binary...'

# Step 1: prepare binary.new
install -m 755 "${SCRIPT_DIR}/proxyctl.sh" "${BIN_NEW}" || {
    die_install 'Failed to stage binary.'
}

echo "  -> staged: ${BIN_NEW}"

# Step 2: verify syntax
if ! bash -n "${BIN_NEW}" 2>&1; then
    rm -f "${BIN_NEW}"
    die_install 'Staged binary has syntax errors.'
fi

# Step 3: verify it runs (version command)
if ! PROXYCTL_DEV_LIB="${LIB_PATH}" bash "${BIN_NEW}" version > /dev/null 2>&1; then
    rm -f "${BIN_NEW}"
    die_install 'Staged binary failed version self-check.'
fi

echo '  -> binary verification passed'

# Step 4: if existing binary, move to old
if [[ -f "${BIN_PATH}" ]]; then
    rm -f "${BIN_OLD}"
    mv "${BIN_PATH}" "${BIN_OLD}"
    _STAGED_BIN=1
fi

# Step 5: binary.new → binary
mv "${BIN_NEW}" "${BIN_PATH}"

# Step 6: verify new binary runs
if ! PROXYCTL_DEV_LIB="${LIB_PATH}" "${BIN_PATH}" version > /dev/null 2>&1; then
    # Swap back
    rm -f "${BIN_PATH}"
    if [[ -f "${BIN_OLD}" ]]; then
        mv "${BIN_OLD}" "${BIN_PATH}"
    fi
    die_install 'Installed binary failed version self-check — rolled back.'
fi

# Step 7: success — clean up old
if [[ -f "${BIN_OLD}" ]]; then
    rm -f "${BIN_OLD}"
    echo '  -> old binary cleaned up'
fi

_staged_bin=''

# --- symlink ----------------------------------------------------------------
ln -sfn "${BIN_PATH}" "${SYMLINK_PATH}" || die_install 'Failed to create symlink.'
echo "  -> ${SYMLINK_PATH} -> ${BIN_PATH}"

# --- create directories with correct permissions -----------------------------
echo ''
echo 'Creating data directories...'

mkdir -p "${DATA_PATH}"
chmod 700 "${DATA_PATH}"
echo "  -> ${DATA_PATH}/ (mode 700)"

mkdir -p "${CERTS_PATH}"
chmod 700 "${CERTS_PATH}"
echo "  -> ${CERTS_PATH}/ (mode 700)"

mkdir -p "${BACKUP_PATH}"
chmod 700 "${BACKUP_PATH}"
echo "  -> ${BACKUP_PATH}/ (mode 700)"

# Transactions directory
mkdir -p "${DATA_PATH}/transactions"
chmod 700 "${DATA_PATH}/transactions"
echo "  -> ${DATA_PATH}/transactions/ (mode 700)"

# --- metadata initialisation (only via internal-init) ------------------------
echo ''
echo 'Initialising metadata...'

# Check jq availability before metadata init
if ! command -v jq > /dev/null 2>&1; then
    echo ''
    echo 'jq is required for proxyctl metadata operations.'
    echo 'Install jq and re-run the installer.'
    echo ''
    echo '  Debian/Ubuntu:  apt-get install jq'
    echo '  RHEL/CentOS:     yum install jq'
    echo '  Fedora:          dnf install jq'
    echo '  Arch:            pacman -S jq'
    echo '  Alpine:          apk add jq'
    die_install 'jq not found — metadata init requires jq.'
fi

# Use internal-init exclusively — NO fallback manual meta.json creation.
if ! PROXYCTL_DEV_LIB="${LIB_PATH}" \
     PROXYCTL_DATA="${DATA_PATH}" \
     PROXYCTL_META="${DATA_PATH}/meta.json" \
     "${BIN_PATH}" internal-init 2>&1; then
    die_install 'Metadata initialisation failed.'
fi

echo '  -> metadata initialised successfully'

# --- verify installed binary end-to-end -------------------------------------
echo ''
echo 'Verifying installation...'

if ! "${BIN_PATH}" version > /dev/null 2>&1; then
    die_install 'Installed binary version check failed.'
fi

if ! "${BIN_PATH}" help > /dev/null 2>&1; then
    die_install 'Installed binary help check failed.'
fi

echo '  -> version: OK'
echo '  -> help:    OK'

# --- result -----------------------------------------------------------------
echo ''
echo 'ProxyCTL installed successfully.'
echo ''
echo 'Run "proxyctl" to start the interactive menu.'
echo 'Run "proxyctl help" for usage information.'
