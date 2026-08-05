#!/usr/bin/env bash
# ------------------------------------------------------------------------------
# certificate.sh — Shared TLS certificate manager for Xray and sing-box
#
# The lifecycle is ported from xrayctl's mature certificate subsystem:
# isolated Certbot, Cloudflare/HTTP/manual-DNS/IP issuance, staged pair sync,
# renewal state tracking, safe deletion, and restart-on-change. Xray-specific
# assumptions are replaced by engine-neutral ProxyCTL adapters.
# ------------------------------------------------------------------------------

certbot_venv()         { printf '%s\n' "${PROXYCTL_CERTBOT_VENV:-/opt/proxyctl/certbot}"; }
certbot_bin()          { printf '%s/bin/certbot\n' "$(certbot_venv)"; }
certbot_config_dir()   { printf '%s\n' "${PROXYCTL_CERTBOT_CONFIG:-/var/lib/proxyctl/letsencrypt/config}"; }
certbot_work_dir()     { printf '%s\n' "${PROXYCTL_CERTBOT_WORK:-/var/lib/proxyctl/letsencrypt/work}"; }
certbot_logs_dir()     { printf '%s\n' "${PROXYCTL_CERTBOT_LOGS:-/var/log/proxyctl/certbot}"; }
cert_cloudflare_file() { printf '%s\n' "${PROXYCTL_CLOUDFLARE_INI:-/etc/proxyctl/cloudflare.ini}"; }
cert_runtime_group()   { printf '%s\n' "${PROXYCTL_CERT_GROUP:-proxyctl-cert}"; }

_cert_require_root() {
    system_is_root && return 0
    error 'Certificate management requires root.'
    return 1
}

