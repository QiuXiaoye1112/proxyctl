#!/usr/bin/env bash
# ------------------------------------------------------------------------------
# inbound.sh — engine-neutral inbound lifecycle
#
# This module owns orchestration only. Engine JSON remains in xray/inbound.sh
# and singbox/inbound.sh.
# ------------------------------------------------------------------------------

inbound_validate_tag() {
    local tag="${1:-}"
    [[ -n "$tag" && ${#tag} -le 128 ]] || return 1
    [[ "$tag" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]]
}

inbound_validate_path() {
    local path="${1:-}"
    [[ "$path" == /* && "$path" != *[[:space:]]* && ${#path} -le 512 ]]
}

inbound_random_hex() {
    local bytes="${1:-4}"
    [[ "$bytes" =~ ^[0-9]+$ ]] && (( bytes >= 1 && bytes <= 64 )) || return 1
    if command -v openssl >/dev/null 2>&1; then
        openssl rand -hex "$bytes"
    else
        od -An -N "$bytes" -tx1 /dev/urandom 2>/dev/null | tr -d ' \n'
    fi
}

inbound_random_password() { inbound_random_hex 16; }

inbound_generate_uuid() {
    if [[ -r /proc/sys/kernel/random/uuid ]]; then
        cat /proc/sys/kernel/random/uuid
    elif command -v uuidgen >/dev/null 2>&1; then
        uuidgen | tr '[:upper:]' '[:lower:]'
    elif command -v openssl >/dev/null 2>&1; then
        local h variant
        h=$(openssl rand -hex 16) || return 1
        printf -v variant '%x' "$(( (0x${h:16:1} & 3) | 8 ))"
        printf '%s-%s-4%s-%s%s-%s\n' "${h:0:8}" "${h:8:4}" "${h:13:3}" "$variant" "${h:17:3}" "${h:20:12}"
    else
        error 'Unable to generate UUID.'
        return 1
    fi
}

inbound_engine_function() { printf 'engine_%s_inbound_%s\n' "$1" "$2"; }

inbound_call() {
    local engine="$1" method="$2" func
    shift 2 || true
    engine_exists "$engine" || { error "Unknown engine: ${engine}"; return 1; }
    func=$(inbound_engine_function "$engine" "$method")
    declare -F "$func" >/dev/null 2>&1 || { error "Inbound operation '${method}' is not implemented for ${engine}."; return 1; }
    "$func" "$@"
}

inbound_post_change() {
    local engine="$1" action="$2" func
    shift 2 || true
    func=$(inbound_engine_function "$engine" post_change)
    declare -F "$func" >/dev/null 2>&1 || return 0
    "$func" "$action" "$@"
}

inbound_config_file() {
    local engine="$1" config
    engine_exists "$engine" || return 1
    config=$(engine_call "$engine" config_file) || return 1
    [[ "$config" == /* ]] || { error "Engine returned a non-absolute config path: ${config}"; return 1; }
    printf '%s\n' "$config"
}

inbound_config_require() {
    local engine="$1" config
    config=$(inbound_config_file "$engine") || return 1
    [[ -f "$config" && ! -L "$config" ]] || { error "Engine config is missing or unsafe: ${config}"; return 1; }
    command -v jq >/dev/null 2>&1 || { error 'jq is required for inbound management.'; return 1; }
    jq -e 'type=="object" and (.inbounds|type=="array")' "$config" >/dev/null 2>&1 || {
        error "Engine config does not contain an inbound array: ${config}"
        return 1
    }
}

inbound_exists() {
    local engine="$1" tag="$2" config
    inbound_validate_tag "$tag" || return 1
    inbound_config_require "$engine" || return 1
    config=$(inbound_config_file "$engine")
    jq -e --arg tag "$tag" '.inbounds[]? | select(.tag==$tag)' "$config" >/dev/null 2>&1
}

inbound_port_in_config() {
    local engine="$1" port="$2" except="${3:-}" config
    port_validate "$port" || return 1
    inbound_config_require "$engine" || return 1
    config=$(inbound_config_file "$engine")
    case "$engine" in
        xray) jq -e --argjson port "$port" --arg except "$except" '.inbounds[]?|select(.port==$port and .tag!=$except)' "$config" >/dev/null ;;
        singbox) jq -e --argjson port "$port" --arg except "$except" '.inbounds[]?|select(.listen_port==$port and .tag!=$except)' "$config" >/dev/null ;;
        *) return 1 ;;
    esac
}

inbound_meta_set() {
    local engine="$1" tag="$2" client_host="${3:-}" reality_public="${4:-}" hop_range="${5:-}"
    inbound_validate_tag "$tag" || return 1
    _metadata_atomic_jq --arg engine "$engine" --arg tag "$tag" --arg host "$client_host" \
        --arg public "$reality_public" --arg hop "$hop_range" --arg now "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" '
        .inbounds[$engine] = (.inbounds[$engine] // {}) |
        .inbounds[$engine][$tag] = {clientHost:$host,realityPublicKey:$public,hy2HopRange:$hop,updatedAt:$now}'
}

inbound_meta_get() {
    local engine="$1" tag="$2" field="$3"
    case "$field" in clientHost|realityPublicKey|hy2HopRange|updatedAt) ;; *) return 1 ;; esac
    metadata_init >/dev/null || return 1
    jq -r --arg engine "$engine" --arg tag "$tag" --arg field "$field" '.inbounds[$engine][$tag][$field] // empty' "$PROXYCTL_META"
}

inbound_meta_delete() {
    local engine="$1" tag="$2"
    _metadata_atomic_jq --arg engine "$engine" --arg tag "$tag" 'del(.inbounds[$engine][$tag]) | if ((.inbounds[$engine] // {})|length)==0 then del(.inbounds[$engine]) else . end'
}

inbound_meta_rename() {
    local engine="$1" old="$2" new="$3"
    _metadata_atomic_jq --arg engine "$engine" --arg old "$old" --arg new "$new" 'if .inbounds[$engine][$old] != null then .inbounds[$engine][$new]=.inbounds[$engine][$old] | del(.inbounds[$engine][$old]) else . end'
}

inbound_add_from_spec() {
    local engine="$1" spec="$2" config candidate inbound tag port host public hop rollback
    engine_exists "$engine" || { error "Unknown engine: ${engine}"; return 1; }
    engine_call "$engine" installed >/dev/null 2>&1 || { error "${engine} is not installed."; return 1; }
    inbound_config_require "$engine" || return 1
    jq -e 'type=="object"' <<<"$spec" >/dev/null 2>&1 || { error 'Inbound spec is not valid JSON.'; return 1; }
    tag=$(jq -r '.tag // empty' <<<"$spec")
    inbound_validate_tag "$tag" || { error "Invalid inbound tag: ${tag}"; return 1; }
    inbound_exists "$engine" "$tag" && { error "Inbound tag already exists on ${engine}: ${tag}"; return 1; }
    port=$(jq -r '.port // .listen_port // empty' <<<"$spec")
    port_validate "$port" || { error "Invalid inbound port: ${port}"; return 1; }
    inbound_port_in_config "$engine" "$port" && { error "Port ${port} is already used by another ${engine} inbound."; return 1; }

    inbound=$(inbound_call "$engine" build_from_spec "$spec") || return 1
    config=$(inbound_config_file "$engine")
    candidate=$(mktemp) || return 1
    jq --argjson inbound "$inbound" '.inbounds += [$inbound]' "$config" >"$candidate" || { rm -f -- "$candidate"; return 1; }
    if ! apply_candidate "$engine" "$candidate"; then rm -f -- "$candidate"; return 1; fi
    rm -f -- "$candidate"

    host=$(jq -r '.client_host // empty' <<<"$spec")
    public=$(jq -r '.reality.public_key // empty' <<<"$spec")
    hop=$(jq -r '.hysteria2.hop_range // empty' <<<"$spec")
    if ! inbound_meta_set "$engine" "$tag" "$host" "$public" "$hop"; then
        warn "Inbound ${tag} was created but metadata could not be updated."
    fi
    if ! inbound_post_change "$engine" add "$tag"; then
        error "Post-create setup failed for ${engine}/${tag}; rolling back the new inbound."
        config=$(inbound_config_file "$engine")
        rollback=$(mktemp) || { critical "Unable to create rollback candidate for ${engine}/${tag}."; return 1; }
        jq --arg tag "$tag" '.inbounds |= map(select(.tag!=$tag))' "$config" >"$rollback" || { rm -f -- "$rollback"; return 1; }
        if ! apply_candidate "$engine" "$rollback"; then
            rm -f -- "$rollback"
            critical "Failed to roll back inbound ${engine}/${tag} after post-create failure."
            return 1
        fi
        rm -f -- "$rollback"
        inbound_meta_delete "$engine" "$tag" >/dev/null 2>&1 || true
        inbound_post_change "$engine" rollback-add "$tag" >/dev/null 2>&1 || true
        return 1
    fi
    info "Inbound created: ${engine}/${tag}"
}

inbound_add_interactive() {
    local engine="$1" spec
    engine_call "$engine" installed >/dev/null 2>&1 || { error "${engine} is not installed."; return 1; }
    spec=$(inbound_call "$engine" collect_spec) || return 1
    inbound_add_from_spec "$engine" "$spec"
}

inbound_list() { local engine="$1"; inbound_config_require "$engine" || return 1; inbound_call "$engine" list; }

inbound_show() {
    local engine="$1" tag="$2" config
    inbound_exists "$engine" "$tag" || { error "Inbound not found: ${engine}/${tag}"; return 1; }
    config=$(inbound_config_file "$engine")
    jq --arg tag "$tag" '.inbounds[]|select(.tag==$tag)' "$config"
}

inbound_rename() {
    local engine="$1" old="$2" new="$3" config candidate
    inbound_validate_tag "$new" || { error "Invalid inbound tag: ${new}"; return 1; }
    inbound_exists "$engine" "$old" || { error "Inbound not found: ${engine}/${old}"; return 1; }
    inbound_exists "$engine" "$new" && { error "Inbound already exists: ${engine}/${new}"; return 1; }
    config=$(inbound_config_file "$engine")
    candidate=$(mktemp) || return 1
    jq --arg old "$old" --arg new "$new" '(.inbounds[]|select(.tag==$old)|.tag)=$new' "$config" >"$candidate" || { rm -f -- "$candidate"; return 1; }
    if apply_candidate "$engine" "$candidate"; then
        inbound_meta_rename "$engine" "$old" "$new" || warn 'Config renamed but metadata rename failed.'
        rm -f -- "$candidate"
        if ! inbound_post_change "$engine" rename "$new" "$old"; then critical "Inbound renamed, but dependent runtime state could not be synchronized."; return 1; fi
        info "Inbound renamed: ${old} -> ${new}"
        return 0
    fi
    rm -f -- "$candidate"
    return 1
}

inbound_delete() {
    local engine="$1" tag="$2" config candidate
    inbound_exists "$engine" "$tag" || { error "Inbound not found: ${engine}/${tag}"; return 1; }
    config=$(inbound_config_file "$engine")
    candidate=$(mktemp) || return 1
    jq --arg tag "$tag" '.inbounds |= map(select(.tag!=$tag))' "$config" >"$candidate" || { rm -f -- "$candidate"; return 1; }
    if apply_candidate "$engine" "$candidate"; then
        inbound_meta_delete "$engine" "$tag" || warn 'Config deleted but metadata cleanup failed.'
        rm -f -- "$candidate"
        if ! inbound_post_change "$engine" delete "$tag"; then critical "Inbound deleted, but dependent runtime state could not be synchronized."; return 1; fi
        info "Inbound deleted: ${engine}/${tag}"
        return 0
    fi
    rm -f -- "$candidate"
    return 1
}

inbound_clients() { inbound_call "$1" clients "${@:2}"; }
inbound_client_add() { inbound_call "$1" client_add "${@:2}"; }
inbound_client_rotate() { inbound_call "$1" client_rotate "${@:2}"; }
inbound_client_delete() { inbound_call "$1" client_delete "${@:2}"; }
inbound_share() { inbound_call "$1" share "${@:2}"; }
