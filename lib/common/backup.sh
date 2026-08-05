#!/usr/bin/env bash
# ------------------------------------------------------------------------------
# backup.sh — Portable ProxyCTL state backup and restore
#
# Backups preserve node identity, not rebuildable runtime dependencies. Archives
# contain metadata, Xray/sing-box configs, managed certificate pairs, and the
# optional Cloudflare credential file. Certbot's venv/work/log state is omitted.
# ------------------------------------------------------------------------------

backup_root() { printf '%s\n' "${PROXYCTL_BACKUP:-/var/backups/proxyctl}"; }

_backup_require_root() {
    system_is_root && return 0
    error 'Backup and restore require root.'
    return 1
}

_backup_require_tools() {
    local cmd
    for cmd in tar jq mktemp; do
        command -v "$cmd" >/dev/null 2>&1 || {
            error "Backup requires ${cmd}."
            return 1
        }
    done
}

_backup_prepare_root() {
    local root
    root=$(backup_root)
    [[ ! -L "$root" ]] || { error "Refusing symlink backup root: ${root}"; return 1; }
    if [[ -e "$root" && ! -d "$root" ]]; then
        error "Backup root is not a directory: ${root}"
        return 1
    fi
    mkdir -p -- "$root" || return 1
    chmod 700 "$root" || return 1
}

