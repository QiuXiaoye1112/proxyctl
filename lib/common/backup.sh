#!/usr/bin/env bash
# ------------------------------------------------------------------------------
# backup.sh — Portable ProxyCTL backup / restore
#
# Portable archives keep node identity: metadata, both engine configs, managed
# certificate pairs, and optional Cloudflare credentials. Rebuildable Certbot
# venv/work/log/lineage state is deliberately excluded.
# ------------------------------------------------------------------------------

backup_root() { printf '%s\n' "${PROXYCTL_BACKUP:-/var/backups/proxyctl}"; }

_backup_require_root() {
    system_is_root && return 0
    error 'Backup and restore require root.'
    return 1
}

_backup_require_tools() {
    local c
    for c in tar jq mktemp; do
        command -v "$c" >/dev/null 2>&1 || { error "Backup requires ${c}."; return 1; }
    done
}

_backup_prepare_root() {
    local root
    root=$(backup_root)
    [[ ! -L "$root" ]] || { error "Refusing symlink backup root: ${root}"; return 1; }
    [[ ! -e "$root" || -d "$root" ]] || { error "Backup root is not a directory: ${root}"; return 1; }
    mkdir -p -- "$root" || return 1
    chmod 700 "$root" || return 1
}

_backup_validate_label() {
    local v="${1:-}"
    [[ -z "$v" ]] && return 0
    [[ ${#v} -le 64 && "$v" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ && "$v" != *'..'* ]]
}

_backup_validate_id() {
    local v="${1:-}"
    [[ -n "$v" && "$v" != */* && "$v" != *'..'* ]] || return 1
    [[ "$v" =~ ^proxyctl-[0-9]{8}-[0-9]{6}-[0-9]+(-[A-Za-z0-9][A-Za-z0-9._-]*)?\.tar\.gz$ ]]
}

_backup_safe_file() {
    local path="$1" what="$2"
    [[ -f "$path" && ! -L "$path" ]] || { error "Unsafe or missing ${what}: ${path}"; return 1; }
}

_backup_copy_state() {
    local dst="$1" engine cfg id cert key cf count=0
    mkdir -p -- "$dst/metadata" "$dst/engines" "$dst/certs" "$dst/secrets" || return 1
    metadata_init >/dev/null || return 1
    metadata_validate || return 1
    _backup_safe_file "$PROXYCTL_META" metadata || return 1
    install -m 600 "$PROXYCTL_META" "$dst/metadata/meta.json" || return 1

    for engine in xray singbox; do
        cfg=$(engine_call "$engine" config_file 2>/dev/null || true)
        [[ -n "$cfg" && ( -e "$cfg" || -L "$cfg" ) ]] || continue
        _backup_safe_file "$cfg" "${engine} config" || return 1
        mkdir -p -- "$dst/engines/$engine"
        install -m 600 "$cfg" "$dst/engines/$engine/config.json" || return 1
    done

    while IFS= read -r id; do
        [[ -n "$id" ]] || continue
        cert_validate_identifier "$id" || return 1
        cert=$(cert_fullchain "$id") || return 1
        key=$(cert_privkey "$id") || return 1
        _backup_safe_file "$cert" certificate || return 1
        _backup_safe_file "$key" 'private key' || return 1
        cert_validate_pair_files "$cert" "$key" || { error "Invalid managed certificate: ${id}"; return 1; }
        mkdir -p -- "$dst/certs/$id"
        install -m 640 "$cert" "$dst/certs/$id/fullchain.pem" || return 1
        install -m 600 "$key" "$dst/certs/$id/privkey.pem" || return 1
        (( count += 1 ))
    done < <(metadata_cert_list)

    cf=$(cert_cloudflare_file 2>/dev/null || true)
    if [[ -n "$cf" && ( -e "$cf" || -L "$cf" ) ]]; then
        _backup_safe_file "$cf" 'Cloudflare credentials' || return 1
        install -m 600 "$cf" "$dst/secrets/cloudflare.ini" || return 1
    fi

    jq -n \
      --arg createdAt "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
      --arg version "${PROXYCTL_VERSION:-unknown}" \
      --argjson xray "$([[ -f "$dst/engines/xray/config.json" ]] && echo true || echo false)" \
      --argjson singbox "$([[ -f "$dst/engines/singbox/config.json" ]] && echo true || echo false)" \
      --argjson certificates "$(( count > 0 ? 1 : 0 ))" \
      --argjson cloudflare "$([[ -f "$dst/secrets/cloudflare.ini" ]] && echo true || echo false)" \
      '{formatVersion:1,type:"proxyctl-portable",createdAt:$createdAt,proxyctlVersion:$version,components:{xray:$xray,singbox:$singbox,certificates:($certificates==1),cloudflare:$cloudflare}}' \
      >"$dst/manifest.json" || return 1
    chmod 600 "$dst/manifest.json"
}

_backup_create_locked() {
    local label="${1:-}" root stage stamp id tmp attempt
    _backup_require_root || return 1
    _backup_require_tools || return 1
    _backup_validate_label "$label" || { error "Invalid backup label: ${label}"; return 1; }
    _backup_prepare_root || return 1
    root=$(backup_root)
    stage=$(mktemp -d "$root/.stage.XXXXXX") || return 1
    chmod 700 "$stage"
    _backup_copy_state "$stage" || { rm -rf -- "$stage"; return 1; }
    stamp=$(date -u '+%Y%m%d-%H%M%S')
    for (( attempt = 0; attempt < 100; attempt++ )); do
        id="proxyctl-${stamp}-${RANDOM}${label:+-${label}}.tar.gz"
        [[ ! -e "$root/$id" && ! -L "$root/$id" ]] && break
    done
    if (( attempt >= 100 )); then
        rm -rf -- "$stage"
        error 'Unable to allocate a unique backup id.'
        return 1
    fi
    tmp="$root/.${id}.tmp"
    tar -C "$stage" -czf "$tmp" manifest.json metadata engines certs secrets || { rm -rf -- "$stage"; rm -f -- "$tmp"; return 1; }
    chmod 600 "$tmp" || { rm -rf -- "$stage"; rm -f -- "$tmp"; return 1; }
    mv -f -- "$tmp" "$root/$id" || { rm -rf -- "$stage"; return 1; }
    rm -rf -- "$stage"
    printf '%s\n' "$id"
}

_backup_create_cert_locked() { with_lock cert _backup_create_locked "${1:-}"; }
backup_create() { with_lock config _backup_create_cert_locked "${1:-}"; }

backup_list() {
    local root f id size stamp found=0
    _backup_prepare_root || return 1
    root=$(backup_root)
    while IFS= read -r f; do
        [[ -n "$f" ]] || continue
        id=${f##*/}; _backup_validate_id "$id" || continue
        [[ -f "$f" && ! -L "$f" ]] || continue
        found=1
        size=$(du -h "$f" 2>/dev/null | awk '{print $1}')
        stamp=$(date -r "$f" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || printf '?')
        printf '%s\t%s\t%s\n' "$id" "${size:-?}" "$stamp"
    done < <(find "$root" -maxdepth 1 -type f -name 'proxyctl-*.tar.gz' -print 2>/dev/null | sort -r)
    (( found )) || info 'No backups found.'
}

_backup_member_ok() {
    local name="${1#./}" rest id tail
    [[ -n "$name" && "$name" != /* && "$name" != *' '* && "$name" != *'\\'* ]] || return 1
    [[ "$name" != '..' && "$name" != ../* && "$name" != */../* && "$name" != */.. ]] || return 1
    case "$name" in
      manifest.json|metadata/|metadata/meta.json|engines/|engines/xray/|engines/xray/config.json|engines/singbox/|engines/singbox/config.json|certs/|secrets/|secrets/cloudflare.ini) return 0 ;;
      certs/*)
        rest=${name#certs/}; id=${rest%%/*}; [[ "$rest" != "$id" ]] || return 1
        tail=${rest#*/}; cert_validate_identifier "$id" || return 1
        [[ -z "$tail" || "$tail" == fullchain.pem || "$tail" == privkey.pem ]] ;;
      *) return 1 ;;
    esac
}

_backup_archive_ok() {
    local a="$1" member line type
    _backup_safe_file "$a" 'backup archive' || return 1
    tar -tzf "$a" >/dev/null 2>&1 || { error 'Invalid backup archive.'; return 1; }
    while IFS= read -r member; do _backup_member_ok "$member" || { error "Unsafe archive member: ${member}"; return 1; }; done < <(tar -tzf "$a")
    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        type=${line:0:1}
        [[ "$type" == '-' || "$type" == d ]] || { error 'Backup archive contains a link or special file.'; return 1; }
    done < <(tar -tvzf "$a")
}

_backup_stage_ok() {
    local s="$1" meta="$1/metadata/meta.json" id dir cert key engine cfg
    jq -e '.formatVersion==1 and .type=="proxyctl-portable"' "$s/manifest.json" >/dev/null 2>&1 || { error 'Unsupported backup manifest.'; return 1; }
    jq -e --argjson v "${META_SCHEMA_VERSION:-1}" '.version==$v and (.certificates|type=="object")' "$meta" >/dev/null 2>&1 || { error 'Invalid backup metadata.'; return 1; }
    for engine in xray singbox; do
        cfg="$s/engines/$engine/config.json"; [[ -f "$cfg" ]] || continue
        [[ ! -L "$cfg" ]] || return 1
        engine_call "$engine" installed >/dev/null 2>&1 || continue
        engine_call "$engine" validate "$cfg" || { error "Backup ${engine} config failed validation."; return 1; }
    done
    while IFS= read -r id; do
        cert_validate_identifier "$id" || return 1
        cert="$s/certs/$id/fullchain.pem"; key="$s/certs/$id/privkey.pem"
        _backup_safe_file "$cert" 'backup certificate' || return 1
        _backup_safe_file "$key" 'backup private key' || return 1
        cert_validate_pair_files "$cert" "$key" || { error "Invalid backup certificate: ${id}"; return 1; }
    done < <(jq -r '.certificates|keys[]' "$meta")
    while IFS= read -r dir; do
        id=${dir##*/}; jq -e --arg id "$id" '.certificates[$id] != null' "$meta" >/dev/null || { error "Unregistered certificate in backup: ${id}"; return 1; }
    done < <(find "$s/certs" -mindepth 1 -maxdepth 1 -type d -print 2>/dev/null)
}

_backup_atomic_file() {
    local src="$1" dst="$2" mode="${3:-600}" parent tmp
    parent=$(dirname "$dst")
    [[ ! -L "$parent" && ! -L "$dst" ]] || { error "Unsafe restore path: ${dst}"; return 1; }
    mkdir -p -- "$parent" || return 1
    tmp=$(mktemp "$parent/.proxyctl-restore.XXXXXX") || return 1
    install -m "$mode" "$src" "$tmp" || { rm -f -- "$tmp"; return 1; }
    mv -f -- "$tmp" "$dst" || { rm -f -- "$tmp"; return 1; }
}

_backup_apply_stage() {
    local s="$1" engine cfg dest id cert key changed cf
    # Certificates first: active engines restarted by apply_candidate will see them.
    while IFS= read -r id; do
        cert="$s/certs/$id/fullchain.pem"; key="$s/certs/$id/privkey.pem"; changed=0
        _cert_replace_pair "$id" "$cert" "$key" changed || return 1
    done < <(jq -r '.certificates|keys[]' "$s/metadata/meta.json")

    for engine in xray singbox; do
        cfg="$s/engines/$engine/config.json"; [[ -f "$cfg" ]] || continue
        if engine_call "$engine" installed >/dev/null 2>&1; then
            apply_candidate "$engine" "$cfg" || return 1
        else
            dest=$(engine_call "$engine" config_file) || return 1
            [[ "$dest" == /* && ! -L "$dest" && ! -L "$(dirname "$dest")" ]] || return 1
            mkdir -p -- "$(dirname "$dest")" || return 1
            _backup_atomic_file "$cfg" "$dest" 600 || return 1
            warn "${engine} is not installed; restored config without core validation."
        fi
    done

    _backup_atomic_file "$s/metadata/meta.json" "$PROXYCTL_META" 600 || return 1
    cf=$(cert_cloudflare_file 2>/dev/null || true)
    if [[ -n "$cf" ]]; then
        if [[ -f "$s/secrets/cloudflare.ini" ]]; then _backup_atomic_file "$s/secrets/cloudflare.ini" "$cf" 600 || return 1
        else rm -f -- "$cf" || return 1
        fi
    fi
}

_backup_restore_locked() {
    local id="$1" root archive stage rollback
    _backup_require_root || return 1
    _backup_require_tools || return 1
    _backup_prepare_root || return 1
    root=$(backup_root); archive="$root/$id"
    _backup_archive_ok "$archive" || return 1
    stage=$(mktemp -d "$root/.restore.XXXXXX") || return 1
    rollback=$(mktemp -d "$root/.rollback.XXXXXX") || { rm -rf -- "$stage"; return 1; }
    chmod 700 "$stage" "$rollback"
    tar -xzf "$archive" -C "$stage" || { rm -rf -- "$stage" "$rollback"; return 1; }
    _backup_stage_ok "$stage" || { rm -rf -- "$stage" "$rollback"; return 1; }
    _backup_copy_state "$rollback" || { rm -rf -- "$stage" "$rollback"; return 1; }

    if ! _backup_apply_stage "$stage"; then
        error 'Restore failed; rolling back to the pre-restore state.'
        if ! _backup_apply_stage "$rollback"; then
            critical "Restore rollback failed. Recovery snapshot preserved at: ${rollback}"
            critical "Extracted target backup preserved at: ${stage}"
            return 1
        fi
        rm -rf -- "$stage" "$rollback"
        return 1
    fi

    rm -rf -- "$stage" "$rollback"
    info "Backup restored: ${id}"
    if jq -e '.certificates|to_entries[]?|select(.value.source=="letsencrypt" and .value.autoRenew==true)' "$PROXYCTL_META" >/dev/null 2>&1; then
        warn 'Managed certificates are usable, but Certbot lineage is not portable. Reissue ACME certificates before the next renewal.'
    fi
}

_backup_restore_cert_locked() { with_lock cert _backup_restore_locked "$1"; }
backup_restore() {
    local id="${1:-}"
    _backup_validate_id "$id" || { error 'Usage: backup_restore <backup-id>'; return 1; }
    with_lock config _backup_restore_cert_locked "$id"
}