cert_validate_identifier() {
    local id="${1:-}"
    [[ -n "$id" && ${#id} -le 253 ]] || return 1
    [[ "$id" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*$ ]] || return 1
    [[ "$id" != *'..'* ]]
}

cert_validate_email() {
    local email="${1:-}"
    [[ "$email" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]]
}

cert_validate_subject() {
    local subject="${1:-}"
    network_validate_ip "$subject" 2>/dev/null || network_validate_domain "$subject" 2>/dev/null
}

_cert_hash_subject() {
    local subject="$1"
    if command -v sha256sum >/dev/null 2>&1; then
        printf '%s' "$subject" | sha256sum | awk '{print substr($1,1,8)}'
    elif command -v openssl >/dev/null 2>&1; then
        printf '%s' "$subject" | openssl dgst -sha256 2>/dev/null | awk '{print substr($NF,1,8)}'
    else
        error 'sha256sum or openssl is required to identify IP certificates.'
        return 1
    fi
}

cert_identifier_for_subject() {
    local subject="${1:-}"
    cert_validate_subject "$subject" || { error "Invalid certificate subject: ${subject}"; return 1; }
    if network_validate_ip "$subject" 2>/dev/null; then
        if [[ "$subject" == *:* ]]; then
            printf 'ip6-%s\n' "$(_cert_hash_subject "$subject")"
        else
            printf 'ip4-%s\n' "$(_cert_hash_subject "$subject")"
        fi
    else
        printf '%s\n' "$(printf '%s' "$subject" | tr '[:upper:]' '[:lower:]')"
    fi
}

cert_dir() {
    local id="${1:-}"
    cert_validate_identifier "$id" || { error "Invalid certificate identifier: ${id}"; return 1; }
    printf '%s/%s\n' "$PROXYCTL_CERTS" "$id"
}

cert_fullchain() { printf '%s/fullchain.pem\n' "$(cert_dir "$1")"; }
cert_privkey()   { printf '%s/privkey.pem\n' "$(cert_dir "$1")"; }

cert_exists() {
    local id="${1:-}" cert key
    cert=$(cert_fullchain "$id") || return 1
    key=$(cert_privkey "$id") || return 1
    metadata_cert_exists "$id" && [[ -f "$cert" && ! -L "$cert" && -f "$key" && ! -L "$key" ]]
}

_cert_group_exists() {
    local group="$1"
    if command -v getent >/dev/null 2>&1; then
        getent group "$group" >/dev/null 2>&1
    else
        grep -q "^${group}:" /etc/group 2>/dev/null
    fi
}

_cert_create_system_group() {
    local group="$1"
    if command -v groupadd >/dev/null 2>&1; then
        groupadd --system "$group"
    elif command -v addgroup >/dev/null 2>&1; then
        addgroup -S "$group"
    else
        error 'No supported system-group creation command is available.'
        return 1
    fi
}

# Certificate copies use root:<proxyctl-cert> 0640. On systemd, installed
# engines receive SupplementaryGroups=proxyctl-cert via a drop-in so the same
# managed pair can be consumed by either engine without world-readable keys.
_cert_setup_runtime_access() {
    _cert_require_root || return 1
    local group engine service dropin changed=0
    group=$(cert_runtime_group)

    _cert_group_exists "$group" || _cert_create_system_group "$group" || return 1
    [[ ! -L "$PROXYCTL_CERTS" ]] || { error "Refusing symlink certificate root: ${PROXYCTL_CERTS}"; return 1; }
    mkdir -p -- "$PROXYCTL_CERTS" || return 1
    chown root:"$group" "$PROXYCTL_CERTS" || return 1
    chmod 750 "$PROXYCTL_CERTS" || return 1

    if [[ "$(system_init 2>/dev/null || true)" == systemd ]]; then
        for engine in xray singbox; do
            engine_call "$engine" installed >/dev/null 2>&1 || continue
            service=$(engine_call "$engine" service_name 2>/dev/null) || continue
            dropin="/etc/systemd/system/${service}.service.d"
            mkdir -p -- "$dropin" || return 1
            cat >"${dropin}/20-proxyctl-certificates.conf" <<EOF
[Service]
SupplementaryGroups=${group}
EOF
            changed=1
        done
        (( changed == 0 )) || systemctl daemon-reload || return 1
    fi
}

_cert_prepare_directory() {
    local id="$1" dir group
    cert_validate_identifier "$id" || return 1
    _cert_setup_runtime_access || return 1
    dir=$(cert_dir "$id") || return 1
    group=$(cert_runtime_group)
    [[ ! -L "$dir" ]] || { error "Refusing symlink certificate directory: ${dir}"; return 1; }
    [[ ! -e "$dir" || -d "$dir" ]] || { error "Certificate path is not a directory: ${dir}"; return 1; }
    mkdir -p -- "$dir" || return 1
    chown root:"$group" "$dir" || return 1
    chmod 750 "$dir" || return 1
}

cert_validate_pair_files() {
    local cert="${1:-}" key="${2:-}"
    command -v openssl >/dev/null 2>&1 || { error 'openssl is required for certificate validation.'; return 1; }
    [[ -r "$cert" && -r "$key" ]] || return 1
    openssl x509 -in "$cert" -noout >/dev/null 2>&1 || return 1
    openssl pkey -in "$key" -noout >/dev/null 2>&1 || return 1
    cmp -s \
        <(openssl x509 -in "$cert" -pubkey -noout 2>/dev/null) \
        <(openssl pkey -in "$key" -pubout 2>/dev/null)
}

# Same safety pattern as xrayctl: compare -> .new -> validate -> .old -> mv;
# if either rename fails, restore both sides to their previous state.
_cert_replace_pair() {
    local id="$1" source_cert="$2" source_key="$3" __changed_var="${4:-}"
    local dir cert_target key_target cert_tmp key_tmp cert_bak key_bak group
    local had_cert=0 had_key=0 need_rollback=0 changed=0

    cert_validate_pair_files "$source_cert" "$source_key" || { error 'Certificate or private key is invalid or mismatched.'; return 1; }
    _cert_prepare_directory "$id" || return 1
    dir=$(cert_dir "$id")
    cert_target="${dir}/fullchain.pem"; key_target="${dir}/privkey.pem"
    group=$(cert_runtime_group)

    [[ ! -L "$cert_target" && ! -L "$key_target" ]] || { error "Refusing symlink certificate files in ${dir}"; return 1; }
    if ! cmp -s "$source_cert" "$cert_target" 2>/dev/null || ! cmp -s "$source_key" "$key_target" 2>/dev/null; then changed=1; fi
    if (( changed == 0 )); then
        [[ -n "$__changed_var" ]] && printf -v "$__changed_var" '%s' 0
        return 0
    fi

    cert_tmp=$(mktemp "${dir}/.fullchain.new.XXXXXX") || return 1
    key_tmp=$(mktemp "${dir}/.privkey.new.XXXXXX") || { rm -f -- "$cert_tmp"; return 1; }
    cert_bak="${dir}/.fullchain.old"; key_bak="${dir}/.privkey.old"

    install -m 640 "$source_cert" "$cert_tmp" || { rm -f -- "$cert_tmp" "$key_tmp"; return 1; }
    install -m 640 "$source_key" "$key_tmp" || { rm -f -- "$cert_tmp" "$key_tmp"; return 1; }
    if system_is_root; then
        chown root:"$group" "$cert_tmp" "$key_tmp" || { rm -f -- "$cert_tmp" "$key_tmp"; return 1; }
    fi
    cert_validate_pair_files "$cert_tmp" "$key_tmp" || { rm -f -- "$cert_tmp" "$key_tmp"; error 'Staged certificate pair failed validation.'; return 1; }

    rm -f -- "$cert_bak" "$key_bak"
    if [[ -f "$cert_target" ]]; then had_cert=1; cp -a -- "$cert_target" "$cert_bak" || { rm -f -- "$cert_tmp" "$key_tmp"; return 1; }; fi
    if [[ -f "$key_target" ]]; then
        had_key=1
        cp -a -- "$key_target" "$key_bak" || { rm -f -- "$cert_tmp" "$key_tmp" "$cert_bak"; return 1; }
    fi

    mv -f -- "$cert_tmp" "$cert_target" || need_rollback=1
    mv -f -- "$key_tmp" "$key_target" || need_rollback=1
    if (( need_rollback == 1 )); then
        rm -f -- "$cert_tmp" "$key_tmp"
        if (( had_cert )); then mv -f -- "$cert_bak" "$cert_target" || true; else rm -f -- "$cert_target"; fi
        if (( had_key )); then mv -f -- "$key_bak" "$key_target" || true; else rm -f -- "$key_target"; fi
        critical "Certificate replacement failed for ${id}; previous state was restored where possible."
        return 1
    fi
    rm -f -- "$cert_bak" "$key_bak"
    [[ -n "$__changed_var" ]] && printf -v "$__changed_var" '%s' 1
}

# Engine-neutral consumer detection: exact managed paths are searched in each
# real engine config, so this layer does not know Xray/sing-box TLS JSON shape.
cert_consumers() {
    local id="$1" cert key engine config
    cert=$(cert_fullchain "$id") || return 1
    key=$(cert_privkey "$id") || return 1
    for engine in xray singbox; do
        config=$(engine_call "$engine" config_file 2>/dev/null || true)
        [[ -n "$config" && -r "$config" ]] || continue
        if grep -Fq -- "$cert" "$config" 2>/dev/null || grep -Fq -- "$key" "$config" 2>/dev/null; then
            printf '%s\n' "$engine"
        fi
    done
}

_cert_restart_consumers_if_changed() {
    local id="$1" changed="$2" engine rc=0
    (( changed == 1 )) || return 0
    while IFS= read -r engine; do
        [[ -n "$engine" ]] || continue
        engine_call "$engine" is_active >/dev/null 2>&1 || continue
        if engine_call "$engine" restart; then
            info "${engine} restarted to load the updated certificate."
        else
            warn "Certificate updated, but ${engine} failed to restart."
            rc=1
        fi
    done < <(cert_consumers "$id")
    return "$rc"
}

_cert_python_bin() {
    if command -v python3 >/dev/null 2>&1; then command -v python3
    elif command -v python >/dev/null 2>&1; then command -v python
    else return 1
    fi
}

_cert_install_python_environment() {
    local pm
    pm=$(system_package_manager) || return 1
    case "$pm" in
        apt) package_install python3 python3-venv ;;
        apk) package_install python3 py3-pip py3-virtualenv ;;
        dnf|yum) package_install python3 python3-pip ;;
        pacman) package_install python python-pip ;;
        *) error "Unsupported package manager for Certbot: ${pm}"; return 1 ;;
    esac
}

