#!/usr/bin/env bash
# ------------------------------------------------------------------------------
# install.sh — ProxyCTL bootstrap + transactional installer
#
# Supports both:
#   curl -fsSL <install.sh> | sudo bash
#   sudo bash ./install.sh
#
# Remote mode downloads the current repository archive to a temporary directory,
# then re-enters this same installer from the extracted source tree. Local mode
# keeps the existing transactional install/rollback behavior.
# ------------------------------------------------------------------------------
set -o errexit
set -o nounset
set -o pipefail

readonly INSTALL_ROOT="${PROXYCTL_INSTALL_ROOT:-/}"
readonly PROXYCTL_REPO_ARCHIVE="${PROXYCTL_REPO_ARCHIVE:-https://codeload.github.com/QiuXiaoye1112/proxyctl/tar.gz/refs/heads/main}"

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    echo '请使用 root 权限运行安装器。' >&2
    echo '示例：curl -fsSL https://github.com/QiuXiaoye1112/proxyctl/raw/refs/heads/main/install.sh | sudo bash' >&2
    exit 1
fi
if [[ "${BASH_VERSINFO[0]:-0}" -lt 4 ]]; then
    echo "ProxyCTL 安装器需要 Bash 4.0+（当前：${BASH_VERSION:-unknown}）" >&2
    exit 1
fi

_bootstrap_die() {
    echo "[致命] $*" >&2
    exit 1
}

_detect_source_dir() {
    local source_file="${BASH_SOURCE[0]-}" dir=''
    [[ -n "$source_file" && -f "$source_file" ]] || return 1
    dir=$(cd "$(dirname "$source_file")" 2>/dev/null && pwd) || return 1
    [[ -f "$dir/proxyctl.sh" && -d "$dir/lib" ]] || return 1
    printf '%s\n' "$dir"
}

_bootstrap_remote() {
    local tmp archive source_dir rc

    # Test/development escape hatch: re-enter a known local source tree without
    # contacting GitHub. Not part of the public installer interface.
    if [[ -n "${PROXYCTL_BOOTSTRAP_SOURCE_DIR:-}" ]]; then
        source_dir="${PROXYCTL_BOOTSTRAP_SOURCE_DIR}"
        [[ -f "$source_dir/install.sh" && -f "$source_dir/proxyctl.sh" && -d "$source_dir/lib" ]] || \
            _bootstrap_die "测试源目录不完整：${source_dir}"
        PROXYCTL_BOOTSTRAPPED=1 bash "$source_dir/install.sh" "$@"
        exit $?
    fi

    command -v curl >/dev/null 2>&1 || _bootstrap_die '缺少 curl，无法下载安装包。'
    command -v tar >/dev/null 2>&1 || _bootstrap_die '缺少 tar，无法解压安装包。'
    command -v mktemp >/dev/null 2>&1 || _bootstrap_die '缺少 mktemp。'

    tmp=$(mktemp -d "${TMPDIR:-/tmp}/proxyctl-bootstrap.XXXXXX") || _bootstrap_die '无法创建临时目录。'
    archive="$tmp/proxyctl.tar.gz"

    echo '[ProxyCTL] 正在下载最新源码...'
    if ! curl --fail --location --proto '=https' --tlsv1.2 --retry 3 --connect-timeout 15 --max-time 180 \
        "$PROXYCTL_REPO_ARCHIVE" -o "$archive"; then
        rm -rf -- "$tmp"
        _bootstrap_die '下载 ProxyCTL 源码失败。'
    fi

    if ! tar -xzf "$archive" -C "$tmp"; then
        rm -rf -- "$tmp"
        _bootstrap_die '解压 ProxyCTL 源码失败。'
    fi

    source_dir=$(find "$tmp" -mindepth 1 -maxdepth 1 -type d -name 'proxyctl-*' -print -quit 2>/dev/null || true)
    if [[ -z "$source_dir" || ! -f "$source_dir/install.sh" || ! -f "$source_dir/proxyctl.sh" || ! -d "$source_dir/lib" ]]; then
        rm -rf -- "$tmp"
        _bootstrap_die '下载的源码包结构不完整。'
    fi

    echo '[ProxyCTL] 下载完成，开始安装...'
    set +e
    PROXYCTL_BOOTSTRAPPED=1 bash "$source_dir/install.sh" "$@"
    rc=$?
    set -e
    rm -rf -- "$tmp"
    exit "$rc"
}

SCRIPT_DIR=''
SCRIPT_DIR=$(_detect_source_dir 2>/dev/null || true)
if [[ -z "$SCRIPT_DIR" ]]; then
    _bootstrap_remote "$@"
fi
readonly SCRIPT_DIR

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
            echo "  缺少文件：${f}" >&2; missing=$((missing + 1))
        elif [[ ! -s "${dir}/${f}" ]]; then
            echo "  空文件：${f}" >&2; missing=$((missing + 1))
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
    install -m 755 "${SCRIPT_DIR}/proxyctl.sh" "$BIN_NEW" || die_install '暂存 ProxyCTL 主程序失败。'
}

verify_staging() {
    _verify_lib_contents "$LIB_NEW" || die_install '暂存库校验失败：存在缺失或空文件。'
    _verify_lib_syntax "$LIB_NEW" || die_install '暂存库存在 Bash 语法错误。'
    bash -n "$BIN_NEW" || die_install 'ProxyCTL 主程序存在 Bash 语法错误。'
    PROXYCTL_DEV_LIB="$LIB_NEW" bash "$BIN_NEW" version >/dev/null 2>&1 || die_install '暂存程序版本自检失败。'
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
    ln -sfn "$BIN_PATH" "$SYMLINK_PATH" || die_install '创建 proxyctl 快捷命令失败。'
    _SYMLINK_CHANGED=1
}

