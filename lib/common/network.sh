#!/usr/bin/env bash
# ------------------------------------------------------------------------------
# network.sh — Network utilities (validation, routes, primary IP, DNS resolve)
#
# Data functions print a single value on stdout; errors go to stderr.
# All external tools (ip, getent) are resolved at call time so tests can
# inject mocks via PATH.
# ------------------------------------------------------------------------------

# --- network_validate_ipv4 ---------------------------------------------------
# Strict IPv4 validation: exactly four decimal octets, each 0-255. Leading
# zeros are accepted as literal text (no octal interpretation).
network_validate_ipv4() {
    local addr="$1"
    [[ -n "$addr" ]] || return 1

    # Exactly three dots, with no leading/trailing/consecutive dots. This is
    # required because bash field-splitting silently drops trailing delimiters.
    local dots="${addr//[^.]/}"
    (( ${#dots} == 3 )) || return 1
    [[ "$addr" != .* && "$addr" != *. && "$addr" != *..* ]] || return 1

    local IFS='.'
    local -a octets=($addr)
    (( ${#octets[@]} == 4 )) || return 1

    local oct
    for oct in "${octets[@]}"; do
        [[ "$oct" =~ ^[0-9]+$ ]] || return 1
        (( ${#oct} <= 3 )) || return 1
        (( oct <= 255 )) || return 1
    done
    return 0
}

# --- _network_validate_ipv6_shell -------------------------------------------
# Pure-shell IPv6 literal validation (RFC 4291 grammar). Used as a fallback
# when python3 is unavailable.
_network_validate_ipv6_shell() {
    local addr="$1"
    [[ "$addr" == *:* ]] || return 1
    [[ "$addr" =~ ^[0-9a-fA-F:.]+$ ]] || return 1
    [[ "$addr" != *::*::* ]] || return 1   # two separate "::" compressions
    [[ "$addr" != *:::* ]] || return 1     # three+ consecutive colons

    # Lone leading/trailing colon (not part of "::") is invalid; bash read
    # would otherwise silently trim it.
    [[ "$addr" == :* && "$addr" != ::* ]] && return 1
    [[ "$addr" == *: && "$addr" != *:: ]] && return 1

    local has_dc=0
    [[ "$addr" == *"::"* ]] && has_dc=1

    local groups=0
    local IFS=':'
    local -a parts=()
    read -r -a parts <<< "$addr"

    local p
    for p in "${parts[@]}"; do
        if [[ -n "$p" ]]; then
            if [[ "$p" == *"."* ]]; then
                # embedded IPv4 counts as two groups
                network_validate_ipv4 "$p" || return 1
                (( groups += 2 ))
            elif [[ "$p" =~ ^[0-9a-fA-F]{1,4}$ ]]; then
                (( groups++ ))
            else
                return 1
            fi
        fi
    done

    if (( has_dc )); then
        # '::' must compress at least one zero group → at most 7 explicit
        (( groups <= 7 )) || return 1
        return 0
    else
        # No compression: exactly 8 groups and no empty field
        (( groups == 8 )) || return 1
        local empty=0
        for p in "${parts[@]}"; do
            [[ -z "$p" ]] && empty=1
        done
        (( empty == 0 )) || return 1
        return 0
    fi
}

# --- network_validate_ipv6 ---------------------------------------------------
# Uses python3's stdlib ipaddress when available, otherwise the shell fallback.
network_validate_ipv6() {
    local addr="$1"
    [[ -n "$addr" ]] || return 1

    if command -v python3 > /dev/null 2>&1; then
        if python3 -c 'import ipaddress,sys; ipaddress.IPv6Address(sys.argv[1])' "$addr" 2>/dev/null; then
            return 0
        fi
        return 1
    fi

    _network_validate_ipv6_shell "$addr"
}

# --- network_validate_ip -----------------------------------------------------
# Accepts either an IPv4 or IPv6 literal.
network_validate_ip() {
    local addr="$1"
    network_validate_ipv4 "$addr" && return 0
    network_validate_ipv6 "$addr" && return 0
    return 1
}

# --- network_validate_domain -------------------------------------------------
# Format-only DNS domain validation (no DNS query). Requires at least one dot.
# A single trailing dot is accepted and stripped.
network_validate_domain() {
    local domain="$1"
    [[ -n "$domain" ]] || return 1

    domain="${domain%.}"                       # strip one trailing dot
    local len=${#domain}
    (( len <= 253 )) || return 1
    [[ "$domain" == *.* ]] || return 1         # must be a DNS domain

    local IFS='.'
    local -a labels=($domain)
    local label
    for label in "${labels[@]}"; do
        [[ -n "$label" ]] || return 1          # no empty label
        (( ${#label} <= 63 )) || return 1
        [[ "$label" =~ ^[A-Za-z0-9-]+$ ]] || return 1
        [[ "$label" != -* && "$label" != *- ]] || return 1
    done
    return 0
}

# --- network_validate_host ---------------------------------------------------
# Accepts an IPv4 literal, IPv6 literal, DNS domain, or a single-label
# hostname (including localhost).
network_validate_host() {
    local host="$1"
    [[ -n "$host" ]] || return 1

    network_validate_ipv4 "$host" && return 0
    network_validate_ipv6 "$host" && return 0
    network_validate_domain "$host" && return 0

    if [[ "$host" =~ ^[A-Za-z0-9-]+$ ]] && [[ "$host" != -* && "$host" != *- ]]; then
        (( ${#host} <= 63 )) && return 0
    fi
    return 1
}

# --- _network_route_get_word ------------------------------------------------
# Runs `ip -<family> route get <target>` and prints the value following the
# given token (e.g. 'dev', 'src'). Returns 1 on failure.
_network_route_get_word() {
    local family="$1" target="$2" token="$3"
    local out
    if [[ "$family" == '4' ]]; then
        out=$(ip -4 route get "$target" 2>/dev/null) || return 1
    else
        out=$(ip -6 route get "$target" 2>/dev/null) || return 1
    fi

    local -a words=()
    read -r -a words <<< "$out"
    local i
    for (( i = 0; i < ${#words[@]} - 1; i++ )); do
        if [[ "${words[$i]}" == "$token" ]]; then
            printf '%s\n' "${words[$i+1]}"
            return 0
        fi
    done
    return 1
}

# --- network_default_interface_v4 --------------------------------------------
network_default_interface_v4() {
    _network_route_get_word '4' '1.1.1.1' 'dev'
}

# --- network_default_interface_v6 --------------------------------------------
network_default_interface_v6() {
    _network_route_get_word '6' '2606:4700:4700::1111' 'dev'
}

# --- network_primary_ipv4 ----------------------------------------------------
# Prints the source IPv4 used to reach the internet. The extracted address is
# re-validated rather than trusting `ip` output blindly.
network_primary_ipv4() {
    local src
    src=$(_network_route_get_word '4' '1.1.1.1' 'src') || return 1
    network_validate_ipv4 "$src" || return 1
    printf '%s\n' "$src"
}

# --- network_primary_ipv6 ----------------------------------------------------
network_primary_ipv6() {
    local src
    src=$(_network_route_get_word '6' '2606:4700:4700::1111' 'src') || return 1
    network_validate_ipv6 "$src" || return 1
    printf '%s\n' "$src"
}

# --- network_has_ipv4 --------------------------------------------------------
# True if a valid primary IPv4 address can be determined.
network_has_ipv4() {
    network_primary_ipv4 > /dev/null 2>&1
}

# --- network_has_ipv6 --------------------------------------------------------
network_has_ipv6() {
    network_primary_ipv6 > /dev/null 2>&1
}

# --- _network_ip_matches_family ----------------------------------------------
# True if the given IP literal belongs to the requested family (4/6/any).
_network_ip_matches_family() {
    local family="$1" ip="$2"
    case "$family" in
        4)   network_validate_ipv4 "$ip" ;;
        6)   network_validate_ipv6 "$ip" ;;
        any) network_validate_ipv4 "$ip" || network_validate_ipv6 "$ip" ;;
    esac
}

# --- network_resolve_domain --------------------------------------------------
# Usage: network_resolve_domain <domain> [4|6|any]
# Prints one unique IP per line. getent is preferred; nslookup is the fallback.
network_resolve_domain() {
    local domain="$1"
    local family="${2-any}"
    network_validate_domain "$domain" || return 1
    case "$family" in
        4|6|any) ;;
        *) error "Invalid address family: ${family}"; return 1 ;;
    esac

    local out=''
    local -a cmd=()
    if command -v getent > /dev/null 2>&1; then
        case "$family" in
            4)   cmd=(getent ahostsv4 "$domain") ;;
            6)   cmd=(getent ahostsv6 "$domain") ;;
            any) cmd=(getent ahosts "$domain") ;;
        esac
    fi
    if (( ${#cmd[@]} > 0 )); then
        out=$("${cmd[@]}" 2>/dev/null) || true
    fi
    if [[ -z "$out" ]] && command -v nslookup > /dev/null 2>&1; then
        local ns_out
        ns_out=$(nslookup "$domain" 2>/dev/null) || true
        out=$(printf '%s\n' "$ns_out" | awk '/^Address/ {print $2}')
    fi

    local found=0 line ip
    local -A seen=()
    while IFS= read -r line; do
        ip=${line%% *}
        [[ -n "$ip" ]] || continue
        if [[ -z "${seen[$ip]:-}" ]] && _network_ip_matches_family "$family" "$ip"; then
            printf '%s\n' "$ip"
            seen[$ip]=1
            found=1
        fi
    done <<< "$out"

    if (( found == 0 )); then
        error "Unable to resolve domain: ${domain}"
        return 1
    fi
    return 0
}

# --- _network_public_ip ------------------------------------------------------
# Queries public-IP providers with a curl timeout and re-validates every
# response before trusting it. Fails closed (no garbage on stdout).
_network_public_ip() {
    local family="$1"
    local -a providers
    if [[ "$family" == '4' ]]; then
        providers=(
            'https://cloudflare.com/cdn-cgi/trace|trace'
            'https://api.ipify.org|raw'
            'https://ipv4.icanhazip.com|raw'
        )
    else
        providers=(
            'https://cloudflare.com/cdn-cgi/trace|trace'
            'https://api64.ipify.org|raw'
            'https://ipv6.icanhazip.com|raw'
        )
    fi

    local entry url kind out ip
    for entry in "${providers[@]}"; do
        url="${entry%%|*}"
        kind="${entry##*|}"

        if ! out=$(curl "-${family}" --connect-timeout 3 --max-time 5 --fail \
            --silent --show-error "$url" 2>/dev/null); then
            continue
        fi

        if [[ "$kind" == 'trace' ]]; then
            ip=$(printf '%s\n' "$out" | awk -F= '/^ip=/{print $2; exit}')
        else
            ip=$(printf '%s' "$out" | tr -d '[:space:]')
        fi
        [[ -n "$ip" ]] || continue

        if [[ "$family" == '4' ]] && network_validate_ipv4 "$ip"; then
            printf '%s\n' "$ip"
            return 0
        fi
        if [[ "$family" == '6' ]] && network_validate_ipv6 "$ip"; then
            printf '%s\n' "$ip"
            return 0
        fi
    done

    error "Unable to determine public IPv${family} address."
    return 1
}

# --- network_public_ipv4 -----------------------------------------------------
network_public_ipv4() {
    _network_public_ip '4'
}

# --- network_public_ipv6 -----------------------------------------------------
network_public_ipv6() {
    _network_public_ip '6'
}

# --- _network_validate_tcp_port ----------------------------------------------
# Numeric port check kept local to network.sh (avoids a network→port cycle).
_network_validate_tcp_port() {
    local port="$1"
    [[ "$port" =~ ^[0-9]+$ ]] || return 1
    (( port >= 1 && port <= 65535 )) || return 1
    return 0
}

# --- _network_validate_tcp_timeout -------------------------------------------
_network_validate_tcp_timeout() {
    local timeout="$1"
    [[ "$timeout" =~ ^[0-9]+$ ]] || return 1
    (( timeout >= 1 && timeout <= 30 )) || return 1
    return 0
}

# --- network_tcp_connect -----------------------------------------------------
# Usage: network_tcp_connect <host> <port> [timeout]
# Uses nc when available, otherwise timeout + bash /dev/tcp.
network_tcp_connect() {
    local host="$1"
    local port="$2"
    local timeout="${3-3}"

    network_validate_host "$host" || {
        error "Invalid host: ${host}"
        return 1
    }
    _network_validate_tcp_port "$port" || {
        error "Invalid TCP port: ${port}"
        return 1
    }
    _network_validate_tcp_timeout "$timeout" || {
        error "Invalid timeout: ${timeout} (must be 1-30)"
        return 1
    }

    if command -v nc > /dev/null 2>&1; then
        if nc -z -w "$timeout" "$host" "$port" 2>/dev/null; then
            return 0
        fi
        return 1
    fi

    if command -v timeout > /dev/null 2>&1; then
        if timeout "$timeout" bash -c "exec 3<>/dev/tcp/$host/$port" 2>/dev/null; then
            return 0
        fi
        return 1
    fi

    error 'No supported TCP connect tool found (nc or timeout + /dev/tcp).'
    return 1
}
