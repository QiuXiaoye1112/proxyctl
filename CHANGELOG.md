# Changelog

## [0.2.5] — Unreleased

### Added

- shared certificate manager in `lib/common/certificate.sh`, ported from the
  mature xrayctl certificate lifecycle and adapted for both Xray and sing-box
- isolated Certbot environment under `/opt/proxyctl/certbot` with dedicated
  config/work/log state under ProxyCTL paths; system `/etc/letsencrypt` is not
  used
- ACME issuance for domains via Cloudflare DNS, HTTP standalone, nginx, or
  manual DNS, plus Certbot short-lived IP certificates
- port-80 ownership handling for `free` / Xray / sing-box / nginx / Apache /
  unknown processes; only managed Xray/sing-box services may be stopped and
  restored automatically, while unknown owners are never killed
- shared managed certificate layout:
  `/etc/proxyctl/certs/<identifier>/fullchain.pem` + `privkey.pem`
- staged certificate-pair synchronization inherited from xrayctl: compare,
  stage, OpenSSL pair validation, old-pair backup, two-file replacement, and
  rollback when replacement fails
- certificate metadata helpers preserving the distinction between ProxyCTL
  `identifier` and Certbot lineage `certName`
- certificate source/validation/auto-renew metadata, list/info/path APIs,
  import, self-signed generation, safe deletion, single-certificate renewal,
  and bulk auto-renewal
- renewal result states `renewed` / `unchanged` / `blocked` / `failed`, with
  blocked renewal for missing Cloudflare credentials, manual DNS, unsupported
  port-80 ownership, or non-systemd engine pre/post hooks
- systemd `proxyctl-certbot-renew.timer` + service, running
  `proxyctl cert renew-auto` twice daily with randomized delay
- `proxyctl-cert` supplementary group and systemd engine drop-ins so Xray and
  sing-box can share non-world-readable managed private keys
- engine-neutral consumer detection: an updated certificate restarts only
  active engines whose real config references that managed certificate path
- `proxyctl cert` CLI: list/info/paths/issue/self/import/renew/renew-auto/delete
  and interactive Cloudflare credential configuration
- `tests/certificate.sh`: local OpenSSL fixtures, pair mismatch/rollback safety,
  symlink protection, metadata `certName`, credential permission/umask checks,
  port-80 ownership, Xray/sing-box stop/restore, isolated Certbot args, shared
  dual-engine consumer restart, delete protection, and real cert-lock contention

### Security

- certificate identifiers reject path traversal and path separators
- managed certificate roots/directories/files reject symlink targets before
  replacement or deletion
- certificate/private-key public keys must match before installation
- Cloudflare credentials are atomically written mode 600 without changing the
  caller's process umask
- Certbot state is fully isolated from system Certbot state
- private keys are mode 640 and restricted to root + `proxyctl-cert`; installed
  systemd engine services receive that supplementary group

### Changed

- version: 0.2.4 → 0.2.5
- certificate management moved from Planned to Implemented
- Phase 2.6 follows xrayctl's existing certificate behavior instead of creating
  a second independent design

## [0.2.4] — Unreleased

### Added

- `apply_candidate <engine> <candidate>` (in `lib/transaction.sh`): safe config
  apply for Xray / sing-box — config lock → candidate checks → real core
  validation → backup → same-directory temp + atomic rename → restart +
  health check → commit, or rollback on any failure
- real engine validation adapters: `engine_xray_validate` runs
  `xray run -test -config FILE`; `engine_singbox_validate` runs
  `sing-box check -c FILE` (no JSON-only fallback; core missing or non-zero
  validation fails closed)
- rollback lifecycle: previous config restored atomically (`cp -a` backup kept
  in the transaction directory), newly applied config removed when there was
  no previous config, and the service restarted only if it was running before
- inactive-service semantics: validate + replace only — the service is never
  started just because a config was applied
- `[CRITICAL]` message when a rollback restores the config but cannot restart
  the service (manual intervention required), via new `critical()` in `ui.sh`
- permission preservation: a replacement keeps the previous file's mode
  (owner/group best-effort); new configs default to mode 600
- symlink candidates are rejected; config parent must be a real (non-symlink)
  absolute directory; the config path always comes from
  `engine_call <engine> config_file`
- per-module suite `tests/transaction.sh`: fully mocked `engine_call` recording
  call order (config_file → validate → is_active → restart → is_active), real
  flock lock-contention coverage, atomic-replace failure injection, permission
  preservation, symlink/unknown-engine rejection, and engine CLI arg checks
- smoke: light `apply_candidate` contract (missing candidate, unknown engine)

### Changed

- version: 0.2.3 → 0.2.4
- `apply_candidate` stub removed from `core.sh`; the real implementation lives
  in `lib/transaction.sh` and no longer dies on unknown engines (returns 1)
- README: config apply transactions moved from Planned to Implemented

## [0.2.3] — Unreleased

### Added

- `lib/common/lock.sh`: flock-backed process locking with three logical locks
  (`config`/`cert`/`firewall`) mapped to fixed lock files and fixed fds
  (200/201/202 — Bash 4.0 compatible, no `exec {fd}>`)