cert_ensure_certbot_environment() {
    _cert_require_root || return 1
    local venv bin config work logs python need_install=0
    venv=$(certbot_venv); bin=$(certbot_bin)
    config=$(certbot_config_dir); work=$(certbot_work_dir); logs=$(certbot_logs_dir)

    if [[ ! -x "$bin" ]]; then need_install=1
    elif ! "$bin" --help all 2>/dev/null | grep -q -- '--ip-address'; then need_install=1
    elif ! "${venv}/bin/python" -c 'import certbot_dns_cloudflare' >/dev/null 2>&1; then need_install=1
    elif ! "${venv}/bin/python" -c 'import certbot_nginx' >/dev/null 2>&1; then need_install=1
    fi

    if (( need_install == 1 )); then
        python=$(_cert_python_bin 2>/dev/null || true)
        if [[ -z "$python" ]]; then
            _cert_install_python_environment || return 1
            python=$(_cert_python_bin) || { error 'Python installation failed.'; return 1; }
        fi
        install -d -m 755 "$(dirname "$venv")" || return 1
        if [[ ! -x "${venv}/bin/python" ]]; then
            if ! "$python" -m venv "$venv"; then
                _cert_install_python_environment || return 1
                python=$(_cert_python_bin) || return 1
                "$python" -m venv "$venv" || { error 'Unable to create the isolated Certbot virtual environment.'; return 1; }
            fi
        fi
        if [[ ! -x "${venv}/bin/pip" ]]; then
            "${venv}/bin/python" -m ensurepip --upgrade >/dev/null 2>&1 || { error 'Unable to bootstrap pip in the Certbot virtual environment.'; return 1; }
        fi
        info 'Installing/updating Certbot and certificate plugins.'
        "${venv}/bin/pip" install --disable-pip-version-check --timeout 15 --retries 2 \
            --upgrade 'certbot>=5.4' certbot-dns-cloudflare certbot-nginx || { error 'Certbot or certificate plugin installation failed.'; return 1; }
        "$bin" --help all 2>/dev/null | grep -q -- '--ip-address' || { error 'Installed Certbot does not support IP certificates.'; return 1; }
        "${venv}/bin/python" -c 'import certbot_dns_cloudflare, certbot_nginx' >/dev/null 2>&1 || { error 'Certbot plugins failed their import check.'; return 1; }
    fi

    mkdir -p -- "$config" "$work" "$logs" || return 1
    chmod 700 "$config" "$work" "$logs" || return 1
}

