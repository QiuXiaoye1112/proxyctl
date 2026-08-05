#!/usr/bin/env bash
# ------------------------------------------------------------------------------
# xray/outbound.sh — Xray SOCKS/HTTP/local-IP outbounds and managed bindings
# ------------------------------------------------------------------------------

_xray_outbound_protocol() {
    case "${1^^}" in
        SOCKS|SOCKS5) printf '%s\n' socks ;;
        HTTP) printf '%s\n' http ;;
        LOCAL) printf '%s\n' local ;;
        *) return 1 ;;
    esac
}

engine_xray_outbound_build_from_spec() {
    local spec="$1" protocol tag server port user pass bind settings
    protocol=$(_xray_outbound_protocol "$(jq -r '.protocol // empty' <<<"$spec")") || { error 'Xray outbound protocol must be SOCKS5, HTTP, or LOCAL.'; return 1; }
    tag=$(jq -r '.tag // empty' <<<"$spec")
    outbound_validate_tag "$tag" || { error 'Invalid Xray outbound tag.'; return 1; }

    if [[ "$protocol" == local ]]; then
        bind=$(jq -r '.bind_ip // empty' <<<"$spec")
        network_validate_ip "$bind" || { error 'LOCAL outbound requires a valid bind_ip.'; return 1; }
        jq -n --arg tag "$tag" --arg bind "$bind" '{tag:$tag,protocol:"freedom",sendThrough:$bind,settings:{domainStrategy:"UseIP"}}'
        return
    fi

    server=$(jq -r '.server // empty' <<<"$spec"); port=$(jq -r '.port // empty' <<<"$spec")
    user=$(jq -r '.username // empty' <<<"$spec"); pass=$(jq -r '.password // empty' <<<"$spec")
    network_validate_host "$server" || { error 'Invalid proxy server address.'; return 1; }
    port_validate "$port" || { error 'Invalid proxy server port.'; return 1; }
    [[ -z "$user" && -z "$pass" || -n "$user" && -n "$pass" ]] || { error 'Proxy authentication requires both username and password.'; return 1; }
    settings=$(jq -n --arg address "$server" --argjson port "$port" --arg user "$user" --arg pass "$pass" '
      {address:$address,port:$port} | if $user!="" then .+{user:$user,pass:$pass,level:0} else . end') || return 1
    jq -n --arg tag "$tag" --arg protocol "$protocol" --argjson settings "$settings" '{tag:$tag,protocol:$protocol,settings:$settings}'
}

engine_xray_outbound_assignable() {
    local tag="$1" config protocol
    config=$(engine_xray_config_file)
    protocol=$(jq -r --arg tag "$tag" '.outbounds[]?|select(.tag==$tag)|.protocol // empty' "$config")
    case "$protocol" in socks|http|freedom) return 0 ;; *) return 1 ;; esac
}

engine_xray_outbound_selectable_tags() {
    local config
    config=$(engine_xray_config_file)
    jq -r '.outbounds[]?|select(.tag!="direct" and .tag!="blocked" and (.protocol=="socks" or .protocol=="http" or .protocol=="freedom"))|.tag' "$config"
}