- public API: `lock_path`, `lock_acquire`, `lock_release`, `lock_is_held`,
  `with_lock`; internal `lock_fd`, `_lock_require_flock`, `_lock_is_available`
- non-blocking acquire (`flock -n`) with per-lock busy messages; duplicate
  acquire and release are idempotent per process
- `with_lock` passes arguments verbatim (`"$@"`, never eval), preserves the
  command's exit code, and does not release a lock the caller already held
- kernel-enforced auto-release on process exit (normal, crash, or SIGKILL);
  lock files are never deleted and their existence is not a lock
- per-module suites `tests/lock.sh` and `tests/lock_security.sh`: real-flock
  contention/ownership coverage plus lock-path hardening regressions
- smoke test: light `lock_path` contract checks (config/cert/firewall mapping,
  unknown-name rejection)

### Fixed

- removed Bash 4.2-only `declare -g`; lock state now uses Bash 4.0-compatible
  top-level associative arrays
- moved default lock files from the shared `/run/lock` directory into the
  dedicated `/run/proxyctl/` runtime directory
- lock setup now rejects symlink parents/files, non-regular lock paths,
  foreign-owned paths, and group/world-writable lock directories before open
- lock fds are opened append-only so acquiring an existing regular lock file
  never truncates it
- duplicate acquire checks current-process ownership before checking for the
  `flock` executable, preserving true idempotent semantics

### Changed

- version: 0.2.2 → 0.2.3
- README: process locking moved from Planned to Implemented; lock semantics,
  secure runtime directory, and lock paths documented

## [0.2.2] — Unreleased

### Added

- network validation: strict IPv4 (four 0-255 octets), IPv6 via python3
  `ipaddress` with a pure-shell RFC 4291 fallback, `network_validate_ip`,
  format-only `network_validate_domain`, `network_validate_host`
- route utilities: `network_default_interface_v4/v6` and
  `network_primary_ipv4/v6` from `ip route get`, with re-validation of the
  extracted source address; `network_has_ipv4/v6`
- public IP: `network_public_ipv4/v6` with a timed (connect 3s / total 5s)
  3-provider fallback (Cloudflare trace, ipify, icanhazip), forced `-4`/`-6`,
  and re-validation of every provider response
- DNS: `network_resolve_domain` (getent → nslookup, dedup, family filter)
- connectivity: `network_tcp_connect` (nc → timeout + /dev/tcp) with
  host/port/timeout validation
- port inspection: `port_validate`, `port_is_listening`, `port_is_free`,
  `port_process`, `port_require_free`, `port_random` backed by `ss` (netstat
  fallback) with exact port matching, TCP/UDP separation, and fail-closed
  behaviour when inspection itself fails
- per-module test suites: `tests/network.sh`, `tests/port.sh` (mocked
  ip/curl/getent/nc/ss — no real network or host socket state needed)

### Changed

- version: 0.2.1 → 0.2.2
- README requirements now list `iproute2` (`ip`, `ss`) and `curl`; `dig` is
  never required (getent preferred, nslookup fallback)

## [0.2.1] — Unreleased

### Fixed

- service name validation: first character must be alphanumeric, so `.` and
  `..` (and `.foo`, `../xray`, `/path`) are rejected — no path-traversal
  through `/etc/init.d/..`
- OpenRC `service_is_enabled` uses exact first-field matching (awk) instead
  of regex `grep -w`, so names containing `.`/`-` match exactly
- `service_logs` validates the line count (integer 1–10000); rejects `0`,
  negatives, non-numeric, fractional, and explicit-empty values
- package API (`package_install`/`package_remove`/`package_update_index`)
  now require root and reject zero package arguments before touching anything
- `system_os_release_value` handles both `"value"` and `'value'` quoting
- `ID_LIKE` tokens are scanned in their original order (e.g. `ubuntu debian`
  → `ubuntu`)

### Changed

- service write-op tests are decoupled from the real EUID via
  `mock_root`/`mock_non_root` (CI / non-root hosts can run the full suite)
- package-manager mapping extracted to the pure `_system_package_manager_for_distro`
- version: 0.2.0 → 0.2.1

## [0.2.0] — Unreleased

### Added

- `system.sh`: canonical architecture tokens (`amd64`/`arm64`/`armv7`/`386`)
  with unsupported-architecture rejection
- `system.sh`: distro detection from `/etc/os-release` (`system_distro`,
  `system_distro_id`, `system_version`), init detection (`system_init` for
  systemd/OpenRC), hostname detection
- `system.sh`: distro-driven package manager mapping and explicit-only
  `package_install` / `package_remove` / `package_update_index`
- `service.sh`: unified service API over systemd and OpenRC
  (`service_exists`, `service_start`, `service_stop`, `service_restart`,
  `service_enable`, `service_disable`, `service_is_active`,
  `service_is_enabled`, `service_logs`) with root enforcement on write ops
- Xray/sing-box engine service methods (`start`/`stop`/`restart`/`enable`/
  `disable`/`is_active`) now delegate to the shared `service_*` API
- per-module test suites: `tests/system.sh`, `tests/service.sh`

