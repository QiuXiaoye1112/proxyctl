#!/usr/bin/env bash
# ------------------------------------------------------------------------------
# singbox/inbound.sh — sing-box-specific inbound JSON, users, and share links
# ------------------------------------------------------------------------------

_singbox_uri_encode() { jq -rn --arg v "$1" '$v|@uri'; }
_singbox_uri_host() { [[ "$1" == *:* ]] && printf '[%s]' "$1" || printf '%s' "$1"; }

_singbox_generate_reality() {
    local output private public
    output=$(sing-box generate reality-keypair 2>&1) || { error "$output"; return 1; }
    private=$(awk -F': *' 'tolower($1) ~ /private/ {print $2; exit}' <<<"$output" | tr -d '"')
    public=$(awk -F': *' 'tolower($1) ~ /public/ {print $2; exit}' <<<"$output" | tr -d '"')
    [[ -n "$private" && -n "$public" ]] || { error 'Unable to parse sing-box REALITY keypair.'; return 1; }
    printf '%s\t%s\n' "$private" "$public"
}

_singbox_collect_certificate_spec() {
    local ids=() id selected subject
    while IFS= read -r id; do [[ -n "$id" ]] && ids+=("$id"); done < <(metadata_cert_list)
    ((${#ids[@]})) || { error 'No managed certificate exists. Use proxyctl cert issue/import first.'; return 1; }
    if ((${#ids[@]} == 1)); then selected=${ids[0]}; else choose selected 'Select managed certificate:' "${ids[@]}" || return 1; fi
    cert_exists "$selected" || { error "Managed certificate is incomplete: ${selected}"; return 1; }
    subject=$(metadata_cert_get_field "$selected" subject)
    printf '%s\t%s\n' "$selected" "${subject:-$selected}"
}

_singbox_validate_hop_range() {
    local value="${1:-}" start end
    [[ "$value" =~ ^([0-9]{1,5})-([0-9]{1,5})$ ]] || return 1
    start=${BASH_REMATCH[1]}; end=${BASH_REMATCH[2]}
    port_validate "$start" && port_validate "$end" && ((10#$start < 10#$end))
}

_singbox_pick_hy2_internal_port() {
    local range="$1" start end candidate i
    start=${range%-*}; end=${range#*-}
    for ((i=0;i<128;i++)); do
        candidate=$(port_random 10000 65535 udp) || return $?
        if ! (( candidate >= 10#$start && candidate <= 10#$end )) && ! inbound_port_in_config singbox "$candidate"; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done
    error 'Unable to find an internal Hysteria2 UDP port outside the hop range.'
    return 1
}

engine_singbox_inbound_collect_spec() {
    local protocol tag listen port client_host default_host transport='' security='' path='' name='' username='' password='' uuid=''
    local cert_id='' sni='' target='' target_port='' private='' public='' sid='' pair mode hop_range='' up='' down='' obfs=''
    choose protocol 'Select sing-box protocol:' AnyTLS VLESS Hysteria2 Trojan SOCKS5 HTTP || return 1
    prompt_value tag 'Inbound tag' "${protocol,,}-$(inbound_random_hex 2)" || return 1
    inbound_validate_tag "$tag" || { error 'Invalid inbound tag.'; return 1; }
    prompt_value listen 'Listen address' '0.0.0.0' || return 1
    network_validate_ip "$listen" || { error 'Listen address must be an IPv4/IPv6 address.'; return 1; }

    if [[ "$protocol" == Hysteria2 ]]; then
        choose mode 'Hysteria2 port mode:' single hopping || return 1
        if [[ "$mode" == hopping ]]; then
            prompt_value hop_range 'UDP hop range' '20000-50000' || return 1
            _singbox_validate_hop_range "$hop_range" || { error 'Invalid hop range. Example: 20000-50000'; return 1; }
            port=$(_singbox_pick_hy2_internal_port "$hop_range") || return 1
            info "Hysteria2 internal UDP port: ${port}"
        else
            prompt_value port 'Listen UDP port' '443' || return 1
            port_validate "$port" || return 1
        fi
    else
        prompt_value port 'Listen port' '443' || return 1
        port_validate "$port" || { error 'Port must be 1-65535.'; return 1; }
    fi

    default_host=$(network_public_ipv4 2>/dev/null || network_public_ipv6 2>/dev/null || true)
    prompt_value client_host 'Client/server address' "${default_host:-127.0.0.1}" || return 1
    network_validate_host "$client_host" || { error 'Client address must be an IP or domain.'; return 1; }

    case "$protocol" in
        AnyTLS|VLESS|Trojan) choose security 'TLS security:' reality tls || return 1 ;;
        Hysteria2) security=tls ;;
    esac
    case "$protocol" in
        VLESS|Trojan) choose transport 'Transport:' RAW WebSocket || return 1 ;;
    esac
    if [[ "$transport" == WebSocket ]]; then
        prompt_value path 'WebSocket path' "/$(inbound_random_hex 6)" || return 1
        inbound_validate_path "$path" || { error 'Invalid WebSocket path.'; return 1; }
    fi

    if [[ "$security" == tls ]]; then
        IFS=$'\t' read -r cert_id sni < <(_singbox_collect_certificate_spec) || return 1
        prompt_value sni 'TLS SNI/serverName' "$sni" || return 1
        network_validate_host "$sni" || { error 'Invalid TLS SNI.'; return 1; }
    elif [[ "$security" == reality ]]; then
        prompt_value target 'REALITY handshake domain' 'www.microsoft.com' || return 1
        network_validate_domain "$target" || { error 'REALITY handshake target must be a domain.'; return 1; }
        prompt_value target_port 'REALITY handshake port' '443' || return 1
        port_validate "$target_port" || return 1
        prompt_value sni 'REALITY serverName/SNI' "$target" || return 1
        network_validate_domain "$sni" || return 1
        pair=$(_singbox_generate_reality) || return 1
        IFS=$'\t' read -r private public <<<"$pair"
        sid=$(inbound_random_hex 4)
    fi

    case "$protocol" in
        VLESS)
            prompt_value name 'User name' "user-$(inbound_random_hex 2)" || return 1
            uuid=$(inbound_generate_uuid) || return 1
            ;;
        AnyTLS|Trojan|Hysteria2)
            prompt_value name 'User name' "user-$(inbound_random_hex 2)" || return 1
            password=$(inbound_random_password)
            ;;
        SOCKS5|HTTP)
            prompt_optional username 'Username (empty = no authentication)' || return 1
            [[ -z "$username" ]] || password=$(inbound_random_password)
            [[ -n "$username" || "$listen" == 127.0.0.1 || "$listen" == ::1 ]] || warn 'Unauthenticated public proxy is high risk.'
            ;;
    esac

    if [[ "$protocol" == Hysteria2 ]]; then
        prompt_optional up 'Upload limit Mbps (empty = unlimited)' || return 1
        prompt_optional down 'Download limit Mbps (empty = unlimited)' || return 1
        [[ -z "$up" || "$up" =~ ^[1-9][0-9]*$ ]] || { error 'Upload limit must be a positive integer.'; return 1; }
        [[ -z "$down" || "$down" =~ ^[1-9][0-9]*$ ]] || { error 'Download limit must be a positive integer.'; return 1; }
        choose mode 'QUIC obfuscation:' off salamander || return 1
        [[ "$mode" != salamander ]] || obfs=$(inbound_random_password)
    fi

    jq -n --arg protocol "$protocol" --arg tag "$tag" --arg listen "$listen" --argjson port "$port" --arg host "$client_host" \
      --arg transport "$transport" --arg security "$security" --arg path "$path" --arg cert "$cert_id" --arg sni "$sni" \
      --arg target "$target" --arg targetPort "$target_port" --arg private "$private" --arg public "$public" --arg sid "$sid" \
      --arg name "$name" --arg username "$username" --arg password "$password" --arg uuid "$uuid" \
      --arg hop "$hop_range" --arg up "$up" --arg down "$down" --arg obfs "$obfs" '
      {protocol:$protocol,tag:$tag,listen:$listen,listen_port:$port,client_host:$host,transport:$transport,security:$security,path:$path,
       tls:{cert_id:$cert,server_name:$sni},reality:{target:$target,target_port:$targetPort,server_name:$sni,private_key:$private,public_key:$public,short_id:$sid},
       user:{name:$name,username:$username,password:$password,uuid:$uuid},hysteria2:{hop_range:$hop,up_mbps:$up,down_mbps:$down,obfs_password:$obfs}}'
}

engine_singbox_inbound_build_from_spec() {
    local spec="$1" protocol type tag listen port transport security path cert_id sni target target_port private sid name username password uuid hop up down obfs
    local tls='{}' transport_json='' user flow='' cert key
    protocol=$(jq -r '.protocol // empty' <<<"$spec")
    case "$protocol" in AnyTLS) type=anytls ;; VLESS) type=vless ;; Hysteria2) type=hysteria2 ;; Trojan) type=trojan ;; SOCKS5) type=socks ;; HTTP) type=http ;; *) error "Unsupported sing-box protocol: ${protocol}"; return 1 ;; esac
    tag=$(jq -r '.tag // empty' <<<"$spec"); listen=$(jq -r '.listen // empty' <<<"$spec"); port=$(jq -r '.listen_port // .port // empty' <<<"$spec")
    transport=$(jq -r '.transport // empty' <<<"$spec"); security=$(jq -r '.security // empty' <<<"$spec"); path=$(jq -r '.path // empty' <<<"$spec")
    cert_id=$(jq -r '.tls.cert_id // empty' <<<"$spec"); sni=$(jq -r '.tls.server_name // .reality.server_name // empty' <<<"$spec")
    target=$(jq -r '.reality.target // empty' <<<"$spec"); target_port=$(jq -r '.reality.target_port // empty' <<<"$spec"); private=$(jq -r '.reality.private_key // empty' <<<"$spec"); sid=$(jq -r '.reality.short_id // empty' <<<"$spec")
    name=$(jq -r '.user.name // empty' <<<"$spec"); username=$(jq -r '.user.username // empty' <<<"$spec"); password=$(jq -r '.user.password // empty' <<<"$spec"); uuid=$(jq -r '.user.uuid // empty' <<<"$spec")
    hop=$(jq -r '.hysteria2.hop_range // empty' <<<"$spec"); up=$(jq -r '.hysteria2.up_mbps // empty' <<<"$spec"); down=$(jq -r '.hysteria2.down_mbps // empty' <<<"$spec"); obfs=$(jq -r '.hysteria2.obfs_password // empty' <<<"$spec")
    inbound_validate_tag "$tag" && network_validate_ip "$listen" && port_validate "$port" || { error 'Invalid sing-box inbound common fields.'; return 1; }
    [[ -z "$hop" ]] || _singbox_validate_hop_range "$hop" || { error 'Invalid Hysteria2 hop range.'; return 1; }

    case "$transport" in ''|RAW|raw) transport_json='' ;; WebSocket|websocket|ws) inbound_validate_path "$path" || return 1; transport_json=$(jq -n --arg path "$path" '{type:"ws",path:$path}') ;; *) error "Unsupported sing-box transport: ${transport}"; return 1 ;; esac
    if [[ "$type" != vless && "$type" != trojan && -n "$transport_json" ]]; then error "${protocol} does not use the generic transport field."; return 1; fi

    case "$type" in
        anytls|vless|trojan)
            case "$security" in
                tls)
                    cert_exists "$cert_id" || { error "Managed certificate not found: ${cert_id}"; return 1; }
                    cert=$(cert_fullchain "$cert_id"); key=$(cert_privkey "$cert_id")
                    network_validate_host "$sni" || return 1
                    tls=$(jq -n --arg sni "$sni" --arg cert "$cert" --arg key "$key" '{enabled:true,server_name:$sni,certificate_path:$cert,key_path:$key,min_version:"1.2"}')
                    ;;
                reality)
                    network_validate_domain "$target" && port_validate "$target_port" && network_validate_domain "$sni" || { error 'Invalid REALITY target/SNI.'; return 1; }
                    [[ -n "$private" && "$sid" =~ ^[0-9A-Fa-f]{0,16}$ ]] || { error 'Incomplete REALITY key material.'; return 1; }
                    tls=$(jq -n --arg sni "$sni" --arg server "$target" --argjson port "$target_port" --arg private "$private" --arg sid "$sid" '{enabled:true,server_name:$sni,reality:{enabled:true,handshake:{server:$server,server_port:$port},private_key:$private,short_id:[$sid]}}')
                    ;;
                *) error "${protocol} requires TLS or REALITY."; return 1 ;;
            esac
            ;;
        hysteria2)
            cert_exists "$cert_id" || { error "Managed certificate not found: ${cert_id}"; return 1; }
            cert=$(cert_fullchain "$cert_id"); key=$(cert_privkey "$cert_id")
            network_validate_host "$sni" || return 1
            tls=$(jq -n --arg sni "$sni" --arg cert "$cert" --arg key "$key" '{enabled:true,server_name:$sni,certificate_path:$cert,key_path:$key,min_version:"1.2"}')
            ;;
    esac

    case "$type" in
        anytls)
            [[ -n "$name" && -n "$password" ]] || return 1
            user=$(jq -n --arg name "$name" --arg password "$password" '{name:$name,password:$password}')
            jq -n --arg tag "$tag" --arg listen "$listen" --argjson port "$port" --argjson user "$user" --argjson tls "$tls" '{type:"anytls",tag:$tag,listen:$listen,listen_port:$port,users:[$user],tls:$tls}'
            ;;
        vless)
            [[ -n "$name" && "$uuid" =~ ^[0-9A-Fa-f-]{36}$ ]] || return 1
            [[ "$security" == reality && -z "$transport_json" ]] && flow=xtls-rprx-vision
            user=$(jq -n --arg name "$name" --arg uuid "$uuid" --arg flow "$flow" '{name:$name,uuid:$uuid}+(if $flow!="" then {flow:$flow} else {} end)')
            if [[ -n "$transport_json" ]]; then jq -n --arg tag "$tag" --arg listen "$listen" --argjson port "$port" --argjson user "$user" --argjson tls "$tls" --argjson transport "$transport_json" '{type:"vless",tag:$tag,listen:$listen,listen_port:$port,users:[$user],tls:$tls,transport:$transport}'; else jq -n --arg tag "$tag" --arg listen "$listen" --argjson port "$port" --argjson user "$user" --argjson tls "$tls" '{type:"vless",tag:$tag,listen:$listen,listen_port:$port,users:[$user],tls:$tls}'; fi
            ;;
        hysteria2)
            [[ -n "$name" && -n "$password" ]] || return 1
            jq -n --arg tag "$tag" --arg listen "$listen" --argjson port "$port" --arg name "$name" --arg password "$password" --arg up "$up" --arg down "$down" --arg obfs "$obfs" --argjson tls "$tls" '{type:"hysteria2",tag:$tag,listen:$listen,listen_port:$port,users:[{name:$name,password:$password}],tls:$tls} | if $up!="" then .up_mbps=($up|tonumber) else . end | if $down!="" then .down_mbps=($down|tonumber) else . end | if $obfs!="" then .obfs={type:"salamander",password:$obfs} else . end'
            ;;
        trojan)
            [[ -n "$name" && -n "$password" ]] || return 1
            user=$(jq -n --arg name "$name" --arg password "$password" '{name:$name,password:$password}')
            if [[ -n "$transport_json" ]]; then jq -n --arg tag "$tag" --arg listen "$listen" --argjson port "$port" --argjson user "$user" --argjson tls "$tls" --argjson transport "$transport_json" '{type:"trojan",tag:$tag,listen:$listen,listen_port:$port,users:[$user],tls:$tls,transport:$transport}'; else jq -n --arg tag "$tag" --arg listen "$listen" --argjson port "$port" --argjson user "$user" --argjson tls "$tls" '{type:"trojan",tag:$tag,listen:$listen,listen_port:$port,users:[$user],tls:$tls}'; fi
            ;;
        socks|http)
            if [[ -n "$username" ]]; then [[ -n "$password" ]] || return 1; jq -n --arg type "$type" --arg tag "$tag" --arg listen "$listen" --argjson port "$port" --arg user "$username" --arg pass "$password" '{type:$type,tag:$tag,listen:$listen,listen_port:$port,users:[{username:$user,password:$pass}]}'; else jq -n --arg type "$type" --arg tag "$tag" --arg listen "$listen" --argjson port "$port" '{type:$type,tag:$tag,listen:$listen,listen_port:$port,users:[]}'; fi
            ;;
    esac
}

