#!/usr/bin/env bash
# ------------------------------------------------------------------------------
# install.sh — Install proxyctl to system paths
#
# Installs ONLY the proxyctl manager. Does NOT install Xray or sing-box.
# ------------------------------------------------------------------------------
set -o errexit
set -o nounset
set -o pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- paths ------------------------------------------------------------------
readonly BIN_PATH='/usr/local/sbin/proxyctl'
readonly LIB_PATH='/usr/local/lib/proxyctl'
readonly DATA_PATH='/var/lib/proxyctl'
readonly CERTS_PATH='/etc/proxyctl/certs'
readonly BACKUP_PATH='/var/backups/proxyctl'

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

# --- install files ----------------------------------------------------------
echo 'Installing proxyctl...'

# Binary
install -m 755 "${SCRIPT_DIR}/proxyctl.sh" "${BIN_PATH}"
echo "  -> ${BIN_PATH}"

# Library
rm -rf "${LIB_PATH}"
cp -r "${SCRIPT_DIR}/lib" "${LIB_PATH}"
chmod -R 644 "${LIB_PATH}"/*.sh "${LIB_PATH}"/**/*.sh 2>/dev/null || true
echo "  -> ${LIB_PATH}/"

# Data directory
mkdir -p "${DATA_PATH}"
echo "  -> ${DATA_PATH}/"

# Certs directory
mkdir -p "${CERTS_PATH}"
echo "  -> ${CERTS_PATH}/"

# Backup directory
mkdir -p "${BACKUP_PATH}"
echo "  -> ${BACKUP_PATH}/"

# --- post-install -----------------------------------------------------------
echo ''
echo 'ProxyCTL installed successfully.'
echo ''
echo 'Run "proxyctl" to start the interactive menu.'
echo 'Run "proxyctl help" for usage information.'
