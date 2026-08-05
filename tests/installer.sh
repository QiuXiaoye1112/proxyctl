#!/usr/bin/env bash
# ------------------------------------------------------------------------------
# tests/installer.sh — installer transaction / collision regression suite
# ------------------------------------------------------------------------------
set -o errexit
set -o nounset
set -o pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

PASS=0; FAIL=0
pass(){ echo "  PASS: $*"; ((++PASS)); }
fail(){ echo "  FAIL: $*" >&2; ((++FAIL)); }
file_hash(){ if command -v sha1sum >/dev/null 2>&1; then sha1sum "$1"|awk '{print $1}'; elif command -v shasum >/dev/null 2>&1; then shasum "$1"|awk '{print $1}'; else cksum "$1"|awk '{print $1}'; fi; }
eqv(){ [[ "$1" == "$2" ]] && pass "$3" || fail "$3 — expected '$2', got '$1'"; }
present(){ [[ -e "$1" || -L "$1" ]] && pass "$2" || fail "$2 — missing: $1"; }
absent(){ [[ ! -e "$1" && ! -L "$1" ]] && pass "$2" || fail "$2 — exists: $1"; }

if [[ "$(id -u)" -ne 0 ]]; then
    echo 'Installer tests skipped: root is required for the install.sh transaction harness.'
    exit 0
fi

BASE=$(mktemp -d)
trap 'rm -rf "$BASE"' EXIT
ROOT="$BASE/fs"

run_installer(){
    local root="$1" failat="${2:-}" out rc
    set +e
    out=$(PROXYCTL_INSTALL_ROOT="$root" PROXYCTL_TEST_FAIL_AT="$failat" bash "$PROJECT_DIR/install.sh" 2>&1)
    rc=$?
    set -e
    printf '%s\n' "$out"
    return "$rc"
}

seed_old_install(){
    local root="$1"
    mkdir -p "$(dirname "$root/usr/local/sbin/proxyctl")" "$root/usr/local/lib/proxyctl" "$root/usr/local/bin" "$root/var/lib/proxyctl"
    printf '#!/usr/bin/env bash\necho old-binary\n' >"$root/usr/local/sbin/proxyctl"
    chmod +x "$root/usr/local/sbin/proxyctl"
    printf 'old-lib\n' >"$root/usr/local/lib/proxyctl/.old-marker"
    ln -s "/usr/local/sbin/proxyctl" "$root/usr/local/bin/proxyctl"
    printf '{"version":1,"inbounds":{},"certificates":{},"firewall":{}}\n' >"$root/var/lib/proxyctl/meta.json"
}

printf '\nProxyCTL installer transaction tests\n\n'

# First install failure must leave no partial application.
rm -rf "$ROOT"; mkdir -p "$ROOT"
set +e; out=$(run_installer "$ROOT" before-metadata); rc=$?; set -e
((rc != 0)) && pass 'first-install injected failure returns non-zero' || fail 'first-install injected failure returns non-zero'
absent "$ROOT/usr/local/sbin/proxyctl" 'first-install failure removes binary'
absent "$ROOT/usr/local/lib/proxyctl" 'first-install failure removes library'
absent "$ROOT/usr/local/bin/proxyctl" 'first-install failure removes symlink'

# Upgrade failure restores binary/library/meta/symlink byte-for-byte.
rm -rf "$ROOT"; mkdir -p "$ROOT"; seed_old_install "$ROOT"
old_bin=$(file_hash "$ROOT/usr/local/sbin/proxyctl")
old_lib=$(file_hash "$ROOT/usr/local/lib/proxyctl/.old-marker")
old_meta=$(file_hash "$ROOT/var/lib/proxyctl/meta.json")
old_link=$(readlink "$ROOT/usr/local/bin/proxyctl")
set +e; out=$(run_installer "$ROOT" before-metadata); rc=$?; set -e
((rc != 0)) && pass 'upgrade injected failure returns non-zero' || fail 'upgrade injected failure returns non-zero'
eqv "$(file_hash "$ROOT/usr/local/sbin/proxyctl")" "$old_bin" 'upgrade rollback restores binary'
eqv "$(file_hash "$ROOT/usr/local/lib/proxyctl/.old-marker")" "$old_lib" 'upgrade rollback restores library'
eqv "$(file_hash "$ROOT/var/lib/proxyctl/meta.json")" "$old_meta" 'upgrade rollback preserves metadata'
eqv "$(readlink "$ROOT/usr/local/bin/proxyctl")" "$old_link" 'upgrade rollback restores symlink'

# Failure after binary swap still restores old installation.
rm -rf "$ROOT"; mkdir -p "$ROOT"; seed_old_install "$ROOT"
old_bin=$(file_hash "$ROOT/usr/local/sbin/proxyctl")
old_lib=$(file_hash "$ROOT/usr/local/lib/proxyctl/.old-marker")
set +e; out=$(run_installer "$ROOT" after-bin-swap); rc=$?; set -e
((rc != 0)) && pass 'after-bin-swap failure is detected' || fail 'after-bin-swap failure is detected'
eqv "$(file_hash "$ROOT/usr/local/sbin/proxyctl")" "$old_bin" 'after-bin-swap rollback restores binary'
eqv "$(file_hash "$ROOT/usr/local/lib/proxyctl/.old-marker")" "$old_lib" 'after-bin-swap rollback restores library'

