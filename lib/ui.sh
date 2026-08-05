#!/usr/bin/env bash
# ------------------------------------------------------------------------------
# ui.sh — Shared terminal UI primitives
#
# All interactive functions return values via a variable name (first argument),
# using printf -v.  They never return data on stdout.
#
# Non-interactive functions (heading, info, warn, error, die) write directly.
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
# Usage: pause [prompt]
# Non-TTY: silent no-op.
pause() {
    local prompt="${1:-Press Enter to continue...}"
    [[ -t 0 ]] || return 0
    read -r -p "${prompt}"
}

# --- confirm ----------------------------------------------------------------
# Usage: confirm <var> <prompt> [default]
# Sets <var> to 'y' or 'n'.
# Non-TTY: fails (cannot confirm interactively).
confirm() {
    local __var="$1"
    local prompt="${2:-Continue?}"
    local default="${3:-n}"
    local response

    if [[ ! -t 0 ]] && [[ -z "${PROXYCTL_NO_TTY_GUARD:-}" ]]; then
        error 'Interactive confirmation requires a TTY.'
        return 1
    fi

    if [[ "${default}" == 'y' ]]; then
        read -r -p "${prompt} [Y/n] " response
        response="${response:-y}"
    else
        read -r -p "${prompt} [y/N] " response
        response="${response:-n}"
    fi

    if [[ "${response,,}" == 'y' || "${response,,}" == 'yes' ]]; then
        printf -v "$__var" '%s' 'y'
    else
        printf -v "$__var" '%s' 'n'
    fi
}

# --- choose -----------------------------------------------------------------
# Usage: choose <var> <prompt> <options...>
# Sets <var> to the selected option string.
# Returns 0 on success, 1 if user cancels (Ctrl-D / EOF).
# Non-TTY: fails immediately.
choose() {
    local __var="$1"
    local prompt="$2"
    shift 2
    local options=("$@")
    local count="${#options[@]}"

    if ((count == 0)); then
        error 'choose: no options provided'
        return 1
    fi

    [[ -t 0 ]] || [[ -n "${PROXYCTL_NO_TTY_GUARD:-}" ]] || {
        error 'Interactive selection requires a TTY.'
        return 1
    }

    echo ''
    echo "${prompt}"
    echo ''

    local i
    for i in "${!options[@]}"; do
        printf '  %d) %s\n' "$((i + 1))" "${options[$i]}"
    done

    echo ''
    local choice
    while true; do
        read -r -p "Select [1-${count}]: " choice || {
            echo ''
            return 1
        }
        if [[ "${choice}" =~ ^[0-9]+$ ]] && ((choice >= 1 && choice <= count)); then
            printf -v "$__var" '%s' "${options[$((choice - 1))]}"
            return 0
        fi
        warn "Invalid selection. Please enter 1-${count}."
    done
}

# --- prompt_value -----------------------------------------------------------
# Usage: prompt_value <var> <prompt> [default]
# Sets <var> to the user's input.
# If no default, loops until a non-empty value is entered.
# Non-TTY: fails if value is required (no default).
prompt_value() {
    local __var="$1"
    local prompt="$2"
    local default="${3:-}"
    local value

    if [[ -n "${default}" ]]; then
        [[ -t 0 ]] || {
            printf -v "$__var" '%s' "${default}"
            return 0
        }
        read -r -p "${prompt} [${default}]: " value
        printf -v "$__var" '%s' "${value:-${default}}"
    else
        [[ -t 0 ]] || {
            error 'Interactive value input requires a TTY.'
            return 1
        }
        while true; do
            read -r -p "${prompt}: " value || {
                echo ''
                return 1
            }
            if [[ -n "${value}" ]]; then
                printf -v "$__var" '%s' "${value}"
                return 0
            fi
            warn 'Value is required.'
        done
    fi
}

# --- prompt_optional --------------------------------------------------------
# Usage: prompt_optional <var> <prompt> [default]
# Sets <var> to the user's input (may be empty).
# Non-TTY: returns default (or empty) without blocking.
prompt_optional() {
    local __var="$1"
    local prompt="$2"
    local default="${3:-}"
    local value

    [[ -t 0 ]] || {
        printf -v "$__var" '%s' "${default}"
        return 0
    }

    read -r -p "${prompt}: " value
    printf -v "$__var" '%s' "${value:-${default}}"
}

# --- prompt_secret ----------------------------------------------------------
# Usage: prompt_secret <var> <prompt>
# Sets <var> to the user's input (characters hidden).
# Non-TTY: fails.
prompt_secret() {
    local __var="$1"
    local prompt="$2"
    local value

    [[ -t 0 ]] || {
        error 'Interactive secret input requires a TTY.'
        return 1
    }

    read -r -s -p "${prompt}: " value || {
        echo ''
        return 1
    }
    echo ''
    printf -v "$__var" '%s' "${value}"
}

# --- prompt_hidden_secret ---------------------------------------------------
# Usage: prompt_hidden_secret <var> <prompt>
# Same as prompt_secret but additionally masks output.
# Non-TTY: fails.
prompt_hidden_secret() {
    local __var="$1"
    local prompt="$2"
    local value

    [[ -t 0 ]] || {
        error 'Interactive secret input requires a TTY.'
        return 1
    }

    read -r -s -p "${prompt}: " value || {
        echo ''
        return 1
    }
    echo ''
    # TODO: mask output in future phase
    printf -v "$__var" '%s' "${value}"
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
