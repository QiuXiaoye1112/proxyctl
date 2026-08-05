#!/usr/bin/env bash
# ------------------------------------------------------------------------------
# client_rename.sh — rename users without rotating credentials
# ------------------------------------------------------------------------------

_client_name_validate() {
    local value="${1:-}"
    [[ -n "$value" && ${#value} -le 128 && "$value" != *$'\n'* && "$value" != *$'\r'* && "$value" != *$'\t'* ]]
}

engine_xray_inbound_client_rename() {
    local tag="$1" old="$2" new="$3" config protocol candidate
    _client_name_validate "$new" || { error 'Invalid user name.'; return 1; }
    inbound_exists xray "$tag" || { error "Inbound not found: xray/${tag}"; return 1; }
    _xray_client_exists "$tag" "$old" || { error "User not found: ${old}"; return 1; }
    _xray_client_exists "$tag" "$new" && { error "User already exists: ${new}"; return 1; }
    config=$(engine_xray_config_file)
    protocol=$(_xray_client_protocol "$config" "$tag")
    candidate=$(mktemp) || return 1
    case "$protocol" in
        vless|vmess|trojan)
            jq --arg tag "$tag" --arg old "$old" --arg new "$new" \
                '(.inbounds[]|select(.tag==$tag)|.settings.clients[]|select(.email==$old)|.email)=$new' \
                "$config" >"$candidate"
            ;;
        socks|http)
            jq --arg tag "$tag" --arg old "$old" --arg new "$new" '
                (.inbounds[]|select(.tag==$tag)|.settings) |=
                ((.accounts // .users // []) as $a |
                 ($a|map(if .user==$old then .user=$new else . end)) as $b |
                 .accounts=$b | .users=$b)' "$config" >"$candidate"
            ;;
        *) rm -f -- "$candidate"; return 1 ;;
    esac
    apply_candidate xray "$candidate"
    local rc=$?
    rm -f -- "$candidate"
    return "$rc"
}

engine_singbox_inbound_client_rename() {
    local tag="$1" old="$2" new="$3" config type candidate
    _client_name_validate "$new" || { error 'Invalid user name.'; return 1; }
    inbound_exists singbox "$tag" || { error "Inbound not found: singbox/${tag}"; return 1; }
    _singbox_client_exists "$tag" "$old" || { error "User not found: ${old}"; return 1; }
    _singbox_client_exists "$tag" "$new" && { error "User already exists: ${new}"; return 1; }
    config=$(engine_singbox_config_file)
    type=$(_singbox_type "$config" "$tag")
    candidate=$(mktemp) || return 1
    case "$type" in
        vless|anytls|hysteria2|trojan)
            jq --arg tag "$tag" --arg old "$old" --arg new "$new" \
                '(.inbounds[]|select(.tag==$tag)|.users[]|select(.name==$old)|.name)=$new' \
                "$config" >"$candidate"
            ;;
        socks|http)
            jq --arg tag "$tag" --arg old "$old" --arg new "$new" \
                '(.inbounds[]|select(.tag==$tag)|.users[]|select(.username==$old)|.username)=$new' \
                "$config" >"$candidate"
            ;;
        *) rm -f -- "$candidate"; return 1 ;;
    esac
    apply_candidate singbox "$candidate"
    local rc=$?
    rm -f -- "$candidate"
    return "$rc"
}

_inbound_client_rename_locked() {
    inbound_call "$1" client_rename "${@:2}"
}

inbound_client_rename() {
    _inbound_with_config_lock _inbound_client_rename_locked "$@"
}