engine_singbox_inbound_list() {
    local config
    config=$(engine_singbox_config_file)
    jq -r '.inbounds[]? | [.tag,.type,(.listen // "0.0.0.0"),(.listen_port|tostring),(.transport.type // "-"),(if .tls.reality.enabled==true then "reality" elif .tls.enabled==true then "tls" else "none" end),(((.users // [])|length)|tostring)] | @tsv' "$config" | awk -F'\t' 'BEGIN{printf "%-24s %-8s %-18s %-7s %-10s %-9s %s\n","名称","协议","监听地址","端口","传输","安全","用户数"} {printf "%-24s %-8s %-18s %-7s %-10s %-9s %s\n",$1,$2,$3,$4,$5,$6,$7}'
}

_singbox_type() { jq -r --arg tag "$2" '.inbounds[]|select(.tag==$tag)|.type' "$1"; }
engine_singbox_inbound_clients() {
    local tag="$1" config type
    inbound_exists singbox "$tag" || return 1
    config=$(engine_singbox_config_file); type=$(_singbox_type "$config" "$tag")
    case "$type" in vless) jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.users[]?|[.name,.uuid]|@tsv' "$config" ;; anytls|hysteria2|trojan) jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.users[]?|[.name,.password]|@tsv' "$config" ;; socks|http) jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.users[]?|[.username,.password]|@tsv' "$config" ;; *) return 1 ;; esac
}

