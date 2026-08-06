#!/usr/bin/env bash
# ------------------------------------------------------------------------------
# xray/inbound.sh — Xray-specific inbound JSON, users, and share links
# ------------------------------------------------------------------------------

_xray_spec_protocol() {
    case "${1^^}" in
        VLESS) printf '%s' vless ;;
        VMESS) printf '%s' vmess ;;
        TROJAN) printf '%s' trojan ;;
        SOCKS|SOCKS5) printf '%s' socks ;;
        HTTP) printf '%s' http ;;
        *) printf '%s' "$1" | tr '[:upper:]' '[:lower:]' ;;
    esac
}
_xray_uri_encode() { jq -rn --arg v "$1" '$v|@uri'; }
_xray_uri_host() { [[ "$1" == *:* ]] && printf '[%s]' "$1" || printf '%s' "$1"; }
_xray_base64() { if base64 --help 2>/dev/null | grep -q -- '-w'; then base64 -w0; else openssl base64 -A; fi; }

_xray_generate_reality() {
    local output private public
    output=$(xray x25519 2>&1) || { error "$output"; return 1; }
    private=$(awk -F': *' 'tolower($1) ~ /(private|privatekey)/ {print $2; exit}' <<<"$output" | tr -d '"')
    public=$(awk -F': *' 'tolower($1) ~ /(public|password)/ {print $2; exit}' <<<"$output" | tr -d '"')
    [[ -n "$private" && -n "$public" ]] || { error 'Unable to parse Xray REALITY keypair.'; return 1; }
    printf '%s\t%s\n' "$private" "$public"
}