certbot_cmd() {
    "$(certbot_bin)" \
        --config-dir "$(certbot_config_dir)" \
        --work-dir "$(certbot_work_dir)" \
        --logs-dir "$(certbot_logs_dir)" \
        "$@"
}

cert_cloudflare_credentials_available() {
    local file
    file=$(cert_cloudflare_file)
    [[ -f "$file" && ! -L "$file" && -r "$file" ]] || return 1
    grep -q '^dns_cloudflare_api_key[[:space:]]*=' "$file" 2>/dev/null
}

_cert_save_cloudflare_credentials_locked() {
    local email="$1" api_key="$2" file dir tmp
    cert_validate_email "$email" || { error "Invalid Cloudflare email: ${email}"; return 1; }
    [[ -n "$api_key" ]] || { error 'Cloudflare API key must not be empty.'; return 1; }
    _cert_require_root || return 1
    file=$(cert_cloudflare_file); dir=$(dirname "$file")
    [[ ! -L "$file" ]] || { error "Refusing symlink Cloudflare credential file: ${file}"; return 1; }
    mkdir -p -- "$dir" || return 1
    chmod 700 "$dir" 2>/dev/null || true
    tmp=$(mktemp "${dir}/.cloudflare.ini.XXXXXX") || return 1
    if ! ( umask 077; printf '%s\n' "dns_cloudflare_email = ${email}" "dns_cloudflare_api_key = ${api_key}" >"$tmp" ); then
        rm -f -- "$tmp"; return 1
    fi
    chmod 600 "$tmp" || { rm -f -- "$tmp"; return 1; }
    mv -f -- "$tmp" "$file"
}

cert_save_cloudflare_credentials() {
    with_lock cert _cert_save_cloudflare_credentials_locked "${1:-}" "${2:-}"
}

_cert_delete_cloudflare_credentials_locked() {
    local file
    file=$(cert_cloudflare_file)
    [[ ! -L "$file" ]] || { error "Refusing symlink Cloudflare credential file: ${file}"; return 1; }
    rm -f -- "$file"
}
cert_delete_cloudflare_credentials() { with_lock cert _cert_delete_cloudflare_credentials_locked; }

cert_detect_port80_owner() {
    local out rc names
    if out=$(port_process 80 tcp 2>/dev/null); then :
    else
        rc=$?
        (( rc == 1 )) && { printf '%s\n' free; return 0; }
        printf '%s\n' unknown; return 0
    fi
    [[ "$out" != unknown ]] || { printf '%s\n' unknown; return 0; }
    names=$(printf '%s\n' "$out" | awk '{print $2}' | sort -u)
    [[ "$(printf '%s\n' "$names" | grep -c .)" -eq 1 ]] || { printf '%s\n' other; return 0; }
    case "$names" in
        xray) printf '%s\n' xray ;;
        sing-box|singbox) printf '%s\n' singbox ;;
        nginx) printf '%s\n' nginx ;;
        httpd|apache2) printf '%s\n' apache ;;
        *) printf '%s\n' other ;;
    esac
}

_cert_run_http_with_engine() {
    local engine="$1" was_active=0 rc=0 restore_rc=0
    shift
    if engine_call "$engine" is_active >/dev/null 2>&1; then
        was_active=1
        engine_call "$engine" stop || return 1
    else
        error "Port 80 belongs to ${engine}, but its managed service is not active; refusing to stop an unknown process."
        return 1
    fi
    "$@" || rc=$?
    if (( was_active )); then engine_call "$engine" start || restore_rc=$?; fi
    if (( restore_rc != 0 )); then
        critical "Certificate operation finished, but ${engine} could not be restored. Manual intervention required."
        return 1
    fi
    return "$rc"
}