engine_singbox_inbound_client_add() {
    local tag="$1" label="${2:-}" credential="${3:-}" config type user flow='' candidate
    inbound_exists singbox "$tag" || return 1
    config=$(engine_singbox_config_file); type=$(_singbox_type "$config" "$tag")
    [[ -n "$label" ]] || prompt_value label 'User name' "user-$(inbound_random_hex 2)" || return 1
    case "$type" in
        vless) [[ -n "$credential" ]] || credential=$(inbound_generate_uuid); if jq -e --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|(.tls.reality.enabled==true and (.transport==null))' "$config" >/dev/null; then flow=xtls-rprx-vision; fi; user=$(jq -n --arg name "$label" --arg uuid "$credential" --arg flow "$flow" '{name:$name,uuid:$uuid}+(if $flow!="" then {flow:$flow} else {} end)') ;;
        anytls|hysteria2|trojan) [[ -n "$credential" ]] || credential=$(inbound_random_password); user=$(jq -n --arg name "$label" --arg password "$credential" '{name:$name,password:$password}') ;;
        socks|http) [[ -n "$credential" ]] || credential=$(inbound_random_password); user=$(jq -n --arg username "$label" --arg password "$credential" '{username:$username,password:$password}') ;;
        *) return 1 ;;
    esac
    candidate=$(mktemp) || return 1
    jq --arg tag "$tag" --argjson user "$user" '(.inbounds[]|select(.tag==$tag)|.users) += [$user]' "$config" >"$candidate"
    apply_candidate singbox "$candidate"; local rc=$?; rm -f -- "$candidate"; return "$rc"
}