# Successful install commits all layout and permissions.
rm -rf "$ROOT"; mkdir -p "$ROOT"
set +e; out=$(run_installer "$ROOT"); rc=$?; set -e
((rc == 0)) && pass 'successful install exits zero' || fail "successful install exits zero: $out"
present "$ROOT/usr/local/sbin/proxyctl" 'successful install writes binary'
present "$ROOT/usr/local/lib/proxyctl" 'successful install writes library'
present "$ROOT/var/lib/proxyctl/meta.json" 'successful install initializes metadata'
eqv "$(readlink "$ROOT/usr/local/bin/proxyctl")" "$ROOT/usr/local/sbin/proxyctl" 'successful install creates intended symlink'
eqv "$(stat -c '%a' "$ROOT/var/lib/proxyctl/meta.json")" 600 'installed metadata is mode 600'
eqv "$(stat -c '%a' "$ROOT/var/lib/proxyctl")" 700 'installed data dir is mode 700'
eqv "$(stat -c '%a' "$ROOT/var/lib/proxyctl/transactions")" 700 'installed transaction dir is mode 700'
eqv "$(stat -c '%a' "$ROOT/etc/proxyctl/certs")" 700 'installed cert dir is mode 700'
eqv "$(stat -c '%a' "$ROOT/var/backups/proxyctl")" 700 'installed backup dir is mode 700'
absent "$ROOT/usr/local/sbin/proxyctl.new" 'successful install cleans binary.new'
absent "$ROOT/usr/local/sbin/proxyctl.old" 'successful install cleans binary.old'
absent "$ROOT/usr/local/lib/proxyctl.new" 'successful install cleans library.new'
absent "$ROOT/usr/local/lib/proxyctl.old" 'successful install cleans library.old'

# Best-effort cleanup failure must not turn a committed install into rollback.
rm -rf "$ROOT"; mkdir -p "$ROOT"; seed_old_install "$ROOT"
seed_hash=$(file_hash "$ROOT/usr/local/sbin/proxyctl")
set +e; out=$(PROXYCTL_INSTALL_ROOT="$ROOT" PROXYCTL_TEST_FAIL_CLEANUP=bin bash "$PROJECT_DIR/install.sh" 2>&1); rc=$?; set -e
((rc == 0)) && pass 'binary cleanup failure does not fail committed install' || fail 'binary cleanup failure does not fail committed install'
[[ "$(file_hash "$ROOT/usr/local/sbin/proxyctl")" != "$seed_hash" ]] && pass 'cleanup failure keeps new binary' || fail 'cleanup failure keeps new binary'

# A foreign regular-file shortcut must never be overwritten.
rm -rf "$ROOT"; mkdir -p "$ROOT/usr/local/bin"
printf 'do-not-touch\n' >"$ROOT/usr/local/bin/proxyctl"
foreign_hash=$(file_hash "$ROOT/usr/local/bin/proxyctl")
set +e; out=$(run_installer "$ROOT"); rc=$?; set -e
((rc != 0)) && pass 'regular-file shortcut collision is rejected' || fail 'regular-file shortcut collision is rejected'
eqv "$(file_hash "$ROOT/usr/local/bin/proxyctl")" "$foreign_hash" 'regular-file shortcut collision remains untouched'
absent "$ROOT/usr/local/sbin/proxyctl" 'collision prevents binary install'

# Directory collision is also foreign and must remain intact.
rm -rf "$ROOT"; mkdir -p "$ROOT/usr/local/bin/proxyctl"
set +e; out=$(run_installer "$ROOT"); rc=$?; set -e
((rc != 0)) && pass 'directory shortcut collision is rejected' || fail 'directory shortcut collision is rejected'
[[ -d "$ROOT/usr/local/bin/proxyctl" ]] && pass 'directory collision remains intact' || fail 'directory collision remains intact'

# Broken symlink is safe to replace.
rm -rf "$ROOT"; mkdir -p "$ROOT/usr/local/bin"
ln -s /nonexistent/old-proxyctl "$ROOT/usr/local/bin/proxyctl"
set +e; out=$(run_installer "$ROOT"); rc=$?; set -e
((rc == 0)) && pass 'broken shortcut symlink can be replaced' || fail "broken shortcut symlink can be replaced: $out"
eqv "$(readlink "$ROOT/usr/local/bin/proxyctl")" "$ROOT/usr/local/sbin/proxyctl" 'broken symlink now targets ProxyCTL binary'

printf '\nInstaller tests: %d passed, %d failed\n' "$PASS" "$FAIL"
((FAIL == 0))
