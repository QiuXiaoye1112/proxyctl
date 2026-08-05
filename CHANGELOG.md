# Changelog

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