engine_singbox_inbound_client_rotate() {
    local tag="$1" label="$2" credential="${3:-}" config type candidate
    inbound_exists singbox "$tag" || return 1
    config=$(engine_singbox_config_file); type=$(_singbox_type "$config" "$tag"); candidate=$(mktemp) || return 1
    case "$type" in
        vless) [[ -n "$credential" ]] || credential=$(inbound_generate_uuid); jq --arg tag "$tag" --arg lbl "$label" --arg v "$credential" '(.inbounds[]|select(.tag==$tag)|.users[]|select(.name==$lbl)|.uuid)=$v' "$config" >"$candidate" ;;
        anytls|hysteria2|trojan) [[ -n "$credential" ]] || credential=$(inbound_random_password); jq --arg tag "$tag" --arg lbl "$label" --arg v "$credential" '(.inbounds[]|select(.tag==$tag)|.users[]|select(.name==$lbl)|.password)=$v' "$config" >"$candidate" ;;
        socks|http) [[ -n "$credential" ]] || credential=$(inbound_random_password); jq --arg tag "$tag" --arg lbl "$label" --arg v "$credential" '(.inbounds[]|select(.tag==$tag)|.users[]|select(.username==$lbl)|.password)=$v' "$config" >"$candidate" ;;
        *) rm -f -- "$candidate"; return 1 ;;
    esac
    apply_candidate singbox "$candidate"; local rc=$?; rm -f -- "$candidate"; return "$rc"
}

