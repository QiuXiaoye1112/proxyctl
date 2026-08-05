#!/usr/bin/env bash
# ------------------------------------------------------------------------------
# outbound.sh — engine-neutral outbound lifecycle and inbound assignment
#
# Engine config is the source of truth. Metadata records only ProxyCTL ownership
# so hand-written outbounds can be used without becoming deletable by ProxyCTL.
# ------------------------------------------------------------------------------

outbound_validate_tag() {
    local tag="${1:-}"
    inbound_validate_tag "$tag" || return 1
    case "$tag" in direct|blocked|block) return 1 ;; esac
}

outbound_engine_function() { printf 'engine_%s_outbound_%s\n' "$1" "$2"; }

outbound_call() {
    local engine="$1" method="$2" func
    shift 2 || true
    engine_exists "$engine" || { error "Unknown engine: ${engine}"; return 1; }
    func=$(outbound_engine_function "$engine" "$method")
    declare -F "$func" >/dev/null 2>&1 || { error "Outbound operation '${method}' is not implemented for ${engine}."; return 1; }
    "$func" "$@"
}

outbound_config_file() {
    local engine="$1" config
    config=$(engine_call "$engine" config_file) || return 1
    [[ "$config" == /* ]] || { error "Engine returned a non-absolute config path: ${config}"; return 1; }
    printf '%s\n' "$config"
}

outbound_config_require() {
    local engine="$1" config
    command -v jq >/dev/null 2>&1 || { error 'jq is required for outbound management.'; return 1; }
    config=$(outbound_config_file "$engine") || return 1
    [[ -f "$config" && ! -L "$config" ]] || { error "Engine config is missing or unsafe: ${config}"; return 1; }
    jq -e 'type=="object" and (.inbounds|type=="array") and (.outbounds|type=="array")' "$config" >/dev/null 2>&1 || {
        error "Engine config does not contain inbound/outbound arrays: ${config}"
        return 1
    }
}

outbound_exists() {
    local engine="$1" tag="$2" config
    outbound_config_require "$engine" || return 1
    config=$(outbound_config_file "$engine")
    jq -e --arg tag "$tag" '.outbounds[]? | select(.tag==$tag)' "$config" >/dev/null 2>&1
}

outbound_tag_is_available() {
    local engine="$1" tag="$2"
    outbound_validate_tag "$tag" || return 1
    outbound_exists "$engine" "$tag" && return 1
    inbound_exists "$engine" "$tag" && return 1
    return 0
}

outbound_meta_mark_managed() {
    local engine="$1" tag="$2"
    metadata_init >/dev/null || return 1
    _metadata_atomic_jq --arg engine "$engine" --arg tag "$tag" --arg now "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" '
      .outbounds=(.outbounds // {}) |
      .outbounds[$engine]=(.outbounds[$engine] // {}) |
      .outbounds[$engine][$tag]={managed:true,updatedAt:$now}'
}

outbound_meta_is_managed() {
    local engine="$1" tag="$2"
    metadata_init >/dev/null || return 1
    jq -e --arg engine "$engine" --arg tag "$tag" '.outbounds[$engine][$tag].managed==true' "$PROXYCTL_META" >/dev/null 2>&1
}

outbound_meta_delete() {
    local engine="$1" tag="$2"
    _metadata_atomic_jq --arg engine "$engine" --arg tag "$tag" '
      del(.outbounds[$engine][$tag]) |
      if ((.outbounds[$engine] // {})|length)==0 then del(.outbounds[$engine]) else . end |
      if ((.outbounds // {})|length)==0 then del(.outbounds) else . end'
}

outbound_meta_list_managed() {
    local engine="$1"
    metadata_init >/dev/null || return 1
    jq -r --arg engine "$engine" '.outbounds[$engine] // {} | to_entries[] | select(.value.managed==true) | .key' "$PROXYCTL_META" 2>/dev/null
}

outbound_collect_spec() {
    local protocol tag server='' port='' username='' password='' bind_ip=''
    choose protocol 'Select outbound type:' SOCKS5 HTTP 'Local IP' || return 1
    case "$protocol" in
        SOCKS5) tag="socks-out-$(inbound_random_hex 2)" ;;
        HTTP) tag="http-out-$(inbound_random_hex 2)" ;;
        'Local IP') tag="local-$(inbound_random_hex 2)" ;;
    esac
    prompt_value tag 'Outbound tag' "$tag" || return 1
    outbound_validate_tag "$tag" || { error 'Invalid or reserved outbound tag.'; return 1; }

    if [[ "$protocol" == 'Local IP' ]]; then
        prompt_value bind_ip 'Local source IP to bind' || return 1
        network_validate_ip "$bind_ip" || { error 'Local outbound requires a valid IPv4/IPv6 address.'; return 1; }
        protocol=LOCAL
    else
        prompt_value server 'Proxy server address' || return 1
        network_validate_host "$server" || { error 'Proxy server must be a valid IP/domain.'; return 1; }
        prompt_value port 'Proxy server port' || return 1
        port_validate "$port" || { error 'Proxy server port must be 1-65535.'; return 1; }
        prompt_optional username 'Username (empty = no authentication)' || return 1
        if [[ -n "$username" ]]; then prompt_hidden_secret password 'Password' || return 1; fi
    fi

    jq -n --arg protocol "$protocol" --arg tag "$tag" --arg server "$server" \
        --arg port "$port" --arg username "$username" --arg password "$password" --arg bind "$bind_ip" '
        {protocol:$protocol,tag:$tag,server:$server,
         port:(if $port=="" then null else ($port|tonumber) end),
         username:$username,password:$password,bind_ip:$bind}'
}

_outbound_restore_snapshots() {
    local engine="$1" config_snapshot="$2" meta_snapshot="$3"
    local ok=1
    apply_candidate "$engine" "$config_snapshot" || { critical "Failed to restore ${engine} config during outbound rollback."; ok=0; }
    _inbound_restore_metadata_snapshot "$meta_snapshot" || { critical 'Failed to restore metadata during outbound rollback.'; ok=0; }
    (( ok ))
}

_outbound_add_from_spec_locked() {
    local engine="$1" spec="$2" tag outbound config candidate config_snapshot meta_snapshot
    engine_exists "$engine" || { error "Unknown engine: ${engine}"; return 1; }
    engine_call "$engine" installed >/dev/null 2>&1 || { error "${engine} is not installed."; return 1; }
    outbound_config_require "$engine" || return 1
    jq -e 'type=="object"' <<<"$spec" >/dev/null 2>&1 || { error 'Outbound spec is not valid JSON.'; return 1; }
    tag=$(jq -r '.tag // empty' <<<"$spec")
    outbound_tag_is_available "$engine" "$tag" || { error "Outbound tag is invalid/reserved or already used: ${tag}"; return 1; }
    outbound=$(outbound_call "$engine" build_from_spec "$spec") || return 1
    config=$(outbound_config_file "$engine")
    candidate=$(mktemp) || return 1
    config_snapshot=$(mktemp) || { rm -f -- "$candidate"; return 1; }
    meta_snapshot=$(mktemp) || { rm -f -- "$candidate" "$config_snapshot"; return 1; }
    cp -a -- "$config" "$config_snapshot" || { rm -f -- "$candidate" "$config_snapshot" "$meta_snapshot"; return 1; }
    _inbound_snapshot_metadata "$meta_snapshot" || { rm -f -- "$candidate" "$config_snapshot" "$meta_snapshot"; return 1; }
    jq --argjson outbound "$outbound" '.outbounds += [$outbound]' "$config" >"$candidate" || { rm -f -- "$candidate" "$config_snapshot" "$meta_snapshot"; return 1; }
    if ! apply_candidate "$engine" "$candidate"; then rm -f -- "$candidate" "$config_snapshot" "$meta_snapshot"; return 1; fi
    rm -f -- "$candidate"
    if ! outbound_meta_mark_managed "$engine" "$tag"; then
        error "Outbound config was applied but ownership metadata failed; rolling back ${engine}/${tag}."
        if _outbound_restore_snapshots "$engine" "$config_snapshot" "$meta_snapshot"; then rm -f -- "$config_snapshot" "$meta_snapshot"; else critical "Outbound add rollback incomplete. Recovery snapshots: ${config_snapshot} ${meta_snapshot}"; fi
        return 1
    fi
    rm -f -- "$config_snapshot" "$meta_snapshot"
    info "Outbound created: ${engine}/${tag}"
}

outbound_add_from_spec() { _inbound_with_config_lock _outbound_add_from_spec_locked "$@"; }

outbound_add_interactive() {
    local engine="$1" spec
    spec=$(outbound_collect_spec) || return 1
    outbound_add_from_spec "$engine" "$spec"
}

outbound_list() {
    local engine="$1"
    outbound_config_require "$engine" || return 1
    outbound_call "$engine" list
}

outbound_show() {
    local engine="$1" tag="$2" config
    outbound_exists "$engine" "$tag" || { error "Outbound not found: ${engine}/${tag}"; return 1; }
    config=$(outbound_config_file "$engine")
    jq --arg tag "$tag" '.outbounds[]|select(.tag==$tag)' "$config"
}

_outbound_assign_locked() {
    local engine="$1" inbound="$2" outbound="$3" config candidate
    inbound_exists "$engine" "$inbound" || { error "Inbound not found: ${engine}/${inbound}"; return 1; }
    if [[ "$outbound" != direct ]]; then
        outbound_exists "$engine" "$outbound" || { error "Outbound not found: ${engine}/${outbound}"; return 1; }
        outbound_call "$engine" assignable "$outbound" || { error "Outbound cannot be assigned by ProxyCTL: ${engine}/${outbound}"; return 1; }
    fi
    config=$(outbound_config_file "$engine")
    candidate=$(mktemp) || return 1
    if ! outbound_call "$engine" assign_candidate "$config" "$inbound" "$outbound" >"$candidate"; then rm -f -- "$candidate"; return 1; fi
    if apply_candidate "$engine" "$candidate"; then rm -f -- "$candidate"; info "Inbound ${engine}/${inbound} now uses outbound ${outbound}."; return 0; fi
    rm -f -- "$candidate"; return 1
}

outbound_assign() { _inbound_with_config_lock _outbound_assign_locked "$@"; }

outbound_select() {
    local engine="$1" __var="$2" tag options=(direct)
    while IFS= read -r tag; do [[ -n "$tag" ]] && options+=("$tag"); done < <(outbound_call "$engine" selectable_tags)
    if ((${#options[@]} == 1)); then printf -v "$__var" '%s' direct; else choose "$__var" 'Select outbound:' "${options[@]}"; fi
}

outbound_assign_interactive() {
    local engine="$1" inbound="$2" outbound
    outbound_select "$engine" outbound || return 1
    outbound_assign "$engine" "$inbound" "$outbound"
}

_outbound_delete_locked() {
    local engine="$1" tag="$2" config candidate config_snapshot meta_snapshot
    outbound_validate_tag "$tag" || { error "Protected/invalid outbound cannot be deleted: ${tag}"; return 1; }
    outbound_exists "$engine" "$tag" || { error "Outbound not found: ${engine}/${tag}"; return 1; }
    outbound_meta_is_managed "$engine" "$tag" || { error "Outbound is not owned by ProxyCTL and will not be deleted automatically: ${engine}/${tag}"; return 1; }
    outbound_call "$engine" delete_safe "$tag" || return 1
    config=$(outbound_config_file "$engine")
    candidate=$(mktemp) || return 1
    config_snapshot=$(mktemp) || { rm -f -- "$candidate"; return 1; }
    meta_snapshot=$(mktemp) || { rm -f -- "$candidate" "$config_snapshot"; return 1; }
    cp -a -- "$config" "$config_snapshot" || { rm -f -- "$candidate" "$config_snapshot" "$meta_snapshot"; return 1; }
    _inbound_snapshot_metadata "$meta_snapshot" || { rm -f -- "$candidate" "$config_snapshot" "$meta_snapshot"; return 1; }
    if ! outbound_call "$engine" delete_candidate "$config" "$tag" >"$candidate"; then rm -f -- "$candidate" "$config_snapshot" "$meta_snapshot"; return 1; fi
    if ! apply_candidate "$engine" "$candidate"; then rm -f -- "$candidate" "$config_snapshot" "$meta_snapshot"; return 1; fi
    rm -f -- "$candidate"
    if ! outbound_meta_delete "$engine" "$tag"; then
        error "Outbound config deletion succeeded but metadata cleanup failed; rolling back ${engine}/${tag}."
        if _outbound_restore_snapshots "$engine" "$config_snapshot" "$meta_snapshot"; then rm -f -- "$config_snapshot" "$meta_snapshot"; else critical "Outbound delete rollback incomplete. Recovery snapshots: ${config_snapshot} ${meta_snapshot}"; fi
        return 1
    fi
    rm -f -- "$config_snapshot" "$meta_snapshot"
    info "Outbound deleted: ${engine}/${tag}. Managed inbound bindings reverted to direct."
}

outbound_delete() { _inbound_with_config_lock _outbound_delete_locked "$@"; }
