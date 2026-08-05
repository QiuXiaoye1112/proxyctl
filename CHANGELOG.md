# Changelog

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
- `metadata_set_string()` and `metadata_set_json()` with `jq --arg` / `--argjson`
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
- `metadata_set_*` uses `jq --arg` / `--argjson` — no dynamic jq injection
- Temporary metadata files use `umask 077`