ensure_directories() {
    mkdir -p "$DATA_PATH"; chmod 700 "$DATA_PATH"
    mkdir -p "$CERTS_PATH"; chmod 700 "$CERTS_PATH"
    mkdir -p "$BACKUP_PATH"; chmod 700 "$BACKUP_PATH"
    mkdir -p "$DATA_PATH/transactions"; chmod 700 "$DATA_PATH/transactions"
}

_install_jq() {
    if command -v apt-get >/dev/null 2>&1; then
        DEBIAN_FRONTEND=noninteractive apt-get update -y && DEBIAN_FRONTEND=noninteractive apt-get install -y jq
    elif command -v apk >/dev/null 2>&1; then
        apk add --no-cache jq
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y jq
    elif command -v yum >/dev/null 2>&1; then
        yum install -y jq
    elif command -v pacman >/dev/null 2>&1; then
        pacman -Sy --noconfirm jq
    elif command -v zypper >/dev/null 2>&1; then
        zypper --non-interactive install jq
    else
        return 1
    fi
}

dependency_check() {
    if ! command -v jq >/dev/null 2>&1; then
        echo '  -> 未检测到 jq，正在自动安装...'
        _install_jq >/dev/null 2>&1 || die_install '自动安装 jq 失败，请先手动安装 jq 后重试。'
    fi
    command -v jq >/dev/null 2>&1 || die_install '未找到 jq。'
}

run_metadata_init() {
    PROXYCTL_DEV_LIB="$LIB_PATH" PROXYCTL_DATA="$DATA_PATH" PROXYCTL_META="$DATA_PATH/meta.json" "$BIN_PATH" internal-init 2>&1 || die_install '初始化管理元数据失败。'
}

final_verify() {
    PROXYCTL_LIB="$LIB_PATH" "$BIN_PATH" version >/dev/null 2>&1 || die_install '安装后的版本检查失败。'
    PROXYCTL_LIB="$LIB_PATH" "$BIN_PATH" help >/dev/null 2>&1 || die_install '安装后的帮助命令检查失败。'
}

warn_install() { echo "[警告] $*" >&2; }
validate_symlink_path() {
    if [[ -e "$SYMLINK_PATH" || -L "$SYMLINK_PATH" ]]; then
        [[ -L "$SYMLINK_PATH" ]] || die_install "拒绝覆盖非符号链接路径：$SYMLINK_PATH"
    fi
}

cleanup_old_artifacts() {
    if [[ "${PROXYCTL_TEST_FAIL_CLEANUP:-}" == bin ]]; then warn_install '已注入旧二进制清理失败（测试）'; elif ! rm -f "$BIN_OLD"; then warn_install "无法删除旧二进制备份：$BIN_OLD"; fi
    if [[ "${PROXYCTL_TEST_FAIL_CLEANUP:-}" == lib ]]; then warn_install '已注入旧库清理失败（测试）'; elif ! rm -rf "$LIB_OLD"; then warn_install "无法删除旧库备份：$LIB_OLD"; fi
}

install_commit() { _INSTALL_COMMITTED=1; cleanup_old_artifacts; }

install_rollback() {
    echo '安装失败，正在回滚...' >&2
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
die_install() { local msg="$1" code="${2:-1}"; echo '' >&2; echo "[致命] ${msg}" >&2; echo '' >&2; exit "$code"; }
_test_failpoint() { [[ "${PROXYCTL_TEST_FAIL_AT:-}" != "$1" ]] || die_install "已触发测试故障点：$1"; }

echo ''
echo '  ProxyCTL 安装器'
echo '  =================='
echo ''
capture_existing_state
validate_symlink_path
trap _cleanup_on_exit EXIT

echo '正在暂存 ProxyCTL 库...'; stage_library; echo "  -> ${LIB_NEW}"
echo '正在暂存 ProxyCTL 主程序...'; stage_binary; echo "  -> ${BIN_NEW}"
echo '正在校验暂存文件...'; verify_staging; echo '  -> 校验通过'
echo '正在更新程序库...'; swap_library; _test_failpoint after-lib-swap; echo "  -> ${LIB_PATH}/"
echo '正在更新主程序...'; swap_binary; _test_failpoint after-bin-swap; echo "  -> ${BIN_PATH}"
echo '正在创建快捷命令...'; create_symlink; _test_failpoint after-symlink; echo "  -> ${SYMLINK_PATH} -> ${BIN_PATH}"
echo ''; echo '正在创建数据目录...'; ensure_directories
echo "  -> ${DATA_PATH}/ (权限 700)"; echo "  -> ${CERTS_PATH}/ (权限 700)"; echo "  -> ${BACKUP_PATH}/ (权限 700)"; echo "  -> ${DATA_PATH}/transactions/ (权限 700)"
echo ''; echo '正在检查依赖...'; dependency_check
echo '正在初始化管理元数据...'; _test_failpoint before-metadata; run_metadata_init; _test_failpoint after-metadata; echo '  -> 初始化成功'
echo ''; echo '正在进行安装后自检...'; _test_failpoint before-final-check; final_verify; echo '  -> version：正常'; echo '  -> help：正常'
install_commit
echo ''; echo 'ProxyCTL 安装成功。'; echo ''; echo '运行 "proxyctl" 打开交互菜单。'; echo '运行 "proxyctl help" 查看命令帮助。'