_xray_collect_certificate_spec() {
    local ids=() id selected subject
    while IFS= read -r id; do [[ -n "$id" ]] && ids+=("$id"); done < <(metadata_cert_list)
    ((${#ids[@]})) || { error 'No managed certificate exists. Use proxyctl cert issue/import first.'; return 1; }
    if ((${#ids[@]} == 1)); then selected=${ids[0]}; else choose selected 'Select managed certificate:' "${ids[@]}" || return 1; fi
    cert_exists "$selected" || { error "Managed certificate is incomplete: ${selected}"; return 1; }
    subject=$(metadata_cert_get_field "$selected" subject)
    printf '%s\t%s\n' "$selected" "${subject:-$selected}"
}

engine_xray_inbound_collect_spec() {
    local protocol transport='' security='' tag listen port client_host name='' username='' password='' uuid=''
    local path='' cert_id='' sni='' target='' private='' public='' short_id='' pair default_host
    choose protocol 'Select Xray protocol:' VLESS VMess Trojan SOCKS5 HTTP || return 1
    prompt_value tag 'Inbound tag' "${protocol,,}-$(inbound_random_hex 2)" || return 1
    inbound_validate_tag "$tag" || { error 'Invalid inbound tag.'; return 1; }
    prompt_value listen 'Listen address' '0.0.0.0' || return 1
    network_validate_ip "$listen" || { error 'Listen address must be an IPv4/IPv6 address.'; return 1; }
    prompt_value port 'Listen port' '443' || return 1
    port_validate "$port" || { error 'Port must be 1-65535.'; return 1; }

    case "$protocol" in
        VLESS) choose security 'Transport security:' reality tls none || return 1 ;;
        VMess) choose security 'Transport security:' tls none || return 1 ;;
        Trojan) choose security 'Transport security:' tls reality none || return 1 ;;
    esac

    case "$protocol" in
        VLESS)
            if [[ "$security" == reality ]]; then choose transport 'Transport:' RAW XHTTP || return 1; else choose transport 'Transport:' RAW XHTTP WebSocket || return 1; fi
            ;;
        VMess) choose transport 'Transport:' RAW WebSocket || return 1 ;;
        Trojan)
            if [[ "$security" == reality ]]; then choose transport 'Transport:' RAW || return 1; else choose transport 'Transport:' RAW WebSocket || return 1; fi
            ;;
    esac

    case "$transport" in
        XHTTP|WebSocket)
            prompt_value path "${transport} path" "/$(inbound_random_hex 6)" || return 1
            inbound_validate_path "$path" || { error 'Transport path must begin with / and contain no spaces.'; return 1; }
            ;;
    esac

    if [[ "$security" == tls ]]; then
        IFS=$'\t' read -r cert_id sni < <(_xray_collect_certificate_spec) || return 1
        prompt_value sni 'TLS SNI/serverName' "$sni" || return 1
        network_validate_host "$sni" || { error 'Invalid TLS SNI.'; return 1; }
    elif [[ "$security" == reality ]]; then
        prompt_value target 'REALITY target (host:port)' 'www.microsoft.com:443' || return 1
        [[ "$target" == *:* ]] || { error 'REALITY target must be host:port.'; return 1; }
        port_validate "${target##*:}" || { error 'Invalid REALITY target port.'; return 1; }
        prompt_value sni 'REALITY serverName/SNI' "${target%%:*}" || return 1
        network_validate_domain "$sni" || { error 'REALITY SNI must be a domain.'; return 1; }
        pair=$(_xray_generate_reality) || return 1
        IFS=$'\t' read -r private public <<<"$pair"
        short_id=$(inbound_random_hex 8)
    elif [[ "$security" == none && ( "$protocol" == VLESS || "$protocol" == Trojan ) ]]; then
        warn "${protocol} without TLS/REALITY should only be used on trusted private networks."
    fi

    # Client address: auto-fill from TLS SNI when available
    default_host=$(network_public_ipv4 2>/dev/null || network_public_ipv6 2>/dev/null || true)
    if [[ "$security" == tls && -n "$sni" ]]; then
        default_host="$sni"
    fi
    prompt_value client_host 'Client/server address' "${default_host:-127.0.0.1}" || return 1
    network_validate_host "$client_host" || { error 'Client address must be an IP or domain.'; return 1; }

    case "$protocol" in
        VLESS|VMess|Trojan)
            prompt_value name 'User name' "user-$(inbound_random_hex 2)" || return 1
            if [[ "$protocol" == VLESS || "$protocol" == VMess ]]; then uuid=$(inbound_generate_uuid) || return 1; else password=$(inbound_random_password); fi
            ;;
        SOCKS5|HTTP)
            prompt_optional username 'Username (empty = no authentication)' || return 1
            [[ -z "$username" ]] || password=$(inbound_random_password)
            if [[ -z "$username" && "$listen" != 127.0.0.1 && "$listen" != ::1 ]]; then warn 'Unauthenticated public proxy is high risk.'; fi
            ;;
    esac

    jq -n \
        --arg protocol "$protocol" --arg tag "$tag" --arg listen "$listen" --argjson port "$port" \
        --arg host "$client_host" --arg transport "$transport" --arg security "$security" --arg path "$path" \
        --arg cert "$cert_id" --arg sni "$sni" --arg target "$target" --arg private "$private" --arg public "$public" --arg sid "$short_id" \
        --arg name "$name" --arg username "$username" --arg password "$password" --arg uuid "$uuid" '
        {protocol:$protocol,tag:$tag,listen:$listen,port:$port,client_host:$host,transport:$transport,security:$security,path:$path,
         tls:{cert_id:$cert,server_name:$sni},reality:{target:$target,server_name:$sni,private_key:$private,public_key:$public,short_id:$sid},
         user:{name:$name,username:$username,password:$password,uuid:$uuid}}'
}

