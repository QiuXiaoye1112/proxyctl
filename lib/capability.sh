#!/usr/bin/env bash
# ------------------------------------------------------------------------------
# capability.sh — V1 protocol and transport capability definitions
# ------------------------------------------------------------------------------

# --- capability data --------------------------------------------------------
# Format:
#   _CAP_PROTOCOLS_<engine> = array of protocol names
#   _CAP_TRANSPORTS_<engine>__<protocol> = array of transport names (or empty)
# ---------------------------------------------------------------------------

declare -a _CAP_PROTOCOLS_XRAY
_CAP_PROTOCOLS_XRAY=(
    VLESS
    VMess
    Trojan
    SOCKS5
    HTTP
)

declare -a _CAP_PROTOCOLS_SINGBOX
_CAP_PROTOCOLS_SINGBOX=(
    AnyTLS
    VLESS
    Hysteria2
    Trojan
    SOCKS5
    HTTP
)

# --- Xray transports --------------------------------------------------------
declare -a _CAP_TRANSPORTS_XRAY__VLESS
_CAP_TRANSPORTS_XRAY__VLESS=(RAW XHTTP WebSocket)

declare -a _CAP_TRANSPORTS_XRAY__VMESS
_CAP_TRANSPORTS_XRAY__VMESS=(RAW WebSocket)

declare -a _CAP_TRANSPORTS_XRAY__TROJAN
_CAP_TRANSPORTS_XRAY__TROJAN=(RAW WebSocket)

declare -a _CAP_TRANSPORTS_XRAY__SOCKS5
_CAP_TRANSPORTS_XRAY__SOCKS5=()

declare -a _CAP_TRANSPORTS_XRAY__HTTP
_CAP_TRANSPORTS_XRAY__HTTP=()

# --- sing-box transports ----------------------------------------------------
declare -a _CAP_TRANSPORTS_SINGBOX__VLESS
_CAP_TRANSPORTS_SINGBOX__VLESS=(RAW WebSocket)

declare -a _CAP_TRANSPORTS_SINGBOX__TROJAN
_CAP_TRANSPORTS_SINGBOX__TROJAN=(RAW WebSocket)

declare -a _CAP_TRANSPORTS_SINGBOX__ANYTLS
_CAP_TRANSPORTS_SINGBOX__ANYTLS=()

declare -a _CAP_TRANSPORTS_SINGBOX__HYSTERIA2
_CAP_TRANSPORTS_SINGBOX__HYSTERIA2=()

declare -a _CAP_TRANSPORTS_SINGBOX__SOCKS5
_CAP_TRANSPORTS_SINGBOX__SOCKS5=()

declare -a _CAP_TRANSPORTS_SINGBOX__HTTP
_CAP_TRANSPORTS_SINGBOX__HTTP=()

# --- _capability_protocols --------------------------------------------------
_capability_protocols() {
    local engine="$1"
    local upper
    upper=$(printf '%s' "${engine}" | tr '[:lower:]' '[:upper:]')
    local var="_CAP_PROTOCOLS_${upper}"
    eval "printf '%s\n' \"\${${var}[@]}\""
}

# --- _capability_transports -------------------------------------------------
_capability_transports() {
    local engine="$1"
    local protocol="$2"

    local upper_eng
    upper_eng=$(printf '%s' "${engine}" | tr '[:lower:]' '[:upper:]')
    local upper_proto
    upper_proto=$(printf '%s' "${protocol}" | tr '[:lower:]' '[:upper:]')

    local var="_CAP_TRANSPORTS_${upper_eng}__${upper_proto}"

    eval "printf '%s\n' \"\${${var}[@]:-}\""
}

# --- capability_has_transports ----------------------------------------------
capability_has_transports() {
    local engine="$1"
    local protocol="$2"
    local transports
    transports=$(_capability_transports "${engine}" "${protocol}")
    [[ -n "${transports}" ]]
}