engine_singbox_inbound_client_delete() {
    local tag="$1" label="$2" config type candidate count listen
    inbound_exists singbox "$tag" || return 1
    config=$(engine_singbox_config_file); type=$(_singbox_type "$config" "$tag")
    if [[ "$type" == http ]]; then count=$(jq --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.users|length' "$config"); listen=$(jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.listen // "0.0.0.0"' "$config"); if ((count==1)) && [[ "$listen" != 127.0.0.1 && "$listen" != ::1 ]]; then error 'Refusing to create an unauthenticated public HTTP proxy.'; return 1; fi; fi
    candidate=$(mktemp) || return 1
    case "$type" in vless|anytls|hysteria2|trojan) jq --arg tag "$tag" --arg lbl "$label" '(.inbounds[]|select(.tag==$tag)|.users) |= map(select(.name!=$lbl))' "$config" >"$candidate" ;; socks|http) jq --arg tag "$tag" --arg lbl "$label" '(.inbounds[]|select(.tag==$tag)|.users) |= map(select(.username!=$lbl))' "$config" >"$candidate" ;; *) rm -f -- "$candidate"; return 1 ;; esac
    apply_candidate singbox "$candidate"; local rc=$?; rm -f -- "$candidate"; return "$rc"
}

engine_singbox_inbound_share() {
    local tag="$1" wanted="${2:-}" config type host uri_host port share_port sni transport path security public sid name credential flow query obfs obfs_password json
    inbound_exists singbox "$tag" || return 1
    config=$(engine_singbox_config_file); type=$(_singbox_type "$config" "$tag")
    host=$(inbound_meta_get singbox "$tag" clientHost); [[ -n "$host" ]] || host=$(jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.listen' "$config")
    uri_host=$(_singbox_uri_host "$host"); port=$(jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.listen_port' "$config"); share_port=$(inbound_meta_get singbox "$tag" hy2HopRange); [[ -n "$share_port" ]] || share_port=$port
    sni=$(jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.tls.server_name // empty' "$config")
    if jq -e --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.tls.reality.enabled==true' "$config" >/dev/null 2>&1; then security=reality; public=$(inbound_meta_get singbox "$tag" realityPublicKey); sid=$(jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.tls.reality.short_id[0]' "$config"); else security=tls; fi
    transport=$(jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.transport.type // empty' "$config"); path=$(jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.transport.path // empty' "$config")
    case "$type" in
        vless|trojan)
            if [[ "$transport" == ws ]]; then query="type=ws&path=$(_singbox_uri_encode "$path")&security=${security}"; else query="type=tcp&security=${security}"; fi
            query+="&sni=$(_singbox_uri_encode "$sni")"
            [[ "$security" != reality ]] || query+="&fp=chrome&pbk=$(_singbox_uri_encode "$public")&sid=$(_singbox_uri_encode "$sid")&spx=%2F"
            while IFS=$'\t' read -r name credential; do
                [[ -z "$wanted" || "$wanted" == "$name" ]] || continue
                flow=''; [[ "$type" != vless ]] || flow=$(jq -r --arg tag "$tag" --arg name "$name" '.inbounds[]|select(.tag==$tag)|.users[]|select(.name==$name)|.flow // empty' "$config")
                printf '----------------------------------------\n'
                printf '用户: %s\n' "$name"
                if [[ "$type" == vless ]]; then printf 'UUID: %s\n' "$credential"; else printf '密码: %s\n' "$credential"; fi
                if [[ "$type" == vless ]]; then
                    printf 'vless://%s@%s:%s?%s%s#%s\n' "$credential" "$uri_host" "$port" "$query" "$([[ -n "$flow" ]] && printf '&flow=%s' "$(_singbox_uri_encode "$flow")")" "$(_singbox_uri_encode "${tag}-${name}")"
                else
                    printf 'trojan://%s@%s:%s?%s#%s\n' "$(_singbox_uri_encode "$credential")" "$uri_host" "$port" "$query" "$(_singbox_uri_encode "${tag}-${name}")"
                fi
            done < <(engine_singbox_inbound_clients "$tag")
            printf '----------------------------------------\n'
            ;;
        hysteria2)
            obfs=$(jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.obfs.type // empty' "$config"); obfs_password=$(jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.obfs.password // empty' "$config")
            while IFS=$'\t' read -r name credential; do
                [[ -z "$wanted" || "$wanted" == "$name" ]] || continue
                query="sni=$(_singbox_uri_encode "$sni")"; [[ -z "$obfs" ]] || query+="&obfs=$(_singbox_uri_encode "$obfs")&obfs-password=$(_singbox_uri_encode "$obfs_password")"
                printf '----------------------------------------\n'
                printf '用户: %s\n密码: %s\n' "$name" "$credential"
                printf 'hysteria2://%s@%s:%s?%s#%s\n' "$(_singbox_uri_encode "$credential")" "$uri_host" "$share_port" "$query" "$(_singbox_uri_encode "${tag}-${name}")"
            done < <(engine_singbox_inbound_clients "$tag")
            printf '----------------------------------------\n'
            ;;
        anytls)
            while IFS=$'\t' read -r name credential; do
                [[ -z "$wanted" || "$wanted" == "$name" ]] || continue
                printf '----------------------------------------\n'
                printf '用户: %s\n密码: %s\n' "$name" "$credential"
                if [[ "$security" == reality ]]; then
                    json=$(jq -cn --arg server "$host" --argjson port "$port" --arg password "$credential" --arg sni "$sni" --arg public "$public" --arg sid "$sid" '{type:"anytls",server:$server,server_port:$port,password:$password,tls:{enabled:true,server_name:$sni,reality:{enabled:true,public_key:$public,short_id:$sid}}}')
                    printf '%s\n' "$json"
                else
                    printf 'anytls://%s@%s:%s/?sni=%s#%s\n' "$(_singbox_uri_encode "$credential")" "$uri_host" "$port" "$(_singbox_uri_encode "$sni")" "$(_singbox_uri_encode "${tag}-${name}")"
                fi
            done < <(engine_singbox_inbound_clients "$tag")
            printf '----------------------------------------\n'
            ;;
        socks|http)
            if [[ $(jq --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.users|length' "$config") == 0 ]]; then
                printf '----------------------------------------\n'
                printf '%s://%s:%s\n' "$type" "$uri_host" "$port"
                printf '----------------------------------------\n'
            else
                while IFS=$'\t' read -r name credential; do
                    [[ -z "$wanted" || "$wanted" == "$name" ]] || continue
                    printf '----------------------------------------\n'
                    printf '用户: %s\n密码: %s\n' "$name" "$credential"
                    printf '%s://%s:%s@%s:%s#%s\n' "$type" "$(_singbox_uri_encode "$name")" "$(_singbox_uri_encode "$credential")" "$uri_host" "$port" "$(_singbox_uri_encode "${tag}-${name}")"
                done < <(engine_singbox_inbound_clients "$tag")
                printf '----------------------------------------\n'
            fi
            ;;
    esac
}
