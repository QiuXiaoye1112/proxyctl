#!/usr/bin/env bash
# ------------------------------------------------------------------------------
# singbox/outbound.sh — sing-box SOCKS/HTTP/local-IP outbounds and bindings
# ------------------------------------------------------------------------------

_singbox_outbound_type() {
    case "${1^^}" in
        SOCKS|SOCKS5) printf '%s\n' socks ;;
        HTTP) printf '%s\n' http ;;
        LOCAL) printf '%s\n' local ;;
        *) return 1 ;;
    esac
}

engine_singbox_outbound_build_from_spec() {
    local spec="$1" type tag server port user pass bind field
    type=$(_singbox_outbound_type "$(jq -r '.protocol // empty' <<<"$spec")") || { error 'sing-box outbound protocol must be SOCKS5, HTTP, or LOCAL.'; return 1; }
    tag=$(jq -r '.tag // empty' <<<"$spec")
    outbound_validate_tag "$tag" || { error 'Invalid sing-box outbound tag.'; return 1; }

    if [[ "$type" == local ]]; then
        bind=$(jq -r '.bind_ip // empty' <<<"$spec")
        network_validate_ip "$bind" || { error 'LOCAL outbound requires a valid bind_ip.'; return 1; }
        if [[ "$bind" == *:* ]]; then field=inet6_bind_address; else field=inet4_bind_address; fi
        jq -n --arg tag "$tag" --arg bind "$bind" --arg field "$field" '{type:"direct",tag:$tag}+{($field):$bind}'
        return
    fi

    server=$(jq -r '.server // empty' <<<"$spec"); port=$(jq -r '.port // empty' <<<"$spec")
    user=$(jq -r '.username // empty' <<<"$spec"); pass=$(jq -r '.password // empty' <<<"$spec")
    network_validate_host "$server" || { error 'Invalid proxy server address.'; return 1; }
    port_validate "$port" || { error 'Invalid proxy server port.'; return 1; }
    [[ -z "$user" && -z "$pass" || -n "$user" && -n "$pass" ]] || { error 'Proxy authentication requires both username and password.'; return 1; }
    if [[ "$type" == socks ]]; then
        jq -n --arg tag "$tag" --arg server "$server" --argjson port "$port" --arg user "$user" --arg pass "$pass" '
          {type:"socks",tag:$tag,server:$server,server_port:$port,version:"5"} |
          if $user!="" then .username=$user|.password=$pass else . end'
    else
        jq -n --arg tag "$tag" --arg server "$server" --argjson port "$port" --arg user "$user" --arg pass "$pass" '
          {type:"http",tag:$tag,server:$server,server_port:$port} |
          if $user!="" then .username=$user|.password=$pass else . end'
    fi
}

engine_singbox_outbound_assignable() {
    local tag="$1" config type
    config=$(engine_singbox_config_file)
    type=$(jq -r --arg tag "$tag" '.outbounds[]?|select(.tag==$tag)|.type // empty' "$config")
    case "$type" in socks|http|direct) return 0 ;; *) return 1 ;; esac
}

engine_singbox_outbound_selectable_tags() {
    local config
    config=$(engine_singbox_config_file)
    jq -r '.outbounds[]?|select(.tag!="direct" and (.type=="socks" or .type=="http" or .type=="direct"))|.tag' "$config"
}

engine_singbox_outbound_assign_candidate() {
    local config="$1" inbound="$2" outbound="$3"
    jq --arg inbound "$inbound" --arg outbound "$outbound" '
      .route=(.route // {}) |
      .route.rules=((.route.rules // []) | map(
        select(.action!="route" or (.inbound // [])!=[$inbound] or
          ((keys_unsorted|sort) != (["action","inbound","outbound"]|sort))))) |
      if $outbound=="direct" then .
      else .route.rules=([{inbound:[$inbound],action:"route",outbound:$outbound}] + .route.rules) end' "$config"
}

engine_singbox_outbound_delete_safe() {
    local tag="$1" config manual
    config=$(engine_singbox_config_file)
    manual=$(jq --arg tag "$tag" '[.route.rules[]? | select(.outbound==$tag) |
      select((.action=="route" and ((.inbound // [])|length)==1 and
        ((keys_unsorted|sort)==(["action","inbound","outbound"]|sort))) | not)] | length' "$config") || return 1
    if (( manual > 0 )); then
        error "Outbound ${tag} is referenced by custom sing-box route rules; refusing automatic deletion."
        return 1
    fi
}

engine_singbox_outbound_delete_candidate() {
    local config="$1" tag="$2"
    jq --arg tag "$tag" '
      .outbounds |= map(select(.tag!=$tag)) |
      .route.rules=((.route.rules // []) | map(select(.outbound!=$tag)))' "$config"
}

engine_singbox_outbound_list() {
    local config
    config=$(engine_singbox_config_file)
    printf '%-24s %-24s\n' 'INBOUND' 'OUTBOUND'
    jq -r '
      (.route.rules // []) as $rules |
      .inbounds[]? | .tag as $tag |
      [$tag, ([$rules[]? | select(.action=="route" and (.inbound // [])==[$tag] and
        ((keys_unsorted|sort)==(["action","inbound","outbound"]|sort))) | .outbound][0] // (.route.final // "direct"))] | @tsv' "$config" |
      while IFS=$'\t' read -r inbound outbound; do printf '%-24s %-24s\n' "$inbound" "$outbound"; done
    printf '\n%-24s %-9s %-28s %s\n' 'TAG' 'TYPE' 'SERVER/BIND' 'AUTH'
    jq -r '.outbounds[]? |
      select(.tag!="direct" and (.type=="socks" or .type=="http" or .type=="direct")) |
      if .type=="direct" then [.tag,"local",(.inet4_bind_address // .inet6_bind_address // "default"),"-"]
      else [.tag,.type,"\(.server):\(.server_port)",(if (.username // "")=="" then "none" else .username end)] end | @tsv' "$config" |
      while IFS=$'\t' read -r tag type address auth; do printf '%-24s %-9s %-28s %s\n' "$tag" "$type" "$address" "$auth"; done
}
