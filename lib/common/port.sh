#!/usr/bin/env bash
# ------------------------------------------------------------------------------
# port.sh — TCP/UDP port validation and socket inspection
#
# ss is the primary inspection tool; netstat is a fallback. Inspection
# failures are NEVER reported as "port free" — they fail closed.
#
# Note: port_is_free / port_random only reflect the state at inspection time.
# Binding is still subject to TOCTOU — the final authority is the core's own
# bind + restart health check during config apply.
# ------------------------------------------------------------------------------

# --- port_validate -----------------------------------------------------------
# Usage: port_validate <port>
# Accepts 1-65535 only.
port_validate() {
    local port="$1"
    [[ "$port" =~ ^[0-9]+$ ]] || return 1
    (( port >= 1 && port <= 65535 )) || return 1
    return 0
}

# --- _port_validate_proto ----------------------------------------------------
# Usage: proto=$(_port_validate_proto [tcp|udp])   (defaults to tcp)
# Prints the canonical lowercase protocol.
_port_validate_proto() {
    local proto="${1:-tcp}"
    case "$proto" in
        tcp|TCP) printf '%s\n' 'tcp'; return 0 ;;
        udp|UDP) printf '%s\n' 'udp'; return 0 ;;
        *) error "Invalid protocol: ${proto}"; return 1 ;;
    esac
}

# --- _port_extract_number ----------------------------------------------------
# Extracts the port number from a local address like:
#   0.0.0.0:443   [::]:443   127.0.0.1:8080   *:53
_port_extract_number() {
    local addr="$1"
    local n="${addr##*:}"
    [[ "$n" =~ ^[0-9]+$ ]] || return 1
    printf '%s\n' "$n"
}

# --- _port_listening_state ---------------------------------------------------
# Returns:
#   0 = listening
#   1 = not listening
#   2 = inspection failed
_port_listening_state() {
    local port="$1"
    local proto="$2"

    local flags out
    if [[ "$proto" == 'tcp' ]]; then
        flags='-H -ltn'
    else
        flags='-H -lun'
    fi

    if command -v ss > /dev/null 2>&1; then
        if ! out=$(ss $flags 2>/dev/null); then
            error 'Unable to inspect listening sockets.'
            return 2
        fi
    elif command -v netstat > /dev/null 2>&1; then
        if [[ "$proto" == 'tcp' ]]; then
            if ! out=$(netstat -ltn 2>/dev/null); then
                error 'Unable to inspect listening sockets.'
                return 2
            fi
        else
            if ! out=$(netstat -lun 2>/dev/null); then
                error 'Unable to inspect listening sockets.'
                return 2
            fi
        fi
    else
        error 'No supported socket inspection tool found.'
        return 2
    fi

    local line addr n
    while IFS= read -r line; do
        addr=$(printf '%s\n' "$line" | awk '{print $4}')
        [[ -n "$addr" ]] || continue
        n=$(_port_extract_number "$addr") || continue
        if (( n == port )); then
            return 0
        fi
    done <<< "$out"

    return 1
}

# --- port_is_listening -------------------------------------------------------
# Usage: port_is_listening <port> [tcp|udp]
# Protocol defaults to tcp.
port_is_listening() {
    local port="$1"
    local proto
    port_validate "$port" || return 1
    proto=$(_port_validate_proto "${2:-tcp}") || return 1

    _port_listening_state "$port" "$proto"
}

# --- port_is_free ------------------------------------------------------------
# Usage: port_is_free <port> [tcp|udp]
# 0 = free (not listening), 1 = occupied, 2 = inspection failed.
# Protocol defaults to tcp.
port_is_free() {
    local port="$1"
    local proto
    port_validate "$port" || return 1
    proto=$(_port_validate_proto "${2:-tcp}") || return 1

    local st
    if _port_listening_state "$port" "$proto"; then
        st=0
    else
        st=$?
    fi

    if (( st == 0 )); then
        return 1          # listening → not free
    fi
    if (( st == 2 )); then
        return 2          # inspection failed → fail closed
    fi
    return 0              # not listening → free
}

# --- _port_process_from_line -------------------------------------------------
# Prints "PID NAME" for every process in a ss users:(...) section.
_port_process_from_line() {
    local line="$1"
    local section="${line#*users:}"
    if [[ "$section" == "$line" ]]; then
        return 0          # no process info available
    fi

    local regex='\("([^"]*)",pid=([0-9]+)'
    while [[ "$section" =~ $regex ]]; do
        printf '%s %s\n' "${BASH_REMATCH[2]}" "${BASH_REMATCH[1]}"
        section="${section#*${BASH_REMATCH[0]}}"
    done
    return 0
}

