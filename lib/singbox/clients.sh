#!/usr/bin/env bash
# ------------------------------------------------------------------------------
# singbox/clients.sh — hardened sing-box user lifecycle
# Overrides the basic client helpers from singbox/inbound.sh.
# ------------------------------------------------------------------------------

_singbox_client_exists() {
    local tag="$1" label="$2" found
    while IFS=$'\t' read -r found _; do
        [[ "$found" == "$label" ]] && return 0
    done < <(engine_singbox_inbound_clients "$tag")
    return 1
}

engine_singbox_inbound_client_add() {
    local tag="$1" label="${2:-}" credential="${3:-}" config type user flow='' candidate
    inbound_exists singbox "$tag" || { error "Inbound not found: ${tag}"; return 1; }
    config=$(engine_singbox_config_file)
    type=$(_singbox_type "$config" "$tag")
    [[ -n "$label" ]] || prompt_value label 'User name' "user-$(inbound_random_hex 2)" || return 1
    _singbox_client_exists "$tag" "$label" && { error "User already exists: ${label}"; return 1; }

    case "$type" in
        vless)
            [[ -n "$credential" ]] || credential=$(inbound_generate_uuid)
            if jq -e --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|(.tls.reality.enabled==true and (.transport==null))' "$config" >/dev/null; then
                flow=xtls-rprx-vision
            fi
            user=$(jq -n --arg name "$label" --arg uuid "$credential" --arg flow "$flow" '{name:$name,uuid:$uuid}+(if $flow!="" then {flow:$flow} else {} end)')
            ;;
        anytls|hysteria2|trojan)
            [[ -n "$credential" ]] || credential=$(inbound_random_password)
            user=$(jq -n --arg name "$label" --arg password "$credential" '{name:$name,password:$password}')
            ;;
        socks|http)
            [[ -n "$credential" ]] || credential=$(inbound_random_password)
            user=$(jq -n --arg username "$label" --arg password "$credential" '{username:$username,password:$password}')
            ;;
        *) error "Protocol does not support user management: ${type}"; return 1 ;;
    esac

    candidate=$(mktemp) || return 1
    jq --arg tag "$tag" --argjson user "$user" '(.inbounds[]|select(.tag==$tag)|.users) += [$user]' "$config" >"$candidate" || {
        rm -f -- "$candidate"
        return 1
    }
    apply_candidate singbox "$candidate"
    local rc=$?
    rm -f -- "$candidate"
    return "$rc"
}

engine_singbox_inbound_client_rotate() {
    local tag="$1" label="$2" credential="${3:-}" config type candidate
    inbound_exists singbox "$tag" || { error "Inbound not found: ${tag}"; return 1; }
    _singbox_client_exists "$tag" "$label" || { error "User not found: ${label}"; return 1; }
    config=$(engine_singbox_config_file)
    type=$(_singbox_type "$config" "$tag")
    candidate=$(mktemp) || return 1

    case "$type" in
        vless)
            [[ -n "$credential" ]] || credential=$(inbound_generate_uuid)
            jq --arg tag "$tag" --arg label "$label" --arg v "$credential" '(.inbounds[]|select(.tag==$tag)|.users[]|select(.name==$label)|.uuid)=$v' "$config" >"$candidate"
            ;;
        anytls|hysteria2|trojan)
            [[ -n "$credential" ]] || credential=$(inbound_random_password)
            jq --arg tag "$tag" --arg label "$label" --arg v "$credential" '(.inbounds[]|select(.tag==$tag)|.users[]|select(.name==$label)|.password)=$v' "$config" >"$candidate"
            ;;
        socks|http)
            [[ -n "$credential" ]] || credential=$(inbound_random_password)
            jq --arg tag "$tag" --arg label "$label" --arg v "$credential" '(.inbounds[]|select(.tag==$tag)|.users[]|select(.username==$label)|.password)=$v' "$config" >"$candidate"
            ;;
        *) rm -f -- "$candidate"; return 1 ;;
    esac

    apply_candidate singbox "$candidate"
    local rc=$?
    rm -f -- "$candidate"
    return "$rc"
}

engine_singbox_inbound_client_delete() {
    local tag="$1" label="$2" config type candidate count listen
    inbound_exists singbox "$tag" || { error "Inbound not found: ${tag}"; return 1; }
    _singbox_client_exists "$tag" "$label" || { error "User not found: ${label}"; return 1; }
    config=$(engine_singbox_config_file)
    type=$(_singbox_type "$config" "$tag")

    if [[ "$type" == http ]]; then
        count=$(jq --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.users|length' "$config")
        listen=$(jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.listen // "0.0.0.0"' "$config")
        if ((count == 1)) && [[ "$listen" != 127.0.0.1 && "$listen" != ::1 ]]; then
            error 'Refusing to turn a public HTTP inbound into an unauthenticated proxy.'
            return 1
        fi
    fi

    candidate=$(mktemp) || return 1
    case "$type" in
        vless|anytls|hysteria2|trojan)
            jq --arg tag "$tag" --arg label "$label" '(.inbounds[]|select(.tag==$tag)|.users) |= map(select(.name!=$label))' "$config" >"$candidate"
            ;;
        socks|http)
            jq --arg tag "$tag" --arg label "$label" '(.inbounds[]|select(.tag==$tag)|.users) |= map(select(.username!=$label))' "$config" >"$candidate"
            ;;
        *) rm -f -- "$candidate"; return 1 ;;
    esac

    apply_candidate singbox "$candidate"
    local rc=$?
    rm -f -- "$candidate"
    return "$rc"
}
