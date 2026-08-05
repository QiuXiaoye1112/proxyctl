# Changelog

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