# --- port_process ------------------------------------------------------------
# Usage: port_process <port> [tcp|udp]
# Prints "PID NAME" lines for processes listening on the port. If the port is
# listening but the process cannot be read, prints "unknown". Returns 1 if the
# port is not listening and 2 if socket inspection fails. Protocol defaults tcp.
port_process() {
    local port="$1"
    local proto
    port_validate "$port" || return 1
    proto=$(_port_validate_proto "${2:-tcp}") || return 1

    local flags out
    if [[ "$proto" == 'tcp' ]]; then
        flags='-H -ltnp'
    else
        flags='-H -lunp'
    fi

    if command -v ss > /dev/null 2>&1; then
        if ! out=$(ss $flags 2>/dev/null); then
            error 'Unable to inspect listening sockets.'
            return 2
        fi
    elif command -v netstat > /dev/null 2>&1; then
        if [[ "$proto" == 'tcp' ]]; then
            if ! out=$(netstat -ltnp 2>/dev/null); then
                error 'Unable to inspect listening sockets.'
                return 2
            fi
        else
            if ! out=$(netstat -lunp 2>/dev/null); then
                error 'Unable to inspect listening sockets.'
                return 2
            fi
        fi
    else
        error 'No supported socket inspection tool found.'
        return 2
    fi

    local found=0 printed=0 line addr n proc_line p
    while IFS= read -r line; do
        addr=$(printf '%s\n' "$line" | awk '{print $4}')
        [[ -n "$addr" ]] || continue
        n=$(_port_extract_number "$addr") || continue
        if (( n == port )); then
            found=1
            proc_line=$(_port_process_from_line "$line")
            if [[ -n "$proc_line" ]]; then
                while IFS= read -r p; do
                    printf '%s\n' "$p"
                    printed=1
                done <<< "$proc_line"
            fi
        fi
    done <<< "$out"

    if (( found == 0 )); then
        return 1
    fi
    if (( printed == 0 )); then
        printf '%s\n' 'unknown'
    fi
    return 0
}

# --- port_require_free -------------------------------------------------------
# Usage: port_require_free <port> [tcp|udp]
# Protocol defaults to tcp.
port_require_free() {
    local port="$1"
    local proto
    port_validate "$port" || return 1
    proto=$(_port_validate_proto "${2:-tcp}") || return 1

    local st
    if _port_listening_state "$port" "$proto"; then
        st=0
    else
        st=$?
    fi

    if (( st == 0 )); then
        local owner pid name
        owner=$(port_process "$port" "$proto" 2>/dev/null || true)
        if [[ -n "$owner" && "$owner" != 'unknown' ]]; then
            pid=${owner%% *}
            name=${owner#* }
            error "Port ${port}/${proto} is already in use by ${name} (PID ${pid})."
        else
            error "Port ${port}/${proto} is already in use."
        fi
        return 1
    fi
    if (( st == 2 )); then
        error "Unable to inspect listening sockets for port ${port}/${proto}."
        return 2
    fi
    return 0
}

# --- _port_random_from_value -------------------------------------------------
# Maps a non-negative random integer into the inclusive port range. Kept pure
# so tests can prove that ranges wider than $RANDOM (0-32767) are reachable.
_port_random_from_value() {
    local start="$1" end="$2" value="$3"
    local range=$(( end - start + 1 ))
    (( value >= 0 )) || return 1
    printf '%d\n' $(( start + (value % range) ))
}

# --- _port_random_number -----------------------------------------------------
# Production random candidate generator. Two $RANDOM reads provide 30 bits,
# enough to cover every valid TCP/UDP port range. This is not cryptographic.
_port_random_number() {
    local start="$1" end="$2"
    local value=$(( (RANDOM << 15) | RANDOM ))
    _port_random_from_value "$start" "$end" "$value"
}

# --- port_random -------------------------------------------------------------
# Usage: port_random <start> <end> [tcp|udp]
# Returns a currently-free port in range, up to 100 attempts. Protocol defaults
# to tcp. Socket inspection failure aborts immediately instead of retrying.
port_random() {
    local start="$1" end="$2"
    local proto
    port_validate "$start" || { error "Invalid start port: ${start}"; return 1; }
    port_validate "$end"   || { error "Invalid end port: ${end}"; return 1; }
    (( start <= end )) || { error "Start port exceeds end port."; return 1; }
    proto=$(_port_validate_proto "${3:-tcp}") || return 1

    local i p rc
    for (( i = 0; i < 100; i++ )); do
        p=$(_port_random_number "$start" "$end") || return 1
        if port_is_free "$p" "$proto"; then
            printf '%s\n' "$p"
            return 0
        else
            rc=$?
            if (( rc == 2 )); then
                return 2
            fi
        fi
    done

    error "Unable to find a free ${proto} port in ${start}-${end}."
    return 1
}
