#!/usr/bin/env bash
# ------------------------------------------------------------------------------
# ui.sh — Shared terminal UI primitives
# ------------------------------------------------------------------------------

readonly COLOR_RESET='\033[0m'
readonly COLOR_BOLD='\033[1m'
readonly COLOR_RED='\033[0;31m'
readonly COLOR_GREEN='\033[0;32m'
readonly COLOR_YELLOW='\033[0;33m'
readonly COLOR_CYAN='\033[0;36m'

# --- heading ----------------------------------------------------------------
heading() {
    local text="$1"
    echo ''
    echo -e "${COLOR_BOLD}${COLOR_CYAN}==> ${text}${COLOR_RESET}"
    echo ''
}

# --- info -------------------------------------------------------------------
info() {
    local text="$1"
    echo -e "${COLOR_GREEN}[+]${COLOR_RESET} ${text}"
}

# --- warn -------------------------------------------------------------------
warn() {
    local text="$1"
    echo -e "${COLOR_YELLOW}[!]${COLOR_RESET} ${text}" >&2
}

# --- error ------------------------------------------------------------------
error() {
    local text="$1"
    echo -e "${COLOR_RED}[x]${COLOR_RESET} ${text}" >&2
}

# --- die --------------------------------------------------------------------
die() {
    local text="$1"
    local code="${2:-1}"
    echo -e "${COLOR_RED}[FATAL]${COLOR_RESET} ${text}" >&2
    exit "${code}"
}

# --- pause ------------------------------------------------------------------
pause() {
    local prompt="${1:-Press Enter to continue...}"
    read -r -p "${prompt}"
}

# --- confirm ----------------------------------------------------------------
confirm() {
    local prompt="${1:-Continue?}"
    local default="${2:-n}"
    local response

    if [[ "${default}" == 'y' ]]; then
        read -r -p "${prompt} [Y/n] " response
        response="${response:-y}"
    else
        read -r -p "${prompt} [y/N] " response
        response="${response:-n}"
    fi

    [[ "${response,,}" == 'y' || "${response,,}" == 'yes' ]]
}

# --- choose -----------------------------------------------------------------
choose() {
    local prompt="$1"
    shift
    local options=("$@")
    local count="${#options[@]}"
    local choice

    echo ''
    echo "${prompt}"
    echo ''

    for i in "${!options[@]}"; do
        printf '  %d) %s\n' "$((i + 1))" "${options[$i]}"
    done

    echo ''
    while true; do
        read -r -p "Select [1-${count}]: " choice
        if [[ "${choice}" =~ ^[0-9]+$ ]] && ((choice >= 1 && choice <= count)); then
            echo "${options[$((choice - 1))]}"
            return 0
        fi
        warn "Invalid selection. Please enter 1-${count}."
    done
}

# --- prompt_value -----------------------------------------------------------
prompt_value() {
    local prompt="$1"
    local default="${2:-}"
    local value

    if [[ -n "${default}" ]]; then
        read -r -p "${prompt} [${default}]: " value
        echo "${value:-${default}}"
    else
        while true; do
            read -r -p "${prompt}: " value
            if [[ -n "${value}" ]]; then
                echo "${value}"
                return 0
            fi
            warn 'Value is required.'
        done
    fi
}

# --- prompt_optional --------------------------------------------------------
prompt_optional() {
    local prompt="$1"
    local default="${2:-}"
    local value

    read -r -p "${prompt}: " value
    echo "${value:-${default}}"
}

# --- prompt_secret ----------------------------------------------------------
prompt_secret() {
    local prompt="$1"
    local value

    read -r -s -p "${prompt}: " value
    echo ''
    echo "${value}"
}

# --- prompt_hidden_secret ---------------------------------------------------
prompt_hidden_secret() {
    local prompt="$1"
    local value

    read -r -s -p "${prompt}: " value
    echo ''
    # Return masked version for display, but echo value for caller
    echo "${value}"
}

# --- table helpers ----------------------------------------------------------
table_header() {
    printf '\n'
    printf '  %-40s %s\n' "$1" "$2"
    printf '  %-40s %s\n' '----------------------------------------' '----------'
}

table_row() {
    printf '  %-40s %s\n' "$1" "$2"
}

table_footer() {
    printf '\n'
}