_cert_issue_domain_cloudflare() {
    local domain="$1" email="$2" force="$3" file args
    file=$(cert_cloudflare_file)
    cert_cloudflare_credentials_available || { error 'Cloudflare credentials are not configured.'; return 1; }
    args=(certonly --dns-cloudflare --dns-cloudflare-credentials "$file" --non-interactive --agree-tos --cert-name "$domain" -m "$email" -d "$domain")
    (( force == 0 )) || args+=(--force-renewal)
    certbot_cmd "${args[@]}"
}

_cert_issue_domain_http() {
    local domain="$1" email="$2" force="$3" owner args
    owner=$(cert_detect_port80_owner)
    args=(certonly --standalone --non-interactive --agree-tos --preferred-challenges http --cert-name "$domain" -m "$email" -d "$domain")
    (( force == 0 )) || args+=(--force-renewal)
    case "$owner" in
        free) certbot_cmd "${args[@]}" ;;
        xray|singbox) _cert_run_http_with_engine "$owner" certbot_cmd "${args[@]}" ;;
        nginx)
            args=(certonly --nginx --non-interactive --agree-tos --cert-name "$domain" -m "$email" -d "$domain")
            (( force == 0 )) || args+=(--force-renewal)
            certbot_cmd "${args[@]}"
            ;;
        apache) error 'Port 80 is owned by Apache; use Cloudflare DNS or manual DNS.'; return 1 ;;
        *) error 'Port 80 is occupied by an unknown process; refusing to stop it. Use DNS validation.'; return 1 ;;
    esac
}

_cert_issue_manual_dns() {
    local domain="$1" email="$2" force="$3" args
    args=(certonly --manual --agree-tos -m "$email" --preferred-challenges dns --cert-name "$domain" -d "$domain")
    (( force == 0 )) || args+=(--force-renewal)
    info 'Certbot will prompt for the required DNS TXT record.'
    certbot_cmd "${args[@]}"
}

_cert_issue_ip() {
    local ip="$1" email="$2" identifier="$3" force="$4" owner args
    owner=$(cert_detect_port80_owner)
    args=(certonly --standalone --non-interactive --agree-tos --preferred-challenges http \
        --cert-name "$identifier" -m "$email" --preferred-profile shortlived --ip-address "$ip")
    (( force == 0 )) || args+=(--force-renewal)
    case "$owner" in
        free) certbot_cmd "${args[@]}" ;;
        xray|singbox) _cert_run_http_with_engine "$owner" certbot_cmd "${args[@]}" ;;
        *) error 'IP certificates require HTTP validation and port 80 is unavailable.'; return 1 ;;
    esac
}

_cert_sync_lineage() {
    local identifier="$1" cert_name="$2" __changed_var="${3:-}" source_cert source_key
    source_cert="$(certbot_config_dir)/live/${cert_name}/fullchain.pem"
    source_key="$(certbot_config_dir)/live/${cert_name}/privkey.pem"
    [[ -r "$source_cert" ]] || { error "Cannot read Certbot certificate: ${source_cert}"; return 1; }
    [[ -r "$source_key" ]] || { error "Cannot read Certbot private key: ${source_key}"; return 1; }
    _cert_replace_pair "$identifier" "$source_cert" "$source_key" "$__changed_var"
}

cert_setup_renewal_timer() {
    _cert_require_root || return 1
    [[ "$(system_init 2>/dev/null || true)" == systemd ]] || {
        warn 'Automatic certificate timer is currently available only on systemd; use proxyctl cert renew-auto manually.'
        return 0
    }
    [[ -x "$PROXYCTL_BIN" ]] || {
        warn "ProxyCTL is not installed at ${PROXYCTL_BIN}; renewal timer was not enabled."
        return 0
    }
    cat >/etc/systemd/system/proxyctl-certbot-renew.service <<EOF
[Unit]
Description=Renew certificates managed by ProxyCTL

[Service]
Type=oneshot
ExecStart=${PROXYCTL_BIN} cert renew-auto
EOF
    cat >/etc/systemd/system/proxyctl-certbot-renew.timer <<'EOF'
[Unit]
Description=Renew certificates managed by ProxyCTL

[Timer]
OnCalendar=*-*-* 00,12:00:00
RandomizedDelaySec=1h
Persistent=true

[Install]
WantedBy=timers.target
EOF
    systemctl daemon-reload || return 1
    systemctl enable --now proxyctl-certbot-renew.timer >/dev/null
}