engine_xray_inbound_build_from_spec() {
    local spec="$1" protocol tag listen port transport security path cert_id sni target private sid name username password uuid
    local stream user flow='' method cert key
    jq -e 'type=="object"' <<<"$spec" >/dev/null || return 1
    protocol=$(_xray_spec_protocol "$(jq -r '.protocol // empty' <<<"$spec")")
    tag=$(jq -r '.tag // empty' <<<"$spec"); listen=$(jq -r '.listen // empty' <<<"$spec"); port=$(jq -r '.port // empty' <<<"$spec")
    transport=$(jq -r '.transport // empty' <<<"$spec"); security=$(jq -r '.security // "none"' <<<"$spec"); path=$(jq -r '.path // empty' <<<"$spec")
    cert_id=$(jq -r '.tls.cert_id // empty' <<<"$spec"); sni=$(jq -r '.tls.server_name // .reality.server_name // empty' <<<"$spec")
    target=$(jq -r '.reality.target // empty' <<<"$spec"); private=$(jq -r '.reality.private_key // empty' <<<"$spec"); sid=$(jq -r '.reality.short_id // empty' <<<"$spec")
    name=$(jq -r '.user.name // empty' <<<"$spec"); username=$(jq -r '.user.username // empty' <<<"$spec"); password=$(jq -r '.user.password // empty' <<<"$spec"); uuid=$(jq -r '.user.uuid // empty' <<<"$spec")

    case "$protocol" in vless|vmess|trojan|socks|http) ;; *) error "Unsupported Xray protocol: ${protocol}"; return 1 ;; esac
    inbound_validate_tag "$tag" && network_validate_ip "$listen" && port_validate "$port" || { error 'Invalid Xray inbound common fields.'; return 1; }

    case "$transport" in RAW|raw|'') method=raw ;; XHTTP|xhttp) method=xhttp ;; WebSocket|websocket|ws) method=websocket ;; *) error "Unsupported Xray transport: ${transport}"; return 1 ;; esac
    if [[ "$protocol" == socks || "$protocol" == http ]]; then method=''; security='none'; fi
    if [[ "$protocol" == vmess && "$method" == xhttp ]]; then error 'VMess XHTTP is outside ProxyCTL V1 capability scope.'; return 1; fi
    if [[ "$protocol" == trojan && "$method" == xhttp ]]; then error 'Trojan XHTTP is outside ProxyCTL V1 capability scope.'; return 1; fi
    if [[ "$security" == reality && "$method" == websocket ]]; then error 'REALITY cannot be combined with WebSocket.'; return 1; fi

    # Map internal transport names to Xray network values (raw→tcp, websocket→ws)
    case "$method" in raw) xray_network=tcp ;; websocket) xray_network=ws ;; *) xray_network="$method" ;; esac

    if [[ -n "$method" ]]; then
        stream=$(jq -n --arg network "$xray_network" --arg security "$security" '{network:$network,security:$security}')
        case "$method" in
            raw) stream=$(jq '. + {tcpSettings:{acceptProxyProtocol:false,header:{type:"none"}}}' <<<"$stream") ;;
            xhttp) inbound_validate_path "$path" || { error 'Invalid XHTTP path.'; return 1; }; stream=$(jq --arg path "$path" '. + {xhttpSettings:{path:$path,mode:"auto"}}' <<<"$stream") ;;
            websocket) inbound_validate_path "$path" || { error 'Invalid WebSocket path.'; return 1; }; stream=$(jq --arg path "$path" '. + {wsSettings:{path:$path,acceptProxyProtocol:false}}' <<<"$stream") ;;
        esac
        case "$security" in
            none) ;;
            tls)
                cert_exists "$cert_id" || { error "Managed certificate not found: ${cert_id}"; return 1; }
                cert=$(cert_fullchain "$cert_id"); key=$(cert_privkey "$cert_id")
                network_validate_host "$sni" || { error 'Invalid TLS SNI.'; return 1; }
                if [[ "$method" == websocket ]]; then
                    stream=$(jq --arg cert "$cert" --arg key "$key" --arg sni "$sni" '. + {tlsSettings:{serverName:$sni,alpn:["http/1.1"],certificates:[{certificateFile:$cert,keyFile:$key}]}}' <<<"$stream")
                else
                    stream=$(jq --arg cert "$cert" --arg key "$key" --arg sni "$sni" '. + {tlsSettings:{serverName:$sni,alpn:["h2","http/1.1"],certificates:[{certificateFile:$cert,keyFile:$key}]}}' <<<"$stream")
                fi
                ;;
            reality)
                [[ -n "$target" && "$target" == *:* && -n "$private" && "$sid" =~ ^[0-9A-Fa-f]{1,16}$ ]] || { error 'Incomplete REALITY settings.'; return 1; }
                network_validate_domain "$sni" || { error 'Invalid REALITY SNI.'; return 1; }
                stream=$(jq --arg target "$target" --arg sni "$sni" --arg private "$private" --arg sid "$sid" '. + {realitySettings:{show:false,target:$target,xver:0,serverNames:[$sni],privateKey:$private,shortIds:[$sid],maxTimeDiff:0}}' <<<"$stream")
                ;;
            *) error "Unsupported transport security: ${security}"; return 1 ;;
        esac
    fi

    case "$protocol" in
        vless)
            [[ "$uuid" =~ ^[0-9A-Fa-f-]{36}$ && -n "$name" ]] || { error 'VLESS requires user name and UUID.'; return 1; }
            [[ "$method" == raw && "$security" != none ]] && flow=xtls-rprx-vision || flow=''
            user=$(jq -n --arg id "$uuid" --arg email "$name" --arg flow "$flow" '{id:$id,email:$email,level:0}+(if $flow!="" then {flow:$flow} else {} end)')
            jq -n --arg tag "$tag" --arg listen "$listen" --argjson port "$port" --argjson user "$user" --argjson stream "$stream" '{tag:$tag,listen:$listen,port:$port,protocol:"vless",settings:{clients:[$user],decryption:"none"},streamSettings:$stream,sniffing:{enabled:true,destOverride:["http","tls","quic"],routeOnly:true}}'
            ;;
        vmess)
            [[ "$uuid" =~ ^[0-9A-Fa-f-]{36}$ && -n "$name" ]] || { error 'VMess requires user name and UUID.'; return 1; }
            user=$(jq -n --arg id "$uuid" --arg email "$name" '{id:$id,alterId:0,email:$email,level:0}')
            jq -n --arg tag "$tag" --arg listen "$listen" --argjson port "$port" --argjson user "$user" --argjson stream "$stream" '{tag:$tag,listen:$listen,port:$port,protocol:"vmess",settings:{clients:[$user]},streamSettings:$stream,sniffing:{enabled:true,destOverride:["http","tls","quic"],routeOnly:true}}'
            ;;
        trojan)
            [[ -n "$password" && -n "$name" ]] || { error 'Trojan requires user name and password.'; return 1; }
            user=$(jq -n --arg password "$password" --arg email "$name" '{password:$password,email:$email,level:0}')
            jq -n --arg tag "$tag" --arg listen "$listen" --argjson port "$port" --argjson user "$user" --argjson stream "$stream" '{tag:$tag,listen:$listen,port:$port,protocol:"trojan",settings:{clients:[$user]},streamSettings:$stream,sniffing:{enabled:true,destOverride:["http","tls","quic"],routeOnly:true}}'
            ;;
        socks)
            if [[ -n "$username" ]]; then
                [[ -n "$password" ]] || return 1
                jq -n --arg tag "$tag" --arg listen "$listen" --argjson port "$port" --arg user "$username" --arg pass "$password" '{tag:$tag,listen:$listen,port:$port,protocol:"socks",settings:{auth:"password",accounts:[{user:$user,pass:$pass}],users:[{user:$user,pass:$pass}],udp:true,ip:"0.0.0.0"}}'
            else
                jq -n --arg tag "$tag" --arg listen "$listen" --argjson port "$port" '{tag:$tag,listen:$listen,port:$port,protocol:"socks",settings:{auth:"noauth",accounts:[],users:[],udp:true,ip:"0.0.0.0"}}'
            fi
            ;;
        http)
            if [[ -n "$username" ]]; then
                [[ -n "$password" ]] || return 1
                jq -n --arg tag "$tag" --arg listen "$listen" --argjson port "$port" --arg user "$username" --arg pass "$password" '{tag:$tag,listen:$listen,port:$port,protocol:"http",settings:{accounts:[{user:$user,pass:$pass}],users:[{user:$user,pass:$pass}],allowTransparent:false}}'
            else
                jq -n --arg tag "$tag" --arg listen "$listen" --argjson port "$port" '{tag:$tag,listen:$listen,port:$port,protocol:"http",settings:{accounts:[],users:[],allowTransparent:false}}'
            fi
            ;;
    esac
}

