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
readonly SYMLINK_PATH='/usr/local/bin/proxyctl'
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
errors=0

# Binary
install -m 755 "${SCRIPT_DIR}/proxyctl.sh" "${BIN_PATH}" || ((errors++))
echo "  -> ${BIN_PATH}"

# Symlink for convenience
ln -sfn "${BIN_PATH}" "${SYMLINK_PATH}" || ((errors++))
echo "  -> ${SYMLINK_PATH} -> ${BIN_PATH}"

# Library: copy to temp first, then atomically replace
lib_tmp=$(mktemp -d)
cp -r "${SCRIPT_DIR}/lib" "${lib_tmp}/lib"
find "${lib_tmp}/lib" -name '*.sh' -exec chmod 644 {} \;

if [[ -d "${LIB_PATH}" ]]; then
    rm -rf "${LIB_PATH}"
fi
mv "${lib_tmp}/lib" "${LIB_PATH}"
rm -rf "${lib_tmp}"
echo "  -> ${LIB_PATH}/"

# Data directory
mkdir -p "${DATA_PATH}"
chmod 755 "${DATA_PATH}"
echo "  -> ${DATA_PATH}/"

# Certs directory
mkdir -p "${CERTS_PATH}"
chmod 700 "${CERTS_PATH}"
echo "  -> ${CERTS_PATH}/"

# Backup directory
mkdir -p "${BACKUP_PATH}"
chmod 755 "${BACKUP_PATH}"
echo "  -> ${BACKUP_PATH}/"

# --- metadata initialisation ------------------------------------------------
echo ''
echo 'Initialising metadata...'
PROXYCTL_DEV_LIB="${LIB_PATH}" "${BIN_PATH}" internal-init 2>/dev/null || {
    # Fallback: create metadata manually if internal-init fails
    mkdir -p "${DATA_PATH}"
    if [[ ! -f "${DATA_PATH}/meta.json" ]]; then
        umask 077
        cat > "${DATA_PATH}/meta.json" <<'METAEOF'
{
  "version": 1,
  "inbounds": {},
  "certificates": {},
  "firewall": {}
}
METAEOF
        chmod 600 "${DATA_PATH}/meta.json"
    fi
}

# --- result -----------------------------------------------------------------
if ((errors > 0)); then
    echo ''
    echo "Installation completed with ${errors} errors."
    exit 1
fi

echo ''
echo 'ProxyCTL installed successfully.'
echo ''
echo 'Run "proxyctl" to start the interactive menu.'
echo 'Run "proxyctl help" for usage information.'
