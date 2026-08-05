#!/usr/bin/env bash
# ------------------------------------------------------------------------------
# outbound.sh — engine-neutral outbound lifecycle and inbound assignment
#
# ProxyCTL owns only deliberately simple per-inbound route bindings. Arbitrary
# user-authored routing rules remain configuration source-of-truth and are not
# rewritten unless an engine adapter can prove the rule is ProxyCTL-managed.
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
        if [[ -n "$username" ]]; then
            prompt_hidden_secret password 'Password' || return 1
        fi
    fi

    jq -n --arg protocol "$protocol" --arg tag "$tag" --arg server "$server" \
        --arg port "$port" --arg username "$username" --arg password "$password" --arg bind "$bind_ip" '
        {protocol:$protocol,tag:$tag,server:$server,
         port:(if $port=="" then null else ($port|tonumber) end),
         username:$username,password:$password,bind_ip:$bind}'
}

_outbound_add_from_spec_locked() {
    local engine="$1" spec="$2" tag outbound config candidate
    engine_exists "$engine" || { error "Unknown engine: ${engine}"; return 1; }
    engine_call "$engine" installed >/dev/null 2>&1 || { error "${engine} is not installed."; return 1; }
    outbound_config_require "$engine" || return 1
    jq -e 'type=="object"' <<<"$spec" >/dev/null 2>&1 || { error 'Outbound spec is not valid JSON.'; return 1; }
    tag=$(jq -r '.tag // empty' <<<"$spec")
    outbound_tag_is_available "$engine" "$tag" || { error "Outbound tag is invalid/reserved or already used: ${tag}"; return 1; }
    outbound=$(outbound_call "$engine" build_from_spec "$spec") || return 1
    config=$(outbound_config_file "$engine")
    candidate=$(mktemp) || return 1
    jq --argjson outbound "$outbound" '.outbounds += [$outbound]' "$config" >"$candidate" || { rm -f -- "$candidate"; return 1; }
    if apply_candidate "$engine" "$candidate"; then
        rm -f -- "$candidate"
        info "Outbound created: ${engine}/${tag}"
        return 0
    fi
    rm -f -- "$candidate"
    return 1
}

outbound_add_from_spec() {
    _inbound_with_config_lock _outbound_add_from_spec_locked "$@"
}

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
    if apply_candidate "$engine" "$candidate"; then
        rm -f -- "$candidate"
        info "Inbound ${engine}/${inbound} now uses outbound ${outbound}."
        return 0
    fi
    rm -f -- "$candidate"
    return 1
}

outbound_assign() {
    _inbound_with_config_lock _outbound_assign_locked "$@"
}

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
    local engine="$1" tag="$2" config candidate
    outbound_validate_tag "$tag" || { error "Protected/invalid outbound cannot be deleted: ${tag}"; return 1; }
    outbound_exists "$engine" "$tag" || { error "Outbound not found: ${engine}/${tag}"; return 1; }
    outbound_call "$engine" delete_safe "$tag" || return 1
    config=$(outbound_config_file "$engine")
    candidate=$(mktemp) || return 1
    if ! outbound_call "$engine" delete_candidate "$config" "$tag" >"$candidate"; then rm -f -- "$candidate"; return 1; fi
    if apply_candidate "$engine" "$candidate"; then
        rm -f -- "$candidate"
        info "Outbound deleted: ${engine}/${tag}. Managed inbound bindings reverted to direct."
        return 0
    fi
    rm -f -- "$candidate"
    return 1
}

outbound_delete() {
    _inbound_with_config_lock _outbound_delete_locked "$@"
}
