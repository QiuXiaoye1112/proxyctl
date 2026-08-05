#!/usr/bin/env bash
# ------------------------------------------------------------------------------
# lock.sh — Advisory file locking to prevent concurrent proxyctl runs
# ------------------------------------------------------------------------------

# --- lock_acquire -----------------------------------------------------------
lock_acquire() {
    mkdir -p "$(dirname "${PROXYCTL_LOCK}")"

    exec 9>"${PROXYCTL_LOCK}"
    if ! flock -n 9; then
        error 'Another proxyctl instance is running.'
        return 1
    fi
    return 0
}

# --- lock_release -----------------------------------------------------------
lock_release() {
    if [[ -n "${PROXYCTL_LOCK:-}" ]]; then
        flock -u 9 2>/dev/null || true
        exec 9>&- 2>/dev/null || true
    fi
}

# --- lock_cleanup -----------------------------------------------------------
lock_cleanup() {
    rm -f "${PROXYCTL_LOCK}"
}