_cert_acme_issue_locked() {
    local subject="$1" email="$2" method="${3:-http}" force="${4:-0}"
    local identifier cert_name validation auto_renew=true changed=0
    _cert_require_root || return 1
    cert_validate_subject "$subject" || { error "Invalid certificate subject: ${subject}"; return 1; }
    cert_validate_email "$email" || { error "Invalid certificate email: ${email}"; return 1; }
    [[ "$force" == 0 || "$force" == 1 ]] || { error 'force must be 0 or 1.'; return 1; }

    identifier=$(cert_identifier_for_subject "$subject") || return 1
    cert_name="$identifier"
    if network_validate_ip "$subject" 2>/dev/null; then method=ip
    else cert_name=$(printf '%s' "$subject" | tr '[:upper:]' '[:lower:]'); fi

    if cert_exists "$identifier" && (( force == 0 )); then
        error "Certificate already exists: ${identifier}. Re-run with force=1 to reissue it."
        return 1
    fi
    cert_ensure_certbot_environment || return 1

    case "$method" in
        dns-cloudflare)
            network_validate_ip "$subject" 2>/dev/null && { error 'Cloudflare DNS validation is for domain certificates only.'; return 1; }
            validation=dns-cloudflare
            _cert_issue_domain_cloudflare "$cert_name" "$email" "$force" || return 1
            ;;
        http)
            validation=http-standalone
            [[ "$(cert_detect_port80_owner)" != nginx ]] || validation=http-nginx
            _cert_issue_domain_http "$cert_name" "$email" "$force" || return 1
            ;;
        dns-manual)
            network_validate_ip "$subject" 2>/dev/null && { error 'Manual DNS validation is for domain certificates only.'; return 1; }
            validation=dns-manual; auto_renew=false
            _cert_issue_manual_dns "$cert_name" "$email" "$force" || return 1
            ;;
        ip)
            network_validate_ip "$subject" 2>/dev/null || { error 'IP validation mode requires an IP address.'; return 1; }
            validation=http-standalone
            _cert_issue_ip "$subject" "$email" "$identifier" "$force" || return 1
            ;;
        *) error "Unknown certificate validation method: ${method}"; return 1 ;;
    esac

    _cert_sync_lineage "$identifier" "$cert_name" changed || {
        error "Let's Encrypt issued the certificate, but syncing the managed copy failed. Certbot lineage remains under $(certbot_config_dir)."
        return 1
    }
    metadata_cert_set "$identifier" "$subject" "$cert_name" letsencrypt "$validation" "$auto_renew" || return 1
    [[ "$auto_renew" != true ]] || cert_setup_renewal_timer || return 1
    _cert_restart_consumers_if_changed "$identifier" "$changed" || return 1
    info "Certificate issued and managed: ${identifier}"
}

# Compatibility with the original ProxyCTL API.
# cert_acme_issue SUBJECT EMAIL [http|dns-cloudflare|dns-manual] [force=0|1]
cert_acme_issue() {
    with_lock cert _cert_acme_issue_locked "${1:-}" "${2:-}" "${3:-http}" "${4:-0}"
}

_cert_generate_self_locked() {
    local subject="$1" identifier tmpdir cert key san changed=0
    _cert_require_root || return 1
    cert_validate_subject "$subject" || { error "Invalid certificate subject: ${subject}"; return 1; }
    command -v openssl >/dev/null 2>&1 || { error 'openssl is required.'; return 1; }
    identifier=$(cert_identifier_for_subject "$subject") || return 1
    metadata_cert_exists "$identifier" && { error "Certificate already exists: ${identifier}"; return 1; }
    tmpdir=$(mktemp -d) || return 1
    cert="${tmpdir}/fullchain.pem"; key="${tmpdir}/privkey.pem"
    if network_validate_ip "$subject" 2>/dev/null; then san="IP:${subject}"; else san="DNS:${subject}"; fi
    if ! openssl req -x509 -newkey rsa:2048 -nodes -days 365 -subj "/CN=${subject}" -addext "subjectAltName=${san}" \
        -keyout "$key" -out "$cert" >/dev/null 2>&1; then
        rm -rf -- "$tmpdir"; error 'Self-signed certificate generation failed.'; return 1
    fi
    _cert_replace_pair "$identifier" "$cert" "$key" changed || { rm -rf -- "$tmpdir"; return 1; }
    rm -rf -- "$tmpdir"
    metadata_cert_set "$identifier" "$subject" "$identifier" self-signed local false || return 1
    _cert_restart_consumers_if_changed "$identifier" "$changed" || return 1
    info "Self-signed certificate generated: ${identifier}"
}
cert_generate_self() { with_lock cert _cert_generate_self_locked "${1:-}"; }

