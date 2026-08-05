#!/usr/bin/env bash
# ------------------------------------------------------------------------------
# menu.sh — Interactive terminal menus
# ------------------------------------------------------------------------------

# --- menu_main --------------------------------------------------------------
menu_main() {
    while true; do
        heading 'ProxyCTL'
        echo '  1) Inbound Management'
        echo '  2) Outbound Management'
        echo '  3) TLS Certificates'
        echo '  4) Core Management'
        echo '  5) System Tools'
        echo '  6) Backup & Restore'
        echo '  0) Exit'
        echo ''

        local choice
        read -r -p 'Select [0-6]: ' choice

        case "${choice}" in
            1) menu_inbound_new ;;
            2) echo 'Outbound management is not yet implemented.'; pause ;;
            3) echo 'TLS certificate management is not yet implemented.'; pause ;;
            4) menu_core ;;
            5) menu_system ;;
            6) echo 'Backup & restore is not yet implemented.'; pause ;;
            0) echo 'Goodbye.'; exit 0 ;;
            *) warn "Invalid selection: ${choice}" ;;
        esac
    done
}

# --- menu_inbound_new -------------------------------------------------------
menu_inbound_new() {
    heading 'Add Inbound — Select Core'

    # Step 1: choose engine
    local engines=()
    while IFS= read -r eng; do
        engines+=("${eng}")
    done < <(engine_list)

    if [[ "${#engines[@]}" -eq 0 ]]; then
        error 'No engines registered.'
        pause
        return
    fi

    local engine
    engine=$(choose 'Select core:' "${engines[@]}") || return

    # Step 2: choose protocol
    local protocols=()
    while IFS= read -r proto; do
        protocols+=("${proto}")
    done < <(engine_protocols "${engine}")

    local protocol
    protocol=$(choose "Select protocol for ${engine}:" "${protocols[@]}") || return

    # Step 3: transport (if applicable)
    local transport=''
    if capability_has_transports "${engine}" "${protocol}"; then
        local transports=()
        while IFS= read -r tr; do
            transports+=("${tr}")
        done < <(protocol_transports "${engine}" "${protocol}")

        transport=$(choose "Select transport for ${engine} / ${protocol}:" "${transports[@]}") || return
    fi

    # Step 4: print result
    echo ''
    if [[ -n "${transport}" ]]; then
        info "Selected: ${engine} / ${protocol} / ${transport}"
    else
        info "Selected: ${engine} / ${protocol}"
    fi

    echo ''
    info '(Configuration generation will be available in a future phase.)'
    pause
}

# --- menu_core --------------------------------------------------------------
menu_core() {
    heading 'Core Management'

    echo '  1) View core status'
    echo '  2) Install a core'
    echo '  3) Uninstall a core'
    echo '  4) Update a core'
    echo '  5) Start a core'
    echo '  6) Stop a core'
    echo '  7) Restart a core'
    echo '  8) Enable auto-start'
    echo '  9) Disable auto-start'
    echo '  0) Back'
    echo ''

    local choice
    read -r -p 'Select [0-9]: ' choice

    case "${choice}" in
        1) cmd_status; pause ;;
        2|3|4|5|6|7|8|9)
            echo 'Core management operations are not yet implemented.'
            echo 'Available in a future phase.'
            pause
            ;;
        0) return ;;
        *) warn "Invalid selection: ${choice}" ;;
    esac
}

# --- menu_system ------------------------------------------------------------
menu_system() {
    heading 'System Tools'

    echo '  1) Enable BBR'
    echo '  2) Check BBR status'
    echo '  3) Firewall setup'
    echo '  0) Back'
    echo ''

    local choice
    read -r -p 'Select [0-3]: ' choice

    case "${choice}" in
        1|2|3)
            echo 'System tools are not yet implemented.'
            echo 'Available in a future phase.'
            pause
            ;;
        0) return ;;
        *) warn "Invalid selection: ${choice}" ;;
    esac
}