engine_xray_inbound_list() {
    local config
    config=$(engine_xray_config_file)
    jq -r '.inbounds[]? | [.tag,.protocol,(.listen // "0.0.0.0"),(.port|tostring),(.streamSettings.network // .streamSettings.method // "-"),(.streamSettings.security // "none"),(((.settings.clients // .settings.accounts // .settings.users // [])|length)|tostring)] | @tsv' "$config" \
      | awk -F'\t' 'BEGIN{printf "%-24s %-8s %-18s %-7s %-10s %-9s %s\n","名称","协议","监听地址","端口","传输","安全","用户数"} {printf "%-24s %-8s %-18s %-7s %-10s %-9s %s\n",$1,$2,$3,$4,$5,$6,$7}'
    printf '\n配置文件: %s\n' "$config"
}

_xray_client_protocol() { jq -r --arg tag "$2" '.inbounds[]|select(.tag==$tag)|.protocol' "$1"; }

engine_xray_inbound_clients() {
    local tag="$1" config protocol
    inbound_exists xray "$tag" || { error "Inbound not found: xray/${tag}"; return 1; }
    config=$(engine_xray_config_file); protocol=$(_xray_client_protocol "$config" "$tag")
    case "$protocol" in
        vless|vmess) jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.settings.clients[]?|[.email,.id]|@tsv' "$config" ;;
        trojan) jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.settings.clients[]?|[.email,.password]|@tsv' "$config" ;;
        socks|http) jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|(.settings.accounts // .settings.users // [])[]?|[.user,.pass]|@tsv' "$config" ;;
        *) return 1 ;;
    esac
}