_cert_import_locked() {
    local identifier="$1" source_cert="$2" source_key="$3" changed=0
    _cert_require_root || return 1
    cert_validate_identifier "$identifier" || { error "Invalid certificate identifier: ${identifier}"; return 1; }
    [[ -f "$source_cert" && ! -L "$source_cert" && -r "$source_cert" ]] || { error 'Certificate source is unavailable or unsafe.'; return 1; }
    [[ -f "$source_key" && ! -L "$source_key" && -r "$source_key" ]] || { error 'Private-key source is unavailable or unsafe.'; return 1; }
    _cert_replace_pair "$identifier" "$source_cert" "$source_key" changed || return 1
    metadata_cert_set "$identifier" "$identifier" "$identifier" imported imported false || return 1
    _cert_restart_consumers_if_changed "$identifier" "$changed" || return 1
    info "Certificate imported: ${identifier}"
}
cert_import() { with_lock cert _cert_import_locked "${1:-}" "${2:-}" "${3:-}"; }

cert_info() {
    local identifier="${1:-}" cert subject cert_name source validation auto_renew updated
    cert_validate_identifier "$identifier" || { error "Invalid certificate identifier: ${identifier}"; return 1; }
    metadata_cert_exists "$identifier" || { error "Certificate is not managed: ${identifier}"; return 1; }
    cert=$(cert_fullchain "$identifier")
    subject=$(metadata_cert_get_field "$identifier" subject)
    cert_name=$(metadata_cert_get_field "$identifier" certName)
    source=$(metadata_cert_get_field "$identifier" source)
    validation=$(metadata_cert_get_field "$identifier" validation)
    auto_renew=$(metadata_cert_get_field "$identifier" autoRenew)
    updated=$(metadata_cert_get_field "$identifier" updatedAt)
    printf 'Identifier: %s\nSubject: %s\nCertbot name: %s\nSource: %s\nValidation: %s\nAuto renew: %s\nUpdated: %s\n' \
        "$identifier" "$subject" "$cert_name" "$source" "$validation" "$auto_renew" "$updated"
    printf 'Full chain: %s\nPrivate key: %s\n' "$(cert_fullchain "$identifier")" "$(cert_privkey "$identifier")"
    [[ ! -r "$cert" ]] || openssl x509 -in "$cert" -noout -subject -issuer -dates 2>/dev/null
}

cert_list() {
    local id
    while IFS= read -r id; do
        [[ -n "$id" ]] || continue
        printf '%s\t%s\t%s\t%s\n' "$id" \
            "$(metadata_cert_get_field "$id" subject)" \
            "$(metadata_cert_get_field "$id" source)" \
            "$(metadata_cert_get_field "$id" validation)"
    done < <(metadata_cert_list)
}
cert_count() { metadata_cert_list | grep -c . 2>/dev/null || printf '%s\n' 0; }

