#!/usr/bin/env bash
# ------------------------------------------------------------------------------
# menu.sh — Interactive terminal menus
#
# All user input goes through ui.sh primitives: choose, confirm, prompt_value,
# prompt_optional, prompt_secret, pause.
# Direct read is never used in this file.
# ------------------------------------------------------------------------------

# --- menu_main --------------------------------------------------------------
menu_main() {
    while true; do
        heading 'ProxyCTL'

        local choice
        choose choice 'Main Menu' \
            'Inbound Management' \
            'Outbound Management' \
            'TLS Certificates' \
            'Core Management' \
            'System Tools' \
            'Backup & Restore' \
            'Exit' || {
            echo 'Goodbye.'
            exit 0
        }

        case "${choice}" in
            'Inbound Management')   menu_inbound_new ;;
            'Outbound Management')  echo 'Outbound management is not yet implemented.'; pause ;;
            'TLS Certificates')     echo 'TLS certificate management is not yet implemented.'; pause ;;
            'Core Management')      menu_core ;;
            'System Tools')         menu_system ;;
            'Backup & Restore')     echo 'Backup & restore is not yet implemented.'; pause ;;
            'Exit')                 echo 'Goodbye.'; exit 0 ;;
            *)                      warn "Unexpected selection: ${choice}" ;;
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
    choose engine 'Select core:' "${engines[@]}" || return

    # Step 2: choose protocol
    local protocols=()
    while IFS= read -r proto; do
        protocols+=("${proto}")
    done < <(engine_protocols "${engine}")

    local protocol
    choose protocol "Select protocol for ${engine}:" "${protocols[@]}" || return

    # Step 3: transport (if applicable)
    local transport=''
    if capability_has_transports "${engine}" "${protocol}"; then
        local transports=()
        while IFS= read -r tr; do
            transports+=("${tr}")
        done < <(protocol_transports "${engine}" "${protocol}")

        choose transport "Select transport for ${engine} / ${protocol}:" "${transports[@]}" || return
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

    local choice
    choose choice 'Core Management' \
        'View core status' \
        'Install a core' \
        'Uninstall a core' \
        'Update a core' \
        'Start a core' \
        'Stop a core' \
        'Restart a core' \
        'Enable auto-start' \
        'Disable auto-start' \
        'Back' || return

    case "${choice}" in
        'View core status')      cmd_status; pause ;;
        'Back')                  return ;;
        *)
            echo 'Core management operations are not yet implemented.'
            echo 'Available in a future phase.'
            pause
            ;;
    esac
}

# --- menu_system ------------------------------------------------------------
menu_system() {
    heading 'System Tools'

    local choice
    choose choice 'System Tools' \
        'Enable BBR' \
        'Check BBR status' \
        'Firewall setup' \
        'Back' || return

    case "${choice}" in
        'Back') return ;;
        *)
            echo 'System tools are not yet implemented.'
            echo 'Available in a future phase.'
            pause
            ;;
    esac
}
