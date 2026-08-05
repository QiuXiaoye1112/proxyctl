#!/usr/bin/env bash
# ------------------------------------------------------------------------------
# inbound_safety.sh — strict shared guards for inbound mutations
# ------------------------------------------------------------------------------

# Override the base helper with an errexit-safe implementation. Both TCP and
# UDP are checked deliberately: ProxyCTL reserves a numeric port globally for
# managed inbounds so reinstalling another core cannot create a latent bind
# conflict later.
inbound_port_require_available() {
    local engine="$1" port="$2" except_tag="${3:-}" skip_os="${4:-0}"
    local proto rc

    port_validate "$port" || return 1
    if inbound_port_in_any_config "$port" "$engine" "$except_tag"; then
        error "Port ${port} is already reserved by another ProxyCTL inbound."
        return 1
    fi
    [[ "$skip_os" == 1 ]] && return 0

    for proto in tcp udp; do
        if port_is_free "$port" "$proto"; then
            rc=0
        else
            rc=$?
        fi
        case "$rc" in
            0) ;;
            1)
                error "Port ${port}/${proto} is already in use by the operating system."
                return 1
                ;;
            *)
                error "Unable to inspect port ${port}/${proto}; refusing to continue."
                return 1
                ;;
        esac
    done
}