engine_xray_outbound_assign_candidate() {
    local config="$1" inbound="$2" outbound="$3" rule_tag="proxyctl-outbound:${inbound}"
    jq --arg inbound "$inbound" --arg outbound "$outbound" --arg ruleTag "$rule_tag" '
      .routing=(.routing // {domainStrategy:"IPIfNonMatch",rules:[]}) |
      (.routing.rules // [] | map(select((.ruleTag // "")!=$ruleTag))) as $rules |
      if $outbound=="direct" then .routing.rules=$rules
      else
        .routing.rules=(
          [$rules[] | select((.outboundTag // "")=="blocked")] +
          [{type:"field",inboundTag:[$inbound],outboundTag:$outbound,ruleTag:$ruleTag}] +
          [$rules[] | select((.outboundTag // "")!="blocked")]
        )
      end' "$config"
}

engine_xray_outbound_delete_safe() {
    local tag="$1" config manual
    config=$(engine_xray_config_file)
    manual=$(jq --arg tag "$tag" '[.routing.rules[]? | select(.outboundTag==$tag) | select(((.ruleTag // "")|startswith("proxyctl-outbound:"))|not)] | length' "$config") || return 1
    if (( manual > 0 )); then
        error "Outbound ${tag} is referenced by custom Xray routing rules; refusing automatic deletion."
        return 1
    fi
}

engine_xray_outbound_delete_candidate() {
    local config="$1" tag="$2"
    jq --arg tag "$tag" '
      .outbounds |= map(select(.tag!=$tag)) |
      .routing.rules=((.routing.rules // []) | map(select(.outboundTag!=$tag)))' "$config"
}

engine_xray_outbound_list() {
    local config
    config=$(engine_xray_config_file)
    printf '%-24s %-24s\n' 'INBOUND' 'OUTBOUND'
    jq -r '
      (.routing.rules // []) as $rules |
      .inbounds[]? | .tag as $tag |
      [$tag, ([$rules[]? | select((.ruleTag // "")==("proxyctl-outbound:"+$tag)) | .outboundTag][0] // "direct")] | @tsv' "$config" |
      while IFS=$'\t' read -r inbound outbound; do printf '%-24s %-24s\n' "$inbound" "$outbound"; done
    printf '\n%-24s %-9s %-28s %s\n' 'TAG' 'TYPE' 'SERVER/BIND' 'AUTH'
    jq -r '.outbounds[]? |
      select(.tag!="direct" and .tag!="blocked" and (.protocol=="socks" or .protocol=="http" or .protocol=="freedom")) |
      if .protocol=="freedom" then [.tag,"local",(.sendThrough // "default"),"-"]
      else [.tag,.protocol,"\(.settings.address):\(.settings.port)",(if (.settings.user // "")=="" then "none" else .settings.user end)] end | @tsv' "$config" |
      while IFS=$'\t' read -r tag type address auth; do printf '%-24s %-9s %-28s %s\n' "$tag" "$type" "$address" "$auth"; done
}

_xray_outbound_sync_inbound_reference() {
    local action="$1" tag="$2" old="${3:-}" config candidate changed=0
    config=$(engine_xray_config_file)
    [[ -f "$config" && ! -L "$config" ]] || return 0
    candidate=$(mktemp) || return 1
    case "$action" in
        rename)
            if jq -e --arg old "$old" '.routing.rules[]?|select((.ruleTag // "")==("proxyctl-outbound:"+$old))' "$config" >/dev/null 2>&1; then
                jq --arg old "$old" --arg new "$tag" '
                  .routing.rules=((.routing.rules // []) | map(
                    if (.ruleTag // "")==("proxyctl-outbound:"+$old) then
                      .ruleTag=("proxyctl-outbound:"+$new) |
                      if (.inboundTag|type)=="array" then .inboundTag|=map(if .==$old then $new else . end)
                      elif .inboundTag==$old then .inboundTag=$new else . end
                    else . end))' "$config" >"$candidate" || { rm -f -- "$candidate"; return 1; }
                changed=1
            fi
            ;;
        delete)
            if jq -e --arg tag "$tag" '.routing.rules[]?|select((.ruleTag // "")==("proxyctl-outbound:"+$tag))' "$config" >/dev/null 2>&1; then
                jq --arg tag "$tag" '.routing.rules=((.routing.rules // []) | map(select((.ruleTag // "")!=("proxyctl-outbound:"+$tag))))' "$config" >"$candidate" || { rm -f -- "$candidate"; return 1; }
                changed=1
            fi
            ;;
    esac
    if (( changed )); then
        if ! apply_candidate xray "$candidate"; then rm -f -- "$candidate"; return 1; fi
    fi
    rm -f -- "$candidate"
}

engine_xray_inbound_post_change() {
    local action="$1" tag="${2:-}" old="${3:-}"
    case "$action" in
        rename|delete) _xray_outbound_sync_inbound_reference "$action" "$tag" "$old" ;;
        *) return 0 ;;
    esac
}