_xray_client_exists() {
    local tag="$1" label="$2" found
    while IFS=$'\t' read -r found _; do [[ "$found" == "$label" ]] && return 0; done < <(engine_xray_inbound_clients "$tag")
    return 1
}

engine_xray_inbound_client_add() {
    local tag="$1" label="${2:-}" credential="${3:-}" config protocol candidate user method security flow=''
    inbound_exists xray "$tag" || { error "Inbound not found: ${tag}"; return 1; }
    config=$(engine_xray_config_file); protocol=$(_xray_client_protocol "$config" "$tag")
    [[ -n "$label" ]] || prompt_value label 'User name' "user-$(inbound_random_hex 2)" || return 1
    _xray_client_exists "$tag" "$label" && { error "User already exists: ${label}"; return 1; }
    case "$protocol" in
        vless)
            [[ -n "$credential" ]] || credential=$(inbound_generate_uuid)
            method=$(jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.streamSettings.network // .streamSettings.method // "tcp"' "$config")
            security=$(jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.streamSettings.security // "none"' "$config")
            [[ "$method" == tcp && "$security" != none ]] && flow=xtls-rprx-vision
            user=$(jq -n --arg id "$credential" --arg email "$label" --arg flow "$flow" '{id:$id,email:$email,level:0}+(if $flow!="" then {flow:$flow} else {} end)') ;;
        vmess) [[ -n "$credential" ]] || credential=$(inbound_generate_uuid); user=$(jq -n --arg id "$credential" --arg email "$label" '{id:$id,alterId:0,email:$email,level:0}') ;;
        trojan) [[ -n "$credential" ]] || credential=$(inbound_random_password); user=$(jq -n --arg password "$credential" --arg email "$label" '{password:$password,email:$email,level:0}') ;;
        socks|http) [[ -n "$credential" ]] || credential=$(inbound_random_password); user=$(jq -n --arg user "$label" --arg pass "$credential" '{user:$user,pass:$pass}') ;;
        *) error "Protocol does not support user management: ${protocol}"; return 1 ;;
    esac
    candidate=$(mktemp) || return 1
    if [[ "$protocol" == socks || "$protocol" == http ]]; then
        jq --arg tag "$tag" --arg protocol "$protocol" --argjson user "$user" '(.inbounds[]|select(.tag==$tag)|.settings) |= (((.accounts // .users // [])+[$user]) as $a | .accounts=$a | .users=$a | if $protocol=="socks" then .auth="password" else . end)' "$config" >"$candidate"
    else
        jq --arg tag "$tag" --argjson user "$user" '(.inbounds[]|select(.tag==$tag)|.settings.clients) += [$user]' "$config" >"$candidate"
    fi
    apply_candidate xray "$candidate"; local rc=$?; rm -f -- "$candidate"; return "$rc"
}

