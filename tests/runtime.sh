#!/usr/bin/env bash
# ------------------------------------------------------------------------------
# tests/runtime.sh — derived runtime state after portable restore
# ------------------------------------------------------------------------------
set -o errexit
set -o nounset
set -o pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
source "$PROJECT_DIR/lib/ui.sh"
source "$PROJECT_DIR/lib/runtime.sh"

PASS=0; FAIL=0
pass(){ echo "  PASS: $*"; ((++PASS)); }
fail(){ echo "  FAIL: $*" >&2; ((++FAIL)); }

BACKUP_CALLED=0; CERT_SYNC=0; HY2_SYNC=0
backup_restore(){ BACKUP_CALLED=1; return 0; }
system_is_root(){ return 0; }
_cert_setup_runtime_access(){ CERT_SYNC=1; return 0; }
singbox_hy2_hop_count(){ echo 1; }
engine_call(){ [[ "$1" == singbox && "$2" == installed ]]; }
singbox_hy2_hop_sync(){ HY2_SYNC=1; return 0; }

printf '\nRuntime restore tests\n\n'
if proxyctl_backup_restore test-backup; then pass 'post-restore synchronization succeeds'; else fail 'post-restore synchronization succeeds'; fi
[[ $BACKUP_CALLED == 1 ]] && pass 'portable restore runs first' || fail 'portable restore runs first'
[[ $CERT_SYNC == 1 ]] && pass 'certificate runtime access is refreshed' || fail 'certificate runtime access is refreshed'
[[ $HY2_SYNC == 1 ]] && pass 'HY2 redirects are rebuilt from restored state' || fail 'HY2 redirects are rebuilt from restored state'

backup_restore(){ return 1; }
CERT_SYNC=0; HY2_SYNC=0
if proxyctl_backup_restore broken >/dev/null 2>&1; then fail 'failed durable restore stops runtime synchronization'; else pass 'failed durable restore stops runtime synchronization'; fi
[[ $CERT_SYNC == 0 && $HY2_SYNC == 0 ]] && pass 'runtime sync is skipped after failed restore' || fail 'runtime sync is skipped after failed restore'

backup_restore(){ return 0; }
_cert_setup_runtime_access(){ return 1; }
if proxyctl_backup_restore runtime-fail >/dev/null 2>&1; then fail 'runtime synchronization failure is surfaced'; else pass 'runtime synchronization failure is surfaced'; fi

printf '\nRuntime tests: %d passed, %d failed\n' "$PASS" "$FAIL"
((FAIL == 0))