### Changed

- version: 0.1.2 → 0.2.0

## [0.1.2] — Unreleased

### Fixed
- installer transaction-level rollback: lib + binary + symlink are preserved
  until the final commit and restored together on any failure
- first-install failure cleanup: no partial binary/lib/symlink is left behind
- upgrade rollback restoration: old binary, lib, symlink, and metadata are
  restored byte-for-byte after a failed upgrade
- symlink rollback: pre-install symlink target is recorded and restored
- installer smoke-test path typo (trailing `}` in `PROXYCTL_LIB`)
- rollback failure-injection coverage via `PROXYCTL_TEST_FAIL_AT`
- transaction root permission invariant: `transaction_begin` enforces mode 700
  independently of the installer
- installer commit marker is set before best-effort old-backup cleanup
  (`_INSTALL_COMMITTED=1` precedes any `*.old` removal)
- old-backup cleanup failure no longer triggers rollback (best-effort warning,
  install still exits 0)
- installer refuses to overwrite a non-symlink `/usr/local/bin/proxyctl`
  (regular file or directory) before any swap; broken symlinks are replaced

### Changed
- installer supports test-only `PROXYCTL_INSTALL_ROOT` override (production
  behaviour unchanged)
- installer rollback handled by a single EXIT trap (`_cleanup_on_exit`)
- production metadata allowlist no longer includes test-only keys
  (`test_key`, `test_obj` removed)
- version: 0.1.1 → 0.1.2

## [0.1.1] — Unreleased

### Security
- reject unsafe metadata keys via allowlist validation (`metadata_validate_key`)
- reject transaction path traversal with strict label/ID/stage name validation
- validate transaction IDs against known ProxyCTL format (`tx_<ts>_<rand>_<label>`)
- harden metadata atomic writes (same-filesystem temp file, validate before mv)
- add `transaction_validate_label`, `transaction_validate_id`, `transaction_validate_stage_name`
- canonical path resolution for all transaction safety checks (`realpath` or `cd+pwd -P`)
- transaction directory permissions set to 700

### Fixed
- transaction safety smoke test now checks real exit codes (not `|| true`)
- installer lib rollback: stages lib.new, validates, swaps atomically, rolls back on failure
- installer binary rollback: stages binary.new, validates, swaps atomically, rolls back on failure
- installer no longer maintains a second metadata schema fallback — uses `internal-init` exclusively
- `internal-init` validation now fails on error (removed `|| true`)
- Bash requirement corrected from 3.2+ to 4.0+ (code uses `${value,,}`)
- all fail-open stubs converted to fail-closed: `backup_create`, `backup_restore`, `bbr_enable`,
  `cert_acme_issue`, `cert_generate_self`, `cert_list`, `backup_list`, `bbr_status`,
  `engine_xray_logs`, `engine_singbox_logs`
- data directory permissions: `/var/lib/proxyctl` 700, `/etc/proxyctl/certs` 700,
  `/var/backups/proxyctl` 700
- add `require_runtime_dependencies` with Bash 4.0+ check
- add `transaction_root()` as canonical source for transaction root path

### Changed
- version: 0.1.0 → 0.1.1
- README: corrected Bash requirement, added security section, updated phase description
- `metadata_validate` uses `jq empty` for JSON validity check
- `metadata_init` is the single source of truth for metadata schema

## [0.1.0] — Unreleased

### Added

- 3-way LIB_DIR resolution (DEV_LIB → sibling lib/ → installed path)
- `engine_validate_registration()` for automated API completeness checks
- `apply_candidate()` interface (fail-closed stub)
- `metadata_set_string()` and `metadata_set_json()` with `jq --arg` / `jq --argjson`
- `transaction_dir()` helper and path-safety guard `_transaction_safe_path()`
- `internal-init` CLI command for post-install metadata initialisation
- `/usr/local/bin/proxyctl` symlink in installer
- Non-TTY guards on interactive UI functions
- `chmod 600` enforcement on `meta.json`

### Changed

- Version: `1.0.0` → `0.1.0`
- UI primitives return values via `printf -v` (variable name as first argument)
- `metadata_validate` now requires `jq` (was optional)
- `metadata_set` replaced by `metadata_set_string` and `metadata_set_json`
- `transaction_begin` includes `$RANDOM` in tx_id for uniqueness
- Transaction functions accept `tx_id` (not raw directory path)
- `menu.sh` uses only `choose`/`pause` UI primitives — no direct `read`

### Fixed

- Installed LIB_DIR resolution: no longer assumes `lib/` next to binary
- UI no longer mixes menu rendering and return values on stdout
- Fail-closed stubs: `validate`, `port_is_free`, `network_check_port`,
  `apply_candidate`, `network_public_ipv4/6` all return non-zero
- `install.sh` atomic library replacement (temp → mv, not `rm -rf` + `cp`)
- Smoke test exit-code handling: `run_proxyctl` preserves real exit status

### Security

- `transaction_commit`/`rollback` validate paths are inside transactions root
- `metadata_set_*` uses `jq --arg` / `jq --argjson` — no dynamic jq injection
- Temporary metadata files use `umask 077`