engine_xray_inbound_client_rotate() {
    local tag="$1" label="$2" credential="${3:-}" config protocol candidate
    inbound_exists xray "$tag" || return 1
    _xray_client_exists "$tag" "$label" || { error "User not found: ${label}"; return 1; }
    config=$(engine_xray_config_file); protocol=$(_xray_client_protocol "$config" "$tag")
    candidate=$(mktemp) || return 1
    case "$protocol" in
        vless|vmess) [[ -n "$credential" ]] || credential=$(inbound_generate_uuid); jq --arg tag "$tag" --arg lbl "$label" --arg v "$credential" '(.inbounds[]|select(.tag==$tag)|.settings.clients[]|select(.email==$lbl)|.id)=$v' "$config" >"$candidate" ;;
        trojan) [[ -n "$credential" ]] || credential=$(inbound_random_password); jq --arg tag "$tag" --arg lbl "$label" --arg v "$credential" '(.inbounds[]|select(.tag==$tag)|.settings.clients[]|select(.email==$lbl)|.password)=$v' "$config" >"$candidate" ;;
        socks|http) [[ -n "$credential" ]] || credential=$(inbound_random_password); jq --arg tag "$tag" --arg lbl "$label" --arg v "$credential" '(.inbounds[]|select(.tag==$tag)|.settings) |= ((.accounts // .users // []) as $a | ($a|map(if .user==$lbl then .pass=$v else . end)) as $b | .accounts=$b | .users=$b)' "$config" >"$candidate" ;;
        *) rm -f -- "$candidate"; return 1 ;;
    esac
    apply_candidate xray "$candidate"; local rc=$?; rm -f -- "$candidate"; return "$rc"
}

engine_xray_inbound_client_delete() {
    local tag="$1" label="$2" config protocol candidate count listen
    inbound_exists xray "$tag" || return 1
    _xray_client_exists "$tag" "$label" || { error "User not found: ${label}"; return 1; }
    config=$(engine_xray_config_file); protocol=$(_xray_client_protocol "$config" "$tag")
    if [[ "$protocol" == http ]]; then
        count=$(jq --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|(.settings.accounts // .settings.users // [])|length' "$config")
        listen=$(jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.listen // "0.0.0.0"' "$config")
        if ((count == 1)) && [[ "$listen" != 127.0.0.1 && "$listen" != ::1 ]]; then error 'Refusing to turn a public HTTP inbound into an unauthenticated proxy.'; return 1; fi
    fi
    candidate=$(mktemp) || return 1
    case "$protocol" in
        vless|vmess|trojan) jq --arg tag "$tag" --arg lbl "$label" '(.inbounds[]|select(.tag==$tag)|.settings.clients) |= map(select(.email!=$lbl))' "$config" >"$candidate" ;;
        socks|http) jq --arg tag "$tag" --arg lbl "$label" --arg protocol "$protocol" '(.inbounds[]|select(.tag==$tag)|.settings) |= ((.accounts // .users // []) as $a | ($a|map(select(.user!=$lbl))) as $b | .accounts=$b | .users=$b | if $protocol=="socks" and ($b|length)==0 then .auth="noauth" else . end)' "$config" >"$candidate" ;;
        *) rm -f -- "$candidate"; return 1 ;;
    esac
    apply_candidate xray "$candidate"; local rc=$?; rm -f -- "$candidate"; return "$rc"
}