_cert_renew_one_locked() {
    local identifier="$1" __result_var="${2:-}" cert_name validation source owner service
    local before_serial='' after_serial='' result=failed sync_changed=0 lineage_changed=0 live_cert args
    metadata_cert_exists "$identifier" || { error "Certificate is not managed: ${identifier}"; return 1; }
    source=$(metadata_cert_get_field "$identifier" source)
    if [[ "$source" != letsencrypt ]]; then
        warn "${identifier}: certificate source '${source}' is not renewable by Certbot."
        [[ -n "$__result_var" ]] && printf -v "$__result_var" '%s' blocked
        return 0
    fi
    cert_name=$(metadata_cert_get_field "$identifier" certName)
    validation=$(metadata_cert_get_field "$identifier" validation)
    [[ -n "$cert_name" ]] || { error "Certificate metadata has no certName: ${identifier}"; return 1; }

    case "$validation" in
        dns-cloudflare)
            cert_cloudflare_credentials_available || {
                warn "${identifier}: Cloudflare credentials are missing; renewal is blocked."
                [[ -n "$__result_var" ]] && printf -v "$__result_var" '%s' blocked; return 0
            }
            ;;
        dns-manual)
            warn "${identifier}: manual DNS certificates cannot renew automatically."
            [[ -n "$__result_var" ]] && printf -v "$__result_var" '%s' blocked; return 0
            ;;
        http-standalone)
            owner=$(cert_detect_port80_owner)
            case "$owner" in
                free) ;;
                xray|singbox)
                    [[ "$(system_init 2>/dev/null || true)" == systemd ]] || {
                        warn "${identifier}: port 80 is owned by ${owner}; automatic hooks require systemd."
                        [[ -n "$__result_var" ]] && printf -v "$__result_var" '%s' blocked; return 0
                    }
                    ;;
                *)
                    warn "${identifier}: port 80 is occupied by ${owner}; renewal is blocked."
                    [[ -n "$__result_var" ]] && printf -v "$__result_var" '%s' blocked; return 0
                    ;;
            esac
            ;;
        http-nginx) ;;
    esac

    cert_ensure_certbot_environment || return 1
    args=(renew --cert-name "$cert_name" --quiet)
    if [[ "$validation" == http-standalone ]]; then
        owner=$(cert_detect_port80_owner)
        if [[ "$owner" == xray || "$owner" == singbox ]]; then
            service=$(engine_call "$owner" service_name) || return 1
            args+=(--pre-hook "systemctl stop ${service}" --post-hook "systemctl start ${service}")
        fi
    fi

    live_cert="$(certbot_config_dir)/live/${cert_name}/fullchain.pem"
    [[ ! -r "$live_cert" ]] || before_serial=$(openssl x509 -in "$live_cert" -noout -serial 2>/dev/null || true)
    if ! certbot_cmd "${args[@]}"; then
        warn "Certificate renewal failed: ${identifier}"
        [[ -n "$__result_var" ]] && printf -v "$__result_var" '%s' failed
        return 1
    fi
    [[ ! -r "$live_cert" ]] || after_serial=$(openssl x509 -in "$live_cert" -noout -serial 2>/dev/null || true)
    [[ -z "$before_serial" || -z "$after_serial" || "$before_serial" == "$after_serial" ]] || lineage_changed=1

    _cert_sync_lineage "$identifier" "$cert_name" sync_changed || {
        warn "Certbot renewal succeeded, but syncing the managed certificate failed: ${identifier}"
        [[ -n "$__result_var" ]] && printf -v "$__result_var" '%s' failed; return 1
    }
    _cert_restart_consumers_if_changed "$identifier" "$sync_changed" || {
        [[ -n "$__result_var" ]] && printf -v "$__result_var" '%s' failed; return 1
    }
    (( lineage_changed == 1 )) && result=renewed || result=unchanged
    [[ -n "$__result_var" ]] && printf -v "$__result_var" '%s' "$result"
}

_cert_renew_one_command_locked() {
    local identifier="$1" result=''
    _cert_renew_one_locked "$identifier" result || return 1
    case "$result" in
        renewed) info "${identifier}: renewed." ;;
        unchanged) info "${identifier}: renewal not required." ;;
        blocked) warn "${identifier}: automatic renewal is blocked." ;;
        *) return 1 ;;
    esac
}
cert_renew() { with_lock cert _cert_renew_one_command_locked "${1:-}"; }

_cert_renew_all_locked() {
    local id result renewed=0 unchanged=0 blocked=0 failed=0
    while IFS= read -r id; do
        [[ -n "$id" ]] || continue
        result=''
        if ! _cert_renew_one_locked "$id" result; then [[ -n "$result" ]] || result=failed; fi
        case "$result" in
            renewed) ((renewed+=1)) ;;
            unchanged) ((unchanged+=1)) ;;
            blocked) ((blocked+=1)) ;;
            *) ((failed+=1)) ;;
        esac
    done < <(metadata_cert_auto_renew_list)
    printf 'renewed=%d unchanged=%d blocked=%d failed=%d\n' "$renewed" "$unchanged" "$blocked" "$failed"
    (( failed == 0 ))
}
cert_renew_all() { with_lock cert _cert_renew_all_locked; }

_cert_delete_locked() {
    local identifier="$1" consumers cert_name source dir renewal
    _cert_require_root || return 1
    cert_validate_identifier "$identifier" || { error "Invalid certificate identifier: ${identifier}"; return 1; }
    metadata_cert_exists "$identifier" || { error "Certificate is not managed: ${identifier}"; return 1; }
    consumers=$(cert_consumers "$identifier")
    [[ -z "$consumers" ]] || { error "Certificate ${identifier} is still referenced by: $(printf '%s' "$consumers" | paste -sd ',')"; return 1; }

    cert_name=$(metadata_cert_get_field "$identifier" certName)
    source=$(metadata_cert_get_field "$identifier" source)
    if [[ "$source" == letsencrypt && -n "$cert_name" ]]; then
        renewal="$(certbot_config_dir)/renewal/${cert_name}.conf"
        if [[ -f "$renewal" ]]; then
            cert_ensure_certbot_environment || return 1
            certbot_cmd delete --cert-name "$cert_name" --non-interactive || return 1
        fi
    fi
    dir=$(cert_dir "$identifier") || return 1
    [[ ! -L "$dir" ]] || { error "Refusing symlink certificate directory: ${dir}"; return 1; }
    rm -rf -- "$dir" || return 1
    metadata_cert_delete "$identifier"
}
cert_delete() { with_lock cert _cert_delete_locked "${1:-}"; }