_backup_validate_label() {
    local label="${1:-}"
    [[ -z "$label" ]] && return 0
    [[ ${#label} -le 64 && "$label" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]
}

_backup_validate_id() {
    local id="${1:-}"
    [[ -n "$id" && "$id" != */* && "$id" != *'..'* ]] || return 1
    [[ "$id" =~ ^proxyctl-[0-9]{8}-[0-9]{6}-[0-9]+(-[A-Za-z0-9][A-Za-z0-9._-]*)?\.tar\.gz$ ]]
}

_backup_archive_path() {
    local id="$1" root
    _backup_validate_id "$id" || { error "Invalid backup id: ${id}"; return 1; }
    root=$(backup_root)
    printf '%s/%s\n' "$root" "$id"
}

_backup_safe_regular() {
    local path="$1" label="$2"
    [[ ! -L "$path" ]] || { error "Refusing symlink ${label}: ${path}"; return 1; }
    [[ -f "$path" ]] || { error "Expected regular ${label}: ${path}"; return 1; }
}

_backup_copy_engine_config() {
    local engine="$1" stage="$2" config target
    config=$(engine_call "$engine" config_file 2>/dev/null) || return 0
    [[ -e "$config" || -L "$config" ]] || return 0
    _backup_safe_regular "$config" "${engine} config" || return 1
    target="${stage}/engines/${engine}/config.json"
    mkdir -p -- "$(dirname "$target")" || return 1
    install -m 600 "$config" "$target"
}

_backup_copy_certificates() {
    local stage="$1" id cert key dir
    mkdir -p -- "${stage}/certs" || return 1
    while IFS= read -r id; do
        [[ -n "$id" ]] || continue
        cert_validate_identifier "$id" || { error "Invalid certificate id in metadata: ${id}"; return 1; }
        cert=$(cert_fullchain "$id") || return 1
        key=$(cert_privkey "$id") || return 1
        _backup_safe_regular "$cert" "certificate" || return 1
        _backup_safe_regular "$key" "private key" || return 1
        cert_validate_pair_files "$cert" "$key" || {
            error "Managed certificate pair is invalid: ${id}"
            return 1
        }
        dir="${stage}/certs/${id}"
        mkdir -p -- "$dir" || return 1
        install -m 640 "$cert" "${dir}/fullchain.pem" || return 1
        install -m 600 "$key" "${dir}/privkey.pem" || return 1
    done < <(metadata_cert_list)
}

_backup_collect_state() {
    local stage="$1" meta cf has_xray=false has_singbox=false has_certs=false has_cf=false count=0
    mkdir -p -- "${stage}/metadata" "${stage}/engines" "${stage}/certs" "${stage}/secrets" || return 1

    metadata_init >/dev/null || return 1
    metadata_validate || return 1
    meta="$PROXYCTL_META"
    _backup_safe_regular "$meta" metadata || return 1
    install -m 600 "$meta" "${stage}/metadata/meta.json" || return 1

    _backup_copy_engine_config xray "$stage" || return 1
    _backup_copy_engine_config singbox "$stage" || return 1
    [[ -f "${stage}/engines/xray/config.json" ]] && has_xray=true
    [[ -f "${stage}/engines/singbox/config.json" ]] && has_singbox=true

    _backup_copy_certificates "$stage" || return 1
    count=$(find "${stage}/certs" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')
    (( count > 0 )) && has_certs=true

    cf=$(cert_cloudflare_file 2>/dev/null || true)
    if [[ -n "$cf" && ( -e "$cf" || -L "$cf" ) ]]; then
        _backup_safe_regular "$cf" 'Cloudflare credential file' || return 1
        install -m 600 "$cf" "${stage}/secrets/cloudflare.ini" || return 1
        has_cf=true
    fi

    jq -n \
        --argjson formatVersion 1 \
        --arg createdAt "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
        --arg proxyctlVersion "${PROXYCTL_VERSION:-unknown}" \
        --argjson xray "$has_xray" \
        --argjson singbox "$has_singbox" \
        --argjson certificates "$has_certs" \
        --argjson cloudflare "$has_cf" \
        '{formatVersion:$formatVersion,type:"proxyctl-portable",createdAt:$createdAt,proxyctlVersion:$proxyctlVersion,components:{xray:$xray,singbox:$singbox,certificates:$certificates,cloudflare:$cloudflare}}' \
        >"${stage}/manifest.json" || return 1
    chmod 600 "${stage}/manifest.json"
}

_backup_create_locked() {
    local label="${1:-}" root stage id tmp final stamp
    _backup_require_root || return 1
    _backup_require_tools || return 1
    _backup_validate_label "$label" || { error "Invalid backup label: ${label}"; return 1; }
    _backup_prepare_root || return 1
    root=$(backup_root)
    stage=$(mktemp -d "${root}/.stage.XXXXXX") || return 1
    chmod 700 "$stage"

    if ! _backup_collect_state "$stage"; then
        rm -rf -- "$stage"
        return 1
    fi

    stamp=$(date -u '+%Y%m%d-%H%M%S')
    id="proxyctl-${stamp}-${RANDOM}"
    [[ -z "$label" ]] || id+="-${label}"
    id+='.tar.gz'
    tmp="${root}/.${id}.tmp"
    final="${root}/${id}"

    if ! tar -C "$stage" -czf "$tmp" manifest.json metadata engines certs secrets; then
        rm -rf -- "$stage"
        rm -f -- "$tmp"
        error 'Failed to create backup archive.'
        return 1
    fi
    chmod 600 "$tmp" || { rm -rf -- "$stage"; rm -f -- "$tmp"; return 1; }
    mv -f -- "$tmp" "$final" || { rm -rf -- "$stage"; rm -f -- "$tmp"; return 1; }
    rm -rf -- "$stage"
    printf '%s\n' "$id"
}

_backup_create_with_cert_lock() { with_lock cert _backup_create_locked "${1:-}"; }

backup_create() {
    with_lock config _backup_create_with_cert_lock "${1:-}"
}

backup_list() {
    local root file id size stamp found=0
    _backup_require_tools || return 1
    _backup_prepare_root || return 1
    root=$(backup_root)
    while IFS= read -r file; do
        [[ -n "$file" ]] || continue
        id=${file##*/}
        _backup_validate_id "$id" || continue
        [[ -f "$file" && ! -L "$file" ]] || continue
        found=1
        size=$(du -h "$file" 2>/dev/null | awk '{print $1}')
        stamp=$(date -r "$file" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || printf '?')
        printf '%s\t%s\t%s\n' "$id" "${size:-?}" "$stamp"
    done < <(find "$root" -maxdepth 1 -type f -name 'proxyctl-*.tar.gz' -print 2>/dev/null | sort -r)
    (( found == 1 )) || info 'No backups found.'
}

_backup_validate_member_name() {
    local name="${1#./}" id
    [[ -n "$name" && "$name" != /* && "$name" != *'\\'* && "$name" != *' '* ]] || return 1
    [[ "$name" != '..' && "$name" != ../* && "$name" != */../* && "$name" != */.. ]] || return 1
    case "$name" in
        manifest.json|metadata/|metadata/meta.json|engines/|engines/xray/|engines/xray/config.json|engines/singbox/|engines/singbox/config.json|certs/|secrets/|secrets/cloudflare.ini)
            return 0 ;;
        certs/*/|certs/*/fullchain.pem|certs/*/privkey.pem)
            id=${name#certs/}; id=${id%%/*}
            cert_validate_identifier "$id" ;;
        *) return 1 ;;
    esac
}

_backup_validate_archive() {
    local archive="$1" member detail type
    _backup_safe_regular "$archive" 'backup archive' || return 1
    tar -tzf "$archive" >/dev/null 2>&1 || { error 'Backup archive is not a valid tar.gz file.'; return 1; }

    while IFS= read -r member; do
        _backup_validate_member_name "$member" || {
            error "Unsafe or unknown backup archive member: ${member}"
            return 1
        }
        detail=$(tar -tvzf "$archive" "$member" 2>/dev/null | head -1) || return 1
        type=${detail:0:1}
        [[ "$type" == '-' || "$type" == 'd' ]] || {
            error "Backup archive contains links or special files: ${member}"
            return 1
        }
    done < <(tar -tzf "$archive")
}

_backup_validate_extracted() {
    local stage="$1" manifest meta id cert key engine config
    manifest="${stage}/manifest.json"
    meta="${stage}/metadata/meta.json"
    [[ -f "$manifest" && ! -L "$manifest" ]] || { error 'Backup manifest is missing.'; return 1; }
    jq -e '.formatVersion == 1 and .type == "proxyctl-portable" and (.components|type=="object")' "$manifest" >/dev/null || {
        error 'Unsupported or invalid backup manifest.'
        return 1
    }
    [[ -f "$meta" && ! -L "$meta" ]] || { error 'Backup metadata is missing.'; return 1; }
    jq -e --argjson v "${META_SCHEMA_VERSION:-1}" '.version == $v and (.inbounds|type=="object") and (.certificates|type=="object") and (.firewall|type=="object")' "$meta" >/dev/null || {
        error 'Backup metadata is invalid or incompatible.'
        return 1
    }

    for engine in xray singbox; do
        config="${stage}/engines/${engine}/config.json"
        [[ ! -e "$config" && ! -L "$config" ]] && continue
        _backup_safe_regular "$config" "backup ${engine} config" || return 1
        if engine_call "$engine" installed >/dev/null 2>&1; then
            engine_call "$engine" validate "$config" || {
                error "Backup ${engine} config failed core validation."
                return 1
            }
        fi
    done

    if [[ -d "${stage}/certs" ]]; then
        while IFS= read -r id; do
            [[ -n "$id" ]] || continue
            cert_validate_identifier "$id" || return 1
            cert="${stage}/certs/${id}/fullchain.pem"
            key="${stage}/certs/${id}/privkey.pem"
            _backup_safe_regular "$cert" "backup certificate" || return 1
            _backup_safe_regular "$key" "backup private key" || return 1
            cert_validate_pair_files "$cert" "$key" || {
                error "Backup certificate pair is invalid: ${id}"
                return 1
            }
        done < <(find "${stage}/certs" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null)
    fi

    if [[ -e "${stage}/secrets/cloudflare.ini" || -L "${stage}/secrets/cloudflare.ini" ]]; then
        _backup_safe_regular "${stage}/secrets/cloudflare.ini" 'backup Cloudflare credential file' || return 1
    fi
}

_backup_atomic_file() {
    local source="$1" dest="$2" mode="${3:-600}" parent tmp
    parent=$(dirname "$dest")
    [[ ! -L "$parent" && ! -L "$dest" ]] || { error "Refusing symlink restore path: ${dest}"; return 1; }
    mkdir -p -- "$parent" || return 1
    tmp=$(mktemp "${parent}/.proxyctl-restore.XXXXXX") || return 1
    if ! install -m "$mode" "$source" "$tmp"; then rm -f -- "$tmp"; return 1; fi
    mv -f -- "$tmp" "$dest" || { rm -f -- "$tmp"; return 1; }
}

_backup_restore_uninstalled_config() {
    local engine="$1" source="$2" dest parent
    dest=$(engine_call "$engine" config_file) || return 1
    [[ "$dest" == /* && ! -L "$dest" ]] || { error "Unsafe ${engine} config path: ${dest}"; return 1; }
    parent=$(dirname "$dest")
    [[ ! -L "$parent" ]] || { error "Refusing symlink config parent: ${parent}"; return 1; }
    mkdir -p -- "$parent" || return 1
    chmod 755 "$parent" 2>/dev/null || true
    _backup_atomic_file "$source" "$dest" 600
}

_backup_snapshot_live() {
    local dir="$1" engine config cf
    mkdir -p -- "$dir/engines" "$dir/secrets" || return 1
    if [[ -e "$PROXYCTL_META" || -L "$PROXYCTL_META" ]]; then
        _backup_safe_regular "$PROXYCTL_META" metadata || return 1
        cp -a -- "$PROXYCTL_META" "$dir/meta.json" || return 1
        touch "$dir/had-meta"
    fi
    for engine in xray singbox; do
        config=$(engine_call "$engine" config_file 2>/dev/null || true)
        [[ -n "$config" ]] || continue
        if [[ -e "$config" || -L "$config" ]]; then
            _backup_safe_regular "$config" "${engine} config" || return 1
            mkdir -p -- "$dir/engines/$engine"
            cp -a -- "$config" "$dir/engines/$engine/config.json" || return 1
            touch "$dir/had-${engine}"
        fi
    done
    if [[ -e "$PROXYCTL_CERTS" || -L "$PROXYCTL_CERTS" ]]; then
        [[ ! -L "$PROXYCTL_CERTS" && -d "$PROXYCTL_CERTS" ]] || { error "Unsafe certificate root: ${PROXYCTL_CERTS}"; return 1; }
        cp -a -- "$PROXYCTL_CERTS" "$dir/certs" || return 1
        touch "$dir/had-certs"
    fi
    cf=$(cert_cloudflare_file 2>/dev/null || true)
    if [[ -n "$cf" && ( -e "$cf" || -L "$cf" ) ]]; then
        _backup_safe_regular "$cf" 'Cloudflare credential file' || return 1
        cp -a -- "$cf" "$dir/secrets/cloudflare.ini" || return 1
        touch "$dir/had-cloudflare"
    fi
}

_backup_swap_cert_tree() {
    local source="$1" parent base new old
    parent=$(dirname "$PROXYCTL_CERTS"); base=$(basename "$PROXYCTL_CERTS")
    [[ ! -L "$parent" && ! -L "$PROXYCTL_CERTS" ]] || { error 'Unsafe certificate restore path.'; return 1; }
    mkdir -p -- "$parent" || return 1
    new="${parent}/.${base}.restore.$$.$RANDOM"
    old="${parent}/.${base}.old.$$.$RANDOM"
    mkdir -p -- "$new" || return 1
    cp -a -- "$source"/. "$new"/ || { rm -rf -- "$new"; return 1; }
    if [[ -d "$PROXYCTL_CERTS" ]]; then
        mv -- "$PROXYCTL_CERTS" "$old" || { rm -rf -- "$new"; return 1; }
    else
        old=''
    fi
    if ! mv -- "$new" "$PROXYCTL_CERTS"; then
        [[ -z "$old" ]] || mv -- "$old" "$PROXYCTL_CERTS" || true
        rm -rf -- "$new"
        return 1
    fi
    printf '%s\n' "$old"
}

_backup_restore_snapshot() {
    local snap="$1" engine source dest rc=0 cf
    # Certificates first so restored configs never restart against missing TLS files.
    if [[ -f "$snap/had-certs" ]]; then
        rm -rf -- "$PROXYCTL_CERTS" 2>/dev/null || rc=1
        cp -a -- "$snap/certs" "$PROXYCTL_CERTS" 2>/dev/null || rc=1
    else
        rm -rf -- "$PROXYCTL_CERTS" 2>/dev/null || rc=1
    fi

    for engine in xray singbox; do
        source="$snap/engines/$engine/config.json"
        dest=$(engine_call "$engine" config_file 2>/dev/null || true)
        [[ -n "$dest" ]] || continue
        if [[ -f "$snap/had-${engine}" ]]; then
            if engine_call "$engine" installed >/dev/null 2>&1; then
                apply_candidate "$engine" "$source" >/dev/null 2>&1 || rc=1
            else
                _backup_restore_uninstalled_config "$engine" "$source" >/dev/null 2>&1 || rc=1
            fi
        else
            rm -f -- "$dest" 2>/dev/null || rc=1
        fi
    done

    if [[ -f "$snap/had-meta" ]]; then
        _backup_atomic_file "$snap/meta.json" "$PROXYCTL_META" 600 >/dev/null 2>&1 || rc=1
    else
        rm -f -- "$PROXYCTL_META" 2>/dev/null || rc=1
    fi

    cf=$(cert_cloudflare_file 2>/dev/null || true)
    if [[ -n "$cf" ]]; then
        if [[ -f "$snap/had-cloudflare" ]]; then
            _backup_atomic_file "$snap/secrets/cloudflare.ini" "$cf" 600 >/dev/null 2>&1 || rc=1
        fi
    fi
    return "$rc"
}

_backup_restore_locked() {
    local id="$1" archive root stage rollback cert_old='' engine source cf rc=0
    local restored_xray=0 restored_singbox=0 cert_swapped=0
    _backup_require_root || return 1
    _backup_require_tools || return 1
    _backup_prepare_root || return 1
    archive=$(_backup_archive_path "$id") || return 1
    [[ -f "$archive" && ! -L "$archive" ]] || { error "Backup not found: ${id}"; return 1; }
    _backup_validate_archive "$archive" || return 1

    root=$(backup_root)
    stage=$(mktemp -d "${root}/.restore.XXXXXX") || return 1
    rollback=$(mktemp -d "${root}/.rollback.XXXXXX") || { rm -rf -- "$stage"; return 1; }
    chmod 700 "$stage" "$rollback"

    if ! tar -xzf "$archive" -C "$stage" || ! _backup_validate_extracted "$stage" || ! _backup_snapshot_live "$rollback"; then
        rm -rf -- "$stage" "$rollback"
        return 1
    fi

    if find "$stage/certs" -mindepth 1 -maxdepth 1 -type d -print -quit 2>/dev/null | grep -q .; then
        if cert_old=$(_backup_swap_cert_tree "$stage/certs"); then
            cert_swapped=1
        else
            rc=1
        fi
    fi

    if (( rc == 0 )); then
        for engine in xray singbox; do
            source="$stage/engines/$engine/config.json"
            [[ -f "$source" ]] || continue
            if engine_call "$engine" installed >/dev/null 2>&1; then
                if apply_candidate "$engine" "$source"; then
                    [[ "$engine" == xray ]] && restored_xray=1 || restored_singbox=1
                else rc=1; break; fi
            else
                if _backup_restore_uninstalled_config "$engine" "$source"; then
                    [[ "$engine" == xray ]] && restored_xray=1 || restored_singbox=1
                    warn "${engine} is not installed; config was restored without core validation."
                else rc=1; break; fi
            fi
        done
    fi

    if (( rc == 0 )); then
        _backup_atomic_file "$stage/metadata/meta.json" "$PROXYCTL_META" 600 || rc=1
    fi

    cf=$(cert_cloudflare_file 2>/dev/null || true)
    if (( rc == 0 )) && [[ -f "$stage/secrets/cloudflare.ini" && -n "$cf" ]]; then
        _backup_atomic_file "$stage/secrets/cloudflare.ini" "$cf" 600 || rc=1
    fi

    if (( rc != 0 )); then
        error 'Restore failed; attempting to restore the pre-restore state.'
        if ! _backup_restore_snapshot "$rollback"; then
            critical "Backup restore rollback failed. Recovery state preserved at: ${rollback}"
            critical "Extracted backup is preserved at: ${stage}"
            return 1
        fi
        [[ -z "$cert_old" ]] || rm -rf -- "$cert_old"
        rm -rf -- "$stage" "$rollback"
        return 1
    fi

    [[ -z "$cert_old" ]] || rm -rf -- "$cert_old"
    rm -rf -- "$stage" "$rollback"
    info "Backup restored: ${id}"
    if jq -e '.certificates | to_entries[]? | select(.value.source == "letsencrypt" and .value.autoRenew == true)' "$PROXYCTL_META" >/dev/null 2>&1; then
        warn 'Managed certificate files were restored, but Certbot lineage is intentionally not portable. Reissue ACME certificates before their next renewal.'
    fi
    return 0
}

_backup_restore_with_cert_lock() { with_lock cert _backup_restore_locked "$1"; }

backup_restore() {
    local id="${1:-}"
    _backup_validate_id "$id" || { error 'Usage: backup_restore <backup-id>'; return 1; }
    with_lock config _backup_restore_with_cert_lock "$id"
}