engine_xray_inbound_share() {
    local tag="$1" wanted="${2:-}" config protocol host uri_host port method security type path sni sid pbk flow label credential query vmess_json count scheme
    inbound_exists xray "$tag" || return 1
    config=$(engine_xray_config_file); protocol=$(_xray_client_protocol "$config" "$tag")
    host=$(inbound_meta_get xray "$tag" clientHost); [[ -n "$host" ]] || host=$(jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.listen' "$config")
    uri_host=$(_xray_uri_host "$host"); port=$(jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.port' "$config")
    method=$(jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.streamSettings.network // .streamSettings.method // "tcp"' "$config"); security=$(jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.streamSettings.security // "none"' "$config")
    case "$method" in tcp) type=tcp ;; ws) type=ws ;; xhttp) type=xhttp ;; *) type="$method" ;; esac
    query="type=$(_xray_uri_encode "$type")&security=$(_xray_uri_encode "$security")"
    if [[ "$method" == ws ]]; then path=$(jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.streamSettings.wsSettings.path // "/"' "$config"); query+="&path=$(_xray_uri_encode "$path")"; fi
    if [[ "$method" == xhttp ]]; then path=$(jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.streamSettings.xhttpSettings.path // "/"' "$config"); query+="&path=$(_xray_uri_encode "$path")&mode=auto"; fi
    if [[ "$security" == tls ]]; then sni=$(jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.streamSettings.tlsSettings.serverName // empty' "$config"); query+="&sni=$(_xray_uri_encode "$sni")&fp=chrome"; fi
    if [[ "$security" == reality ]]; then
        sni=$(jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.streamSettings.realitySettings.serverNames[0]' "$config"); sid=$(jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.streamSettings.realitySettings.shortIds[0]' "$config")
        pbk=$(inbound_meta_get xray "$tag" realityPublicKey); [[ -n "$pbk" ]] || { error 'REALITY public key metadata is unavailable.'; return 1; }
        query+="&sni=$(_xray_uri_encode "$sni")&fp=chrome&pbk=$(_xray_uri_encode "$pbk")&sid=$(_xray_uri_encode "$sid")&spx=%2F"
    fi
    case "$protocol" in
        vless|trojan)
            while IFS=$'\t' read -r label credential; do
                [[ -z "$wanted" || "$wanted" == "$label" ]] || continue
                flow=''; [[ "$protocol" != vless ]] || flow=$(jq -r --arg tag "$tag" --arg lbl "$label" '.inbounds[]|select(.tag==$tag)|.settings.clients[]|select(.email==$lbl)|.flow // empty' "$config")
                echo '----------------------------------------'
                printf '用户: %s\n' "$label"
                if [[ "$protocol" == vless ]]; then printf 'UUID: %s\n' "$credential"; else printf '密码: %s\n' "$credential"; fi
                if [[ -n "$flow" ]]; then
                    printf 'vless://%s@%s:%s?%s&flow=%s#%s\n' "$credential" "$uri_host" "$port" "$query" "$(_xray_uri_encode "$flow")" "$(_xray_uri_encode "${tag}-${label}")"
                else
                    printf '%s://%s@%s:%s?%s#%s\n' "$protocol" "$credential" "$uri_host" "$port" "$query" "$(_xray_uri_encode "${tag}-${label}")"
                fi
            done < <(engine_xray_inbound_clients "$tag")
            echo '----------------------------------------'
            ;;
        vmess)
            path=$(jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|(.streamSettings.wsSettings.path // "/")' "$config"); sni=$(jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.streamSettings.tlsSettings.serverName // empty' "$config")
            while IFS=$'\t' read -r label credential; do
                [[ -z "$wanted" || "$wanted" == "$label" ]] || continue
                vmess_json=$(jq -cn --arg ps "${tag}-${label}" --arg add "$host" --arg port "$port" --arg id "$credential" --arg net "$type" --arg path "$path" --arg tls "$security" --arg sni "$sni" '{v:"2",ps:$ps,add:$add,port:$port,id:$id,aid:"0",scy:"auto",net:$net,type:"none",host:$sni,path:$path,tls:(if $tls=="tls" then "tls" else "" end),sni:$sni,alpn:""}')
                echo '----------------------------------------'
                printf '用户: %s\nUUID: %s\n' "$label" "$credential"
                printf 'vmess://%s\n' "$(printf '%s' "$vmess_json" | _xray_base64)"
            done < <(engine_xray_inbound_clients "$tag")
            echo '----------------------------------------'
            ;;
        socks|http)
            count=$(jq --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|(.settings.accounts // .settings.users // [])|length' "$config")
            scheme=$([[ "$protocol" == socks ]] && printf socks5 || printf http)
            if (( count == 0 )); then
                echo '----------------------------------------'
                printf '%s://%s:%s\n' "$scheme" "$uri_host" "$port"
                echo '----------------------------------------'
            else
                while IFS=$'\t' read -r label credential; do
                    [[ -z "$wanted" || "$wanted" == "$label" ]] || continue
                    echo '----------------------------------------'
                    printf '用户: %s\n密码: %s\n' "$label" "$credential"
                    printf '%s://%s:%s@%s:%s\n' "$scheme" "$(_xray_uri_encode "$label")" "$(_xray_uri_encode "$credential")" "$uri_host" "$port"
                done < <(engine_xray_inbound_clients "$tag")
                echo '----------------------------------------'
            fi
            ;;
    esac
}
